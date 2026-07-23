#!/usr/bin/env bash
# tests/fm-afk-inbox.test.sh - away-mode PULL delivery: the durable outbox record
# and acknowledgement contract (bin/fm-afk-outbox-lib.sh) and its blocking reader
# (bin/fm-afk-inbox.sh).
#
# The contract these cover is the one the 2026-07-22 incident needed: a primary
# firstmate with no supervisor pane must still receive away-mode escalations, and
# a reader that dies mid-wait or mid-print must lose nothing. Delivery is
# exactly-once within a run and at-least-once across a killed run, because
# records are acknowledged only after they are already on the reader's stdout.
#
# Mode selection and the daemon-side dispatch into this outbox live in
# tests/fm-daemon.test.sh, next to the rest of the injection units.
set -u

# wake-helpers.sh brings tests/lib.sh plus the wedge-alarm notifier recorder, so
# the real daemon this suite starts can never post a desktop notification.
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

INBOX="$ROOT/bin/fm-afk-inbox.sh"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
OUTBOX_LIB="$ROOT/bin/fm-afk-outbox-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-afk-inbox-tests)

# shellcheck source=bin/fm-afk-outbox-lib.sh
. "$OUTBOX_LIB"

# The daemon prefixes every digest with the sentinel marker before delivery; the
# record must carry it through verbatim, so the fixtures use the real bytes.
FM_TEST_MARK=$'\xE2\x81\xA3'

make_inbox_case() {  # <name> -> state dir
  local name=$1 state
  state="$TMP_ROOT/$name/state"
  mkdir -p "$state"
  printf '%s\n' "$state"
}

enter_away() {  # <state>
  date +%s > "$1/.afk"
}

append_digest() {  # <state> <text>
  fm_afk_outbox_append "$1" escalation "${FM_TEST_MARK}$2" \
    || fail "could not append an away-mode delivery record"
}

