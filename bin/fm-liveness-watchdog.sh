#!/usr/bin/env bash
# fm-liveness-watchdog.sh - EXTERNAL liveness watchdog for the firstmate primary.
#
# Why this exists (data/scout-overnight-turnover-while-captain-asleep/report.md):
# on 2026-07-29 the hosted firstmate primary was collected by an idle sweep,
# which tree-killed its child supervision watcher in the same stroke. The fleet
# sat silent 3h41m with no self-recovery, because the one process that would have
# woken the session died with it. The idle-sweep cause is closed on the patched
# daemon, but the STRUCTURAL gap remains: whenever the hosted primary dies for
# ANY reason (daemon crash, deliberate restart, a reverted pin, a future
# failure), its in-process watcher dies with it and nothing observes the fleet
# until a human attaches.
#
# This watchdog closes that gap. It runs OUTSIDE the agent process tree, so
# whatever kills the primary cannot kill it, and it watches durable on-disk state
# (state/*.meta plus the watcher beacon state/.last-watcher-beat) that SURVIVES
# the primary's death. When work is recorded as under way but no watcher has
# beaten within the grace window, the primary's supervision is gone: the watchdog
# pushes an alert to the captain's phone AND attempts a capped, rate-limited
# auto-resume, then alerts again with whether the resume succeeded.
#
# Outside-the-tree hosting on THIS host: there is no launchd (Linux), and no
# systemd/cron available, so - exactly like bin/fm-present-daemon.sh - the loop
# detaches with setsid (or a perl setsid fallback) into its own session leader
# with no controlling terminal, which reparents it to init. A tree-kill of the
# agent (the failure this defends against) therefore cannot reach it, and a
# disconnecting terminal or a finished harness background task cannot reap it. If
# the watchdog process itself ever dies, the next locked session start relaunches
# it (bin/fm-bootstrap.sh liveness_watchdog_sweep), the same belt-and-suspenders
# the present daemon uses.
#
# What it is NOT: it does not classify, decide, or act on ordinary wakes (that is
# the watcher and firstmate itself), and it is not the fix for the composer-defer
# wedge (bin/fm-supervise-daemon.sh deferring injection while the primary is
# alive - a separate ticket). Its stale-beacon signal DOES incidentally catch a
# wedged-but-alive primary as a secondary benefit: when the optional alive-probe
# says the primary is still running but supervision has been dead past grace, it
# alerts "supervision stalled, primary still alive" and deliberately does NOT
# resume a live process. It does not attempt to fix that wedge.
#
# Opt-in: inert unless config/liveness-watchdog exists. Away-mode interlock: the
# away daemon (bin/fm-afk-launch.sh start-paneless) already hosts a durable,
# session-independent watcher outside the session; this watchdog stands down
# under state/.afk to avoid two supervisors racing a resume.
#
# Config (all local, gitignored; see docs/liveness-watchdog.md):
#   config/liveness-watchdog       presence flag: enable the watchdog
#   config/liveness-alarm          alarm channels (fm-alarm-lib grammar); falls
#                                  back to config/wedge-alarm, then `auto`
#   config/liveness-resume         auto-resume command run via `sh -c`; absent
#                                  means resume is not possible and the alarm says so
#   config/liveness-alive-probe    optional command; exit 0 = primary alive,
#                                  nonzero = dead. Absent = treat as dead (resume)
#
# Usage:
#   fm-liveness-watchdog.sh start    launch the loop DETACHED and return; prints one line
#   fm-liveness-watchdog.sh run      run the loop in the foreground (what start execs)
#   fm-liveness-watchdog.sh tick     evaluate ONCE and act; the pure decision, used by tests
#   fm-liveness-watchdog.sh status   print running/not-running and exit 0/1
#   fm-liveness-watchdog.sh stop     signal ONLY this home's recorded watchdog and wait
#
# Home scoping: every kill targets a pid recorded in THIS home's own lock. NEVER
# a broad pkill, which would match every firstmate home on the machine.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-alarm-lib.sh
. "$SCRIPT_DIR/fm-alarm-lib.sh"

CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
FLAG="$CONFIG/liveness-watchdog"
ALARM_CONFIG="$CONFIG/liveness-alarm"
WEDGE_ALARM_CONFIG="$CONFIG/wedge-alarm"
RESUME_CONFIG="$CONFIG/liveness-resume"
ALIVE_PROBE_CONFIG="$CONFIG/liveness-alive-probe"
AFK="$STATE/.afk"
DAEMON_LOCK="$STATE/.liveness-watchdog.lock"
LOG="$STATE/.liveness-watchdog.log"
# Durable per-episode trigger state: the beacon key that armed the current
# down-episode, how many resumes we have attempted in it, and whether we already
# reported cap-reached. One line each; bounded, overwritten, never grows.
EPISODE_MARKER="$STATE/.liveness-watchdog-episode"
RESUME_COUNT_MARKER="$STATE/.liveness-watchdog-resumes"
CAP_REPORTED_MARKER="$STATE/.liveness-watchdog-capreported"

