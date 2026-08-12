#!/usr/bin/env bash
# fm-liveness-watchdog.sh - EXTERNAL liveness watchdog for the firstmate primary.
#
# Why this exists (data/scout-overnight-turnover-while-captain-asleep/report.md):
# on 2026-07-29 the hosted firstmate primary was collected by an idle sweep,
# which tree-killed its child supervision watcher in the same stroke. The fleet
# sat silent 3h41m with no self-recovery, because the one process that would have
# woken the session died with it. The idle-sweep cause is closed, but the
# STRUCTURAL gap remains: whenever the hosted primary dies for ANY reason (daemon
# crash, deliberate restart, a reverted pin, a future failure), its in-process
# watcher dies with it and nothing observes the fleet until a human attaches.
#
# This watchdog closes that gap. It runs OUTSIDE the agent process tree, so
# whatever kills the primary cannot kill it, and it watches durable on-disk state
# (state/*.meta plus the watcher beacon state/.last-watcher-beat) that SURVIVES
# the primary's death. When work is recorded as under way but no watcher has
# beaten within the grace window, the primary's supervision is gone, and the
# watchdog does two things:
#
#   1. AUTO-RESUME: re-wakes the primary's own supervisor pane, the herdr pane
#      firstmate itself runs in (recorded durably at session start into
#      state/.supervisor-target, because this detached loop inherits no herdr
#      env). It reads that pane's agent liveness: a live-but-idle client gets a
#      gentle Enter nudge to re-drive its turn; a dead-shell husk optionally gets
#      a configured relaunch command run IN that pane (config/liveness-resume).
#      Resume is capped and rate-limited per down-episode: after the cap it stops
#      re-nudging and just escalates, because a resume loop against a genuinely
#      broken primary is worse than silence.
#   2. DURABLE ESCALATION: writes state/.liveness-escalation, a bounded record of
#      what happened and whether the resume succeeded. There is NO phone push on
#      this home (the previous hosting runtime's phone-attach path is gone); the
#      escalation is surfaced PROMINENTLY at the next session start
#      (bin/fm-session-start.sh) and via a durable `check` wake, so the captain
#      sees on next attach whether the fleet self-recovered or is still down.
#
# What it is NOT: it does not classify, decide, or act on ordinary wakes (that is
# the watcher and firstmate itself), and it is not the fix for the composer-defer
# wedge (a separate ticket). Its stale-beacon signal DOES incidentally catch a
# wedged-but-alive primary as a secondary benefit: the Enter nudge is exactly the
# right, safe action for a live-but-idle supervisor pane, and it never relaunches
# a live client. It does not attempt to fix that wedge.
#
# Opt-in: inert unless config/liveness-watchdog exists. Away-mode interlock: the
# away daemon (bin/fm-afk-launch.sh start-paneless) already hosts a durable,
# session-independent watcher outside the session; this watchdog stands down
# under state/.afk to avoid two supervisors racing a resume.
#
# Outside-the-tree hosting on THIS host: no launchd (Linux), no systemd user
# session, no cron - so, exactly like bin/fm-present-daemon.sh, the loop detaches
# with setsid (or a perl setsid fallback) into its own session leader with no
# controlling terminal, which reparents it to init. A tree-kill of the agent
# cannot reach it, and a disconnecting terminal or a finished harness background
# task cannot reap it. If the watchdog process itself ever dies, the next locked
# session start relaunches it (bin/fm-bootstrap.sh liveness_watchdog_sweep).
#
# Config (all local, gitignored; see docs/liveness-watchdog.md):
#   config/liveness-watchdog       presence flag: enable the watchdog
#   config/liveness-resume         OPTIONAL relaunch command run in the supervisor
#                                  pane when it reads as a DEAD shell (e.g. the
#                                  jcode --resume line). Absent = nudge-only: a
#                                  dead client is escalated but not relaunched.
# state (durable, gitignored):
#   state/.supervisor-target       "<backend>\t<target>" of the primary's own
#                                  pane, recorded at session start by `record`.
#   state/.liveness-escalation     the durable escalation record surfaced at
#                                  session start; cleared by `ack`.
#
# Usage:
#   fm-liveness-watchdog.sh record   capture THIS session's supervisor pane into
#                                    state/.supervisor-target (run at session
#                                    start, from inside the primary's pane, so the
#                                    herdr env is inherited). Prints one line.
#   fm-liveness-watchdog.sh start    launch the loop DETACHED and return
#   fm-liveness-watchdog.sh run      run the loop in the foreground (start execs this)
#   fm-liveness-watchdog.sh tick     evaluate ONCE and act; the pure decision, for tests
#   fm-liveness-watchdog.sh status   print running/not-running and exit 0/1
#   fm-liveness-watchdog.sh stop     signal ONLY this home's recorded watchdog and wait
#   fm-liveness-watchdog.sh escalation  print the durable escalation record, if any
#   fm-liveness-watchdog.sh ack      clear the durable escalation record (after surfacing)
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
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
# The typed operational-input construct, so a jcode resume injects the same
# marked wake line the present-daemon pane-wake uses rather than a bare Enter
# (which does not re-drive an idle jcode model; docs/jcode-wake-adapter.md).
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"

CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
FLAG="$CONFIG/liveness-watchdog"
RESUME_CONFIG="$CONFIG/liveness-resume"
AFK="$STATE/.afk"
DAEMON_LOCK="$STATE/.liveness-watchdog.lock"
LOG="$STATE/.liveness-watchdog.log"
SUPERVISOR_TARGET_FILE="$STATE/.supervisor-target"
ESCALATION_FILE="$STATE/.liveness-escalation"
# Durable per-episode trigger state (bounded, overwritten, never grows).
EPISODE_MARKER="$STATE/.liveness-watchdog-episode"
RESUME_COUNT_MARKER="$STATE/.liveness-watchdog-resumes"
CAP_REPORTED_MARKER="$STATE/.liveness-watchdog-capreported"

# Staleness threshold. Reuses the watcher-liveness grace so the watchdog and the
# in-session guard (bin/fm-guard.sh) agree on "the watcher is down".
GRACE=${FM_GUARD_GRACE:-900}
# How often the loop evaluates. Far shorter than GRACE so a real death is caught
# within roughly one interval past grace, not a full grace window later.
INTERVAL=${FM_LIVENESS_INTERVAL:-60}
# Maximum resume attempts within one down-episode before the watchdog stops
# re-nudging and just escalates.
MAX_RESUMES=${FM_LIVENESS_MAX_RESUMES:-3}
# Verify-retry knobs for the jcode text-submit wake, mirroring the present
# daemon's pane-wake submit (bin/fm-present-daemon.sh). Only the submission is
# retried, never the typing.
WAKE_CONFIRM_RETRIES=${FM_LIVENESS_WAKE_RETRIES:-3}
WAKE_CONFIRM_SLEEP=${FM_LIVENESS_WAKE_SLEEP:-0.5}

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

read_marker() {  # <path>
  cat "$1" 2>/dev/null || true
}

write_marker() {  # <path> <value>
  printf '%s\n' "$2" > "$1" 2>/dev/null || true
}

# --- supervisor-target record (record) -------------------------------------

# Capture the primary's own supervisor pane into state/.supervisor-target. MUST
# run from inside the primary's session (session start) so discover_supervisor_*
# resolves the real pane from the inherited backend env; the detached loop later
# reads this file because it inherits no such env. Records "<backend>\t<target>".
record_supervisor_target() {
  local target backend
  target=$(discover_supervisor_target) || {
    echo "liveness-watchdog: could not resolve supervisor pane (set FM_SUPERVISOR_TARGET); not recording" >&2
    return 1
  }
  backend=$(discover_supervisor_backend) || {
    echo "liveness-watchdog: could not resolve supervisor backend (set FM_SUPERVISOR_BACKEND); not recording" >&2
    return 1
  }
  mkdir -p "$STATE" || return 1
  local pending
  pending=$(mktemp "$STATE/.supervisor-target.pending.XXXXXX") || return 1
  printf '%s\t%s\n' "$backend" "$target" > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$SUPERVISOR_TARGET_FILE" || { rm -f "$pending"; return 1; }
  echo "liveness-watchdog: recorded supervisor target $backend:$target"
}