run_inbox() {  # <state> [args...]
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" FM_HOME="$(dirname "$state")" "$INBOX" "$@" 2>&1
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

test_reader_delivers_pending_records_then_acknowledges_them() {
  local state out
  state=$(make_inbox_case deliver-once)
  enter_away "$state"
  append_digest "$state" "Supervisor escalate (1 event(s)): alpha.status: done: PR 1"
  append_digest "$state" "Supervisor escalate (1 event(s)): beta.status: blocked: needs a token"

  out=$(run_inbox "$state" --once) || fail "reader failed with records pending: $out"
  assert_contains "$out" "afk-inbox: delivered 2 away-mode escalation(s)" "reader did not announce what it delivered"
  assert_contains "$out" "alpha.status: done: PR 1" "reader did not print the first digest"
  assert_contains "$out" "beta.status: blocked: needs a token" "reader did not print the second digest"
  assert_contains "$out" "${FM_TEST_MARK}Supervisor escalate" "reader dropped the sentinel marker from the digest"
  [ "$(cat "$state/.afk-outbox.ack")" = 2 ] || fail "reader did not record the acknowledged high-water mark"

  out=$(run_inbox "$state" --once) || fail "second reader run failed: $out"
  assert_contains "$out" "afk-inbox: nothing pending" "acknowledged records were delivered a second time"
  assert_not_contains "$out" "alpha.status" "acknowledged records were re-printed"
  pass "reader delivers every pending record once and acknowledges exactly what it printed"
}

test_killed_reader_loses_nothing() {
  local state out pid rc
  state=$(make_inbox_case killed-reader)
  enter_away "$state"

  # (1) A reader killed while WAITING, before anything is written.
  FM_STATE_OVERRIDE="$state" "$INBOX" --poll 1 --timeout 60 > "$state/killed.out" 2>&1 &
  pid=$!
  sleep 1
  kill -9 "$pid" 2>/dev/null || fail "background reader was not running to be killed"
  wait "$pid" 2>/dev/null || true
  append_digest "$state" "Supervisor escalate (1 event(s)): gamma.status: failed: CI red"
  out=$(run_inbox "$state" --once) || fail "reader after a killed wait failed: $out"
  assert_contains "$out" "gamma.status: failed: CI red" "a record written after a killed reader was not delivered"
  [ "$(cat "$state/.afk-outbox.ack")" = 1 ] || fail "delivery after a killed wait did not acknowledge"

  # (2) A reader killed BETWEEN printing and acknowledging: the records were
  # printed to a stdout nobody received, so the same records must be delivered
  # again - once - by the next run.
  append_digest "$state" "Supervisor escalate (1 event(s)): delta.status: needs-decision: pick one"
  fm_afk_outbox_pending "$state" >/dev/null || fail "pending read failed"
  [ "$(cat "$state/.afk-outbox.ack")" = 1 ] || fail "a pending read must never acknowledge on its own"
  rc=0
  out=$(run_inbox "$state" --once) || rc=$?
  [ "$rc" -eq 0 ] || fail "reader failed re-delivering an unacknowledged record (rc=$rc): $out"
  assert_contains "$out" "delta.status: needs-decision: pick one" "an unacknowledged record was lost"
  [ "$(printf '%s\n' "$out" | grep -c 'delta.status')" -eq 1 ] || fail "re-delivery duplicated the record within one run"
  [ "$(cat "$state/.afk-outbox.ack")" = 2 ] || fail "re-delivery did not advance the acknowledged mark"

  out=$(run_inbox "$state" --once) || fail "reader failed after re-delivery: $out"
  assert_contains "$out" "nothing pending" "re-delivered records were not acknowledged"
  pass "a killed reader loses nothing and the next run delivers the same records exactly once"
}

test_reader_wakes_on_a_record_written_while_it_waits() {
  local state pid rc out
  state=$(make_inbox_case concurrent-append)
  enter_away "$state"
  FM_STATE_OVERRIDE="$state" "$INBOX" --poll 1 --timeout 60 > "$state/reader.out" 2>&1 &
  pid=$!
  sleep 1
  append_digest "$state" "Supervisor escalate (1 event(s)): epsilon.status: done: PR 9"
  wait_pid_exit "$pid" 200
  rc=$?
  [ "$rc" -eq 0 ] || fail "blocked reader did not exit cleanly after a record arrived (rc=$rc)"
  out=$(cat "$state/reader.out")
  assert_contains "$out" "epsilon.status: done: PR 9" "blocked reader did not deliver the record written while it waited"
  assert_contains "$out" "re-arm to keep listening" "delivery did not tell firstmate to re-arm"
  pass "a record appended while the reader waits wakes it and is delivered"
}

test_reader_exits_immediately_when_the_daemon_uses_the_pane() {
  local state out started elapsed
  state=$(make_inbox_case pane-mode)
  enter_away "$state"
  fm_afk_delivery_mode_record "$state" pane || fail "could not record pane delivery mode"

  started=$(date +%s)
  out=$(run_inbox "$state" --poll 1 --timeout 30) || fail "reader failed in pane mode: $out"
  elapsed=$(( $(date +%s) - started ))
  assert_contains "$out" "delivering into the supervisor pane" "reader did not report that no inbox is needed"
  [ "$elapsed" -lt 5 ] || fail "reader blocked for ${elapsed}s in pane mode instead of exiting immediately"
  pass "recorded pane delivery makes the reader exit immediately instead of waiting"
}

test_reader_exits_when_away_mode_is_over_but_still_delivers_leftovers() {
  local state out pid rc
  state=$(make_inbox_case away-ended)

  out=$(run_inbox "$state" --poll 1 --timeout 30) || fail "reader failed with away mode off: $out"
  assert_contains "$out" "away mode is not active" "reader did not refuse to wait outside away mode"

  # A record left over from the away session is still delivered, never dropped
  # because the flag has since been cleared.
  append_digest "$state" "Supervisor escalate (1 event(s)): zeta.status: done: PR 4"
  out=$(run_inbox "$state" --once) || fail "reader failed delivering a leftover record: $out"
  assert_contains "$out" "zeta.status: done: PR 4" "a leftover record was dropped after away mode ended"

  # A reader already waiting exits as soon as away mode ends.
  enter_away "$state"
  FM_STATE_OVERRIDE="$state" "$INBOX" --poll 1 --timeout 60 > "$state/ended.out" 2>&1 &
  pid=$!
  sleep 1
  rm -f "$state/.afk"
  wait_pid_exit "$pid" 200
  rc=$?
  [ "$rc" -eq 0 ] || fail "waiting reader did not exit cleanly when away mode ended (rc=$rc)"
  assert_contains "$(cat "$state/ended.out")" "away mode ended" "waiting reader did not report the ended away session"
  pass "the reader never waits outside away mode and still delivers leftover records"
}

test_reader_reports_an_idle_timeout() {
  local state out
  state=$(make_inbox_case idle-timeout)
  enter_away "$state"
  out=$(run_inbox "$state" --poll 1 --timeout 1) || fail "idle reader should exit 0: $out"
  assert_contains "$out" "idle after" "idle reader did not report its timeout"
  assert_contains "$out" "re-arm to keep listening" "idle reader did not tell firstmate to re-arm"
  pass "an idle reader times out with a re-arm line rather than hanging forever"
}

test_records_survive_a_lost_sequence_counter() {
  local state out
  state=$(make_inbox_case lost-counter)
  enter_away "$state"
  append_digest "$state" "first"
  run_inbox "$state" --once >/dev/null || fail "initial delivery failed"
  [ "$(cat "$state/.afk-outbox.ack")" = 1 ] || fail "initial delivery did not acknowledge"

  # A truncated or deleted counter must not hand out a sequence number that an
  # existing acknowledgement already covers, which would hide the record forever.
  rm -f "$state/.afk-outbox.seq"
  append_digest "$state" "second"
  out=$(run_inbox "$state" --once) || fail "delivery after a lost counter failed: $out"
  assert_contains "$out" "second" "a record written after the counter was lost became invisible"
  pass "a lost sequence counter cannot make a new record look already acknowledged"
}

test_append_failure_is_reported_rather_than_hanging() {
  local state lock holder rc i=0
  state=$(make_inbox_case lock-held)
  enter_away "$state"
  lock="$state/$FM_AFK_OUTBOX_LOCK_NAME"

  # A live holder keeps the lock for longer than the append's bounded budget.
  # The append must report failure so the daemon keeps the digest buffered,
  # rather than waiting forever inside a delivery attempt.
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$2"
    sleep 5
  ' _ "$ROOT" "$lock" &
  holder=$!
  while [ ! -e "$lock" ]; do
    [ "$i" -lt 100 ] || fail "the background lock holder never took the outbox lock"
    sleep 0.1
    i=$((i + 1))
  done

  rc=0
  FM_AFK_OUTBOX_LOCK_TRIES=2 fm_afk_outbox_append "$state" escalation "blocked digest" || rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$rc" -ne 0 ] || fail "an append that cannot take the lock must report failure, not claim delivery"
  [ ! -s "$state/.afk-outbox" ] || fail "a failed append still wrote a record"
  pass "an outbox lock held elsewhere fails the append in bounded time instead of hanging"
}

# Firstmate arms one reader, but a re-arm after a context reset can leave two
# waiting at once. Records are printed before they are acknowledged, so the loser
# of that race must simply print NOTHING: announcing a count it did not deliver
# would read to firstmate as an escalation that was swallowed.
test_concurrent_readers_never_announce_what_they_did_not_deliver() {
  local state round out1 out2 combined delivered=0
  state=$(make_inbox_case concurrent-readers)
  enter_away "$state"

  for round in 1 2 3 4 5; do
    FM_STATE_OVERRIDE="$state" "$INBOX" --poll 1 --timeout 6 > "$state/r1.out" 2>&1 &
    local pid1=$!
    FM_STATE_OVERRIDE="$state" "$INBOX" --poll 1 --timeout 6 > "$state/r2.out" 2>&1 &
    local pid2=$!
    sleep 1
    append_digest "$state" "Supervisor escalate (1 event(s)): theta$round.status: done: PR $round"
    wait_pid_exit "$pid1" 200 || fail "reader 1 did not exit in round $round"
    wait_pid_exit "$pid2" 200 || fail "reader 2 did not exit in round $round"

    out1=$(cat "$state/r1.out")
    out2=$(cat "$state/r2.out")
    for combined in "$out1" "$out2"; do
      case "$combined" in
        *"away-mode escalation(s)"*)
          assert_contains "$combined" "theta$round.status" \
            "a reader announced a delivery without printing any record (round $round): $combined"
          ;;
      esac
    done
    case "$out1$out2" in
      *"theta$round.status"*) delivered=$((delivered + 1)) ;;
    esac
  done

  [ "$delivered" -eq 5 ] || fail "concurrent readers dropped a record ($delivered/5 rounds delivered)"
  [ "$(fm_afk_outbox_pending_count "$state")" -eq 0 ] || fail "a record was left unacknowledged after both readers exited"
  pass "racing readers never announce a delivery they did not print, and no record is dropped"
}

