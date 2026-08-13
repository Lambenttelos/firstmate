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
# Pane-wake (config/present-daemon-pane-wake). By default the daemon only keeps a
# watcher armed and re-arms silently. On claude and grok a background task's
# completion re-drives the model by default, so a silent re-arm is enough - the
# arm-task completion wakes the model. jcode background tasks default to a passive
# notification that does NOT wake an idle model, and the wake flag can only be set
# from the model's own bg call, not from any script, so a silently re-armed
# watcher cannot wake an idle jcode session (docs/jcode-wake-adapter.md,
# docs/jcode-primary-supervision.md). When pane-wake is enabled the daemon ALSO
# injects one short wake line into firstmate's own supervisor pane on each
# actionable watcher cycle, which jcode always re-drives on, exactly as the
# away-mode daemon (bin/fm-supervise-daemon.sh) already injects escalations.
# It is enabled when the local, gitignored config/present-daemon-pane-wake flag is
# present (its contents are ignored unless the first non-empty line is "off"),
# OR automatically when firstmate's own harness is jcode (the harness that needs
# it); claude and grok stay on the silent-re-arm path unless the flag forces it.
# Supported supervisor backends are tmux and herdr only; anything else, or a pane
# that does not positively resolve, degrades silently to the silent-re-arm
# behavior. On herdr the pane id is NOT stable - herdr can reassign it under the
# same live tab (HERDR_PANE_ID drift) - so the daemon captures the stable owning
# tab identity at resolve time and re-resolves the current pane by that tab before
# each inject, waking the drifted-to pane instead of skipping forever. Pane-wake
# never runs in away mode - the away daemon owns the pane then - which the
# existing away-mode interlock already guarantees. See docs/configuration.md.
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

# Pane-wake reuses the away daemon's injection primitives rather than
# reinventing them: fm_operational_input_construct builds the typed wake line,
# fm-backend.sh dispatches the busy/composer guards and the verify-retry submit,
# and fm-supervisor-target-lib.sh resolves firstmate's own pane the same single
# way the away daemon does. All three are source-safe.
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
# fm-tmux-lib.sh owns FM_TMUX_BUSY_REGEX_DEFAULT (the busy-footer fallback the
# pane-wake busy-guard reuses); the away daemon sources it for the same reason.
# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ARM="$SCRIPT_DIR/fm-watch-arm.sh"
FLAG="$CONFIG/present-daemon"
PANE_WAKE_FLAG="$CONFIG/present-daemon-pane-wake"
AFK="$STATE/.afk"
DAEMON_LOCK="$STATE/.present-daemon.lock"
LOG="$STATE/.present-daemon.log"
# Supervisor backends pane-wake knows how to inject into (matches the away
# daemon's FM_SUPERVISOR_SUPPORTED_BACKENDS). Anything else degrades silently.
PANE_WAKE_SUPPORTED_BACKENDS="tmux herdr"
# Retry/settle knobs for the verify-retry submit, mirroring the away daemon's.
PANE_WAKE_CONFIRM_RETRIES=${FM_PRESENT_PANE_WAKE_RETRIES:-3}
PANE_WAKE_CONFIRM_SLEEP=${FM_PRESENT_PANE_WAKE_SLEEP:-0.5}
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

# pane_wake_enabled: decide whether the daemon should ALSO pane-inject a wake on
# actionable cycles, on top of the silent re-arm. Precedence:
#   1. config/present-daemon-pane-wake present -> on, UNLESS its first non-empty,
#      non-comment line is "off" (an explicit local disable that also overrides
#      the jcode auto path below).
#   2. otherwise auto-on when firstmate's own harness is jcode - the harness whose
#      background tasks do not wake an idle model, so the silent re-arm alone
#      cannot wake it. claude and grok re-drive on background-task completion, so
#      they stay on the silent-re-arm path.
# Harness comes from FM_SUPERVISOR_HARNESS when set (a testing seam and the same
# override the away daemon honors) else bin/fm-harness.sh. A harness read that
# fails is treated as not-jcode, so the safe default (silent re-arm) holds.
pane_wake_enabled() {
  local first harness
  if [ -f "$PANE_WAKE_FLAG" ]; then
    first=$(grep -vE '^[[:space:]]*(#|$)' "$PANE_WAKE_FLAG" 2>/dev/null | head -1)
    first=${first#"${first%%[![:space:]]*}"}
    first=${first%"${first##*[![:space:]]}"}
    [ "$first" = off ] && return 1
    return 0
  fi
  harness=${FM_SUPERVISOR_HARNESS:-}
  [ -n "$harness" ] || harness=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf 'unknown')
  [ "$harness" = jcode ]
}

