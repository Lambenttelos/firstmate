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
# fm_pid_alive is the daemon's OWN liveness definition (zombie-aware): a stopped
# daemon that this container's init has not reaped lingers as a defunct/Z process
# that a bare `kill -0` still reports as alive, exactly the false positive the pid
# lib exists to reject. The stop/detach assertions below check liveness through
# it, not through raw `kill -0`, so they match how the daemon itself decides a
# daemon is gone.
# shellcheck source=bin/fm-pid-lib.sh
. "$ROOT/bin/fm-pid-lib.sh"

# pid_is_dead: true when <pid> is not a live process by the daemon's own
# zombie-aware definition. A reaped or never-existent pid is dead; an un-reaped
# zombie is dead too (fm_pid_alive rejects state Z).
pid_is_dead() {  # <pid>
  ! fm_pid_alive "$1"
}

TMP_ROOT=$(fm_test_tmproot fm-present-daemon)
STARTED_PIDS=()

# The launch-based tests below exercise the re-arm loop, not pane-wake, so pin a
# neutral (non-jcode) supervisor harness for the whole process: pane-wake then
# stays off in every launched daemon unless a test opts in, keeping those tests
# independent of whichever runtime this suite happens to run on. The
# sourced-function pane-wake tests override FM_SUPERVISOR_HARNESS per call.
export FM_SUPERVISOR_HARNESS=claude

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
  # fm-wake-lib.sh sources its own siblings, so the copied bin/ needs them too.
  cp "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-mutex-lib.sh" \
    "$ROOT/bin/fm-pid-lib.sh" "$dir/bin/"
  # Pane-wake sources these siblings at daemon startup (source-safe), plus
  # fm-harness.sh for the jcode auto-detect; a copied bin/ needs them or the
  # daemon cannot start. The backend adapters under bin/backends are sourced
  # lazily only when pane-wake actually injects, so they are copied too.
  cp "$ROOT/bin/fm-operational-input.sh" "$ROOT/bin/fm-supervisor-target-lib.sh" \
    "$ROOT/bin/fm-backend.sh" "$ROOT/bin/fm-harness.sh" \
    "$ROOT/bin/fm-tmux-lib.sh" "$ROOT/bin/fm-composer-lib.sh" \
    "$ROOT/bin/fm-backend-hometag-lib.sh" "$dir/bin/"
  mkdir -p "$dir/bin/backends"
  cp "$ROOT/bin/backends/tmux.sh" "$ROOT/bin/backends/herdr.sh" \
    "$ROOT/bin/backends/zellij.sh" "$ROOT/bin/backends/orca.sh" \
    "$ROOT/bin/backends/cmux.sh" "$dir/bin/backends/"
  chmod +x "$dir/bin/fm-harness.sh"
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
  wait_until 10 pid_is_dead "$pid" || fail "loop did not exit on SIGTERM"
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
  wait_until 10 pid_is_dead "$pid" || fail "loop did not exit on SIGTERM"

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
  wait_until 10 pid_is_dead "$pid" || fail "stop did not end the daemon"
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
  wait_until 10 pid_is_dead "$pid" \
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
  wait_until 10 pid_is_dead "$pid" || fail "loop did not exit on SIGTERM during backoff"
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
  wait_until 10 pid_is_dead "$pid" || fail "loop did not exit on SIGTERM"
  pass "supervision instructions defer re-arming to a live present daemon and never to a dead one"
}

# --- status/stop see a live daemon (non-empty pid-identity) ------------------