# Every exit is a completed background task firstmate must react to, so each one
# has to say whether to arm another reader. An exit that says "do not re-arm" and
# is re-armed anyway becomes an immediate-exit loop during an unattended away
# session; an exit that says nothing leaves firstmate guessing.
test_every_exit_line_carries_a_re_arm_verdict() {
  local state out last
  assert_verdict() {  # <output> <expected-verdict> <label>
    local text=$1 want=$2 label=$3 final
    final=$(printf '%s\n' "$text" | grep '^afk-inbox: ' | tail -n 1)
    [ -n "$final" ] || fail "$label produced no afk-inbox status line: $text"
    case "$want" in
      rearm)
        case "$final" in
          *"re-arm to keep listening"*) return 0 ;;
        esac
        fail "$label must tell firstmate to re-arm: $final"
        ;;
      stop)
        case "$final" in
          *"- do not re-arm") return 0 ;;
        esac
        fail "$label must tell firstmate NOT to re-arm: $final"
        ;;
    esac
  }

  state=$(make_inbox_case rearm-verdict)
  out=$(run_inbox "$state" --once) || fail "reader failed outside away mode: $out"
  assert_verdict "$out" stop "the away-mode-inactive exit"

  enter_away "$state"
  out=$(run_inbox "$state" --once) || fail "reader failed with nothing pending: $out"
  assert_verdict "$out" rearm "the nothing-pending exit"

  out=$(run_inbox "$state" --poll 1 --timeout 1) || fail "reader failed idling out: $out"
  assert_verdict "$out" rearm "the idle-timeout exit"

  append_digest "$state" "Supervisor escalate (1 event(s)): iota.status: done: PR 7"
  out=$(run_inbox "$state" --once) || fail "reader failed delivering: $out"
  assert_verdict "$out" rearm "the delivered exit"

  fm_afk_delivery_mode_record "$state" pane || fail "could not record pane delivery mode"
  out=$(run_inbox "$state" --once) || fail "reader failed in pane mode: $out"
  assert_verdict "$out" stop "the pane-delivery exit"

  # A record still pending outranks pane mode: it is delivered, and that exit
  # must invite a re-arm rather than closing the channel.
  append_digest "$state" "Supervisor escalate (1 event(s)): kappa.status: blocked: needs a token"
  out=$(run_inbox "$state" --once) || fail "reader failed delivering a leftover in pane mode: $out"
  assert_contains "$out" "kappa.status: blocked: needs a token" "a pending record was dropped in pane mode"
  assert_verdict "$out" rearm "the delivered-in-pane-mode exit"

  last=$out
  assert_not_contains "$last" "do not re-arm" "a delivering exit must not also tell firstmate to stop"
  pass "every reader exit ends with exactly one re-arm verdict firstmate can act on"
}

