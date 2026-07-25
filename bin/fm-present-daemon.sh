#!/usr/bin/env bash
# Present-mode supervision daemon: keep a live watcher armed WITHOUT spending the
# active firstmate session's turn on it.
#
# The watcher (bin/fm-watch.sh) is single-shot on an actionable wake: it enqueues
# the wake to state/.wake-queue, prints one reason line, and exits. Something must
# then re-arm it. Today that something is the active session, which pays a
# per-turn tax: run bin/fm-watch-arm.sh as a tracked background task and park up
# to a full poll waiting for the arm to confirm. This daemon is that re-arm loop,
# moved off the session and into one small detached background process.
#
# It NEVER classifies, decides, or acts on a wake. Every wake stays in the durable
# queue for firstmate to drain at the top of its next turn. That is the safety
# line separating this from the away-mode sub-supervisor (bin/fm-supervise-daemon.sh),
# which does own triage, escalation, and injection. This daemon owns none of it and
# changes no approval authority.
#
# Usage:
#   fm-present-daemon.sh start
#     Launch the loop DETACHED (its own session leader) so a disconnecting
#     terminal or a finished harness background task cannot reap it, then return
#     immediately. Prints exactly one line:
#       present-daemon: started pid=<N>
#       present-daemon: already running pid=<N>
#       present-daemon: disabled (config/present-daemon absent)
#       present-daemon: skipped (away mode owns supervision)
#       present-daemon: FAILED - <reason>
#     Exits non-zero only on FAILED; disabled/skipped/already-running are exit 0
#     so a session-start sweep can call it unconditionally and idempotently.
#   fm-present-daemon.sh run
#     Run the loop in the FOREGROUND. This is what `start` execs after detaching;
#     tests and manual debugging use it directly.
#   fm-present-daemon.sh status
#     Print "present-daemon: running pid=<N>" and exit 0 when this home's daemon
#     is alive, or "present-daemon: not running" and exit 1 when it is not.
#   fm-present-daemon.sh stop
#     Signal ONLY this home's recorded daemon pid and wait for it to exit.
#
# Opt-in: the whole feature is inert unless the local, gitignored
# config/present-daemon presence flag exists. See docs/configuration.md.
#
# Away-mode interlock: while state/.afk exists the away daemon owns supervision,
# so the two never supervise concurrently. `start` refuses under the flag,
# bin/fm-afk-start.sh stops this daemon before the away daemon takes over, and a
# running loop re-checks the flag between arm cycles as a backstop for a flag set
# by any other route.
#
# Never-blind is unchanged. This daemon does not touch either guard
# (bin/fm-continuity-pretool-check.sh, bin/fm-turnend-guard.sh) and does not touch
# the SESSION lock (state/.lock). It only keeps a watcher in the WATCH lock
# (state/.watch.lock) beating state/.last-watcher-beat. If this daemon dies, the
# orphaned watcher ends on its next actionable wake, nobody re-arms, the beacon
# ages past the guard grace, and the turn-end guard fires its normal alarm - the
# session degrades to exactly today's per-turn arm, never to blind.
#
# Home scoping: every kill targets a pid recorded in THIS home's own lock. NEVER
# `pkill -f bin/fm-watch.sh` or `pkill -f fm-present-daemon.sh` - those patterns
# match every firstmate home on the machine, including secondmates.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ARM="$SCRIPT_DIR/fm-watch-arm.sh"
FLAG="$CONFIG/present-daemon"
AFK="$STATE/.afk"
DAEMON_LOCK="$STATE/.present-daemon.lock"
LOG="$STATE/.present-daemon.log"
# An arm cycle shorter than this counts as "rapid" for crash-loop detection.
RAPID_SECONDS=${FM_PRESENT_RAPID_SECONDS:-5}
# Consecutive rapid failures before the daemon surfaces a degraded wake.
FAILURE_THRESHOLD=${FM_PRESENT_FAILURE_THRESHOLD:-5}
BACKOFF_BASE=${FM_PRESENT_BACKOFF_BASE:-2}
BACKOFF_MAX=${FM_PRESENT_BACKOFF_MAX:-60}
LOG_MAX_BYTES=${FM_PRESENT_LOG_MAX_BYTES:-262144}
LOG_KEEP_LINES=${FM_PRESENT_LOG_KEEP_LINES:-500}

# A misconfigured knob must refuse loudly rather than silently degrade the loop
# into a spin or a permanent stall.
require_positive_int() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*|0)
      echo "present-daemon: FAILED - $1 must be a positive integer" >&2
      exit 2
      ;;
  esac
}

require_positive_int FM_PRESENT_RAPID_SECONDS "$RAPID_SECONDS"
require_positive_int FM_PRESENT_FAILURE_THRESHOLD "$FAILURE_THRESHOLD"
require_positive_int FM_PRESENT_BACKOFF_BASE "$BACKOFF_BASE"
require_positive_int FM_PRESENT_BACKOFF_MAX "$BACKOFF_MAX"
require_positive_int FM_PRESENT_LOG_MAX_BYTES "$LOG_MAX_BYTES"
require_positive_int FM_PRESENT_LOG_KEEP_LINES "$LOG_KEEP_LINES"

