#!/usr/bin/env bash
# Behavior tests for the present-mode supervision daemon (bin/fm-present-daemon.sh).
#
# The daemon's whole value is that it keeps a watcher armed WITHOUT the active
# session spending its turn on it, so the properties worth pinning are safety
# properties, not convenience:
#   - it is inert until the local config/present-daemon flag exists;
#   - it re-arms after every watcher cycle ends;
#   - it detaches, so a disconnecting parent cannot reap it;
#   - two daemons can never run in one home;
#   - it never touches the SESSION lock (state/.lock);
#   - it never supervises alongside away mode;
#   - a crash-looping arm backs off and surfaces one durable wake instead of
#     spinning, and never decides anything about it;
#   - and when the daemon is gone the turn-end guard still fires its normal
#     alarm, so the never-blind backstop is unaffected.
#
# Each scenario builds its own home carrying a copy of the daemon plus a FAKE
# bin/fm-watch-arm.sh, so nothing here ever starts a real watcher.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-present-daemon)
STARTED_PIDS=()

cleanup_daemons() {
  local pid
  for pid in "${STARTED_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup_daemons EXIT

# --- fixtures ---------------------------------------------------------------

# A home with the daemon, its library, and a fake arm. The daemon resolves its
# sibling arm by its own absolute path, so a copied bin/ is what makes these
# tests hermetic.
make_home() {  # <dir> <arm-body>
  local dir=$1 arm_body=$2
  mkdir -p "$dir/bin" "$dir/state" "$dir/config"
  cp "$ROOT/bin/fm-present-daemon.sh" "$dir/bin/fm-present-daemon.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  chmod +x "$dir/bin/fm-present-daemon.sh"
  printf '#!/usr/bin/env bash\n%s\n' "$arm_body" > "$dir/bin/fm-watch-arm.sh"
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

enable_flag() {  # <dir>
  : > "$1/config/present-daemon"
}

daemon() {  # <dir> <subcommand>...
  local dir=$1
  shift
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" "$dir/bin/fm-present-daemon.sh" "$@"
}

lock_pid() {  # <dir>
  cat "$1/state/.present-daemon.lock/pid" 2>/dev/null || true
}

# Wait until <predicate> succeeds or the bound elapses. Every wait in this file
# is bounded and condition-based rather than a fixed sleep, so a slow machine
# cannot turn a real pass into a flake.
wait_until() {  # <seconds> <command>...
  local bound=$1 i=0 limit
  shift
  limit=$((bound * 20))
  while [ "$i" -lt "$limit" ]; do
    if "$@"; then
      return 0
    fi
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

daemon_is_up() {  # <dir>
  daemon "$1" status >/dev/null 2>&1
}

arm_calls_at_least() {  # <dir> <n>
  local count
  [ -f "$1/state/arm-calls" ] || return 1
  count=$(wc -l < "$1/state/arm-calls" | tr -d " ")
  [ "${count:-0}" -ge "$2" ]
}

# Sets RUN_PID rather than echoing it: a command substitution would run the
# background launch in a subshell, losing the pid from the cleanup list.
RUN_PID=
start_run_loop() {  # <dir>
  FM_HOME="$1" FM_ROOT_OVERRIDE="$1" "$1/bin/fm-present-daemon.sh" run > "$1/state/run.out" 2>&1 &
  RUN_PID=$!
  STARTED_PIDS+=("$RUN_PID")
}

# --- inert until opted in ---------------------------------------------------

test_inert_without_flag() {
  local home="$TMP_ROOT/inert" out
  make_home "$home" 'exit 0'

  out=$(daemon "$home" start) || fail "start must succeed when the feature is off"
  [ "$out" = "present-daemon: disabled (config/present-daemon absent)" ] \
    || fail "start without the flag must report disabled, got: $out"
  [ ! -e "$home/state/.present-daemon.lock" ] || fail "a disabled daemon took its lock"

  out=$(daemon "$home" run) || fail "run must succeed when the feature is off"
  [ "$out" = "present-daemon: disabled (config/present-daemon absent)" ] \
    || fail "run without the flag must report disabled, got: $out"

  daemon "$home" status >/dev/null 2>&1 && fail "status reported a daemon that was never started"
  pass "present daemon is inert until config/present-daemon exists"
}

# --- the re-arm loop --------------------------------------------------------

test_loop_rearms_after_each_cycle() {
  local home="$TMP_ROOT/rearm" pid
  # shellcheck disable=SC2016 # $FM_HOME must expand inside the fake arm, not here.
  make_home "$home" 'echo cycle >> "$FM_HOME/state/arm-calls"
sleep 0.1
exit 0'
  enable_flag "$home"

  start_run_loop "$home"
  pid=$RUN_PID
  wait_until 10 arm_calls_at_least "$home" 3 \
    || fail "loop did not re-arm after watcher cycles ended (calls: $(cat "$home/state/arm-calls" 2>/dev/null | wc -l))"
  [ "$(lock_pid "$home")" = "$pid" ] || fail "the running loop did not record its own pid in the daemon lock"

  kill -TERM "$pid" 2>/dev/null || true
  wait_until 10 eval '! kill -0 '"$pid"' 2>/dev/null' || fail "loop did not exit on SIGTERM"
  [ ! -e "$home/state/.present-daemon.lock" ] || fail "a clean shutdown left the daemon lock behind"
  pass "re-arm loop runs a fresh arm after each watcher cycle and releases its lock on SIGTERM"
}

test_session_lock_is_never_touched() {
  local home="$TMP_ROOT/session-lock" pid before after
  # shellcheck disable=SC2016 # $FM_HOME must expand inside the fake arm, not here.
  make_home "$home" 'echo cycle >> "$FM_HOME/state/arm-calls"
sleep 0.1
exit 0'
  enable_flag "$home"
  # A sentinel standing in for the session lock the active firstmate owns. The
  # daemon and the session must never contend: they hold different locks.
  printf 'session-owned\n' > "$home/state/.lock"
  before=$(cat "$home/state/.lock")

  start_run_loop "$home"
  pid=$RUN_PID
  wait_until 10 arm_calls_at_least "$home" 2 || fail "loop never armed"
  kill -TERM "$pid" 2>/dev/null || true
  wait_until 10 eval '! kill -0 '"$pid"' 2>/dev/null' || fail "loop did not exit on SIGTERM"

  after=$(cat "$home/state/.lock")
  [ "$after" = "$before" ] || fail "the daemon modified the session lock: $after"
  pass "daemon never reads, writes, or removes the session lock state/.lock"
}

# --- single instance --------------------------------------------------------

test_second_daemon_cannot_start() {
  local home="$TMP_ROOT/single" pid out
  make_home "$home" 'sleep 30'
  enable_flag "$home"

  start_run_loop "$home"
  pid=$RUN_PID
  wait_until 10 daemon_is_up "$home" || fail "first daemon never took the lock"

  out=$(daemon "$home" start) || fail "a redundant start must be a silent success, not an error"
  [ "$out" = "present-daemon: already running pid=$pid" ] \
    || fail "second start must report the live daemon, got: $out"

  out=$(daemon "$home" run) || fail "a redundant run must be a silent success, not an error"
  case "$out" in
    "present-daemon: already running pid="*) ;;
    *) fail "second run must refuse to take the lock, got: $out" ;;
  esac
  pass "a second daemon cannot run in the same home"
}

# --- detached launch --------------------------------------------------------

test_start_detaches_from_its_parent() {
  local home="$TMP_ROOT/detach" pid pgid ppid
  make_home "$home" 'sleep 30'
  enable_flag "$home"

  # Launch through a parent shell that exits immediately: this is the shape that
  # kills today's watcher when the harness background task that armed it ends.
  bash -c "FM_HOME='$home' FM_ROOT_OVERRIDE='$home' '$home/bin/fm-present-daemon.sh' start >/dev/null" \
    || fail "detached start failed"
  wait_until 10 daemon_is_up "$home" || fail "detached daemon never took the lock"
  pid=$(lock_pid "$home")
  STARTED_PIDS+=("$pid")

  # Leading its own process group with no surviving parent is the property that
  # makes it survivable: a signal or reap aimed at the launcher's group cannot
  # reach it. (BSD ps has no portable session-id column, so the group is the
  # observable proxy for the setsid call.)
  pgid=$(ps -p "$pid" -o pgid= 2>/dev/null | tr -d ' ')
  [ "$pgid" = "$pid" ] || fail "daemon did not detach into its own process group (pid=$pid pgid=$pgid)"
  ppid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
  [ "$ppid" != "$$" ] || fail "daemon is still a child of the test shell"
  kill -0 "$pid" 2>/dev/null || fail "daemon died with the parent shell that started it"

  daemon "$home" stop >/dev/null || fail "stop failed"
  wait_until 10 eval '! kill -0 '"$pid"' 2>/dev/null' || fail "stop did not end the daemon"
  pass "start detaches into its own session and survives the parent that launched it"
}

# --- away-mode interlock ----------------------------------------------------

test_away_mode_interlock() {
  local home="$TMP_ROOT/afk" pid out
  # shellcheck disable=SC2016 # $FM_HOME must expand inside the fake arm, not here.
  make_home "$home" 'echo cycle >> "$FM_HOME/state/arm-calls"
sleep 0.1
exit 0'
  enable_flag "$home"

  date '+%s' > "$home/state/.afk"
  out=$(daemon "$home" start) || fail "start must succeed under away mode"
  [ "$out" = "present-daemon: skipped (away mode owns supervision)" ] \
    || fail "start under away mode must stand down, got: $out"
  [ ! -e "$home/state/.present-daemon.lock" ] || fail "a stood-down daemon took its lock"
  rm -f "$home/state/.afk"

  start_run_loop "$home"
  pid=$RUN_PID
  wait_until 10 arm_calls_at_least "$home" 2 || fail "loop never armed before away mode"
  date '+%s' > "$home/state/.afk"
  wait_until 10 eval '! kill -0 '"$pid"' 2>/dev/null' \
    || fail "running loop kept supervising after away mode took over"
  pass "present and away supervision never run concurrently"
}

# --- crash-loop backoff -----------------------------------------------------

test_crash_loop_backs_off_and_surfaces_one_wake() {
  local home="$TMP_ROOT/crashloop" pid queue calls records
  # shellcheck disable=SC2016 # $FM_HOME must expand inside the fake arm, not here.
  make_home "$home" 'echo cycle >> "$FM_HOME/state/arm-calls"
exit 1'
  enable_flag "$home"
  queue="$home/state/.wake-queue"

  FM_PRESENT_FAILURE_THRESHOLD=2 FM_PRESENT_BACKOFF_BASE=1 FM_PRESENT_BACKOFF_MAX=1 \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-present-daemon.sh" run \
    > "$home/state/run.out" 2>&1 &
  pid=$!
  STARTED_PIDS+=("$pid")

  wait_until 20 test -s "$queue" || fail "a crash-looping arm never surfaced a wake"
  records=$(wc -l < "$queue" | tr -d ' ')
  [ "$records" = 1 ] || fail "crash loop surfaced $records wakes; it must surface exactly one per episode"
  cut -f3 "$queue" | grep -qx check || fail "the degraded report must be a plain check wake: $(cat "$queue")"
  cut -f4 "$queue" | grep -qx present-daemon || fail "degraded wake used an unexpected key: $(cat "$queue")"

  # Backoff, not a spin: with a 1s floor the arm cannot have been retried
  # anywhere near as often as an unthrottled loop would.
  calls=$(wc -l < "$home/state/arm-calls" | tr -d ' ')
  [ "$calls" -lt 30 ] || fail "failing arm was retried $calls times; backoff did not engage"

  kill -TERM "$pid" 2>/dev/null || true
  wait_until 10 eval '! kill -0 '"$pid"' 2>/dev/null' || fail "loop did not exit on SIGTERM during backoff"
  pass "crash-looping arm backs off and surfaces exactly one durable check wake"
}

test_degraded_wake_is_reported_not_acted_on() {
  local home="$TMP_ROOT/crashloop" payload
  [ -s "$home/state/.wake-queue" ] || fail "expected the crash-loop scenario's queue"
  payload=$(cut -f5 "$home/state/.wake-queue")
  case "$payload" in
    *"cannot keep a watcher armed"*) ;;
    *) fail "degraded payload does not state the observed fact: $payload" ;;
  esac
  # The daemon reports; firstmate decides. Nothing may be torn down, merged, or
  # resolved on its own authority, so the queue is its only output.
  [ ! -e "$home/state/.afk" ] || fail "daemon created away-mode state"
  ls "$home/state"/*.status >/dev/null 2>&1 && fail "daemon wrote task status events"
  pass "degraded daemon only reports through the wake queue; it decides nothing"
}

# --- never-blind fallback ---------------------------------------------------

test_daemon_death_leaves_turnend_alarm_intact() {
  local home="$TMP_ROOT/neverblind" out rc=0
  make_home "$home" 'sleep 30'
  enable_flag "$home"
  # A primary-shaped checkout is what the turn-end guard scopes in-flight work to.
  git init -q "$home"
  git -C "$home" commit -q --allow-empty -m init
  : > "$home/AGENTS.md"
  cp "$ROOT/bin/fm-turnend-guard.sh" "$ROOT/bin/fm-supervision-instructions.sh" \
     "$ROOT/bin/fm-harness.sh" "$ROOT/bin/fm-primary-scope-lib.sh" \
     "$ROOT/bin/fm-supervision-lib.sh" "$ROOT/bin/fm-operational-input.sh" "$home/bin/"
  chmod +x "$home/bin/fm-turnend-guard.sh" "$home/bin/fm-supervision-instructions.sh" \
           "$home/bin/fm-harness.sh" "$home/bin/fm-operational-input.sh"
  mkdir -p "$home/docs"
  cp -R "$ROOT/docs/supervision-protocols" "$home/docs/supervision-protocols"
  printf 'project=fixture\n' > "$home/state/task1.meta"

  # No daemon, no watcher, no beacon: exactly the state a dead daemon leaves.
  out=$(printf '%s' '{"stop_hook_active":false}' \
    | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-turnend-guard.sh" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "turn-end guard must still fire with no watcher alive, got exit $rc"
  case "$out" in
    *"TURN WOULD END BLIND"*) ;;
    *) fail "turn-end guard alarm text changed or did not fire: $out" ;;
  esac
  pass "a dead present daemon still leaves the turn-end guard firing its normal alarm"
}

test_supervision_block_reports_a_live_daemon() {
  local home="$TMP_ROOT/instructions" pid out
  make_home "$home" 'sleep 30'
  enable_flag "$home"
  cp "$ROOT/bin/fm-supervision-instructions.sh" "$ROOT/bin/fm-harness.sh" "$home/bin/"
  chmod +x "$home/bin/fm-supervision-instructions.sh" "$home/bin/fm-harness.sh"
  mkdir -p "$home/docs"
  cp -R "$ROOT/docs/supervision-protocols" "$home/docs/supervision-protocols"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-supervision-instructions.sh" --harness claude)
  case "$out" in
    *"Present-mode supervision daemon: live"*) fail "reported a live daemon before one existed" ;;
  esac

  start_run_loop "$home"
  pid=$RUN_PID
  wait_until 10 daemon_is_up "$home" || fail "daemon never took the lock"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-supervision-instructions.sh" --harness claude)
  case "$out" in
    *"Present-mode supervision daemon: live"*) ;;
    *) fail "supervision block did not report the live daemon: $out" ;;
  esac
  case "$out" in
    *"already owns re-arming; drain queued wakes and do not arm another cycle"*) ;;
    *) fail "ordinary-wake continuation did not defer to the live daemon: $out" ;;
  esac

  kill -TERM "$pid" 2>/dev/null || true
  wait_until 10 eval '! kill -0 '"$pid"' 2>/dev/null' || fail "loop did not exit on SIGTERM"
  pass "supervision instructions defer re-arming to a live present daemon and never to a dead one"
}

test_inert_without_flag
test_loop_rearms_after_each_cycle
test_session_lock_is_never_touched
test_second_daemon_cannot_start
test_start_detaches_from_its_parent
test_away_mode_interlock
test_crash_loop_backs_off_and_surfaces_one_wake
test_degraded_wake_is_reported_not_acted_on
test_daemon_death_leaves_turnend_alarm_intact
test_supervision_block_reports_a_live_daemon
