#!/usr/bin/env bash
# tests/fm-watch-fleet-quota.test.sh - Visibility Gap-1, the watcher's slow-poll
# account/quota producer (bin/fm-watch.sh fleet_quota_sweep). Design:
# data/design-visibility-improvements/report.md "Gap 1".
#
# Contract pinned here:
#   1. quota-axi --json runs ONCE per sweep, never per pane: N live tasks produce
#      exactly one quota-axi invocation, and a sweep over more panes still runs
#      it once.
#   2. The fan-out writes quota_pct/quota_window/quota_reset_ts onto each live
#      task's state/<id>.telemetry from the SINGLE quota-axi reading, using the
#      claude provider's relevant general windows (five_hour/seven_day), never a
#      per-pane reading.
#   3. Fail-soft: an absent/unreadable quota-axi yields NO telemetry keys (a
#      gap, never a zero) and no error.
#   4. The producer is passive: it never wakes, never writes a check: line, and
#      prints nothing.
#   5. The supervised pane set matches the watcher's own live-window list
#      (state/<id>.meta minus supervise=off), so an unsupervised griller pane is
#      never written.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
assert_present "$WATCH" "bin/fm-watch.sh is missing"

command -v jq >/dev/null 2>&1 || { echo "1..0 # SKIP jq required"; exit 0; }

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

TMP=$(fm_test_tmproot fm-watch-fleet-quota)
STATE="$TMP/state"
FAKEBIN="$TMP/fakebin"
mkdir -p "$STATE" "$FAKEBIN"

# Fake quota-axi: logs every invocation (QUOTA_LOG) and emits a fixture --json
# whose claude provider's relevant windows are five_hour 40% and seven_day 8%
# (min = 8 from seven_day) plus distracting non-general windows (a model window
# and a codex provider) that must NOT drive the pct. The seven_day window carries
# resetsAt so quota_reset_ts is exercised. The outer heredoc is unquoted so
# QUOTA_LOG expands to the real log path at build time.
QUOTA_LOG="$TMP/quota.log"
: > "$QUOTA_LOG"
cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$QUOTA_LOG"
cat <<'JSON'
{"schemaVersion":2,"providers":[
  {"provider":"claude","state":{"status":"fresh"},"windows":[
    {"id":"five_hour","kind":"session","percentRemaining":40,"resetsAt":"2026-08-20T18:00:00Z"},
    {"id":"seven_day","kind":"weekly","percentRemaining":8,"resetsAt":"2026-08-24T00:00:00Z"},
    {"id":"model:fable","label":"Fable week","kind":"model","percentRemaining":5}
  ]},
  {"provider":"codex","state":{"status":"fresh"},"windows":[
    {"id":"five_hour","kind":"session","percentRemaining":90}
  ]}
]}
JSON
exit 0
SH
chmod +x "$FAKEBIN/quota-axi"

# Expected reset epoch for 2026-08-24T00:00:00Z, portable (macOS -j, GNU -d).
REQ_RESET=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' '2026-08-24T00:00:00Z' +%s 2>/dev/null \
  || date -u -d '2026-08-24T00:00:00Z' +%s 2>/dev/null)
[ -n "$REQ_RESET" ] || fail "test could not compute the expected reset epoch"