# The staleness threshold. Reuses the watcher-liveness grace so the watchdog and
# the in-session guard (bin/fm-guard.sh) agree on "the watcher is down".
GRACE=${FM_GUARD_GRACE:-900}
# How often the loop evaluates. Far shorter than GRACE so a real death is caught
# within roughly one interval past grace, not a full grace window later.
INTERVAL=${FM_LIVENESS_INTERVAL:-60}
# Maximum auto-resume attempts within one down-episode before the watchdog stops
# retrying and escalates through the alarm instead. A resume loop against a
# genuinely broken primary is worse than silence.
MAX_RESUMES=${FM_LIVENESS_MAX_RESUMES:-3}

require_positive_int() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*|0)
      echo "liveness-watchdog: FAILED - $1 must be a positive integer" >&2
      exit 2
      ;;
  esac
}
require_positive_int FM_GUARD_GRACE "$GRACE"
require_positive_int FM_LIVENESS_INTERVAL "$INTERVAL"
require_positive_int FM_LIVENESS_MAX_RESUMES "$MAX_RESUMES"

# --- shared helpers ---------------------------------------------------------

log_line() {
  printf '%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$LOG" 2>/dev/null || true
}

enabled() {
  [ -f "$FLAG" ]
}

away_mode_active() {
  [ -e "$AFK" ]
}

# The alarm config: prefer the dedicated liveness file, fall back to the wedge
# alarm file (so a home that already wired a phone push for wedges gets liveness
# alerts for free), then to fm-alarm-lib's own `auto` default when neither exists.
resolve_alarm_config() {
  if [ -f "$ALARM_CONFIG" ]; then
    printf '%s\n' "$ALARM_CONFIG"
  elif [ -f "$WEDGE_ALARM_CONFIG" ]; then
    printf '%s\n' "$WEDGE_ALARM_CONFIG"
  else
    printf '%s\n' "$ALARM_CONFIG"  # absent; fm_alarm_notify falls back to `auto`
  fi
}

fire_alarm() {  # <summary>
  local summary=$1 config
  config=$(resolve_alarm_config)
  FM_ALARM_TITLE="firstmate: PRIMARY SUPERVISION DOWN" \
    fm_alarm_notify "$config" "$summary" || true
  if [ "$FM_ALARM_FIRED" -eq 1 ]; then
    log_line "alarm fired: $summary"
  else
    log_line "alarm had no channel (configure config/liveness-alarm command:); summary: $summary"
  fi
}

# Report the primary's aliveness via the optional probe. Prints "alive", "dead",
# or "unknown". No probe configured -> "unknown", which the caller treats as
# dead-enough to resume (the primary's supervision is provably gone either way).
probe_primary() {
  local out rc
  [ -f "$ALIVE_PROBE_CONFIG" ] || { printf 'unknown\n'; return 0; }
  out=$(cat "$ALIVE_PROBE_CONFIG" 2>/dev/null) || out=""
  [ -n "$out" ] || { printf 'unknown\n'; return 0; }
  if fm_alarm_run_bounded sh -c "$out" fm-liveness-probe >/dev/null 2>&1; then
    printf 'alive\n'
  else
    rc=$?
    if [ "$rc" -eq 124 ]; then
      printf 'unknown\n'  # probe timed out; do not claim dead on a hang
    else
      printf 'dead\n'
    fi
  fi
}

# Attempt one auto-resume. Returns 0 when the configured command exits 0, 1 when
# it fails, and 3 when no resume command is configured (nothing to run).
attempt_resume() {
  local cmd
  [ -f "$RESUME_CONFIG" ] || return 3
  cmd=$(cat "$RESUME_CONFIG" 2>/dev/null) || cmd=""
  [ -n "$cmd" ] || return 3
  log_line "resume: running configured command"
  if fm_alarm_run_bounded sh -c "$cmd" fm-liveness-resume >> "$LOG" 2>&1; then
    return 0
  fi
  return 1
}

# --- durable episode state --------------------------------------------------

read_marker() {  # <path>
  cat "$1" 2>/dev/null || true
}

write_marker() {  # <path> <value>
  printf '%s\n' "$2" > "$1" 2>/dev/null || true
}

clear_episode() {
  rm -f "$EPISODE_MARKER" "$RESUME_COUNT_MARKER" "$CAP_REPORTED_MARKER" 2>/dev/null || true
}

