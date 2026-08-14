#!/usr/bin/env bash
# tests/fm-account-orchestrator.test.sh - contract tests for
# bin/fm-account-orchestrator.sh, firstmate's thin CALLER of the quota-axi
# account-switch orchestrator (ADR 0031, Phase 1).
#
# These tests assert the four things the ticket's acceptance criteria require of
# the CALLER, without a real installed quota-axi:
#
#   1. The tripwire error catalog (recognize-tripwire) matches the REAL jcode/
#      Claude limit-error strings observed in the merged jcode clone
#      (crates/jcode-provider-anthropic-runtime) and EXCLUDES transient faults
#      (overloaded, 5xx, network drops) so a blip never trips a fleet rotation.
#   2. resolve-account consults `decide` and prints the chosen non-exhausted
#      account when the orchestrator reports the current one exhausted.
#   3. rotate invokes `switch` (the fenced mutation verb) with the observations
#      and shared tripwire store, and passes its versioned result through.
#   4. FAIL-SOFT: an unavailable orchestrator, an old CLI without the verbs, or an
#      erroring decide/switch never blocks the caller - resolve-account keeps the
#      current account (empty stdout) and rotate declines non-zero.
#
# A fake quota-axi (a fakebin shim) emulates the merged decide/switch --json
# contract so the decide+switch path is exercised end to end against a
# contract-faithful stub. The real merged verbs are NOT installed in this
# environment (the installed CLI is the old upstream without decide/switch), so
# this fixture is how the path is covered; the real-CLI gap is named in the
# task report.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SRC="$ROOT/bin/fm-account-orchestrator.sh"
assert_present "$SRC" "bin/fm-account-orchestrator.sh is missing"
[ -x "$SRC" ] || fail "bin/fm-account-orchestrator.sh must be executable"

command -v jq >/dev/null 2>&1 || { echo "1..0 # SKIP jq required" ; exit 0; }

TMP=$(fm_test_tmproot fm-account-orchestrator)
BIN="$TMP/bin"
mkdir -p "$BIN"

# --- fake quota-axi emulating the merged decide/switch --json contract --------
# It advertises decide/switch in --help (so `supports` passes), returns a decide
# DecisionResponse that switches OFF the current account onto claude-2, and a
# switch SwitchResponse. It logs every switch invocation to SWITCH_LOG so the
# test can assert the caller actually invoked the fenced verb.
SWITCH_LOG="$TMP/switch.log"
: > "$SWITCH_LOG"
cat > "$BIN/quota-axi" <<SH
#!/usr/bin/env bash
sub="\${1:-}"
case "\$sub" in
  --help)
    echo "usage: quota-axi [quota|auth|models|validate|decide|switch] [flags]"
    echo "commands[6]:"
    echo "  (none)=quota, auth, models, validate, decide, switch"
    exit 0
    ;;
  --json)
    # Live quota report: claude provider present with usable windows.
    cat <<'JSON'
{"schemaVersion":2,"providers":[{"provider":"claude","state":{"status":"fresh"},"windows":[{"id":"five_hour","kind":"session","percentRemaining":8},{"id":"seven_day","kind":"weekly","percentRemaining":40}]}]}
JSON
    exit 0
    ;;
  decide)
    # A decide DecisionResponse that rotates off the current account onto claude-2.
    cat <<'JSON'
{"schemaVersion":1,"generatedAt":"2026-08-14T00:00:00Z","provider":"claude","harness":"jcode","decisions":[{"scope":"spawn","action":"switch","currentAccount":"claude-1","chosenAccount":"claude-2","reasons":[{"code":"current_reserve_crossed","account":"claude-1"},{"code":"selected_available","account":"claude-2"}]}]}
JSON
    exit 0
    ;;
  switch)
    printf 'switch %s\n' "\$*" >> "$SWITCH_LOG"
    cat <<'JSON'
{"schemaVersion":1,"generatedAt":"2026-08-14T00:00:00Z","provider":"claude","harness":"jcode","dryRun":false,"outcomes":[{"scope":"spawn","action":"switch","currentAccount":"claude-1","chosenAccount":"claude-2","status":"applied","recordedTripwire":{"account":"claude-1","exhaustedUntil":"2026-08-15T00:00:00Z"}}]}
JSON
    exit 0
    ;;
  *)
    echo "unknown: \$sub" >&2
    exit 2
    ;;
esac
SH
chmod +x "$BIN/quota-axi"

# An OLD upstream quota-axi: accepts <verb> --help but routes to the top-level
# quota help (no decide/switch in its command list) and exits 0.
OLDBIN="$TMP/oldbin"
mkdir -p "$OLDBIN"
cat > "$OLDBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
echo "usage: quota-axi [auth] [flags]"
echo "commands[2]:"
echo "  (none)=quota, auth"
exit 0
SH
chmod +x "$OLDBIN/quota-axi"

TRIPWIRES="$TMP/tripwires.json"

run_orch() {  # <FM_DISPATCH_QUOTA_AXI> <args...> -> OUT/RC
  local q=$1; shift
  OUT=$(FM_DISPATCH_QUOTA_AXI="$q" FM_ORCH_TRIPWIRES="$TRIPWIRES" \
        FM_ORCH_NOW="2026-08-14T00:00:00Z" "$SRC" "$@" 2>/dev/null)
  RC=$?
}

