#!/usr/bin/env bash
# tests/fm-watch-tripwire-rotation.test.sh - the watcher's live-tripwire account
# rotation glue (bin/fm-watch.sh), the account-switch orchestrator's second
# firstmate integration point (ADR 0031, Phase 1).
#
# On a live limit-error (tripwire) wake for a jcode/Claude worker, the watcher
# calls the orchestrator (bin/fm-account-orchestrator.sh -> quota-axi
# decide+switch) to rotate the fleet onto the next non-exhausted account WITHOUT
# captain intervention. This suite pins the watcher-side glue directly by
# sourcing bin/fm-watch.sh (its source guard returns before the lock/loop, so
# only the functions load) and driving:
#
#   - status_is_tripwire: recognizes a real limit-error status line, and does NOT
#     fire on a benign working line.
#   - orchestrator_rotate_on_tripwire: invokes the orchestrator's `rotate` for a
#     jcode worker, is idempotent within the cooldown window, and is scoped to
#     jcode (a non-jcode worker never rotates through this path).
#
# The orchestrator is replaced with a fake script recording every invocation, so
# no assertion depends on a real quota-axi. This proves the watcher CALLS the
# orchestrator on a tripwire; the orchestrator's own decide+switch contract is
# covered by tests/fm-account-orchestrator.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
assert_present "$WATCH" "bin/fm-watch.sh is missing"

TMP=$(fm_test_tmproot fm-watch-tripwire)
STATE="$TMP/state"
FAKEBIN="$TMP/fakebin"
mkdir -p "$STATE" "$FAKEBIN"

# Fake orchestrator: `supports` succeeds, `rotate` logs and succeeds,
# `recognize-tripwire` uses the same narrow catalog the real one does (so
# status_is_tripwire behaves), and every call is recorded.
ORCH_LOG="$TMP/orch.log"
: > "$ORCH_LOG"
cat > "$FAKEBIN/fm-account-orchestrator.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ORCH_LOG"
case "\${1:-}" in
  supports) exit 0 ;;
  rotate) echo '{"schemaVersion":1,"outcomes":[]}'; exit 0 ;;
  recognize-tripwire)
    shift
    printf '%s' "\$*" | grep -qiE 'rate[ _-]?limit|usage[ _-]?limit|429 too many requests|limit reached' && exit 0
    exit 1
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$FAKEBIN/fm-account-orchestrator.sh"

# Source the watcher with SCRIPT_DIR pointed at the fakebin so its
# "$SCRIPT_DIR/fm-account-orchestrator.sh" calls hit the fake. The real backend
# lib is still needed for fm_meta_get/fm_backend_of_meta, so copy those in too.
cp "$ROOT/bin/fm-backend.sh" "$FAKEBIN/fm-backend.sh" 2>/dev/null || true

# Drive the watcher functions in a subshell: source it (guard returns before the
# loop), override SCRIPT_DIR and STATE, then call the functions under test.
run_case() {  # <bash-body> -> OUT
  OUT=$(FM_STATE_OVERRIDE="$STATE" bash -c '
    . "'"$WATCH"'" >/dev/null 2>&1
    SCRIPT_DIR="'"$FAKEBIN"'"
    STATE="'"$STATE"'"
    '"$1"'
  ' 2>&1)
}

# --- status_is_tripwire recognizes a real limit error ------------------------
run_case 'if status_is_tripwire "blocked: 429 rate_limit reached, resets 5pm"; then echo TRIP; else echo NO; fi'
assert_contains "$OUT" "TRIP" "status_is_tripwire must recognize a live limit-error status line"
pass "status_is_tripwire recognizes a real jcode/Claude limit-error status line"

run_case 'if status_is_tripwire "working: building the project"; then echo TRIP; else echo NO; fi'
assert_contains "$OUT" "NO" "status_is_tripwire must not fire on a benign working line"
pass "status_is_tripwire does not fire on a benign working line"

# --- orchestrator_rotate_on_tripwire invokes rotate for a jcode worker --------
fm_write_meta "$STATE/jtask.meta" "harness=jcode" "window=default:w1:p2" "project=demo"
: > "$ORCH_LOG"
run_case 'orchestrator_rotate_on_tripwire jtask'
assert_grep "rotate" "$ORCH_LOG" "the watcher must invoke the orchestrator rotate for a jcode worker on a tripwire"
pass "orchestrator_rotate_on_tripwire invokes the orchestrator rotate for a jcode worker"

# --- idempotent within the cooldown window -----------------------------------
# Clear the per-task marker the prior case left so this case starts fresh, then
# call twice in ONE subshell so the marker persists between the two calls.
rm -f "$STATE"/.orch-rotated-*
: > "$ORCH_LOG"
run_case 'orchestrator_rotate_on_tripwire jtask; orchestrator_rotate_on_tripwire jtask'
rotates=$(grep -c '^rotate' "$ORCH_LOG" || true)
[ "$rotates" = 1 ] || fail "rotation must be idempotent within the cooldown window, got $rotates rotate calls"
pass "orchestrator_rotate_on_tripwire is idempotent within the cooldown window (one rotate for a burst)"

# --- scoped to jcode: a non-jcode worker never rotates -----------------------
fm_write_meta "$STATE/ctask.meta" "harness=claude" "window=default:w9:p9" "project=demo"
: > "$ORCH_LOG"
run_case 'orchestrator_rotate_on_tripwire ctask'
assert_no_grep "rotate" "$ORCH_LOG" "a non-jcode worker must never rotate through the jcode account path"
pass "orchestrator_rotate_on_tripwire is scoped to jcode (a claude-harness worker never rotates)"

pass "fm-watch-tripwire-rotation.test.sh: all checks passed"