test_status_and_stop_see_a_live_daemon() {
  # Regression: the daemon wrote a ZERO-BYTE pid-identity because it computed the
  # identity from $(fm_current_pid) - a command substitution whose subshell pid is
  # already dead by the time fm_pid_identity reads /proc - so daemon_lock_matches_pid
  # always failed and status/stop reported a live daemon as "not running", leaving
  # the stale daemon invisible and letting a restart spawn a duplicate. This pins
  # that a running daemon writes a real pid-identity and that status/stop see it.
  local home="$TMP_ROOT/status-live" pid out identity_bytes
  make_home "$home" 'sleep 30'
  enable_flag "$home"

  start_run_loop "$home"
  pid=$RUN_PID
  wait_until 10 daemon_is_up "$home" || fail "daemon never took the lock"

  # The pid-identity must be real, non-empty content - the exact thing the bug
  # got wrong.
  [ -s "$home/state/.present-daemon.lock/pid-identity" ] \
    || fail "running daemon wrote an empty pid-identity (the status/stop blindness bug)"
  identity_bytes=$(wc -c < "$home/state/.present-daemon.lock/pid-identity" | tr -d ' ')
  [ "${identity_bytes:-0}" -gt 0 ] || fail "pid-identity is zero bytes"

  out=$(daemon "$home" status) || fail "status must exit 0 for a live daemon"
  [ "$out" = "present-daemon: running pid=$pid" ] \
    || fail "status must report the live daemon, got: $out"

  # stop must actually end THIS live daemon (no duplicate-daemon hazard).
  out=$(daemon "$home" stop) || fail "stop must exit 0 when it stops a live daemon"
  [ "$out" = "present-daemon: stopped pid=$pid" ] \
    || fail "stop must report stopping the live daemon, got: $out"
  wait_until 10 pid_is_dead "$pid" || fail "stop did not actually end the live daemon"

  daemon "$home" status >/dev/null 2>&1 && fail "status still reports a daemon after stop"
  pass "status and stop correctly see and end a live daemon (non-empty pid-identity)"
}

# --- pane-wake decision + guard reuse (sourced-function tests) ---------------
# These source the REAL bin/fm-present-daemon.sh (the dispatch at its foot is
# guarded so a source runs only the definitions) and exercise the pane-wake
# helpers directly with fake backend primitives, so the decision and guard logic
# is pinned without launching a real watcher or touching a real pane.

# Run a bash snippet with the daemon sourced and its backend primitives replaced
# by test doubles. The snippet is evaluated after sourcing; it prints its own
# result. FM_SUPERVISOR_HARNESS/target/backend and the config dir are inherited
# from the caller's environment. STATE points at a scratch dir so log_line has
# somewhere to write.
pane_wake_eval() {  # <home> <snippet>
  local home=$1 snippet=$2
  mkdir -p "$home/state" "$home/config"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" bash -c '
      set -u
      # shellcheck source=/dev/null
      . "'"$ROOT"'/bin/fm-present-daemon.sh"
      '"$snippet"'
    '
}