away_mode_active() {
  [ -e "$AFK" ]
}

# --- pane-wake (resolve once at startup, re-resolve on drift each cycle) ------
# Resolved in run_main and read/refreshed by the injector. Empty target means
# pane-wake degraded silently to the silent-re-arm behavior (no pane, unsupported
# backend, or feature off).
#
# Herdr reassigns a session's pane id under the same live tab (the HERDR_PANE_ID
# drift), so a target frozen at startup goes stale and every inject then logs
# "target gone; skipping" forever while never waking the model - the blind-but-
# healthy-looking failure this daemon must not have. PANE_WAKE_TAB_IDENTITY holds
# the STABLE "<session>\t<tab_id>" of firstmate's own tab (herdr only) captured at
# resolve time, so inject can re-resolve the CURRENT pane for that tab whenever
# the recorded pane id has drifted, and wake the new pane instead of skipping.
PANE_WAKE_ACTIVE=0
PANE_WAKE_TARGET=
PANE_WAKE_BACKEND=
PANE_WAKE_TAB_IDENTITY=

# pane_wake_resolve: at startup, decide whether pane-wake is active for this run
# and, if so, resolve firstmate's own supervisor pane ONCE using the shared owner
# the away daemon uses. Degrades SILENTLY (logs, sets PANE_WAKE_ACTIVE=0) rather
# than blocking supervision when the feature is off, the backend is unsupported,
# or no real pane resolves (only the firstmate:0 / FALLBACK guess remained). Never
# runs under away mode - the away daemon owns the pane then.
pane_wake_resolve() {
  local target backend rc=0 identity
  PANE_WAKE_ACTIVE=0
  PANE_WAKE_TARGET=
  PANE_WAKE_BACKEND=
  PANE_WAKE_TAB_IDENTITY=
  if ! pane_wake_enabled; then
    log_line "pane-wake: disabled (silent re-arm only)"
    return 0
  fi
  if away_mode_active; then
    log_line "pane-wake: skipped (away mode owns the pane)"
    return 0
  fi
  backend=$(discover_supervisor_backend) || true
  if ! fm_backend_list_contains "$PANE_WAKE_SUPPORTED_BACKENDS" "$backend"; then
    log_line "pane-wake: degraded (unsupported supervisor backend '$backend'; silent re-arm only)"
    return 0
  fi
  target=$(discover_supervisor_target) || rc=$?
  # rc != 0 means only the firstmate:0 fallback remained - no pane was positively
  # identified, so degrade rather than type into an unrelated pane.
  if [ "$rc" -ne 0 ]; then
    log_line "pane-wake: degraded (no supervisor pane identified; silent re-arm only)"
    return 0
  fi
  PANE_WAKE_TARGET=$target
  PANE_WAKE_BACKEND=$backend
  PANE_WAKE_ACTIVE=1
  # Herdr only: capture the STABLE owning tab identity of the resolved pane, so a
  # later pane-id reassignment (HERDR_PANE_ID drift) is recoverable by re-resolve
  # rather than freezing the target dead. Best-effort - an empty identity just
  # means no drift recovery is available and inject falls back to the recorded
  # target exactly as before. tmux pane ids are stable, so it needs none of this.
  if [ "$backend" = herdr ]; then
    if identity=$(fm_backend_herdr_pane_tab_identity "$target" 2>/dev/null) && [ -n "$identity" ]; then
      PANE_WAKE_TAB_IDENTITY=$identity
      log_line "pane-wake: active (backend=$backend target=$target tab=${identity#*$'\t'})"
      return 0
    fi
    log_line "pane-wake: active (backend=$backend target=$target; no stable tab identity, drift recovery unavailable)"
    return 0
  fi
  log_line "pane-wake: active (backend=$backend target=$target)"
}