# Read the recorded target into FM_LW_SUP_BACKEND / FM_LW_SUP_TARGET. Returns 1
# when no valid record exists.
FM_LW_SUP_BACKEND=""
FM_LW_SUP_TARGET=""
read_supervisor_target() {
  FM_LW_SUP_BACKEND=""; FM_LW_SUP_TARGET=""
  [ -f "$SUPERVISOR_TARGET_FILE" ] || return 1
  IFS=$'\t' read -r FM_LW_SUP_BACKEND FM_LW_SUP_TARGET < "$SUPERVISOR_TARGET_FILE" || return 1
  [ -n "$FM_LW_SUP_BACKEND" ] && [ -n "$FM_LW_SUP_TARGET" ]
}

# --- durable escalation (escalation / ack) ---------------------------------

# Write the durable escalation record. Bounded, overwritten each time so it never
# grows, and always carries the latest resume outcome.
write_escalation() {  # <summary>
  local pending
  mkdir -p "$STATE" || return 1
  pending=$(mktemp "$STATE/.liveness-escalation.pending.XXXXXX") || return 1
  {
    printf 'time=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'summary=%s\n' "$1"
  } > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$ESCALATION_FILE" || { rm -f "$pending"; return 1; }
  log_line "escalation recorded: $1"
}

print_escalation() {
  [ -f "$ESCALATION_FILE" ] || { echo "liveness-watchdog: no escalation recorded"; return 1; }
  cat "$ESCALATION_FILE"
}

ack_escalation() {
  rm -f "$ESCALATION_FILE" 2>/dev/null || true
  echo "liveness-watchdog: escalation acknowledged and cleared"
}

# Enqueue a durable check wake so a still-live-but-recovered session (rather than
# a fresh session start) also learns of the escalation. Best-effort.
enqueue_escalation_wake() {  # <summary>
  fm_wake_append check liveness-watchdog \
    "external liveness watchdog escalation: $1 (see state/.liveness-escalation and bin/fm-liveness-watchdog.sh escalation)" \
    2>/dev/null || log_line "escalation wake enqueue failed"
}

# --- durable episode state --------------------------------------------------

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

# --- resume: re-wake the recorded supervisor pane --------------------------

# Resolve firstmate's own primary harness for the resume decision. Comes from
# FM_SUPERVISOR_HARNESS when set (a testing seam and the same override the
# present daemon and away daemon honor) else bin/fm-harness.sh. A harness read
# that fails is treated as not-jcode, so the safe default (the bare Enter nudge
# that works on claude and grok) holds. Mirrors bin/fm-present-daemon.sh's
# pane_wake_enabled harness resolution.
resume_harness() {
  local harness=${FM_SUPERVISOR_HARNESS:-}
  [ -n "$harness" ] || harness=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf 'unknown')
  [ -n "$harness" ] || harness=unknown
  printf '%s' "$harness"
}

# Probe the recorded supervisor pane's agent liveness. Prints alive|dead|unknown.
# Uses fm_backend_agent_alive, which for jcode-on-herdr corroborates a no-agent
# pane by reading its composer row (a live jcode client draws a numbered prompt
# row; a bare-shell husk does not), so it is the correct alive-vs-dead signal for
# the supervisor pane and never false-deads a live jcode lane.
probe_supervisor() {
  read_supervisor_target || { printf 'unknown\n'; return 0; }
  # fm-backend.sh is heavy (sources adapters); load it lazily only when resuming.
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh" 2>/dev/null || { printf 'unknown\n'; return 0; }
  local verdict
  verdict=$(fm_backend_agent_alive "$FM_LW_SUP_BACKEND" "$FM_LW_SUP_TARGET" 2>/dev/null) || verdict=unknown
  case "$verdict" in
    alive|dead|unknown) printf '%s\n' "$verdict" ;;
    *) printf 'unknown\n' ;;
  esac
}