# --- 1: the tripwire error catalog -------------------------------------------
for pos in \
  'rate_limit_error' \
  'usage limit reached for the 7-day model window' \
  '429 Too Many Requests' \
  '429 {"type":"rate_limit_error","message":"You have reached your weekly Fable limit"}' \
  'global 5-hour rate limit reached'; do
  if "$SRC" recognize-tripwire "$pos" >/dev/null 2>&1; then :; else
    fail "recognize-tripwire must match real limit error: $pos"
  fi
done
pass "recognize-tripwire matches every real jcode/Claude account-exhaustion limit error"

for neg in \
  '429 overloaded_error: service temporarily overloaded' \
  '503 service unavailable' \
  '500 internal server error' \
  'connection reset by peer' \
  'working: normal progress line'; do
  if "$SRC" recognize-tripwire "$neg" >/dev/null 2>&1; then
    fail "recognize-tripwire must NOT match transient/benign text: $neg"
  fi
done
pass "recognize-tripwire excludes transient faults (overloaded, 5xx, network) and benign lines"

# recognize-tripwire also reads stdin with '-'.
if printf '%s' 'usage_limit' | "$SRC" recognize-tripwire - >/dev/null 2>&1; then
  pass "recognize-tripwire reads stdin with '-'"
else
  fail "recognize-tripwire must read stdin with '-'"
fi

# --- 2: supports capability probe --------------------------------------------
run_orch "$BIN/quota-axi" supports
expect_code 0 "$RC" "supports must pass against a CLI advertising decide+switch"
pass "supports detects the merged decide+switch verbs"

run_orch "$OLDBIN/quota-axi" supports
expect_code 1 "$RC" "supports must fail against the old CLI without decide+switch"
pass "supports fails closed against the old upstream CLI"

# --- 3: resolve-account consults decide --------------------------------------
run_orch "$BIN/quota-axi" resolve-account --current claude-1
expect_code 0 "$RC" "resolve-account must exit 0"
assert_contains "$OUT" "claude-2" "resolve-account must print the account decide chose"
[ "$OUT" = "claude-2" ] || fail "resolve-account must print ONLY the chosen account, got: $OUT"
pass "resolve-account consults decide and prints the chosen non-exhausted account"

# --- 4: rotate invokes switch ------------------------------------------------
: > "$SWITCH_LOG"
run_orch "$BIN/quota-axi" rotate --current claude-1
expect_code 0 "$RC" "rotate must exit 0 when switch succeeds"
assert_grep "switch" "$SWITCH_LOG" "rotate must invoke the quota-axi switch verb"
assert_contains "$OUT" '"schemaVersion"' "rotate must pass switch's versioned result through"
assert_contains "$OUT" 'claude-2' "rotate result must name the chosen account"
# The switch invocation must carry the shared observations and tripwire store so
# an exhausted account actually stays out.
assert_grep "--tripwires" "$SWITCH_LOG" "rotate must pass the shared tripwire store to switch"
assert_grep "--observations" "$SWITCH_LOG" "rotate must pass observations to switch"
pass "rotate invokes the fenced switch verb with the shared observations and tripwire store"

# --- 5: FAIL-SOFT paths ------------------------------------------------------
# Missing quota-axi entirely.
run_orch "$TMP/does-not-exist-quota-axi" resolve-account --current claude-1
expect_code 0 "$RC" "resolve-account must exit 0 when the orchestrator is missing"
[ -z "$OUT" ] || fail "resolve-account must print nothing (keep current) when orchestrator missing, got: $OUT"
pass "resolve-account fails soft (keeps current account) when the orchestrator is unavailable"

# Old CLI without the verbs: keep current, and rotate declines.
run_orch "$OLDBIN/quota-axi" resolve-account --current claude-1
expect_code 0 "$RC" "resolve-account must exit 0 against the old CLI"
[ -z "$OUT" ] || fail "resolve-account must keep current against the old CLI, got: $OUT"
pass "resolve-account fails soft against the old CLI lacking decide/switch"

run_orch "$OLDBIN/quota-axi" rotate --current claude-1
expect_code 1 "$RC" "rotate must decline (non-zero) against the old CLI"
pass "rotate declines fail-soft against the old CLI lacking decide/switch"

# An erroring decide (fake that exits non-zero on decide) keeps current.
ERRBIN="$TMP/errbin"
mkdir -p "$ERRBIN"
cat > "$ERRBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --help) echo "commands[6]: (none)=quota, auth, models, validate, decide, switch"; exit 0 ;;
  --json) echo '{"schemaVersion":2,"providers":[]}'; exit 0 ;;
  decide) echo "boom" >&2; exit 1 ;;
  switch) echo "boom" >&2; exit 1 ;;
  *) exit 2 ;;
esac
SH
chmod +x "$ERRBIN/quota-axi"
run_orch "$ERRBIN/quota-axi" resolve-account --current claude-1
expect_code 0 "$RC" "resolve-account must exit 0 when decide errors"
[ -z "$OUT" ] || fail "resolve-account must keep current when decide errors, got: $OUT"
pass "resolve-account fails soft when decide errors"

run_orch "$ERRBIN/quota-axi" rotate --current claude-1
expect_code 1 "$RC" "rotate must fail non-zero when switch errors, never crash"
pass "rotate fails soft (non-zero, no crash) when switch errors"

pass "fm-account-orchestrator.sh: all checks passed"