# pane_wake_refresh_target: before an inject, re-resolve firstmate's own pane if
# the recorded target has drifted. Herdr can reassign a session's pane id under
# the same live tab, so a target frozen at startup silently goes stale. When the
# recorded pane still exists, keep it. When it is gone but a stable tab identity
# was captured at resolve time, re-resolve the CURRENT pane for that tab and adopt
# it, so the daemon wakes the NEW pane instead of logging "gone; skipping" for the
# life of the run. Returns 0 when PANE_WAKE_TARGET is usable, 1 when no live pane
# resolves (inject then skips this cycle, wake already durably queued). tmux never
# drifts, so its target passes straight through.
pane_wake_refresh_target() {
  local backend=$PANE_WAKE_BACKEND session tab_id fresh
  fm_backend_target_exists "$backend" "$PANE_WAKE_TARGET" && return 0
  # Recorded target is gone. Only herdr with a captured tab identity can recover.
  if [ "$backend" != herdr ] || [ -z "$PANE_WAKE_TAB_IDENTITY" ]; then
    return 1
  fi
  session=${PANE_WAKE_TAB_IDENTITY%%$'\t'*}
  tab_id=${PANE_WAKE_TAB_IDENTITY#*$'\t'}
  fresh=$(fm_backend_herdr_target_for_tab_identity "$session" "$tab_id" 2>/dev/null) || fresh=
  if [ -z "$fresh" ]; then
    # The tab itself is gone (firstmate's own pane genuinely closed), not a drift.
    return 1
  fi
  if [ "$fresh" != "$PANE_WAKE_TARGET" ]; then
    log_line "pane-wake: target drifted $PANE_WAKE_TARGET -> $fresh (re-resolved by tab $tab_id)"
    PANE_WAKE_TARGET=$fresh
  fi
  fm_backend_target_exists "$backend" "$PANE_WAKE_TARGET"
}

# pane_wake_inject: nudge firstmate's own pane to read the already-queued wake.
# Reuses the away daemon's guards and submit primitive: never types into a busy
# pane mid-turn (fm_backend_busy_state fallback to the busy-footer regex), never
# into anything but a confirmed-empty genuine agent composer
# (fm_backend_composer_state), and never into a pane that has gone away
# (fm_backend_target_exists). A deferred inject is fine - the wake is already
# durably queued by the watcher, so the pane inject is only the nudge to read it,
# and the next actionable cycle retries. Best-effort: always returns 0 so a
# failed nudge can never break the re-arm loop.
pane_wake_inject() {
  local target backend=$PANE_WAKE_BACKEND msg verdict tail40
  [ "$PANE_WAKE_ACTIVE" -eq 1 ] || return 0
  # Away mode may have been entered mid-run; the loop breaks on it separately, but
  # guard here too so a race never injects while the away daemon owns the pane.
  away_mode_active && return 0
  # Re-resolve the target before every inject so a herdr pane-id reassignment
  # (HERDR_PANE_ID drift) recovers to the CURRENT pane instead of skipping forever.
  # It may update PANE_WAKE_TARGET, so read the local copy only AFTER it returns.
  if ! pane_wake_refresh_target; then
    log_line "pane-wake: target '$PANE_WAKE_TARGET' gone and unrecoverable; skipping nudge (wake already queued)"
    return 0
  fi
  target=$PANE_WAKE_TARGET
  # Busy-guard: never inject into a pane whose agent is mid-turn.
  case "$(fm_backend_busy_state "$backend" "$target" 2>/dev/null)" in
    busy)
      log_line "pane-wake: deferred (pane busy, agent mid-turn); wake stays queued"
      return 0
      ;;
    *)
      tail40=$(fm_backend_capture "$backend" "$target" 40 2>/dev/null) || tail40=
      if printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
        | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"; then
        log_line "pane-wake: deferred (pane busy footer); wake stays queued"
        return 0
      fi
      ;;
  esac
  # Composer-guard: inject only into a confirmed-empty genuine agent composer.
  if [ "$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)" != empty ]; then
    log_line "pane-wake: deferred (composer not confirmed-empty); wake stays queued"
    return 0
  fi
  # Reuse the existing 'watcher' operational kind - this is a watcher wake nudge.
  fm_operational_input_construct watcher \
    'Present-mode watcher surfaced an actionable wake. Run bin/fm-wake-drain.sh first and handle the queued wake.' \
    msg || return 0
  verdict=$(fm_backend_send_text_submit "$backend" "$target" "$msg" \
    "$PANE_WAKE_CONFIRM_RETRIES" "$PANE_WAKE_CONFIRM_SLEEP" "$PANE_WAKE_CONFIRM_SLEEP" 2>/dev/null)
  if [ "$verdict" = empty ]; then
    log_line "pane-wake: nudged pane $target"
  else
    log_line "pane-wake: nudge unconfirmed (verdict=${verdict:-unknown}); wake stays queued"
  fi
  return 0
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
  # so a recycled pid can never read as a live daemon. The identity MUST be
  # computed for THIS shell's own pid taken directly from $BASHPID, never via a
  # command substitution: $(fm_current_pid) runs in a subshell and prints that
  # already-exited subshell's pid, whose /proc entry is gone by the time
  # fm_pid_identity reads it, so the write produced a ZERO-BYTE pid-identity and
  # daemon_lock_matches_pid then reported every live daemon as "not running"
  # (task fix-present-daemon-stale-pane-wake-target). Write atomically through a
  # temp file so a reader never observes a half-written identity, and only after
  # the identity is present is the lock considered a live daemon's.
  local mypid identity
  mypid=${BASHPID:-$$}
  printf '%s\n' "$FM_HOME" > "$DAEMON_LOCK/fm-home" 2>/dev/null || true
  if identity=$(fm_pid_identity "$mypid") && [ -n "$identity" ]; then
    if printf '%s\n' "$identity" > "$DAEMON_LOCK/pid-identity.tmp" 2>/dev/null; then
      mv -f "$DAEMON_LOCK/pid-identity.tmp" "$DAEMON_LOCK/pid-identity" 2>/dev/null \
        || rm -f "$DAEMON_LOCK/pid-identity.tmp" 2>/dev/null || true
    fi
  fi

  trap on_exit EXIT
  trap handle_signal HUP TERM INT

  # Resolve pane-wake once, before the loop. It degrades silently to today's
  # silent re-arm when the feature is off, the backend is unsupported, or no real
  # pane resolves, so it can never block supervision.
  pane_wake_resolve

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
      # rc 0 is an actionable wake exit (the arm returns 0 only on a surfaced
      # wake or a benign tick). The watcher already durably queued that wake; on
      # a harness whose background completion does not re-drive an idle model,
      # nudge firstmate's own pane so it reads the queued wake. A no-op unless
      # pane-wake resolved active, and best-effort so it can never break re-arm.
      [ "$rc" -eq 0 ] && pane_wake_inject
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
  sed -n '2,82p' "$SELF" | sed 's/^# \{0,1\}//'
}

# Everything above is source-safe: the pane-wake decision and injection helpers
# are pure enough for unit tests to source this file and call them with fake
# backend primitives on PATH. The subcommand dispatch below runs only when the
# script is EXECUTED, never when sourced (only tests source it).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    start) start_main ;;
    run) run_main ;;
    status) status_main ;;
    stop) stop_main ;;
    -h|--help) usage ;;
    *) echo "usage: $(basename "$0") start|run|status|stop" >&2; exit 2 ;;
  esac
fi