# Attempt one resume of the recorded supervisor pane, given its probed liveness.
# Returns:
#   0  a resume action was taken (a configured relaunch)
#   2  the pane is alive-but-idle and got the Enter nudge (a subtype of 0 for the
#      caller's message; treated as success) - the claude/grok path
#   5  the pane is alive-but-idle on jcode and got a text-submit wake line (a
#      subtype of success): a bare Enter does not re-drive an idle jcode model,
#      so this injects the same marked wake the present-daemon pane-wake uses
#   3  no supervisor target recorded (nothing to resume)
#   4  the pane is a DEAD shell and NO relaunch command is configured (escalate)
#   1  a resume action was attempted but failed
attempt_resume() {  # <liveness alive|dead|unknown>
  local liveness=$1 cmd harness msg
  read_supervisor_target || return 3
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh" 2>/dev/null || return 1
  case "$liveness" in
    alive|unknown)
      # A live-but-idle (or unreadable) supervisor pane. The correct wake action
      # depends on the primary harness. On claude and grok a bare Enter re-drives
      # the idle turn, so the minimal-action Enter nudge is right (and an Enter
      # into a truly dead shell is harmless). On jcode a bare Enter does NOT
      # re-drive an idle model (docs/jcode-wake-adapter.md), so a bare Enter is
      # structurally inert - exactly the 2026-08-12 recovery gap where three
      # Enter nudges per outage no-op'd. For jcode, inject the same typed,
      # marked wake line the present-daemon pane-wake uses, via a verify-retry
      # text submit, so the idle model actually re-drives its turn. Never
      # relaunch a possibly-live client either way.
      harness=$(resume_harness)
      if [ "$harness" = jcode ]; then
        fm_operational_input_construct away-supervisor \
          'External liveness watchdog: primary supervision beacon went dark with work in flight. Re-drive supervision now: run bin/fm-wake-drain.sh first, then handle the fleet.' \
          msg || return 1
        log_line "resume: jcode text-submit wake to $FM_LW_SUP_BACKEND:$FM_LW_SUP_TARGET (liveness=$liveness)"
        if fm_backend_send_text_submit "$FM_LW_SUP_BACKEND" "$FM_LW_SUP_TARGET" "$msg" \
          "$WAKE_CONFIRM_RETRIES" "$WAKE_CONFIRM_SLEEP" "$WAKE_CONFIRM_SLEEP" >/dev/null 2>&1; then
          return 5
        fi
        return 1
      fi
      log_line "resume: Enter nudge to $FM_LW_SUP_BACKEND:$FM_LW_SUP_TARGET (liveness=$liveness)"
      if fm_backend_send_key "$FM_LW_SUP_BACKEND" "$FM_LW_SUP_TARGET" Enter >/dev/null 2>&1; then
        return 2
      fi
      return 1
      ;;
    dead)
      # A confidently dead shell: an Enter would do nothing. Relaunch only if the
      # captain configured how to on this host.
      if [ ! -f "$RESUME_CONFIG" ]; then
        return 4
      fi
      cmd=$(cat "$RESUME_CONFIG" 2>/dev/null) || cmd=""
      [ -n "$cmd" ] || return 4
      log_line "resume: relaunch command in dead pane $FM_LW_SUP_BACKEND:$FM_LW_SUP_TARGET"
      if fm_backend_send_text_submit "$FM_LW_SUP_BACKEND" "$FM_LW_SUP_TARGET" "$cmd" 3 0.4 1 >/dev/null 2>&1; then
        return 0
      fi
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

# --- the core decision (tick) ----------------------------------------------

