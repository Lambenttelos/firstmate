#!/usr/bin/env bash
# tests/fm-afk-inbox-arm.test.sh - the resilient arm wrapper for the away-mode
# PULL-delivery reader (bin/fm-afk-inbox-arm.sh).
#
# The bare reader (bin/fm-afk-inbox.sh, covered in tests/fm-afk-inbox.test.sh)
# delivers once and exits, so a paneless away home must re-arm it after every
# delivery, and it kept dying silently between re-arms (evidence 2026-07-30,
# ~11.5 hours blind). This wrapper closes that gap two ways: it runs the reader
# RESIDENT (--timeout 0) so it never idle-exits on a quiet home, and it
# self-relaunches the reader on a crash with bounded backoff, escalating a
# durable degraded wake only after a run of rapid failures. It must still pass
# every GENUINE reader outcome - a delivery, an operational failure, a
# do-not-re-arm condition - straight through to firstmate with the reader's own
# stdout and status, because those are firstmate's to see and act on.
set -u

# wake-helpers.sh brings tests/lib.sh plus the wedge-alarm recorder seam, and
# defines TMP_ROOT/ROOT for the suite.
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

ARM="$ROOT/bin/fm-afk-inbox-arm.sh"
OUTBOX_LIB="$ROOT/bin/fm-afk-outbox-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-afk-inbox-arm-tests)

# shellcheck source=bin/fm-afk-outbox-lib.sh
. "$OUTBOX_LIB"

# The daemon prefixes every digest with the sentinel marker before delivery; the
# record carries it through verbatim, so fixtures use the real bytes.
FM_TEST_MARK=$'\xE2\x81\xA3'

make_arm_case() {  # <name> -> state dir
  local name=$1 state
  state="$TMP_ROOT/$name/state"
  mkdir -p "$state"
  printf '%s\n' "$state"
}

enter_away() {  # <state>
  date +%s > "$1/.afk"
}

# Portable mtime in epoch seconds; BSD and GNU stat disagree on the flag, the
# same split bin/fm-watch.sh decides once rather than probing per call.
if stat -f %m . >/dev/null 2>&1; then
  fm_test_mtime() { stat -f %m "$1"; }
else
  fm_test_mtime() { stat -c %Y "$1"; }
fi

append_digest() {  # <state> <text>
  fm_afk_outbox_append "$1" escalation "${FM_TEST_MARK}$2" \
    || fail "could not append an away-mode delivery record"
}

# Run the wrapper against <state>, capturing merged stdout+stderr. Extra args and
# env are set by the caller inline.
run_arm() {  # <state>
  local state=$1
  FM_STATE_OVERRIDE="$state" FM_HOME="$(dirname "$state")" "$ARM" 2>&1
}

wait_pid_exit() {  # <pid> [tenths]
  local pid=$1 limit=${2:-200} i=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge "$limit" ]; then
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.1
    i=$((i + 1))
  done
  wait "$pid"
}

# A pending record is delivered and the wrapper hands the reader's stdout and its
# exit 0 straight back, so the harness completion wakes firstmate with the
# digest and its re-arm verdict intact. The reader is resident (--timeout 0), so
# a delivery is the ONLY thing that ends this run.
test_delivers_pending_records_and_passes_the_verdict_through() {
  local state out rc
  state=$(make_arm_case delivers-through)
  enter_away "$state"
  append_digest "$state" "Supervisor escalate (1 event(s)): alpha.status: done: PR 1"

  rc=0
  out=$(run_arm "$state") || rc=$?
  [ "$rc" -eq 0 ] || fail "the wrapper did not exit 0 on a delivery (rc=$rc): $out"
  assert_contains "$out" "alpha.status: done: PR 1" "the wrapper did not pass the delivered digest through"
  assert_contains "$out" "${FM_TEST_MARK}Supervisor escalate" "the wrapper dropped the sentinel marker"
  assert_contains "$out" "re-arm to keep listening" "the wrapper did not pass the reader's re-arm verdict through"
  [ "$(cat "$state/.afk-outbox.ack")" = 1 ] || fail "the delivered record was not acknowledged"
  pass "a pending delivery is passed through with the reader's stdout, verdict, and exit 0"
}

