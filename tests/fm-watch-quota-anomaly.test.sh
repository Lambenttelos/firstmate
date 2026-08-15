#!/usr/bin/env bash
# tests/fm-watch-quota-anomaly.test.sh - Visibility Gap-2, the watcher's hot-path
# 429/rate-limit anomaly scan (bin/fm-watch.sh quota_anomaly_scan). Design:
# data/design-visibility-improvements/report.md "Gap 2".
#
# Contract pinned here:
#   1. A FIRST 429 on a pane writes count_429/last_429_ts telemetry and does NOT
#      wake (a single overloaded-429 self-heals).
#   2. A 429 RATE (count crosses FM_QUOTA_ANOMALY_RATE) emits a proactive
#      `check: quota-anomaly <task> <account> <count>` wake.
#   3. It reuses the SHARED tripwire regex the orchestrator owns
#      (FM_ORCH_TRIPWIRE_RE_DEFAULT), not a forked catalog.
#   4. It adds NO new backend capture to the fast loop: the scan takes the
#      already-captured tail40 as an argument and its body calls no
#      fm_backend_capture, so the loop keeps exactly one capture per window.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
assert_present "$WATCH" "bin/fm-watch.sh is missing"

# fm_meta_get reads the key=value telemetry file the scan writes.
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

TMP=$(fm_test_tmproot fm-watch-quota-anomaly)
STATE="$TMP/state"
mkdir -p "$STATE"

# Drive quota_anomaly_scan in a subshell: source the watcher (its guard returns
# before the lock/loop, loading only functions and libs), override STATE and the
# wake queue path, set a low rate threshold, then call the function. wake() exits
# 0 after printing its reason, so a rate case ends the subshell with the reason
# on stdout; a telemetry-only case returns and we echo a sentinel.
run_scan() {  # <window> <task> <tail-text>  -> OUT (+ exit status)
  OUT=$(FM_STATE_OVERRIDE="$STATE" FM_WAKE_QUEUE="$STATE/.wake-queue" \
        FM_WAKE_QUEUE_LOCK="$STATE/.wake-queue.lock" \
        FM_QUOTA_ANOMALY_RATE=3 bash -c '
    . "'"$WATCH"'" >/dev/null 2>&1
    STATE="'"$STATE"'"
    quota_anomaly_scan "'"$1"'" "'"$2"'" "'"$3"'" "hash-'"$RANDOM$RANDOM"'"
    echo "NOWAKE"
  ' 2>&1)
}

W="default:w1:p2"
TASK="qtask"

# --- (1) first 429: telemetry written, NO wake -------------------------------
run_scan "$W" "$TASK" "Error: 429 too many requests"
assert_contains "$OUT" "NOWAKE" "a first single 429 must NOT wake (telemetry only)"
case "$OUT" in *quota-anomaly*) fail "a first single 429 must not emit a quota-anomaly wake" ;; esac
[ "$(fm_meta_get "$STATE/$TASK.telemetry" count_429)" = 1 ] \
  || fail "first 429 must write count_429=1"
grep -q '^last_429_ts=' "$STATE/$TASK.telemetry" \
  || fail "first 429 must write last_429_ts"
pass "first 429 writes count_429/last_429_ts telemetry without a wake"

# The seen-marker dedup is keyed by tail hash; run_scan uses a fresh random hash
# each call, so repeated calls simulate distinct 429 bursts and the count climbs.
# --- (2) rate threshold: proactive quota-anomaly wake ------------------------
# count is 1 from case (1). Two more distinct bursts reach 3 (the threshold).
run_scan "$W" "$TASK" "429 too many requests (burst 2)"
assert_contains "$OUT" "NOWAKE" "second 429 (count 2) is still under the rate threshold, no wake"
run_scan "$W" "$TASK" "rate_limit_error (burst 3)"
assert_contains "$OUT" "check: quota-anomaly $TASK" "count reaching the rate threshold must emit check: quota-anomaly"
assert_contains "$OUT" " 3" "the anomaly wake must carry the count (3)"
pass "a 429 rate crossing the threshold emits a proactive check: quota-anomaly wake"

# account label appears in the wake when telemetry carries it -----------------
rm -rf "$STATE"; mkdir -p "$STATE"
printf 'account=claude-2\n' > "$STATE/$TASK.telemetry"
run_scan "$W" "$TASK" "429 too many requests A"
run_scan "$W" "$TASK" "429 too many requests B"
run_scan "$W" "$TASK" "429 too many requests C"
assert_contains "$OUT" "check: quota-anomaly $TASK claude-2 3" "the anomaly wake must name the pinned account"
pass "the anomaly wake names the account label from telemetry"

# --- (3) reuses the shared orchestrator regex, not a fork --------------------
# The watcher must derive its regex from FM_ORCH_TRIPWIRE_RE_DEFAULT in
# bin/fm-account-orchestrator.sh, not restate the pattern inline.
assert_grep "FM_ORCH_TRIPWIRE_RE_DEFAULT" "$WATCH" \
  "fm-watch.sh must reference the orchestrator's tripwire constant, not fork a catalog"
if grep -qE "rate\[ _-\]\?limit\|usage\[ _-\]\?limit\|429 too many requests" "$WATCH"; then
  fail "fm-watch.sh must NOT restate the tripwire regex pattern (single-owner rule)"
fi
pass "the 429 scan reuses the orchestrator's tripwire catalog without forking it"

# --- (4) ZERO new backend capture in the fast loop ---------------------------
# The scan function body must contain no fm_backend_capture call: it consumes the
# tail40 the loop already captured. And the stale loop must still have exactly one
# fm_backend_capture (the pre-existing per-window capture), so the hot path added
# no backend call.
scan_body=$(awk '/^quota_anomaly_scan\(\)/{f=1} f{print} f&&/^}/{exit}' "$WATCH")
if printf '%s' "$scan_body" | grep -q 'fm_backend_capture'; then
  fail "quota_anomaly_scan must add NO fm_backend_capture (it reuses the passed tail40)"
fi
# shellcheck disable=SC2016  # literal grep pattern, no expansion intended.
caps=$(grep -c 'fm_backend_capture "\$(window_backend' "$WATCH" || true)
[ "$caps" = 1 ] || fail "the stale loop must keep exactly one per-window fm_backend_capture, found $caps"
pass "quota_anomaly_scan adds zero backend captures; the loop keeps its single capture"

pass "fm-watch-quota-anomaly.test.sh: all checks passed"