# Evaluate once and act. Idempotent and side-effect-bounded so a test can drive
# it directly without the loop. Returns 0 always (a watchdog never aborts).
tick() {
  local in_flight watcher_fresh beacon_desc key seen_key resumes cap_reported
  local liveness rc summary

  enabled || return 0
  if away_mode_active; then
    clear_episode
    return 0
  fi

  fm_supervision_status "$STATE" "$GRACE"
  in_flight=$FM_SUP_IN_FLIGHT
  watcher_fresh=$FM_SUP_WATCHER_FRESH
  beacon_desc=$FM_SUP_BEACON_DESC

  if [ "$in_flight" -eq 0 ]; then
    clear_episode
    return 0
  fi
  if [ "$watcher_fresh" = true ]; then
    clear_episode
    return 0
  fi

  # TRIGGER: work in flight and no fresh watcher beacon past the grace window.
  key=$(episode_key)
  seen_key=$(read_marker "$EPISODE_MARKER")
  if [ "$seen_key" != "$key" ]; then
    write_marker "$EPISODE_MARKER" "$key"
    write_marker "$RESUME_COUNT_MARKER" 0
    rm -f "$CAP_REPORTED_MARKER" 2>/dev/null || true
    log_line "TRIGGER: $in_flight task(s) in flight, watcher beacon $beacon_desc (grace ${GRACE}s), episode $key"
  fi
  resumes=$(read_marker "$RESUME_COUNT_MARKER")
  case "$resumes" in ''|*[!0-9]*) resumes=0 ;; esac
  cap_reported=$(read_marker "$CAP_REPORTED_MARKER")

  # Past the cap: stop re-nudging, escalate once.
  if [ "$resumes" -ge "$MAX_RESUMES" ]; then
    if [ "$cap_reported" != 1 ]; then
      write_marker "$CAP_REPORTED_MARKER" 1
      summary="primary supervision DOWN, $in_flight task(s) in flight (watcher beacon $beacon_desc). Auto-resume did NOT recover it after $resumes attempt(s) (cap $MAX_RESUMES). Fleet is unsupervised - MANUAL recovery needed."
      write_escalation "$summary"
      enqueue_escalation_wake "$summary"
    fi
    return 0
  fi

  liveness=$(probe_supervisor)
  attempt_resume "$liveness"
  rc=$?
  case "$rc" in
    3)
      # No supervisor target recorded: we cannot resume. Escalate once per
      # episode so the gap is visible, but do not count it as a resume attempt.
      if [ "$seen_key" != "$key" ]; then
        summary="primary supervision DOWN, $in_flight task(s) in flight (watcher beacon $beacon_desc). NO supervisor pane recorded (state/.supervisor-target missing) - cannot auto-resume. Attach and recover manually."
        write_escalation "$summary"
        enqueue_escalation_wake "$summary"
      fi
      return 0
      ;;
    4)
      # Dead shell with no relaunch command configured. Escalate once; do not spin.
      if [ "$cap_reported" != 1 ]; then
        write_marker "$CAP_REPORTED_MARKER" 1
        summary="primary supervisor pane is a DEAD shell, $in_flight task(s) in flight (watcher beacon $beacon_desc). No relaunch command configured (config/liveness-resume) - cannot auto-resume a dead client. MANUAL recovery needed."
        write_escalation "$summary"
        enqueue_escalation_wake "$summary"
      fi
      return 0
      ;;
    0|2|5)
      resumes=$((resumes + 1))
      write_marker "$RESUME_COUNT_MARKER" "$resumes"
      if [ "$rc" -eq 2 ]; then
        summary="primary supervision was DOWN, $in_flight task(s) in flight (watcher beacon $beacon_desc). Sent an Enter nudge to the supervisor pane (attempt $resumes) to re-drive its turn. Verify on waking whether the fleet recovered."
      elif [ "$rc" -eq 5 ]; then
        summary="primary supervision was DOWN, $in_flight task(s) in flight (watcher beacon $beacon_desc). Injected a wake line into the jcode supervisor pane (attempt $resumes) to re-drive its turn. Verify on waking whether the fleet recovered."
      else
        summary="primary supervisor pane was a DEAD shell, $in_flight task(s) in flight (watcher beacon $beacon_desc). Ran the configured relaunch command (attempt $resumes). Verify on waking whether the primary came back."
      fi
      write_escalation "$summary"
      enqueue_escalation_wake "$summary"
      ;;
    *)
      resumes=$((resumes + 1))
      write_marker "$RESUME_COUNT_MARKER" "$resumes"
      summary="primary supervision DOWN, $in_flight task(s) in flight (watcher beacon $beacon_desc). Auto-resume attempt $resumes FAILED to drive the supervisor pane - will retry up to $MAX_RESUMES, then escalate."
      write_escalation "$summary"
      enqueue_escalation_wake "$summary"
      ;;
  esac
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
  # Bind the identity to $$ directly, NOT $(fm_current_pid): a command
  # substitution runs in a short-lived subshell whose BASHPID is a different,
  # already-dead pid by the time fm_pid_identity reads /proc, leaving an empty
  # identity that can never match. fm_lock_try_acquire wrote the lock's pid file
  # from ${BASHPID:-$$} in this same process, so $$ is the pid to describe.
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
  sed -n '2,80p' "$SELF" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  record) record_supervisor_target ;;
  start) start_main ;;
  run) run_main ;;
  tick) tick ;;
  status) status_main ;;
  stop) stop_main ;;
  escalation) print_escalation ;;
  ack) ack_escalation ;;
  -h|--help) usage ;;
  *) echo "usage: $(basename "$0") record|start|run|tick|status|stop|escalation|ack" >&2; exit 2 ;;
esac
