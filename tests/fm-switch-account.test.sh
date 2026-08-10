#!/usr/bin/env bash
# tests/fm-switch-account.test.sh - contract tests for bin/fm-switch-account.sh,
# the helper that broadcasts jcode's per-session `/account claude switch <label>`
# into every live worker pane.
#
# The whole reason these tests exist is the no-args pane auto-discovery path.
# That path used to fail SILENTLY: under `set -euo pipefail`, a state/*.meta with
# no `window=` line (for example a service sidecar such as state/.lavish-lan.meta,
# which records only port=/bind=/target=) makes the discovery grep exit non-zero,
# that status propagates through the command substitution, and set -e kills the
# whole script with exit 1 before it can print anything or reach a real target.
# A related bug wrote grep/herdr stderr to LITERAL files (2>e_find, 2>e_meta, ...)
# instead of suppressing it, leaving stray e_* files behind.
#
# These tests pin the fixed behavior with everything injected: a fake repo layout
# (bin/ + state/) and a fake herdr on PATH, so no assertion depends on any real
# pane, task, or account.
#
#   - no-args discovery lists every windowed pane and SKIPS a windowless meta   (the bug)
#   - discovery exits 0 in that case, not 1                                     (the bug)
#   - the default: session prefix is stripped from discovered pane ids          (id shape)
#   - explicit pane-id args bypass discovery and are used verbatim              (explicit)
#   - no stray e_* files are left in the repo root                              (redirect bug)
#   - a state/ with zero windowed metas reports "no target panes" and exits 1   (empty)
#   - a missing label argument exits 2 with usage                              (arg guard)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SRC="$ROOT/bin/fm-switch-account.sh"
assert_present "$SRC" "bin/fm-switch-account.sh is missing"
[ -x "$SRC" ] || fail "bin/fm-switch-account.sh must be executable"

TMPROOT=$(fm_test_tmproot fm-switch-account)

# Build a fake repo layout the script will cd into: bin/<script> + state/*.meta.
# The script resolves its root as dirname/.. of its own path, so placing it in
# REPO/bin makes REPO/state the discovery dir.
REPO="$TMPROOT/repo"
mkdir -p "$REPO/bin" "$REPO/state" "$TMPROOT/fakebin"
cp "$SRC" "$REPO/bin/fm-switch-account.sh"
chmod +x "$REPO/bin/fm-switch-account.sh"

# Fake herdr: record every invocation, print a stub line, always succeed. The
# `read` subcommand emits a line so the confirmation tail has something to show.
cat > "$TMPROOT/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf 'HERDR %s\n' "$*" >> "$HERDR_LOG"
case "${1:-} ${2:-}" in
  "pane read") echo "stub pane content" ;;
esac
exit 0
SH
chmod +x "$TMPROOT/fakebin/herdr"
export HERDR_LOG="$TMPROOT/herdr.log"
: > "$HERDR_LOG"

# Skip the real inter-keystroke and confirmation waits so the suite runs fast.
export FM_SWITCH_SEND_SETTLE=0 FM_SWITCH_CONFIRM_WAIT=0

PATH="$TMPROOT/fakebin:$PATH"

run_switch() {  # <args...> -> sets OUT / RC
  : > "$HERDR_LOG"
  OUT=$(cd "$REPO" && ./bin/fm-switch-account.sh "$@" 2>&1)
  RC=$?
}

# --- case 1: no-args discovery skips a windowless meta and lists the rest -----
#
# Two windowed task metas plus one windowless sidecar meta (the exact shape that
# used to kill the script). Discovery must list the two panes, skip the sidecar,
# and exit 0.
fm_write_meta "$REPO/state/alpha.meta" "window=default:w1:p2" "project=alpha"
fm_write_meta "$REPO/state/bravo.meta" "window=default:w2:p3" "project=bravo"
fm_write_meta "$REPO/state/.lavish-lan.meta" "port=4388" "bind=0.0.0.0" "target=4387"

run_switch claude-2
expect_code 0 "$RC" "no-args discovery must exit 0 with a windowless meta present"
assert_contains "$OUT" "in 2 pane(s)" "discovery must find exactly the two windowed panes"
assert_contains "$OUT" "w1:p2" "discovery must include the first windowed pane"
assert_contains "$OUT" "w2:p3" "discovery must include the second windowed pane"
assert_not_contains "$OUT" "no target panes" "discovery must not report an empty target set"
# The default: session prefix must be stripped from the discovered id.
assert_not_contains "$OUT" "default:w1:p2" "the default: prefix must be stripped from pane ids"
# The switch command must have been sent to both panes.
assert_grep "pane send-text w1:p2 /account claude switch claude-2" "$HERDR_LOG" "switch command must reach the first pane"
assert_grep "pane send-text w2:p3 /account claude switch claude-2" "$HERDR_LOG" "switch command must reach the second pane"
pass "no-args discovery lists windowed panes and skips a windowless meta"

# --- case 2: no stray e_* files left in the repo root -------------------------
#
# The old redirect bug wrote stderr to literal files e_find/e_meta/e_send/e_key/
# e_read. After a full run the repo root must contain none of them.
strays=""
for f in "$REPO"/e_*; do
  [ -e "$f" ] && strays="$strays $(basename "$f")"
done
[ -z "$strays" ] || fail "run left stray stderr files in repo root:$strays"
pass "no stray e_* stderr files are created"

# --- case 3: explicit pane-id args bypass discovery ---------------------------
#
# With explicit args the state dir must be ignored entirely: only the given ids
# are targeted, verbatim (no default: stripping is needed since caller controls them).
run_switch claude-4 pX:p9 pY:p1
expect_code 0 "$RC" "explicit pane args must exit 0"
assert_contains "$OUT" "in 2 pane(s)" "explicit args must target exactly the given panes"
assert_grep "pane send-text pX:p9 /account claude switch claude-4" "$HERDR_LOG" "explicit pane pX:p9 must be targeted"
assert_grep "pane send-text pY:p1 /account claude switch claude-4" "$HERDR_LOG" "explicit pane pY:p1 must be targeted"
assert_no_grep "w1:p2" "$HERDR_LOG" "explicit args must not fall back to discovered panes"
pass "explicit pane-id args bypass discovery and are used verbatim"

# --- case 4: a state/ with zero windowed metas reports no targets and exits 1 -
EMPTY="$TMPROOT/empty"
mkdir -p "$EMPTY/bin" "$EMPTY/state"
cp "$SRC" "$EMPTY/bin/fm-switch-account.sh"
chmod +x "$EMPTY/bin/fm-switch-account.sh"
fm_write_meta "$EMPTY/state/.lavish-lan.meta" "port=4388" "bind=0.0.0.0"
OUT=$(cd "$EMPTY" && ./bin/fm-switch-account.sh claude-2 2>&1); RC=$?
expect_code 1 "$RC" "a state dir with no windowed metas must exit 1"
assert_contains "$OUT" "no target panes found" "empty discovery must report no target panes"
pass "no windowed metas reports no targets and exits 1"

# --- case 5: a missing label exits 2 with usage -------------------------------
OUT=$(cd "$REPO" && ./bin/fm-switch-account.sh 2>&1); RC=$?
expect_code 2 "$RC" "a missing label must exit 2"
assert_contains "$OUT" "usage:" "a missing label must print usage"
pass "a missing label argument exits 2 with usage"

pass "fm-switch-account.sh: all checks passed"