# Deterministic key for the current down-episode, from the beacon's state, so a
# continuous outage shares one key and a recovered-then-restale beacon starts a
# fresh episode (same design as bin/fm-guard.sh's stale-episode key).
episode_key() {
  local beat="$STATE/.last-watcher-beat" m
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    printf 'beat:%s\n' "${m:-unknown}"
  else
    printf 'beat:absent\n'
  fi
}

# --- the core decision (tick) ----------------------------------------------

# Evaluate once and act. Idempotent and side-effect-bounded so a test can drive
# it directly without the loop. Returns 0 always (a watchdog never aborts).
tick() {
  local in_flight watcher_fresh beacon_desc key seen_key resumes cap_reported
  local primary summary rc

  enabled || return 0
  if away_mode_active; then
    # Away mode owns durable supervision through its own host; stand down and
    # clear any episode so a later non-away outage is a fresh episode.
    clear_episode
    return 0
  fi

  fm_supervision_status "$STATE" "$GRACE"
  in_flight=$FM_SUP_IN_FLIGHT
  watcher_fresh=$FM_SUP_WATCHER_FRESH
  beacon_desc=$FM_SUP_BEACON_DESC

  if [ "$in_flight" -eq 0 ]; then
    # A quiet fleet with nothing in flight is healthy and must NOT alert.
    clear_episode
    return 0
  fi
  if [ "$watcher_fresh" = true ]; then
    # Supervision is alive; end any episode so a later restale re-arms fresh.
    clear_episode
    return 0
  fi

  # TRIGGER: work in flight and no fresh watcher beacon past the grace window.
  key=$(episode_key)
  seen_key=$(read_marker "$EPISODE_MARKER")
  if [ "$seen_key" != "$key" ]; then
    # New down-episode: reset counters.
    write_marker "$EPISODE_MARKER" "$key"
    write_marker "$RESUME_COUNT_MARKER" 0
    rm -f "$CAP_REPORTED_MARKER" 2>/dev/null || true
    log_line "TRIGGER: $in_flight task(s) in flight, watcher beacon $beacon_desc (grace ${GRACE}s), episode $key"
  fi
  resumes=$(read_marker "$RESUME_COUNT_MARKER")
  case "$resumes" in ''|*[!0-9]*) resumes=0 ;; esac
  cap_reported=$(read_marker "$CAP_REPORTED_MARKER")

  primary=$(probe_primary)
  if [ "$primary" = alive ]; then
    # Wedged-but-alive secondary case: supervision is gone but the primary
    # process is still running. Never resume a live primary; alert once so the
    # stall is visible, then wait for recovery or death.
    if [ "$seen_key" != "$key" ]; then
      fire_alarm "primary supervision has been DOWN past grace (${beacon_desc}) with $in_flight task(s) in flight, but the primary process is still ALIVE - possible wedge. NOT auto-resuming a live process. Attach and check."
    fi
    return 0
  fi

  # primary is dead or unknown -> the death case. Attempt a capped resume.
  if [ "$resumes" -ge "$MAX_RESUMES" ]; then
    if [ "$cap_reported" != 1 ]; then
      write_marker "$CAP_REPORTED_MARKER" 1
      fire_alarm "primary is DOWN with $in_flight task(s) in flight; auto-resume FAILED after $resumes attempt(s) (cap ${MAX_RESUMES}). Fleet is unsupervised - MANUAL recovery needed."
    fi
    return 0
  fi

  attempt_resume
  rc=$?
  resumes=$((resumes + 1))
  write_marker "$RESUME_COUNT_MARKER" "$resumes"
  case "$rc" in
    0)
      summary="primary was DOWN with $in_flight task(s) in flight (watcher beacon $beacon_desc). Auto-resume attempt $resumes SUCCEEDED - the fleet should self-recover. Verify on waking."
      log_line "resume attempt $resumes succeeded"
      ;;
    3)
      summary="primary is DOWN with $in_flight task(s) in flight (watcher beacon $beacon_desc). NO auto-resume command is configured (config/liveness-resume) - the fleet is unsupervised and needs MANUAL recovery."
      log_line "resume attempt $resumes: no resume command configured"
      # No point retrying a resume that cannot run; treat as cap so we alert once.
      write_marker "$RESUME_COUNT_MARKER" "$MAX_RESUMES"
      ;;
    *)
      summary="primary is DOWN with $in_flight task(s) in flight (watcher beacon $beacon_desc). Auto-resume attempt $resumes FAILED - will retry up to $MAX_RESUMES total, then escalate."
      log_line "resume attempt $resumes failed (rc=$rc)"
      ;;
  esac
  fire_alarm "$summary"
  return 0
}