# A record written WHILE the resident reader waits wakes it, is delivered, and
# ends the wrapper run - proving the wrapper does not idle-exit on a quiet home
# and only returns on a real delivery.
test_resident_wrapper_wakes_on_a_record_written_while_it_waits() {
  local state pid rc out beacon first
  state=$(make_arm_case resident-wakes)
  enter_away "$state"
  beacon=$(fm_afk_inbox_beacon_file "$state")

  FM_STATE_OVERRIDE="$state" FM_HOME="$(dirname "$state")" FM_AFK_INBOX_POLL=1 \
    "$ARM" > "$state/arm.out" 2>&1 &
  pid=$!
  sleep 2
  # Still alive and blocking after well past the old bare-reader default would
  # matter - a resident reader does not idle-exit, and its beacon is fresh.
  kill -0 "$pid" 2>/dev/null || fail "the resident wrapper exited on a quiet home: $(cat "$state/arm.out")"
  [ -e "$beacon" ] || fail "the resident reader stamped no liveness beacon"
  first=$(cat "$state/arm.out" 2>/dev/null || true)
  [ -z "$first" ] || fail "the wrapper printed output before any delivery: $first"

  append_digest "$state" "Supervisor escalate (1 event(s)): beta.status: blocked: needs a token"
  wait_pid_exit "$pid" 200
  rc=$?
  out=$(cat "$state/arm.out")
  [ "$rc" -eq 0 ] || fail "the wrapper did not exit cleanly after delivering (rc=$rc): $out"
  assert_contains "$out" "beta.status: blocked: needs a token" "the record written while waiting was not delivered"
  pass "the resident wrapper waits quietly, wakes on a record, and only then exits"
}

# The reader stamps its liveness beacon on every poll while it waits, and the
# resident wrapper must keep that alive across a completely quiet stretch so the
# daemon's paneless undelivered-escalation alarm does not fire on the healthy
# path.
test_resident_wrapper_keeps_the_reader_beacon_fresh() {
  local state pid beacon first second
  state=$(make_arm_case resident-beacon)
  enter_away "$state"
  beacon=$(fm_afk_inbox_beacon_file "$state")

  FM_STATE_OVERRIDE="$state" FM_HOME="$(dirname "$state")" FM_AFK_INBOX_POLL=1 \
    "$ARM" > "$state/arm.out" 2>&1 &
  pid=$!
  sleep 1
  [ -e "$beacon" ] || fail "no beacon after arming"
  first=$(fm_test_mtime "$beacon")
  sleep 3
  second=$(fm_test_mtime "$beacon")
  [ "$second" -gt "$first" ] || fail "the beacon stopped advancing during a quiet resident wait ($first -> $second)"

  kill -TERM "$pid" 2>/dev/null || true
  wait_pid_exit "$pid" 200
  pass "the resident wrapper keeps the reader's liveness beacon fresh on a quiet home"
}

# Pane delivery means no pull channel exists, so the wrapper stands down at once
# with a do-not-re-arm line rather than launching a reader that would only exit.
test_wrapper_stands_down_immediately_in_pane_mode() {
  local state out rc started elapsed
  state=$(make_arm_case pane-mode)
  enter_away "$state"
  fm_afk_delivery_mode_record "$state" pane || fail "could not record pane delivery mode"

  started=$(date +%s)
  rc=0
  out=$(run_arm "$state") || rc=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$rc" -eq 0 ] || fail "the wrapper did not exit 0 in pane mode (rc=$rc): $out"
  assert_contains "$out" "delivering into the supervisor pane" "the wrapper did not report the pane channel"
  assert_contains "$out" "do not re-arm" "the wrapper did not tell firstmate to stop in pane mode"
  [ "$elapsed" -lt 5 ] || fail "the wrapper blocked for ${elapsed}s in pane mode instead of standing down"
  pass "a recorded pane channel makes the wrapper stand down instead of arming a reader"
}

# Away mode already over: nothing to keep armed, so the wrapper stands down.
test_wrapper_stands_down_when_away_mode_is_not_active() {
  local state out rc
  state=$(make_arm_case away-off)
  rc=0
  out=$(run_arm "$state") || rc=$?
  [ "$rc" -eq 0 ] || fail "the wrapper did not exit 0 with away mode off (rc=$rc): $out"
  assert_contains "$out" "away mode is not active" "the wrapper did not report that away mode is off"
  assert_contains "$out" "do not re-arm" "the wrapper did not tell firstmate to stop"
  pass "the wrapper stands down cleanly when away mode is not active"
}