# Drive fleet_quota_sweep in a subshell: source the watcher (its guard returns
# before the lock/loop, loading only functions and libs), override STATE and the
# quota-axi command, then call the function. The sweep is passive: it never wakes,
# so the subshell always returns and echoes the NOQUOTA sentinel.
run_sweep() {  # <quota-axi-cmd> -> OUT
  OUT=$(FM_STATE_OVERRIDE="$STATE" FM_WAKE_QUEUE="$STATE/.wake-queue" \
        FM_WAKE_QUEUE_LOCK="$STATE/.wake-queue.lock" \
        FM_DISPATCH_QUOTA_AXI="$1" bash -c '
    . "'"$WATCH"'" >/dev/null 2>&1
    STATE="'"$STATE"'"
    fleet_quota_sweep
    echo "NOQUOTA"
  ' 2>&1)
}

new_state() {
  rm -rf "$STATE"; mkdir -p "$STATE"
  fm_write_meta "$STATE/t1.meta" "harness=jcode" "window=fm-sess:w1" "project=demo"
  fm_write_meta "$STATE/t2.meta" "harness=jcode" "window=fm-sess:w2" "project=demo"
  fm_write_meta "$STATE/t3.meta" "harness=jcode" "window=fm-sess:w3" "project=demo"
}

# --- (1) one quota-axi invocation fans out to every live task -----------------
new_state
: > "$QUOTA_LOG"
run_sweep "$FAKEBIN/quota-axi"
assert_contains "$OUT" "NOQUOTA" "fleet_quota_sweep must return silently (passive producer)"
[ "$(wc -l < "$QUOTA_LOG")" = 1 ] \
  || fail "quota-axi must run exactly ONCE for a 3-pane fleet, ran $(wc -l < "$QUOTA_LOG") times: $(cat "$QUOTA_LOG")"
for t in t1 t2 t3; do
  [ "$(fm_meta_get "$STATE/$t.telemetry" quota_pct)" = 8 ] \
    || fail "$t must get quota_pct=8 (min of claude five_hour/seven_day), got: $(fm_meta_get "$STATE/$t.telemetry" quota_pct)"
  [ "$(fm_meta_get "$STATE/$t.telemetry" quota_window)" = seven_day ] \
    || fail "$t must get quota_window=seven_day (the window that drove the pct)"
  [ "$(fm_meta_get "$STATE/$t.telemetry" quota_reset_ts)" = "$REQ_RESET" ] \
    || fail "$t must get quota_reset_ts=$REQ_RESET, got: $(fm_meta_get "$STATE/$t.telemetry" quota_reset_ts)"
done
pass "one quota-axi call fans quota_pct/quota_window/quota_reset_ts onto every live pane"

# --- (2) still one invocation when the fleet grows (never per pane) -----------
: > "$QUOTA_LOG"
fm_write_meta "$STATE/t4.meta" "harness=jcode" "window=fm-sess:w4" "project=demo"
fm_write_meta "$STATE/t5.meta" "harness=jcode" "window=fm-sess:w5" "project=demo"
run_sweep "$FAKEBIN/quota-axi"
[ "$(wc -l < "$QUOTA_LOG")" = 1 ] \
  || fail "a 5-pane fleet still runs quota-axi exactly once, ran $(wc -l < "$QUOTA_LOG") times"
[ "$(fm_meta_get "$STATE/t5.telemetry" quota_pct)" = 8 ] || fail "new pane t5 must be fanned too"
pass "quota-axi is invoked once per sweep interval, never per pane"

# --- (3) a window that drives pct can vary; resetsAt is per driving window -----
# fixture with five_hour lower: the pct must follow the min window's owner and
# carry that window's reset.
REQ_RESET5=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' '2026-08-20T18:00:00Z' +%s 2>/dev/null \
  || date -u -d '2026-08-20T18:00:00Z' +%s 2>/dev/null)
cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$QUOTA_LOG"
cat <<'JSON'
{"schemaVersion":2,"providers":[{"provider":"claude","state":{"status":"fresh"},"windows":[
  {"id":"five_hour","kind":"session","percentRemaining":12,"resetsAt":"2026-08-20T18:00:00Z"},
  {"id":"seven_day","kind":"weekly","percentRemaining":60}
]}]}
JSON
exit 0
SH
chmod +x "$FAKEBIN/quota-axi"
new_state
: > "$QUOTA_LOG"
run_sweep "$FAKEBIN/quota-axi"
[ "$(fm_meta_get "$STATE/t1.telemetry" quota_pct)" = 12 ] \
  || fail "min window (five_hour 12%) must drive quota_pct, got $(fm_meta_get "$STATE/t1.telemetry" quota_pct)"
[ "$(fm_meta_get "$STATE/t1.telemetry" quota_window)" = five_hour ] \
  || fail "quota_window must name the driving window (five_hour)"
[ "$(fm_meta_get "$STATE/t1.telemetry" quota_reset_ts)" = "$REQ_RESET5" ] \
  || fail "quota_reset_ts must be the driving window's resetsAt, got $(fm_meta_get "$STATE/t1.telemetry" quota_reset_ts)"
pass "quota_pct/quota_window/quota_reset_ts follow the min general window and its reset"

# A fixture with NO resetsAt anywhere must leave quota_reset_ts absent.
cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$QUOTA_LOG"
cat <<'JSON'
{"schemaVersion":2,"providers":[{"provider":"claude","state":{"status":"fresh"},"windows":[
  {"id":"five_hour","kind":"session","percentRemaining":30},
  {"id":"seven_day","kind":"weekly","percentRemaining":55}
]}]}
JSON
exit 0
SH
chmod +x "$FAKEBIN/quota-axi"
new_state
: > "$QUOTA_LOG"
run_sweep "$FAKEBIN/quota-axi"
[ "$(fm_meta_get "$STATE/t1.telemetry" quota_pct)" = 30 ] || fail "no-resetsAt fixture must still fan quota_pct"
[ -z "$(fm_meta_get "$STATE/t1.telemetry" quota_reset_ts)" ] \
  || fail "no resetsAt in the quota payload must leave quota_reset_ts absent (gap, not zero)"
pass "absent resetsAt leaves quota_reset_ts absent while quota_pct/quota_window still fan"

# --- (4) fail-soft: absent quota-axi leaves NO keys, no error ----------------
new_state
: > "$QUOTA_LOG"
run_sweep "$TMP/no-such-quota-axi"
assert_contains "$OUT" "NOQUOTA" "fail-soft sweep must still return silently"
for t in t1 t2 t3; do
  [ -f "$STATE/$t.telemetry" ] || continue
  if [ -n "$(fm_meta_get "$STATE/$t.telemetry" quota_pct)" ]; then
    fail "$t must NOT get quota keys when quota-axi is unavailable (gap, not a value)"
  fi
done
[ "$(wc -l < "$QUOTA_LOG")" = 0 ] || fail "missing quota-axi must not be invoked"
pass "absent quota-axi yields no quota telemetry and no wake (fail-soft, gap never zero)"

# --- (5) supervise=off panes are never written (matches recorded_windows) ----
fm_write_meta "$STATE/g1.meta" "harness=jcode" "window=fm-sess:g1" "project=demo" "supervise=off"
: > "$QUOTA_LOG"
run_sweep "$FAKEBIN/quota-axi"
if grep -rq 'quota_pct' "$STATE/g1.telemetry" 2>/dev/null; then
  fail "an unsupervised (supervise=off) pane must never receive quota telemetry"
fi
[ "$(fm_meta_get "$STATE/t1.telemetry" quota_pct)" = 30 ] || fail "supervised panes still fanned"
pass "fleet_quota_sweep skips supervise=off panes like the watcher's live-window list"

# --- (6) never wakes ---------------------------------------------------------
# A waking sweep would leave a check: line or exit early; assert no wake payload
# and no queued wake record.
new_state
run_sweep "$FAKEBIN/quota-axi"
case "$OUT" in
  *"check:"*) fail "the passive fleet-quota producer must never emit a check: wake: $OUT" ;;
esac
[ ! -e "$STATE/.wake-queue" ] || [ "$(wc -l < "$STATE/.wake-queue")" = 0 ] \
  || fail "the passive producer must not enqueue a wake"
pass "fleet_quota_sweep is passive: no check: payload, no queued wake"

pass "fm-watch-fleet-quota.test.sh: all checks passed"