# --- the loop (run) ---------------------------------------------------------

RUNNING=1
SLEEP_PID=

release_lock() {
  fm_lock_release "$DAEMON_LOCK" 2>/dev/null || true
}

# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_signal() {
  RUNNING=0
  [ -n "$SLEEP_PID" ] && kill -TERM "$SLEEP_PID" 2>/dev/null
}

# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
on_exit() {
  release_lock
}

interruptible_sleep() {  # <seconds>
  sleep "$1" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null || true
  SLEEP_PID=
}

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

run_main() {
  enabled || { echo "liveness-watchdog: disabled (config/liveness-watchdog absent)"; return 0; }
  if away_mode_active; then
    echo "liveness-watchdog: skipped (away mode owns supervision)"
    return 0
  fi
  if ! fm_lock_try_acquire "$DAEMON_LOCK"; then
    echo "liveness-watchdog: already running pid=${FM_LOCK_HELD_PID:-unknown}"
    return 0
  fi
  printf '%s\n' "$FM_HOME" > "$DAEMON_LOCK/fm-home" 2>/dev/null || true
  # Bind the identity to THIS loop process. It must be computed for $$ directly,
  # NOT $(fm_current_pid): a command substitution runs in a short-lived subshell
  # whose BASHPID is a different, already-dead pid by the time fm_pid_identity
  # reads /proc, leaving an empty identity that can never match. fm_lock_try_acquire
  # wrote the lock's pid file from ${BASHPID:-$$} in this same process, so $$ is
  # exactly the pid the identity must describe.
  fm_pid_identity "$$" > "$DAEMON_LOCK/pid-identity" 2>/dev/null || true

  trap on_exit EXIT
  trap handle_signal HUP TERM INT

  log_line "start pid=$(fm_current_pid) home=$FM_HOME grace=${GRACE}s interval=${INTERVAL}s max-resumes=$MAX_RESUMES"
  while [ "$RUNNING" -eq 1 ]; do
    if away_mode_active; then
      log_line "stop reason=afk"
      break
    fi
    tick
    [ "$RUNNING" -eq 1 ] || { log_line "stop reason=signal"; break; }
    interruptible_sleep "$INTERVAL"
  done
  log_line "exit pid=$(fm_current_pid)"
  return 0
}

# --- detached launch (start) ------------------------------------------------

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
  enabled || { echo "liveness-watchdog: disabled (config/liveness-watchdog absent)"; return 0; }
  if away_mode_active; then
    echo "liveness-watchdog: skipped (away mode owns supervision)"
    return 0
  fi
  if pid=$(daemon_alive_pid); then
    echo "liveness-watchdog: already running pid=$pid"
    return 0
  fi
  if ! launch_detached; then
    echo "liveness-watchdog: FAILED - no way to detach (need setsid or perl)" >&2
    return 1
  fi
  i=0
  while [ "$i" -lt 50 ]; do
    if pid=$(daemon_alive_pid); then
      echo "liveness-watchdog: started pid=$pid"
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  echo "liveness-watchdog: FAILED - detached loop did not take the lock within 5s (see $LOG)" >&2
  return 1
}

status_main() {
  local pid
  if pid=$(daemon_alive_pid); then
    echo "liveness-watchdog: running pid=$pid"
    return 0
  fi
  echo "liveness-watchdog: not running"
  return 1
}

stop_main() {
  local pid i
  if ! pid=$(daemon_alive_pid); then
    echo "liveness-watchdog: not running"
    return 0
  fi
  kill -TERM "$pid" 2>/dev/null || true
  # Wait on the identity-checked liveness, not raw kill -0. A reaped loop can
  # linger briefly as a zombie (kill -0 still succeeds on a zombie), whose empty
  # /proc cmdline fails the identity match, so daemon_alive_pid is the accurate
  # "is the real loop still running" test and does not hang on an unreaped zombie
  # on a host whose init does not reap promptly.
  i=0
  while [ "$i" -lt 100 ] && daemon_alive_pid >/dev/null 2>&1; do
    sleep 0.1
    i=$((i + 1))
  done
  if daemon_alive_pid >/dev/null 2>&1; then
    echo "liveness-watchdog: FAILED - pid=$pid did not exit" >&2
    return 1
  fi
  echo "liveness-watchdog: stopped pid=$pid"
  return 0
}

usage() {
  sed -n '2,66p' "$SELF" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  start) start_main ;;
  run) run_main ;;
  tick) tick ;;
  status) status_main ;;
  stop) stop_main ;;
  -h|--help) usage ;;
  *) echo "usage: $(basename "$0") start|run|tick|status|stop" >&2; exit 2 ;;
esac