# An OPERATIONAL failure (a lock nobody releases) is a genuine reader outcome:
# the bare reader exits non-zero with a re-arm verdict, and the wrapper must pass
# that exact stdout and non-zero status straight through rather than absorbing it
# as a crash - firstmate needs to see the diagnostic and re-arm.
test_operational_failure_is_passed_through_not_absorbed() {
  local state out rc holder lock i=0
  state=$(make_arm_case operational-failure)
  enter_away "$state"
  append_digest "$state" "Supervisor escalate (1 event(s)): gamma.status: failed: CI red"
  lock="$state/$FM_AFK_OUTBOX_LOCK_NAME"

  # Hold the outbox lock so every reader acquire fails; the reader exhausts its
  # bounded retry and exits non-zero naming the lock, with a re-arm verdict.
  bash -c '
    # shellcheck disable=SC1090
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$2"
    sleep 30
  ' _ "$ROOT" "$lock" >/dev/null 2>&1 &
  holder=$!
  while [ ! -e "$lock" ]; do
    [ "$i" -lt 100 ] || fail "the background lock holder never took the outbox lock"
    sleep 0.1
    i=$((i + 1))
  done

  rc=0
  out=$(FM_STATE_OVERRIDE="$state" FM_HOME="$(dirname "$state")" \
    FM_AFK_OUTBOX_LOCK_TRIES=2 FM_AFK_INBOX_LOCK_TIMEOUT_MAX=2 FM_AFK_INBOX_POLL=1 \
    "$ARM" 2>&1) || rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  [ "$rc" -ne 0 ] || fail "the wrapper swallowed an operational failure (exited 0): $out"
  assert_contains "$out" "$FM_AFK_OUTBOX_LOCK_NAME" "the wrapper did not pass the reader's lock diagnostic through"
  assert_contains "$out" "re-arm to keep listening" "the wrapper did not pass the failed-read re-arm verdict through"
  case "$out" in
    *"afk-inbox-arm: FAILED - the away-mode reader crashed"*)
      fail "the wrapper misclassified an operational failure as a crash: $out" ;;
  esac
  [ "$(fm_afk_outbox_pending_count "$state")" -eq 1 ] \
    || fail "the record did not stay pending after the operational failure"
  pass "an operational reader failure is passed straight through, never absorbed as a crash"
}

# The wrapper resolves the reader as a sibling of its own script path, so the
# crash simulation runs a COPY of the wrapper placed next to a crashing reader
# stand-in. That copy's SCRIPT_DIR resolves the fake reader, exercising the real
# crash-absorb-and-escalate loop.
test_repeated_crashes_escalate_a_degraded_wake_via_sibling_copy() {
  local state bindir out rc queue
  state=$(make_arm_case crash-sibling)
  enter_away "$state"
  bindir="$TMP_ROOT/crash-sibling/bin"
  mkdir -p "$bindir"
  # Copy the real wrapper and its library dependencies' resolution: the wrapper
  # sources libraries from its own SCRIPT_DIR, so symlink the real bin dir's
  # libraries next to the copy. Simplest and robust: symlink every real bin file
  # in, then overwrite only the reader with a crashing stand-in.
  ln -s "$ROOT/bin"/*.sh "$bindir/" 2>/dev/null || true
  rm -f "$bindir/fm-afk-inbox.sh" "$bindir/fm-afk-inbox-arm.sh"
  cp "$ROOT/bin/fm-afk-inbox-arm.sh" "$bindir/fm-afk-inbox-arm.sh"
  cat > "$bindir/fm-afk-inbox.sh" <<'SH'
#!/usr/bin/env bash
# crash stand-in: die instantly with no verdict line
exit 137
SH
  chmod +x "$bindir/fm-afk-inbox.sh"

  rc=0
  out=$(FM_STATE_OVERRIDE="$state" FM_HOME="$(dirname "$state")" \
    FM_AFK_INBOX_ARM_FAILURE_THRESHOLD=3 FM_AFK_INBOX_ARM_BACKOFF_BASE=1 \
    FM_AFK_INBOX_ARM_BACKOFF_MAX=1 \
    "$bindir/fm-afk-inbox-arm.sh" 2>&1) || rc=$?

  [ "$rc" -ne 0 ] || fail "the wrapper did not exit non-zero after repeated crashes: $out"
  assert_contains "$out" "crashed 3 times in a row" "the wrapper did not report the crash-loop count"
  assert_contains "$out" "re-arm to keep listening" "the crash-loop exit did not carry a re-arm verdict"
  queue=$(cat "$state/.wake-queue" 2>/dev/null || true)
  assert_contains "$queue" "afk-inbox-arm" "no durable degraded wake was enqueued after repeated crashes"
  assert_contains "$queue" "keeps crashing" "the degraded wake did not describe the crash loop"
  pass "repeated reader crashes escalate one durable degraded wake and a non-zero re-arm exit"
}

# A misconfigured knob must refuse loudly rather than silently spin or stall.
test_a_bad_knob_refuses_loudly() {
  local state out rc
  state=$(make_arm_case bad-knob)
  enter_away "$state"
  rc=0
  out=$(FM_STATE_OVERRIDE="$state" FM_HOME="$(dirname "$state")" \
    FM_AFK_INBOX_ARM_FAILURE_THRESHOLD=0 "$ARM" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a zero failure threshold did not refuse: $out"
  assert_contains "$out" "must be a positive integer" "the wrapper did not name the bad knob"
  pass "a misconfigured wrapper knob refuses loudly instead of degrading the loop"
}

test_delivers_pending_records_and_passes_the_verdict_through
test_resident_wrapper_wakes_on_a_record_written_while_it_waits
test_resident_wrapper_keeps_the_reader_beacon_fresh
test_wrapper_stands_down_immediately_in_pane_mode
test_wrapper_stands_down_when_away_mode_is_not_active
test_operational_failure_is_passed_through_not_absorbed
test_repeated_crashes_escalate_a_degraded_wake_via_sibling_copy
test_a_bad_knob_refuses_loudly