# --- shared helpers ---------------------------------------------------------

log_line() {
  local size
  size=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
    if tail -n "$LOG_KEEP_LINES" "$LOG" > "$LOG.trim" 2>/dev/null; then
      mv "$LOG.trim" "$LOG" 2>/dev/null || rm -f "$LOG.trim" 2>/dev/null
    else
      rm -f "$LOG.trim" 2>/dev/null
    fi
  fi
  printf '%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$LOG" 2>/dev/null || true
}

enabled() {
  [ -f "$FLAG" ]
}

away_mode_active() {
  [ -e "$AFK" ]
}

# The daemon lock records only the field names fm_lock_clean_known_files knows,
# so a release never strands an owner directory. `pid-identity` is what makes a
# recycled pid a mismatch rather than a false "already running".
daemon_lock_pid() {
  cat "$DAEMON_LOCK/pid" 2>/dev/null || true
}

daemon_lock_matches_pid() {
  local pid=$1 lock_home lock_identity current
  lock_home=$(cat "$DAEMON_LOCK/fm-home" 2>/dev/null || true)
  [ "$lock_home" = "$FM_HOME" ] || return 1
  lock_identity=$(cat "$DAEMON_LOCK/pid-identity" 2>/dev/null || true)
  [ -n "$lock_identity" ] || return 1
  current=$(fm_pid_identity "$pid") || return 1
  [ "$current" = "$lock_identity" ]
}

daemon_alive_pid() {
  local pid
  pid=$(daemon_lock_pid)
  fm_pid_alive "$pid" || return 1
  daemon_lock_matches_pid "$pid" || return 1
  printf '%s\n' "$pid"
}

# --- the loop (run) ---------------------------------------------------------

RUNNING=1
ARM_PID=
SLEEP_PID=

release_daemon_lock() {
  fm_lock_release "$DAEMON_LOCK" 2>/dev/null || true
}

stop_arm_child() {
  [ -n "$ARM_PID" ] || return 0
  fm_pid_alive "$ARM_PID" || return 0
  # The arm owns its watcher child and tears it down on SIGTERM, so this one
  # signal ends the whole cycle without ever matching another home's watcher.
  kill -TERM "$ARM_PID" 2>/dev/null || true
}

# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_signal() {
  RUNNING=0
  [ -n "$SLEEP_PID" ] && kill -TERM "$SLEEP_PID" 2>/dev/null
  stop_arm_child
}

# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
on_exit() {
  stop_arm_child
  release_daemon_lock
}

# Sleep in a killable child so a shutdown signal lands immediately instead of
# behind a foreground sleep - the same wedge bin/fm-watch.sh fixed with its own
# backgrounded sleep child.
interruptible_sleep() {  # <seconds>
  sleep "$1" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null || true
  SLEEP_PID=
}

# Run one arm cycle and block until it ends. The loop idles inside `wait`, never
# polling: the arm itself blocks until its watcher's cycle ends, which under the
# in-process benign-wake absorb in bin/fm-watch.sh is roughly once per genuinely
# actionable wake. A shutdown signal interrupts this `wait` and runs the trap
# immediately, so no signal ever queues behind a foreground sleep.
run_arm_cycle() {
  local rc=0
  "$ARM" >> "$LOG" 2>&1 &
  ARM_PID=$!
  wait "$ARM_PID" 2>/dev/null || rc=$?
  # A signal handled mid-wait leaves the arm mid-teardown; reap it for real so
  # the next cycle never races a dying watcher for the watch lock.
  if fm_pid_alive "$ARM_PID"; then
    stop_arm_child
    wait "$ARM_PID" 2>/dev/null || rc=$?
  fi
  ARM_PID=
  CYCLE_RC=$rc
}