test_pane_wake_disabled_by_default_on_claude() {
  local home="$TMP_ROOT/pw-claude" out
  out=$(FM_SUPERVISOR_HARNESS=claude pane_wake_eval "$home" '
    if pane_wake_enabled; then echo ENABLED; else echo DISABLED; fi')
  [ "$out" = DISABLED ] || fail "pane-wake must be OFF on claude with no flag, got: $out"
  pass "pane-wake stays off on a claude primary when the flag is absent"
}

test_pane_wake_auto_on_for_jcode() {
  local home="$TMP_ROOT/pw-jcode" out
  out=$(FM_SUPERVISOR_HARNESS=jcode pane_wake_eval "$home" '
    if pane_wake_enabled; then echo ENABLED; else echo DISABLED; fi')
  [ "$out" = ENABLED ] || fail "pane-wake must auto-enable on jcode, got: $out"
  pass "pane-wake auto-enables on a jcode primary without the flag"
}

test_pane_wake_flag_forces_on_for_claude() {
  local home="$TMP_ROOT/pw-flag-on" out
  mkdir -p "$home/config"
  : > "$home/config/present-daemon-pane-wake"
  out=$(FM_SUPERVISOR_HARNESS=claude pane_wake_eval "$home" '
    if pane_wake_enabled; then echo ENABLED; else echo DISABLED; fi')
  [ "$out" = ENABLED ] || fail "the flag must force pane-wake on even for claude, got: $out"
  pass "config/present-daemon-pane-wake forces pane-wake on regardless of harness"
}

test_pane_wake_flag_off_forces_off_for_jcode() {
  local home="$TMP_ROOT/pw-flag-off" out
  mkdir -p "$home/config"
  printf 'off\n' > "$home/config/present-daemon-pane-wake"
  out=$(FM_SUPERVISOR_HARNESS=jcode pane_wake_eval "$home" '
    if pane_wake_enabled; then echo ENABLED; else echo DISABLED; fi')
  [ "$out" = DISABLED ] || fail "a flag reading 'off' must force pane-wake off even on jcode, got: $out"
  pass "config/present-daemon-pane-wake='off' overrides the jcode auto path"
}

test_pane_wake_resolve_active_with_real_pane() {
  local home="$TMP_ROOT/pw-resolve" out
  # shellcheck disable=SC2016 # $PANE_WAKE_* must expand inside the sourced subshell, not here.
  out=$(FM_SUPERVISOR_HARNESS=jcode FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET='%3' \
    pane_wake_eval "$home" '
      pane_wake_resolve
      echo "$PANE_WAKE_ACTIVE|$PANE_WAKE_BACKEND|$PANE_WAKE_TARGET"')
  [ "$out" = "1|tmux|%3" ] || fail "resolve must activate with a real tmux pane, got: $out"
  pass "pane_wake_resolve activates when a real supervisor pane resolves"
}

test_pane_wake_resolve_degrades_on_fallback_pane() {
  local home="$TMP_ROOT/pw-fallback" out
  # No FM_SUPERVISOR_TARGET, no TMUX_PANE, no HERDR env: only the firstmate:0
  # fallback remains, so pane-wake must degrade silently (no pane identified).
  # The vars are unset INSIDE the sourced subshell (env(1) cannot run a shell
  # function like pane_wake_eval), before pane_wake_resolve reads them.
  # shellcheck disable=SC2016 # $PANE_WAKE_ACTIVE must expand inside the sourced subshell, not here.
  out=$(FM_SUPERVISOR_HARNESS=jcode FM_SUPERVISOR_BACKEND=tmux \
    pane_wake_eval "$home" '
      unset TMUX_PANE HERDR_ENV HERDR_PANE_ID FM_SUPERVISOR_TARGET
      pane_wake_resolve
      echo "$PANE_WAKE_ACTIVE"')
  [ "$out" = 0 ] || fail "resolve must degrade when only the firstmate:0 fallback remains, got: $out"
  pass "pane_wake_resolve degrades silently when no real supervisor pane resolves"
}

test_pane_wake_resolve_degrades_on_unsupported_backend() {
  local home="$TMP_ROOT/pw-unsupported" out
  # shellcheck disable=SC2016 # $PANE_WAKE_ACTIVE must expand inside the sourced subshell, not here.
  out=$(FM_SUPERVISOR_HARNESS=jcode FM_SUPERVISOR_BACKEND=zellij FM_SUPERVISOR_TARGET='z1' \
    pane_wake_eval "$home" '
      pane_wake_resolve
      echo "$PANE_WAKE_ACTIVE"')
  [ "$out" = 0 ] || fail "resolve must degrade on an unsupported backend, got: $out"
  pass "pane_wake_resolve degrades silently on an unsupported supervisor backend"
}

test_pane_wake_resolve_off_when_disabled() {
  local home="$TMP_ROOT/pw-resolve-off" out
  # shellcheck disable=SC2016 # $PANE_WAKE_ACTIVE must expand inside the sourced subshell, not here.
  out=$(FM_SUPERVISOR_HARNESS=claude FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET='%3' \
    pane_wake_eval "$home" '
      pane_wake_resolve
      echo "$PANE_WAKE_ACTIVE"')
  [ "$out" = 0 ] || fail "resolve must stay inactive when pane-wake is disabled, got: $out"
  pass "pane_wake_resolve stays inactive when pane-wake is disabled (claude, no flag)"
}

# The guard-reuse tests replace the backend primitives with doubles AFTER
# sourcing, then drive pane_wake_inject. The submit double records reaching the
# submit primitive by touching a marker file (pane_wake_inject sends the real
# submit's stderr to /dev/null, so the double cannot signal through stderr),
# proving a busy pane or a non-empty composer defers before the submit.
test_pane_wake_inject_submits_on_idle_empty_pane() {
  local home="$TMP_ROOT/pw-inject-ok" out
  out=$(pane_wake_eval "$home" '
    PANE_WAKE_ACTIVE=1; PANE_WAKE_BACKEND=tmux; PANE_WAKE_TARGET=%3
    fm_backend_target_exists() { return 0; }
    fm_backend_busy_state() { printf idle; }
    fm_backend_capture() { printf "an idle agent prompt\n"; }
    fm_backend_composer_state() { printf empty; }
    fm_backend_send_text_submit() { : > "'"$home"'/submit.mark"; printf empty; }
    pane_wake_inject
    if [ -e "'"$home"'/submit.mark" ]; then echo SUBMITTED; else echo NOSUBMIT; fi')
  [ "$out" = SUBMITTED ] || fail "inject must submit into an idle, confirmed-empty pane, got: $out"
  pass "pane_wake_inject submits the wake nudge into an idle empty pane"
}

test_pane_wake_inject_defers_on_busy_pane() {
  local home="$TMP_ROOT/pw-inject-busy" out
  out=$(pane_wake_eval "$home" '
    PANE_WAKE_ACTIVE=1; PANE_WAKE_BACKEND=tmux; PANE_WAKE_TARGET=%3
    fm_backend_target_exists() { return 0; }
    fm_backend_busy_state() { printf busy; }
    fm_backend_capture() { printf ""; }
    fm_backend_composer_state() { printf empty; }
    fm_backend_send_text_submit() { : > "'"$home"'/submit.mark"; printf empty; }
    pane_wake_inject
    if [ -e "'"$home"'/submit.mark" ]; then echo SUBMITTED; else echo DEFERRED; fi')
  [ "$out" = DEFERRED ] || fail "inject must defer on a busy pane, never submit, got: $out"
  pass "pane_wake_inject defers (no submit) when the supervisor pane is busy"
}

test_pane_wake_inject_defers_on_pending_composer() {
  local home="$TMP_ROOT/pw-inject-pending" out
  out=$(pane_wake_eval "$home" '
    PANE_WAKE_ACTIVE=1; PANE_WAKE_BACKEND=tmux; PANE_WAKE_TARGET=%3
    fm_backend_target_exists() { return 0; }
    fm_backend_busy_state() { printf idle; }
    fm_backend_capture() { printf "an idle prompt\n"; }
    fm_backend_composer_state() { printf pending; }
    fm_backend_send_text_submit() { : > "'"$home"'/submit.mark"; printf empty; }
    pane_wake_inject
    if [ -e "'"$home"'/submit.mark" ]; then echo SUBMITTED; else echo DEFERRED; fi')
  [ "$out" = DEFERRED ] || fail "inject must defer on a non-empty composer, got: $out"
  pass "pane_wake_inject defers (no submit) when the composer holds unsubmitted text"
}

test_pane_wake_inject_noop_when_inactive() {
  local home="$TMP_ROOT/pw-inject-inactive" out
  out=$(pane_wake_eval "$home" '
    PANE_WAKE_ACTIVE=0; PANE_WAKE_BACKEND=tmux; PANE_WAKE_TARGET=%3
    fm_backend_target_exists() { echo "REACHED" >&2; return 0; }
    pane_wake_inject 2>"'"$home"'/reach.log"
    if grep -q "^REACHED" "'"$home"'/reach.log"; then echo REACHED; else echo NOOP; fi')
  [ "$out" = NOOP ] || fail "inject must be a no-op when pane-wake is inactive, got: $out"
  pass "pane_wake_inject is a no-op when pane-wake did not resolve active"
}

# --- herdr pane-id drift recovery (the never-blind fix) ----------------------
# Herdr reassigns a session's pane id under the same live tab, silently freezing
# a startup-resolved pane-wake target. These tests drive pane_wake_refresh_target
# and pane_wake_inject with fake herdr primitives to pin that a drifted target is
# re-resolved by its stable tab identity and the NEW pane is woken, instead of
# logging "gone; skipping" forever.

test_pane_wake_refresh_keeps_a_live_target() {
  # When the recorded target still exists, keep it verbatim - no re-resolve.
  local home="$TMP_ROOT/pw-refresh-live" out
  # shellcheck disable=SC2016 # $PANE_WAKE_*/$'...' must expand inside the sourced subshell, not here.
  out=$(pane_wake_eval "$home" '
    PANE_WAKE_ACTIVE=1; PANE_WAKE_BACKEND=herdr
    PANE_WAKE_TARGET=default:w19:pA; PANE_WAKE_TAB_IDENTITY=$'"'"'default\tt5'"'"'
    fm_backend_target_exists() { [ "$2" = default:w19:pA ]; }
    fm_backend_herdr_target_for_tab_identity() { echo "SHOULD-NOT-RESOLVE"; }
    if pane_wake_refresh_target; then echo "OK|$PANE_WAKE_TARGET"; else echo "FAIL"; fi')
  [ "$out" = "OK|default:w19:pA" ] || fail "a live target must pass through unchanged, got: $out"
  pass "pane_wake_refresh_target keeps a still-live target without re-resolving"
}

test_pane_wake_refresh_reresolves_drifted_target() {
  # The recorded pane is gone but its tab survived and now owns a NEW pane id.
  local home="$TMP_ROOT/pw-refresh-drift" out
  # shellcheck disable=SC2016 # $PANE_WAKE_*/$'...' must expand inside the sourced subshell, not here.
  out=$(pane_wake_eval "$home" '
    PANE_WAKE_ACTIVE=1; PANE_WAKE_BACKEND=herdr
    PANE_WAKE_TARGET=default:w19:pA; PANE_WAKE_TAB_IDENTITY=$'"'"'default\tt5'"'"'
    # Old pane gone; new pane present.
    fm_backend_target_exists() { [ "$2" = default:w19:p9 ]; }
    fm_backend_herdr_target_for_tab_identity() {
      [ "$1" = default ] && [ "$2" = t5 ] && echo default:w19:p9; }
    if pane_wake_refresh_target; then echo "OK|$PANE_WAKE_TARGET"; else echo "FAIL|$PANE_WAKE_TARGET"; fi')
  [ "$out" = "OK|default:w19:p9" ] \
    || fail "a drifted target must re-resolve to the new pane, got: $out"
  pass "pane_wake_refresh_target re-resolves a drifted pane id via its stable tab identity"
}

test_pane_wake_refresh_fails_when_tab_gone() {
  # Both the recorded pane AND its tab are gone: firstmate's own pane genuinely
  # closed, so refresh must fail (no wake into an unrelated pane).
  local home="$TMP_ROOT/pw-refresh-gone" out
  # shellcheck disable=SC2016 # $PANE_WAKE_*/$'...' must expand inside the sourced subshell, not here.
  out=$(pane_wake_eval "$home" '
    PANE_WAKE_ACTIVE=1; PANE_WAKE_BACKEND=herdr
    PANE_WAKE_TARGET=default:w19:pA; PANE_WAKE_TAB_IDENTITY=$'"'"'default\tt5'"'"'
    fm_backend_target_exists() { return 1; }
    fm_backend_herdr_target_for_tab_identity() { return 1; }
    if pane_wake_refresh_target; then echo "RESOLVED"; else echo "REFUSED"; fi')
  [ "$out" = REFUSED ] || fail "refresh must refuse when the tab itself is gone, got: $out"
  pass "pane_wake_refresh_target refuses when firstmate's own tab is genuinely gone"
}

test_pane_wake_refresh_no_identity_cannot_recover() {
  # No captured tab identity (e.g. tmux, or a herdr resolve that could not read
  # the tab): a gone target cannot be recovered, so refresh fails cleanly.
  local home="$TMP_ROOT/pw-refresh-noid" out
  out=$(pane_wake_eval "$home" '
    PANE_WAKE_ACTIVE=1; PANE_WAKE_BACKEND=herdr
    PANE_WAKE_TARGET=default:w19:pA; PANE_WAKE_TAB_IDENTITY=
    fm_backend_target_exists() { return 1; }
    fm_backend_herdr_target_for_tab_identity() { echo "SHOULD-NOT-BE-CALLED"; }
    if pane_wake_refresh_target; then echo "RESOLVED"; else echo "REFUSED"; fi')
  [ "$out" = REFUSED ] || fail "refresh must refuse a gone target with no tab identity, got: $out"
  pass "pane_wake_refresh_target cannot recover a gone target without a captured tab identity"
}

test_pane_wake_inject_wakes_the_drifted_pane() {
  # End to end through pane_wake_inject: the recorded pane drifted, so inject must
  # re-resolve and submit into the NEW pane, not skip.
  local home="$TMP_ROOT/pw-inject-drift" out
  # shellcheck disable=SC2016 # $PANE_WAKE_*/$'...'/$(cat) must expand inside the sourced subshell, not here.
  out=$(pane_wake_eval "$home" '
    PANE_WAKE_ACTIVE=1; PANE_WAKE_BACKEND=herdr
    PANE_WAKE_TARGET=default:w19:pA; PANE_WAKE_TAB_IDENTITY=$'"'"'default\tt5'"'"'
    fm_backend_target_exists() { [ "$2" = default:w19:p9 ]; }
    fm_backend_herdr_target_for_tab_identity() { echo default:w19:p9; }
    fm_backend_busy_state() { printf idle; }
    fm_backend_capture() { printf "an idle prompt\n"; }
    fm_backend_composer_state() { printf empty; }
    fm_backend_send_text_submit() { printf "%s" "$2" > "'"$home"'/submit-target"; printf empty; }
    pane_wake_inject
    if [ -e "'"$home"'/submit-target" ]; then echo "SUBMITTED|$(cat "'"$home"'/submit-target")"; else echo NOSUBMIT; fi')
  [ "$out" = "SUBMITTED|default:w19:p9" ] \
    || fail "inject must re-resolve the drifted target and wake the NEW pane, got: $out"
  pass "pane_wake_inject wakes the re-resolved pane after a pane-id drift"
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
test_status_and_stop_see_a_live_daemon
test_pane_wake_disabled_by_default_on_claude
test_pane_wake_auto_on_for_jcode
test_pane_wake_flag_forces_on_for_claude
test_pane_wake_flag_off_forces_off_for_jcode
test_pane_wake_resolve_active_with_real_pane
test_pane_wake_resolve_degrades_on_fallback_pane
test_pane_wake_resolve_degrades_on_unsupported_backend
test_pane_wake_resolve_off_when_disabled
test_pane_wake_inject_submits_on_idle_empty_pane
test_pane_wake_inject_defers_on_busy_pane
test_pane_wake_inject_defers_on_pending_composer
test_pane_wake_inject_noop_when_inactive
test_pane_wake_refresh_keeps_a_live_target
test_pane_wake_refresh_reresolves_drifted_target
test_pane_wake_refresh_fails_when_tab_gone
test_pane_wake_refresh_no_identity_cannot_recover
test_pane_wake_inject_wakes_the_drifted_pane