# The whole point, end to end: a REAL daemon with no terminal backend reachable
# at all. It must select paneless delivery instead of typing into the legacy
# firstmate:0 guess, and a captain-relevant status must reach the reader's stdout
# without buffering indefinitely and without raising a wedge alarm.
test_real_daemon_without_a_backend_delivers_to_the_reader() {
  local state fakebin pid i=0 out log
  state=$(make_inbox_case real-daemon)
  fakebin="$TMP_ROOT/real-daemon/fakebin"
  mkdir -p "$fakebin"
  # No terminal backend is reachable: every tmux call fails the way it does with
  # no server running, and no herdr environment is present.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  make_fake_crew_state "$fakebin" >/dev/null
  enter_away "$state"
  printf 'done: PR https://example.test/pr/42\n' > "$state/task-w1.status"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WEDGE_ALARM_EXEC=discard \
    FM_ESCALATE_BATCH_SECS=0 FM_HOUSEKEEPING_TICK=1 FM_MAX_DEFER_SECS=5 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    env -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND \
    "$DAEMON" > "$state/daemon.out" 2>&1 &
  pid=$!

  while [ "$(fm_afk_outbox_pending_count "$state")" -eq 0 ]; do
    if [ "$i" -ge 300 ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      fail "a real backendless daemon never delivered the escalation: $(cat "$state/daemon.out" "$state/.supervise-daemon.log" 2>/dev/null)"
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      fail "the daemon exited instead of switching to paneless delivery: $(cat "$state/daemon.out" 2>/dev/null)"
    fi
    sleep 0.1
    i=$((i + 1))
  done

  out=$(run_inbox "$state" --once) || fail "the reader failed to deliver the daemon's escalation: $out"
  assert_contains "$out" "PR https://example.test/pr/42" "the escalation did not reach the reader's stdout"
  assert_contains "$out" "$FM_TEST_MARK" "the delivered digest lost its sentinel marker"
  [ ! -e "$state/.subsuper-inject-wedged" ] || fail "paneless delivery raised a wedge alarm"
  [ ! -s "$state/.subsuper-escalations" ] || fail "the digest stayed buffered after paneless delivery"
  [ "$(cat "$state/.afk-delivery")" = paneless ] || fail "the daemon did not record its paneless delivery mode"
  log=$(cat "$state/.supervise-daemon.log" 2>/dev/null || true)
  assert_contains "$log" "delivery mode: paneless" "the daemon did not log which delivery mode it chose and why"

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "a real daemon with no terminal backend delivers escalations to the reader, unbuffered and without a wedge alarm"
}

test_reader_delivers_pending_records_then_acknowledges_them
test_killed_reader_loses_nothing
test_reader_wakes_on_a_record_written_while_it_waits
test_reader_exits_immediately_when_the_daemon_uses_the_pane
test_reader_exits_when_away_mode_is_over_but_still_delivers_leftovers
test_reader_reports_an_idle_timeout
test_records_survive_a_lost_sequence_counter
test_append_failure_is_reported_rather_than_hanging
test_concurrent_readers_never_announce_what_they_did_not_deliver
test_every_exit_line_carries_a_re_arm_verdict
test_real_daemon_without_a_backend_delivers_to_the_reader