run_main() {
  local started rc elapsed failures=0 backoff degraded=0

  enabled || { echo "present-daemon: disabled (config/present-daemon absent)"; return 0; }
  if away_mode_active; then
    echo "present-daemon: skipped (away mode owns supervision)"
    return 0
  fi
  [ -x "$ARM" ] || { echo "present-daemon: FAILED - missing $ARM" >&2; return 1; }

  if ! fm_lock_try_acquire "$DAEMON_LOCK"; then
    echo "present-daemon: already running pid=${FM_LOCK_HELD_PID:-unknown}"
    return 0
  fi
  # Bind the lock to this home and this process's identity before any cycle runs,
  # so a recycled pid can never read as a live daemon.
  printf '%s\n' "$FM_HOME" > "$DAEMON_LOCK/fm-home" 2>/dev/null || true
  fm_pid_identity "$(fm_current_pid)" > "$DAEMON_LOCK/pid-identity" 2>/dev/null || true

  trap on_exit EXIT
  trap handle_signal HUP TERM INT

  log_line "start pid=$(fm_current_pid) home=$FM_HOME"
  while [ "$RUNNING" -eq 1 ]; do
    if away_mode_active; then
      log_line "stop reason=afk"
      break
    fi
    started=$(date +%s)
    run_arm_cycle
    rc=$CYCLE_RC
    [ "$RUNNING" -eq 1 ] || { log_line "stop reason=signal"; break; }
    elapsed=$(( $(date +%s) - started ))

    if [ "$rc" -eq 0 ] || [ "$elapsed" -ge "$RAPID_SECONDS" ]; then
      # A wake exit (rc 0) or any cycle that actually ran for a while is a
      # healthy cycle: re-arm straight away so the watcher gap stays in
      # milliseconds, far inside the guard grace.
      [ "$failures" -eq 0 ] || log_line "recovered after $failures rapid failure(s)"
      failures=0
      degraded=0
      # A clean-but-instant return would otherwise re-arm in a tight loop and
      # burn a core on a resource-constrained host. One second is invisible
      # against the guard grace and makes the loop unspinnable by construction.
      [ "$elapsed" -ge "$RAPID_SECONDS" ] || interruptible_sleep 1
      continue
    fi

    failures=$((failures + 1))
    backoff=$((BACKOFF_BASE * failures))
    [ "$backoff" -gt "$BACKOFF_MAX" ] && backoff=$BACKOFF_MAX
    log_line "rapid arm failure rc=$rc elapsed=${elapsed}s consecutive=$failures backoff=${backoff}s"
    if [ "$failures" -ge "$FAILURE_THRESHOLD" ] && [ "$degraded" -eq 0 ]; then
      degraded=1
      # Surface through the durable queue only. The daemon reports the problem;
      # firstmate decides what to do about it.
      fm_wake_append check present-daemon \
        "present-mode supervision daemon cannot keep a watcher armed ($failures consecutive rapid failures, rc=$rc); re-arm supervision from the session and check $LOG" \
        || log_line "degraded wake enqueue failed"
      log_line "degraded: surfaced check wake after $failures consecutive rapid failures"
    fi
    interruptible_sleep "$backoff"
  done
  log_line "exit pid=$(fm_current_pid)"
  return 0
}

# --- detached launch (start) ------------------------------------------------

# macOS ships no setsid(1), so fall back to perl's POSIX::setsid after a fork.
# Either way the loop becomes its own session leader with no controlling
# terminal, which is what keeps a disconnecting terminal or a completed harness
# background task from reaping it.
launch_detached() {
  if command -v setsid >/dev/null 2>&1; then
    setsid "$SELF" run >> "$LOG" 2>&1 < /dev/null &
    return 0
  fi
  command -v perl >/dev/null 2>&1 || return 1
  perl -e '
    use POSIX qw(setsid);
    my $pid = fork();
    die "fork failed" unless defined $pid;
    exit 0 if $pid;
    setsid();
    exec @ARGV or die "exec failed";
  ' "$SELF" run >> "$LOG" 2>&1 < /dev/null
}

start_main() {
  local pid i

  enabled || { echo "present-daemon: disabled (config/present-daemon absent)"; return 0; }
  if away_mode_active; then
    echo "present-daemon: skipped (away mode owns supervision)"
    return 0
  fi
  if pid=$(daemon_alive_pid); then
    echo "present-daemon: already running pid=$pid"
    return 0
  fi
  [ -x "$ARM" ] || { echo "present-daemon: FAILED - missing $ARM" >&2; return 1; }

  if ! launch_detached; then
    echo "present-daemon: FAILED - no way to detach (need setsid or perl)" >&2
    return 1
  fi

  # Confirm the detached loop actually took the lock rather than reporting a
  # start off a process that died immediately.
  i=0
  while [ "$i" -lt 50 ]; do
    if pid=$(daemon_alive_pid); then
      echo "present-daemon: started pid=$pid"
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  echo "present-daemon: FAILED - detached loop did not take the lock within 5s (see $LOG)" >&2
  return 1
}

status_main() {
  local pid
  if pid=$(daemon_alive_pid); then
    echo "present-daemon: running pid=$pid"
    return 0
  fi
  echo "present-daemon: not running"
  return 1
}

stop_main() {
  local pid i
  if ! pid=$(daemon_alive_pid); then
    echo "present-daemon: not running"
    return 0
  fi
  kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 100 ] && fm_pid_alive "$pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  if fm_pid_alive "$pid"; then
    echo "present-daemon: FAILED - pid=$pid did not exit" >&2
    return 1
  fi
  echo "present-daemon: stopped pid=$pid"
  return 0
}

usage() {
  sed -n '2,58p' "$SELF" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  start) start_main ;;
  run) run_main ;;
  status) status_main ;;
  stop) stop_main ;;
  -h|--help) usage ;;
  *) echo "usage: $(basename "$0") start|run|status|stop" >&2; exit 2 ;;
esac
