#!/usr/bin/env bash
# Firstmate watcher.
# Classifies supervision wakes in bash. In normal mode it absorbs benign wakes
# and keeps blocking; it queues and exits only for actionable wakes, apart from
# the env-gated proof-of-life "tick:" close described below, which queues nothing.
# The no-verb signal and stale path is absorb-only-when-provably-working: a wake
# is absorbed only when the crew shows POSITIVE evidence it is still working (an
# actively-running no-mistakes step, or a backend busy signal), and surfaced
# otherwise, so a crew that finishes (or stops and waits) without a current
# working signal is never silently swallowed. A declared external-wait pause is
# the separate idle absorb case and re-surfaces only on its long bounded cadence,
# although its initial no-verb status signal still surfaces in normal mode.
# While away mode is on AND a live daemon for this home is actually running it,
# the daemon owns triage and this watcher queues and exits on every wake; away
# mode with no daemon is the away posture only and leaves triage here.
# Printed reason lines:
#   signal: <file>...      status/turn-end signals, surfaced when a listed status
#                          has a captain-relevant verb OR a no-verb signal's crew
#                          is not provably working, unless a live away-mode daemon owns triage
#   stale: <window>        a provably-working stale is ALWAYS absorbed (with a wedge
#                          timer) regardless of what the status log says - an active
#                          run-step or busy pane outranks even a captain-relevant log
#                          line, since the crew's own log gets no new entry once
#                          firstmate hands it to a no-mistakes validation. A declared
#                          external-wait pause is absorbed instead with its own long
#                          re-surface cadence, never as a wedge. Only when neither
#                          absorb class applies does the log's last line decide:
#                          terminal (captain-relevant) or non-terminal (no verb),
#                          both surfaced at once. A provably-working stale past the
#                          wedge threshold also surfaces, with an "escalation N"
#                          count in the reason; at FM_WEDGE_DEMAND_INSPECT_COUNT
#                          consecutive escalations on the SAME pane, the reason
#                          also carries a "demand-deep-inspection" marker so the
#                          wake payload itself, not just repetition, forces a
#                          closer look instead of another routine supervision
#                          resume. Unless a live away-mode daemon owns triage.
#   check: <script>: <out> authenticated check output, always actionable
#   check: rejected unauthenticated state checks: <paths>
#                          unsafe state checks were refused without execution
#   check: host-resources <reading>
#                          the host-resource sweep found CPU/memory/swap pressure
#                          WORSE than the level firstmate was last told about.
#                          Report-only: nothing is paused, shed or killed here.
#   check: session-review <headline>
#                          the hourly session review found something that has
#                          NOT moved (a silent worker, an unanswered decision,
#                          queued work with nothing running, a batch of unmerged
#                          branches). Silent when there is nothing new to say.
#   check: session-cleanup <headline>
#                          the hourly cleanup sweep found accumulated material it
#                          deliberately did NOT remove because it could hold
#                          unlanded work. Report-only; nothing is discarded here.
#                          Both are armed by bin/fm-session-start.sh and run on
#                          this watcher's slow poll (bin/fm-hourly-lib.sh).
#   tick: <note>           env-gated proof-of-life close (FM_WATCH_ABSORB_TICK=1,
#                          default off) for a benign-ABSORBED wake while work is
#                          under way. Not an actionable wake: nothing is queued,
#                          and the arm layer classifies it as a benign completion
#                          rather than the empty-cycle failure. See absorb_tick
#                          and docs/watcher-continuity.md
#   heartbeat              fleet-scan backstop found an unsurfaced captain-relevant
#                          status, unless a live away-mode daemon owns triage.
#                          Becomes "heartbeat: host resources degraded|critical"
#                          when a recent sweep found the host under pressure; a
#                          disabled monitor or a stale cached reading annotates
#                          nothing. The annotation keeps the "heartbeat:" prefix
#                          every wake consumer matches on, so an annotated
#                          heartbeat is still recognised as an actionable wake
# For normal supervision, resume the session-start primary-harness protocol
# after each printed reason. Direct duplicate invocations of this script still
# no-op through the watcher singleton lock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
mkdir -p "$STATE"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# Same in-flight count the guards use, so the watcher and they cannot disagree
# about what "work under way" means (see absorb_tick).
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# Shared wake classifier (captain-relevant verbs + signal/stale/heartbeat
# predicates), the SAME library the away-mode daemon uses, so the triage policy
# has one definition.
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# One owner for "is an away-mode daemon actually running for THIS home?", the
# question that decides whether this watcher keeps its own triage or hands every
# wake to the daemon.
# shellcheck source=bin/fm-afk-daemon-lib.sh
. "$SCRIPT_DIR/fm-afk-daemon-lib.sh"
# The DEFAULT EVENT SOURCE: this watcher's poll loop over the pull primitives
# (capture, recorded windows, backend busy-state, and the BUSY_REGEX fallback)
# synthesizes the signal/stale/check/heartbeat wake vocabulary for backends with
# no native event push. tmux always reports unknown busy-state, preserving the
# original regex path. A push-capable backend (herdr) additionally replaces this
# watcher's blind terminal sleep with a bounded wait on its native event stream
# (event_wait_or_sleep below), so a crew entering `blocked` wakes its supervisor
# sub-second; the poll loop stays live every cycle as the permanent fail-closed
# backstop. See bin/fm-backend.sh and docs/herdr-backend.md.
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# Shared normalized-transition accessors and the single-owner status->action
# policy table, so the event-wait splice reads transition records the same way
# the herdr subscriber writes them (bin/fm-transition-lib.sh).
# shellcheck source=bin/fm-transition-lib.sh
. "$SCRIPT_DIR/fm-transition-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# Parent-owned secondmate missed-report guards: durable pending-reply
# expectations created by fm-send on marked secondmate requests. The tick is
# cheap when no records exist and never scrapes secondmate conversation.
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# Secondmate context-window read + threshold, for the slow-poll context monitor
# (secondmate_context_sweep). Fails closed: an unreadable/unsupported harness
# yields no tokens and never wakes. See docs/secondmate-context-handoff.md.
# shellcheck source=bin/fm-secondmate-context-lib.sh
. "$SCRIPT_DIR/fm-secondmate-context-lib.sh"

# Arming, cadence, and script mapping for the two session-lifetime hourly
# passes (hourly_pass_sweep below). Unarmed homes never run them.
# shellcheck source=bin/fm-hourly-lib.sh
. "$SCRIPT_DIR/fm-hourly-lib.sh"

WATCH_LOCK="$STATE/.watch.lock"
WATCH_PATH="$SCRIPT_DIR/fm-watch.sh"
WATCHER_STALE_GRACE=${FM_WATCHER_STALE_GRACE:-${FM_GUARD_GRACE:-900}}
# The singleton-lock acquisition, EXIT trap, and the blocking supervision loop
# all live below the source guard at the very bottom of this file (see "Main
# entry"). Sourcing this file for unit tests therefore loads the functions -
# including the event-wait splice below - and returns before acquiring the lock
# or starting the loop. Running it as a script executes the runtime exactly as
# before, byte-for-byte.

# Portable stat. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU) stat uses `-c <fmt>`.
# Do NOT use the `stat -f <fmt> ... || stat -c <fmt> ...` fallback form: on Linux
# `stat -f` is *filesystem* stat and writes a partial filesystem dump ("File: ...",
# "Blocks: ...") to stdout before failing, so the fallback's correct output gets
# appended to that garbage. Arithmetic under `set -u` then aborts on the stray
# token (e.g. the word "File" read as an unset variable), which silently kills the
# watcher mid-cycle. Detect the platform once and pick the right form.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }        # epoch seconds of mtime
  stat_sig()   { stat -f '%z:%Fm' "$1" 2>/dev/null; }   # size:mtime signature
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
  stat_sig()   { stat -c '%s:%Y' "$1" 2>/dev/null; }
fi

POLL=${FM_POLL:-300}                  # seconds between cycles (captain default: 5 min).
                                      # INVARIANT: POLL < grace (WATCHER_STALE_GRACE,
                                      # set above from FM_WATCHER_STALE_GRACE, then
                                      # FM_GUARD_GRACE) so a full cycle's wait never
                                      # outlives the liveness beacon - see beacon_sleep
                                      # and the start-up invariant check in the runtime
                                      # section, which warns when it is violated.
                                      # This default of 300 sits below the tracked
                                      # grace default of 900, which is the captain's
                                      # operating pair. If either value is changed,
                                      # keep POLL below the grace.
HEARTBEAT=${FM_HEARTBEAT:-600}        # base seconds between heartbeat scans
HEARTBEAT_MAX=${FM_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${FM_CHECK_INTERVAL:-600}  # seconds between *.check.sh sweeps (captain default: 10 min)
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}     # seconds allowed per *.check.sh
# Host-resource sweep cadence, on its OWN interval rather than POLL or
# CHECK_INTERVAL: host pressure moves on a scale of minutes, and X mode drives
# CHECK_INTERVAL down to 30s. bin/fm-resource-check.sh owns the knob, its default
# and its disabled (0) form; this reads the resolved value once at start, the
# same way every other cadence here is fixed for the process lifetime.
# An unrunnable or unparseable resolver falls back to that default rather than
# silently switching the monitor off for this watcher's whole lifetime; the
# fallback is logged once at startup so the condition is visible.
# Mirror of bin/fm-resource-check.sh's RESOURCE_INTERVAL_DEFAULT, which is the
# single source of truth for this number; keep the two in step.
# The flag is kept separate from the offending value, because the case this
# fallback exists for - a resolver that cannot run at all - yields an EMPTY
# value, and an emptiness test would suppress exactly that log line.
RESOURCE_INTERVAL_DEFAULT=900
RESOURCE_INTERVAL_FELL_BACK=0
RESOURCE_INTERVAL_RAW=$("$SCRIPT_DIR/fm-resource-check.sh" --interval 2>/dev/null || printf '')
RESOURCE_INTERVAL=$RESOURCE_INTERVAL_RAW
case "$RESOURCE_INTERVAL" in
  ''|*[!0-9]*)
    RESOURCE_INTERVAL_FELL_BACK=1
    [ -n "$RESOURCE_INTERVAL_RAW" ] || RESOURCE_INTERVAL_RAW='<empty>'
    RESOURCE_INTERVAL=$RESOURCE_INTERVAL_DEFAULT
    ;;
esac
SIGNAL_GRACE=${FM_SIGNAL_GRACE:-30}   # seconds to linger after a signal so trailing
                                      # signals (a status write, then the same turn's
                                      # turn-end hook) coalesce into one wake
# Longest blind-sleep slice. A single `sleep POLL` refreshes the beacon only at
# the loop top, so once POLL approaches the grace a healthy sleeping watcher
# reads as dead for the back of every cycle (the wedge). beacon_sleep splits the
# wait into slices no longer than min(POLL, grace/2) and re-touches the beacon
# each slice, so a healthy watcher stays fresh within the grace for the whole
# cycle and a machine-suspend can strand the beacon for at most one slice past
# resume. Floor at 1s so a tiny grace still makes progress.
_beacon_half=$(( WATCHER_STALE_GRACE / 2 ))
[ "$_beacon_half" -lt 1 ] && _beacon_half=1
if [ "$POLL" -lt "$_beacon_half" ]; then BEACON_SLICE=$POLL; else BEACON_SLICE=$_beacon_half; fi
[ "$BEACON_SLICE" -lt 1 ] && BEACON_SLICE=1
# Busy signatures per harness, OR-ed. Extend via env when new adapters are verified.
# claude/codex: "esc to interrupt"; opencode: "esc interrupt"; pi: "Working...";
# grok: "Ctrl+c:cancel" (the mid-turn cancel hint in grok's keybind bar, shown iff a
# turn is running; absent when idle - verified grok 0.2.73, ASCII to avoid the
# locale fragility of matching grok's braille spinner glyph directly).
BUSY_REGEX=${FM_BUSY_REGEX:-'esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'}
# Always-on wake triage: most wakes during a long crew validation are benign (a
# working: note or turn-end while a pipeline runs, a no-change heartbeat). Rather
# than wake firstmate's LLM for each, this watcher classifies every wake in bash
# and ABSORBS the benign majority - it advances the suppression marker, logs to a
# debug log, and keeps blocking WITHOUT enqueuing or exiting. The no-verb signal
# / stale path is absorb-only-when-provably-working: such a wake is absorbed ONLY
# while the crew shows positive evidence it is still working (an actively-running
# no-mistakes step, or a busy pane, via crew_is_provably_working over
# fm-crew-state.sh); a crew that stopped its turn with no running pipeline and no
# busy pane is SURFACED, so a finish reported only through interactive pane menus
# (no done: status) is never swallowed. An ACTIONABLE wake (a captain-relevant
# signal, a no-verb signal whose crew is not provably working, any check, a stale
# pane whose crew is not provably working, a provably-working stale past the
# threshold, or anything unknown) is written to the durable queue and exits, which
# is what wakes the LLM through the background-task completion. The same classifier
# (fm-classify-lib.sh) backs the away-mode daemon; while a live daemon for this home
# owns triage, this watcher reverts to one-shot (enqueue + exit on every wake) and
# never double-triages - and never runs the costly provably-working read.
STALE_ESCALATE_SECS=${FM_STALE_ESCALATE_SECS:-240}  # idle secs before a provably-working stale escalates as a possible wedge
# A crew that declared a pause is idling on a known external wait, so its stale
# pane is absorbed rather than wedge-escalated.
# A captain-held or paused crew whose agent has confidently exited uses the same
# bounded cadence, while a live or ambiguously read agent still surfaces once.
# These cases re-surface once for a recheck every PAUSE_RESURFACE_SECS - far
# longer than the wedge threshold, but finite so a forgotten hold cannot rot invisibly.
PAUSE_RESURFACE_SECS=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
TRIAGE_LOG="$STATE/.watch-triage.log"
TRIAGE_LOG_MAX_BYTES=${FM_WATCH_TRIAGE_LOG_MAX_BYTES:-262144}
# Consecutive event-path failures (fm_backend_wait_transition returning 2 -
# connect/subscribe failure) before the push fast-path is disabled for the rest
# of this watcher process and the loop reverts to pure polling (report section
# 5c trigger 3: proven-unreliable-at-runtime). A watcher restart re-probes
# capability, so a transient herdr hiccup self-heals on the next cycle chain.
EVENT_CAP_FAIL_MAX=${FM_EVENT_CAP_FAIL_MAX:-3}
# Per-process memo for the push-capability probe (fm_backend_events_capable runs
# a ~220KB `herdr api schema` read, too heavy to repeat every poll). Keyed by
# "<backend>:<session>"; re-probed only when that key changes.
_event_cap_key=""
_event_cap_ok=0
_event_cap_fails=0
# Bumped once per poll iteration; per-cycle memos key off it.
POLL_CYCLE=0

# afk_daemon_owns_triage: 0 while away mode is on AND a live daemon for this home
# is actually running it. Then the daemon wraps this watcher and owns triage, so
# the watcher must behave one-shot (enqueue + exit on every wake) and let the
# daemon classify - never absorb here, or the daemon's digest/injection layer
# would never see the wake. Away mode with NO daemon is the away posture only:
# deferring to a triager that never runs would surface every benign wake and
# leave the fleet effectively unsupervised, so the watcher keeps its own normal
# triage. Memoized for the whole poll cycle so one wake never reads the daemon
# lock several times (bin/fm-afk-daemon-lib.sh owns the liveness question).
_afk_owner_cycle=""
_afk_owner_verdict=1
afk_daemon_owns_triage() {
  if [ "$_afk_owner_cycle" != "$POLL_CYCLE" ]; then
    _afk_owner_cycle=$POLL_CYCLE
    _afk_owner_verdict=1
    fm_afk_daemon_owns_supervision "$STATE" "$SCRIPT_DIR" && _afk_owner_verdict=0
  fi
  return "$_afk_owner_verdict"
}

# Append one line to the triage debug log explaining an absorbed (benign) wake,
# size-capped so a long benign stretch cannot grow it without bound. Best-effort:
# a logging hiccup never affects supervision.
triage_log() {
  local sz
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$TRIAGE_LOG" 2>/dev/null || return 0
  sz=$(wc -c < "$TRIAGE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$TRIAGE_LOG_MAX_BYTES" ]; then
    tail -n 2000 "$TRIAGE_LOG" > "$TRIAGE_LOG.tmp" 2>/dev/null && mv -f "$TRIAGE_LOG.tmp" "$TRIAGE_LOG" 2>/dev/null
    rm -f "$TRIAGE_LOG.tmp" 2>/dev/null || true
  fi
}

hash_pane() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

# window_is_busy: 0 (busy) iff the task's harness is actively working. Prefers
# a backend's native semantic busy state (fm_backend_busy_state - herdr's
# agent.get; herdr-addendum "busy state" row, "the first backend where
# fm_session_busy_state gets real semantics"); falls back to the existing
# pane-tail regex ONLY when the backend reports unknown (tmux always does, so
# its path is unchanged byte-for-byte). <tail40> is the same bounded capture
# already read for hashing, so this adds no extra backend calls on the
# regex-fallback path.
window_is_busy() {  # <window> <tail40>
  local w=$1 tail40=$2 bs
  bs=$(fm_backend_busy_state "$(window_backend "$w")" "$w" 2>/dev/null)
  case "$bs" in
    busy) return 0 ;;
    idle) return 1 ;;
    *)
      printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 | grep -qiE "$BUSY_REGEX"
      ;;
  esac
}

window_kind() {
  local w=$1 meta kind
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    echo "$kind"
    return 0
  fi
  echo unknown
}

# window_backend: the backend recorded in the meta whose window= matches <w>,
# defaulting to tmux (absent backend= means tmux; the P1 compatibility
# contract) when no matching meta carries the field, or none matches at all.
window_backend() {
  local w=$1 meta backend
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    backend=$(grep '^backend=' "$meta" | cut -d= -f2- || true)
    [ -n "$backend" ] || backend=tmux
    echo "$backend"
    return 0
  fi
  echo tmux
}

window_label() {
  local w=$1 task
  task=$(window_to_task "$w" "$STATE")
  [ -n "$task" ] && printf 'fm-%s' "$task"
}

recorded_windows() {
  local meta w seen=
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    w=$(fm_backend_target_of_meta "$meta")
    [ -n "$w" ] || continue
    case "$seen" in
      *"|$w|"*) continue ;;
    esac
    seen="$seen|$w|"
    printf '%s\n' "$w"
  done
}

# secondmate_context_sweep: the slow-poll context monitor. For each live
# secondmate window, read its context-window occupancy (claude only; every other
# harness reads unknown and is skipped - fail closed, no false handoff) and wake
# firstmate once when it first crosses the configured threshold, so a proactive
# handoff replaces the context-full agent BEFORE it must /compact. A per-window
# surfaced marker makes the crossing idempotent: the wake fires once and re-arms
# only after the count drops back under the threshold (a fresh post-handoff
# agent). Runs only on the CHECK_INTERVAL cadence, never on every fast poll.
# Like the *.check.sh loop it lives in, wake() exits the cycle; a second crossed
# secondmate surfaces on a later cycle.
secondmate_context_sweep() {
  local threshold w meta home harness tokens key marker id reason
  threshold=$(fm_sm_context_threshold "$CONFIG")
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    [ "$(window_kind "$w")" = secondmate ] || continue
    meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
    [ -n "$meta" ] || continue
    home=$(fm_meta_get "$meta" home); [ -n "$home" ] || home=$(fm_meta_get "$meta" worktree)
    [ -n "$home" ] || continue
    harness=$(fm_meta_get "$meta" harness); [ -n "$harness" ] || harness=$(fm_backend_of_meta "$meta")
    tokens=$(fm_sm_context_tokens "$home" "$harness" 2>/dev/null || true)
    key=$(printf '%s' "$w" | tr ':/.' '___')
    marker="$STATE/.sm-context-surfaced-$key"
    if [ -n "$tokens" ] && [ "$tokens" -ge "$threshold" ]; then
      [ -e "$marker" ] && continue
      : > "$marker"
      id=$(window_to_task "$w" "$STATE")
      reason="check: secondmate-context $id (context ${tokens} tokens >= threshold ${threshold})"
      fm_wake_append check "secondmate-context-$id" "$reason" || exit 1
      touch "$STATE/.last-check"
      wake "$reason"
    else
      rm -f "$marker"
    fi
  done <<EOF
$(recorded_windows)
EOF
}

# resource_sweep: the slow-poll HOST monitor. Reads kernel-wide CPU load, memory
# headroom and swap through bin/fm-resource-check.sh (its own cadence, see
# RESOURCE_INTERVAL) and wakes firstmate when host pressure first gets WORSE than
# the level it was last told about, so a thrashing host is reported once instead
# of nagged about every sweep. It is monitor-and-report only: nothing here pauses,
# sheds or kills anything, because shedding load is the captain's decision.
#
# This sweep is the ONLY caller that runs the check with --sweep, so crew-liveness
# probing happens once per cadence here and never on a synchronous path.
# .resource-status caches the latest reading for the heartbeat annotation.
# .resource-surfaced remembers the worst level already reported; recovery to
# healthy re-arms it SILENTLY (no wake), so the fleet is only interrupted for
# pressure it has not already been told about. An unknown or disabled reading
# leaves both markers untouched and never wakes - the same
# never-wake-on-an-unreadable-probe rule as secondmate_context_sweep.
resource_sweep() {
  local out rc status last rank last_rank reason
  out=$("$SCRIPT_DIR/fm-resource-check.sh" --sweep 2>/dev/null) && rc=0 || rc=$?
  case "$rc" in
    0) status=healthy ;;
    1) status=degraded ;;
    2) status=critical ;;
    *) return 0 ;;
  esac
  printf '%s\n' "$status" > "$STATE/.resource-status"
  last=$(cat "$STATE/.resource-surfaced" 2>/dev/null || printf 'healthy')
  case "$status" in healthy) rank=0 ;; degraded) rank=1 ;; *) rank=2 ;; esac
  case "$last" in healthy) last_rank=0 ;; degraded) last_rank=1 ;; critical) last_rank=2 ;; *) last_rank=0 ;; esac
  if [ "$rank" -eq 0 ]; then
    [ "$last_rank" -eq 0 ] || triage_log "host resources recovered to healthy (re-armed, no wake)"
    printf '%s\n' healthy > "$STATE/.resource-surfaced"
    return 0
  fi
  if [ "$rank" -le "$last_rank" ]; then
    triage_log "absorbed host resources $status (already reported at $last)"
    return 0
  fi
  printf '%s\n' "$status" > "$STATE/.resource-surfaced"
  # Flatten the reading (and its SHED advice, when present) onto the single line
  # a wake record holds.
  reason="check: host-resources $(printf '%s\n' "$out" \
    | awk '{sub(/^resources: /, ""); printf "%s%s", sep, $0; sep="; "}')"
  fm_wake_append check host-resources "$reason" || exit 1
  wake "$reason"
}

# hourly_pass_sweep: run the session-lifetime hourly passes that
# bin/fm-session-start.sh armed - the session review and the cleanup sweep.
# They live here, on the one watcher, precisely so no second supervision cycle
# is needed: this loop is already the home's single scheduler, so an hourly duty
# becomes one more cadence-gated sweep rather than a competing timer.
#
# Each pass runs at most once per its own interval, time-based via its stamp
# mtime so the cadence survives watcher restarts, and the stamp is touched
# BEFORE the run so a slow or failing pass cannot re-fire every poll. Only
# repository-owned, non-symlinked bin/ scripts are executed, the same trust rule
# the X-mode poll shim uses. A pass that prints nothing is the normal case and
# wakes nobody; output means it has something the fleet has not been told about,
# so it is flattened onto one wake record. wake() ends the cycle, so a second
# due pass runs on a later poll.
hourly_pass_sweep() {
  local pass interval stamp script script_name out reason
  fm_hourly_is_armed "$STATE" || return 0
  for pass in $FM_HOURLY_PASSES; do
    interval=$(fm_hourly_interval "$pass") || continue
    [ "$interval" -gt 0 ] || continue
    stamp=$(fm_hourly_stamp "$STATE" "$pass")
    [ "$(age_of "$stamp")" -ge "$interval" ] || continue
    touch "$stamp"
    script_name=$(fm_hourly_pass_script "$pass") || continue
    [ -n "$script_name" ] || continue
    script="$SCRIPT_DIR/$script_name"
    [ -f "$script" ] && [ ! -L "$script" ] || continue
    FM_HOME="$FM_HOME" run_check_capture "$script" || exit 1
    out=$FM_CHECK_RESULT
    [ -n "$out" ] || continue
    reason="check: session-$pass $(printf '%s\n' "$out" \
      | awk 'NF {printf "%s%s", sep, $0; sep="; "}')"
    fm_wake_append check "session-$pass" "$reason" || exit 1
    wake "$reason"
  done
}

# Exit reporting a wake. Consecutive heartbeats with no other wake in between
# mean an idle fleet, so the heartbeat interval backs off exponentially
# (base * 2^streak, capped at HEARTBEAT_MAX); any real wake resets the cadence.
wake() {
  case "$1" in
    heartbeat*) echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak" ;;
    *) echo 0 > "$STATE/.heartbeat-streak" ;;
  esac
  echo "$1"
  exit 0
}

# Proof-of-life "tick" for a benign-ABSORBED wake. Default OFF: with
# FM_WATCH_ABSORB_TICK unset or any value other than 1 this is a no-op that RETURNS,
# so the caller keeps blocking exactly as before and behavior is byte-identical. When
# set to 1, a benign-absorbed wake instead ENDS the cycle with a distinguishable
# "tick: <note>" reason line and exit 0, so the arming session can tell a
# live-but-quiet watcher from a dead one at minimal token cost (the standing rule on a
# tick-enabled home is a single literal "tick" reply). A tick enqueues NO durable wake
# record, so bin/fm-wake-drain.sh, the continuity guard, and the turn-end guard see no
# actionable work; bin/fm-watch-arm.sh classifies the "tick:" line as a benign
# completion, distinct from an actionable wake (signal/stale/check/heartbeat) and from
# a failure (nonzero exit). Call ONLY from one-shot absorb points that have already
# advanced their suppression state (a benign signal whose .seen-* signature is
# written, an absorbed heartbeat whose schedule and backoff are advanced), never from
# a per-poll re-evaluation of an unchanged pane, so it fires at most once per
# absorbed-wake event and never storms on a static fleet. A tick also fires ONLY while
# work is under way: a signal presupposes a task, and the absorbed-heartbeat caller
# gates on the shared in-flight count. That is exactly the state in which the turn-end
# guard already forces a re-arm, so ending the cycle can never leave a home without
# supervision and no guard needs to know about this knob. With nothing under way the
# watcher keeps absorbing silently and self-sustains as it always has.
# This function itself never
# writes .heartbeat-streak and never enqueues anything, because a tick is not an
# actionable wake; the absorbed-heartbeat caller deliberately bumps the streak just
# before calling here, since that bump is what drives the heartbeat backoff.
FM_WATCH_ABSORB_TICK=${FM_WATCH_ABSORB_TICK:-0}
absorb_tick() {  # <note>
  [ "$FM_WATCH_ABSORB_TICK" = 1 ] || return 0
  echo "tick: $1"
  exit 0
}

# Consecutive wedge-escalation count for a window past FM_WEDGE_DEMAND_INSPECT_COUNT
# (default 3): a pane that keeps re-wedging on the SAME stale hash - each
# escalation gets absorbed again as "still validating" one poll later, since the
# hash never changes - can otherwise repeat forever with no signal that this is
# no longer a one-off. At the threshold, wedge_timer_check appends a
# "demand-deep-inspection" marker to the wake payload so the wake reason itself
# (not just repetition the supervisor has to notice on its own) forces a closer
# look instead of another routine supervision resume. Reset wherever a window's
# pane/hash state resets to genuinely active (see the two rm-on-reset call sites
# below).
FM_WEDGE_DEMAND_INSPECT_COUNT=${FM_WEDGE_DEMAND_INSPECT_COUNT:-3}

# Repeat-poll wedge-timer bookkeeping for an already-classified stale hash
# absorbed as provably-working - repairs a missing/corrupt timer (self-heals a
# watcher restart between recording the hash and recording the timer), or
# escalates once STALE_ESCALATE_SECS have elapsed. Never re-reads the crew
# state (the costly check already ran once, at classification time). Shared by
# both places a hash can be absorbed this way: the plain non-terminal path,
# and the stale_is_terminal-overridden path (a captain-relevant status-log
# line that an active run/busy pane outranked).
wedge_timer_check() {  # <window> <since-file> <triage-label> <escalation-count-file>
  local win=$1 since_file=$2 label=$3 escalation_file=$4 since age n reason
  since=$(cat "$since_file" 2>/dev/null || true)
  case "$since" in
    ''|*[!0-9]*)
      date +%s > "$since_file"
      triage_log "absorbed $label timer reset: $win"
      ;;
    *)
      age=$(( $(date +%s) - since ))
      if [ "$age" -ge "$STALE_ESCALATE_SECS" ]; then
        n=$(( $(cat "$escalation_file" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$escalation_file"
        reason="stale: $win (idle ${age}s, possible wedge, escalation $n)"
        if [ "$n" -ge "$FM_WEDGE_DEMAND_INSPECT_COUNT" ]; then
          reason="stale: $win (idle ${age}s, possible wedge, escalation $n, demand-deep-inspection: same pane has wedge-escalated $n times in a row - do not re-absorb on the run-step/pane state alone)"
        fi
        fm_wake_append stale "$win" "$reason" || exit 1
        rm -f "$since_file"
        wake "$reason"
      fi
      ;;
  esac
}

# Absorb a stale pane under a declared external-wait pause (paused:) or a
# dead-agent captain-held transfer, and re-surface it once every
# PAUSE_RESURFACE_SECS for a recheck so it cannot rot invisibly. Called on any
# stale poll once pause_state_class permits the bounded cadence, so it must be
# cheap: it NEVER re-reads crew state. The re-surface age is anchored on the
# status file mtime, not a per-hash marker, so a churny idle pane (a ticking
# clock, a token counter) cannot keep resetting the cadence the way a hash-tied
# timer would. A .paused-resurfaced-<key> throttle marker records the last
# re-surface epoch so, once past the window, it fires once per window rather than
# every poll. Advances the stale suppressor to <hash> and flags the key paused.
handle_paused_stale() {  # <window> <task> <hash>
  local win=$1 task=$2 h=$3 key statusf mtime age rf rf_age reason
  key=$(printf '%s' "$win" | tr ':/.' '___')
  printf '%s' "$h" > "$STATE/.stale-$key"
  : > "$STATE/.paused-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key" "$STATE/.stale-verdict-$key"
  statusf="$STATE/$task.status"
  mtime=$(stat_mtime "$statusf")
  case "$mtime" in ''|*[!0-9]*) mtime=$(date +%s) ;; esac
  age=$(( $(date +%s) - mtime ))
  rf="$STATE/.paused-resurfaced-$key"
  rf_age=$(age_of "$rf")   # 999999 when no prior re-surface
  if [ "$age" -ge "$PAUSE_RESURFACE_SECS" ] && [ "$rf_age" -ge "$PAUSE_RESURFACE_SECS" ]; then
    reason="stale: $win (paused ${age}s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)"
    fm_wake_append stale "$win" "$reason" || exit 1
    date +%s > "$rf"
    wake "$reason"
  fi
  triage_log "absorbed stale (paused, awaiting external, age ${age}s): $win"
}

clear_pause_state() {  # <window>
  local win=$1 key
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
}

clear_pause_tracking() {  # <window>
  local win=$1 key
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  clear_pause_state "$win"
  rm -f "$STATE/.stale-$key" "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key" "$STATE/.stale-verdict-$key"
}

# Reconcile a declared pause or captain-held status with authoritative crew state.
# Only a confidently dead ordinary crew may recover paused classification after
# fm-crew-state has fallen back to stopped or unknown.
pause_state_class() {  # <window> <task>
  local win=$1 task=$2 key last recheck_file class agent_alive
  key=${win//:/_}
  key=${key//\//_}
  key=${key//./_}
  last=$(last_status_line "$STATE/$task.status")
  recheck_file="$STATE/.paused-rechecked-$key"
  if ! status_is_paused_or_captain_held "$last"; then
    rm -f "$recheck_file"
    crew_absorb_class "$task"
    return
  fi
  if [ -e "$STATE/.paused-$key" ] && [ "$(age_of "$recheck_file")" -lt "$STALE_ESCALATE_SECS" ]; then
    if [ "$(window_kind "$win")" != secondmate ]; then
      agent_alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent_alive=unknown
      if [ "$agent_alive" != dead ]; then
        rm -f "$recheck_file"
        printf 'none'
        return
      fi
    fi
    printf 'paused'
    return
  fi
  class=$(crew_absorb_class "$task")
  if [ "$class" = working ]; then
    rm -f "$recheck_file"
    printf 'working'
    return
  fi
  if [ "$(window_kind "$win")" != secondmate ]; then
    agent_alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent_alive=unknown
    if [ "$agent_alive" != dead ]; then
      rm -f "$recheck_file"
      printf 'none'
      return
    fi
  fi
  [ "$class" = none ] && [ "${agent_alive:-unknown}" = dead ] && class=paused
  case "$class" in
    paused) date +%s > "$recheck_file" ;;
    *) rm -f "$recheck_file" ;;
  esac
  printf '%s' "$class"
}

surface_nonterminal_stale() {  # <window> <hash>
  local win=$1 h=$2 key task last
  key=$(printf '%s' "$win" | tr ':/.' '___')
  fm_wake_append stale "$win" "stale: $win" || exit 1
  printf '%s' "$h" > "$STATE/.stale-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.stale-verdict-$key"
  task=$(window_to_task "$win" "$STATE")
  last=$(last_status_line "$STATE/$task.status")
  if status_is_paused_or_captain_held "$last"; then
    : > "$STATE/.paused-$key"
    date +%s > "$STATE/.paused-rechecked-$key"
    date +%s > "$STATE/.paused-resurfaced-$key"
  else
    rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
  fi
  wake "stale: $win"
}

# Check and heartbeat cadence must survive actionable exits and restarts: the
# watcher may be relaunched before in-memory counters reach their threshold on a
# busy fleet. Persist the schedule as file mtimes instead.
age_of() {  # seconds since file mtime; "due immediately" if missing
  local f=$1 m
  m=$(stat_mtime "$f") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

# Layer 2 + 3 signal scan: status files and turn-end markers. Each file is
# compared against a persisted size:mtime signature (.seen-*) rather than
# mtime-vs-a-startup-touch, so signals that land while no watcher is running
# are caught by the next one, and same-second writes cannot slip through a
# strict -nt comparison. Pure read: prints one "<seen-file>\t<sig>\t<file>"
# line per changed file. .seen-* is updated only after the wake is either
# surfaced or intentionally absorbed, so a watcher killed mid-cycle never
# swallows a signal.
scan_signals() {
  local f sig sf
  for f in "$STATE"/*.status "$STATE"/*.turn-ended; do
    [ -e "$f" ] || continue
    sig=$(stat_sig "$f") || continue
    sf="$STATE/.seen-$(basename "$f" | tr '.' '_')"
    if [ "$sig" != "$(cat "$sf" 2>/dev/null)" ]; then
      printf '%s\t%s\t%s\n' "$sf" "$sig" "$f"
    fi
  done
  return 0
}

run_check_process() {
  local c=$1
  shift
  if [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v timeout >/dev/null 2>&1; then
    exec timeout "$CHECK_TIMEOUT" bash "$c" "$@"
  elif [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    exec gtimeout "$CHECK_TIMEOUT" bash "$c" "$@"
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    exec perl -e 'my $t = shift; my $owned = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0) unless $owned; exec @ARGV } my $group = $owned ? getpgrp(0) : $pid; my $stop = sub { $SIG{HUP} = $SIG{INT} = $SIG{TERM} = "IGNORE"; kill "TERM", -$group; select undef, undef, undef, 0.2; kill "KILL", -$group; waitpid $pid, 0; exit 124 }; local $SIG{ALRM} = $stop; local $SIG{HUP} = $stop; local $SIG{INT} = $stop; local $SIG{TERM} = $stop; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" "${FM_CHECK_OWNED_GROUP:-0}" bash "$c" "$@"
  fi
}

run_check() {
  ( run_check_process "$@" ) 2>/dev/null || true
}

FM_ACTIVE_CHECK_PID=
FM_ACTIVE_CHECK_PGID=
FM_CHECK_OUTPUT=
FM_CHECK_RESULT=
FM_CHECK_SIGNAL_PENDING=

fm_check_output_cleanup() {
  [ -z "$FM_CHECK_OUTPUT" ] || rm -f -- "$FM_CHECK_OUTPUT"
  FM_CHECK_OUTPUT=
}

fm_active_check_stop() {
  local pid=${FM_ACTIVE_CHECK_PID:-} pgid=${FM_ACTIVE_CHECK_PGID:-} i
  [ -n "$pid" ] || [ -n "$pgid" ] || return 0
  [ -z "$pgid" ] || kill -TERM -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 20 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -z "$pgid" ] || kill -KILL -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
  [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  if [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null; then
    return 1
  fi
  FM_ACTIVE_CHECK_PID=
  FM_ACTIVE_CHECK_PGID=
}

run_check_capture() {
  local pgid
  fm_check_output_cleanup
  FM_CHECK_RESULT=
  FM_CHECK_OUTPUT=$(mktemp "$STATE/.fm-check-output.XXXXXX") || return 1
  chmod 0600 "$FM_CHECK_OUTPUT" || { fm_check_output_cleanup; return 1; }
  FM_CHECK_SIGNAL_PENDING=
  trap 'FM_CHECK_SIGNAL_PENDING=1' HUP INT TERM
  set -m
  ( FM_CHECK_OWNED_GROUP=1 run_check_process "$@" ) > "$FM_CHECK_OUTPUT" 2>/dev/null &
  FM_ACTIVE_CHECK_PID=$!
  FM_ACTIVE_CHECK_PGID=$FM_ACTIVE_CHECK_PID
  set +m
  pgid=$(ps -o pgid= -p "$FM_ACTIVE_CHECK_PID" 2>/dev/null | tr -d '[:space:]')
  trap 'exit 1' HUP INT TERM
  if [ -n "$pgid" ] && [ "$pgid" != "$FM_ACTIVE_CHECK_PGID" ]; then
    fm_active_check_stop || true
    fm_check_output_cleanup
    return 1
  fi
  [ -z "$FM_CHECK_SIGNAL_PENDING" ] || exit 1
  wait "$FM_ACTIVE_CHECK_PID" 2>/dev/null || true
  FM_ACTIVE_CHECK_PID=
  fm_active_check_stop || return 1
  FM_CHECK_RESULT=$(cat "$FM_CHECK_OUTPUT" 2>/dev/null || true)
  fm_check_output_cleanup
}

# Surfaced-marker bookkeeping for the heartbeat backstop. The watcher records the
# captain-relevant status line it SURFACED (woke firstmate for) in
# .hb-surfaced-<task>, the watcher's analogue of the daemon's
# .subsuper-seen-status. Unlike .seen-* (a size:mtime signature advanced on BOTH
# surface and absorb), .hb-surfaced is advanced ONLY on surface, so the heartbeat
# fleet-scan can tell apart a captain-relevant status that already woke firstmate
# from one that has not - the latter being a per-wake-path miss it must surface.
_hb_surfaced_path() { printf '%s/.hb-surfaced-%s' "$STATE" "$(printf '%s' "$1" | tr ':/.' '___')"; }

# Record a status file's captain-relevant last line as surfaced (no-op for a
# non-captain-relevant or empty status). Call AFTER the wake is enqueued, so the
# enqueue-before-suppress ordering holds for this marker too.
mark_surfaced() {  # <status-file>
  local f=$1 task last
  task=$(basename "$f"); task="${task%.status}"
  last=$(last_status_line "$f")
  [ -n "$last" ] || return 0
  status_is_captain_relevant "$last" || return 0
  printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
}

# Mark every current captain-relevant status as surfaced. Called after the
# heartbeat backstop enqueues its wake, so the same statuses are not re-surfaced
# by the next heartbeat.
mark_all_captain_relevant_surfaced() {
  local f task last
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
  done < <(scan_captain_relevant_statuses "$STATE")
}

# Cheap heartbeat fleet-scan (the always-on twin of the daemon's catch-all). 0 if
# any captain-relevant status has NOT already been surfaced to firstmate (its
# content differs from the .hb-surfaced-<task> marker). Pure detect, no side
# effects: the caller enqueues first, then marks surfaced. Because every
# captain-relevant signal/stale already marks itself surfaced when it wakes
# firstmate, this normally finds nothing and the heartbeat is absorbed; it
# surfaces only a captain-relevant status the per-wake path absorbed by mistake -
# the fail-safe backstop.
heartbeat_scan_finds_actionable() {
  local f task last surfaced
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    surfaced=$(cat "$(_hb_surfaced_path "$task")" 2>/dev/null || true)
    [ "$surfaced" = "$last" ] && continue
    return 0
  done < <(scan_captain_relevant_statuses "$STATE")
  return 1
}

# event_wait_or_sleep: the terminal wait of each supervision cycle. For a home
# with push-capable windows (herdr), it replaces the blind `sleep POLL` with a
# bounded wait on the backend's native transition stream, so a crew going
# `blocked` wakes the supervisor sub-second instead of after the stale-pane
# wedge timer. For every other home - no push-capable window, backend not
# capable, or the event path proven unreliable this process - it sleeps POLL,
# byte-for-byte today's behavior. The poll loop above still runs every cycle, so
# this only ever SHORTENS latency; it can never drop an escalation (the poll
# loop is the permanent fail-closed backstop). This preserves the single live
# supervision cycle: the reader is a short-lived subprocess of THIS watcher, not
# a second watcher, so every guard/beacon/arm/turn-end mechanism is unchanged.
# beacon_sleep: sleep `total` seconds while keeping the liveness beacon fresh and
# staying promptly interruptible. The sleep runs as a backgrounded child we
# `wait` on, so a HUP/INT/TERM delivered to this watcher runs its trap right away
# instead of being deferred behind a foreground `sleep` - the recovery wedge
# where --restart's SIGTERM could not land until the whole poll elapsed. The
# beacon is re-touched every slice (see BEACON_SLICE) so a healthy sleeping
# watcher never reads as dead mid-cycle.
_beacon_sleep_child=
beacon_sleep() {  # <total-seconds>
  local slice remaining=$1
  while [ "$remaining" -gt 0 ]; do
    slice=$BEACON_SLICE
    [ "$remaining" -lt "$slice" ] && slice=$remaining
    sleep "$slice" &
    _beacon_sleep_child=$!
    wait "$_beacon_sleep_child"
    _beacon_sleep_child=
    touch "$STATE/.last-watcher-beat"
    remaining=$((remaining - slice))
  done
}

event_wait_or_sleep() {
  local w b session first_backend="" first_session="" rec rc
  local windows=()
  while IFS= read -r w; do
    b=$(window_backend "$w")
    fm_backend_has_push "$b" || continue
    # Secondmate endpoints are supervised via status writes, not pane/agent
    # state (an idle or blocked secondmate agent pane is healthy by design), so
    # they are excluded from the fast escalation exactly as the stale loop skips
    # them.
    [ "$(window_kind "$w")" = secondmate ] && continue
    session=${w%%:*}
    if [ -z "$first_backend" ]; then first_backend=$b; first_session=$session; fi
    # One socket connection covers one backend+session; a home normally has a
    # single herdr session. A window in a different backend/session stays on the
    # poll path this cycle.
    if [ "$b" != "$first_backend" ] || [ "$session" != "$first_session" ]; then
      continue
    fi
    windows+=("$w")
  done < <(recorded_windows)

  if [ "${#windows[@]}" -eq 0 ]; then
    beacon_sleep "$POLL"
    return
  fi

  # Memoized capability probe (fm_backend_events_capable runs a heavy schema
  # read); re-probed only when the backend/session key changes.
  if [ "$_event_cap_key" != "$first_backend:$first_session" ]; then
    _event_cap_key="$first_backend:$first_session"
    if fm_backend_events_capable "$first_backend" "$first_session"; then
      _event_cap_ok=1
    else
      _event_cap_ok=0
    fi
    _event_cap_fails=0
  fi
  if [ "$_event_cap_ok" != 1 ]; then
    beacon_sleep "$POLL"
    return
  fi

  rec=$(FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1 fm_backend_wait_transition "$first_backend" "$first_session" "$POLL" "$STATE" "${windows[@]}")
  rc=$?
  case "$rc" in
    0)
      _event_cap_fails=0
      handle_push_transition "$first_backend" "$first_session" "$rec"
      ;;
    2)
      # Event path unusable this cycle (connect/subscribe failure). Sleep the
      # budget and count toward the runtime-disable threshold; past it, drop to
      # pure polling for the rest of this watcher process.
      _event_cap_fails=$((_event_cap_fails + 1))
      [ "$_event_cap_fails" -ge "$EVENT_CAP_FAIL_MAX" ] && _event_cap_ok=0
      beacon_sleep "$POLL"
      ;;
    *)
      # 1: a clean full-budget wait with no actionable edge - the reader already
      # blocked ~POLL, so just continue; the next cycle re-scans.
      _event_cap_fails=0
      ;;
  esac
}

# handle_push_transition: act on a fresh actionable (blocked) transition record
# the backend returned. Maps the pane back to its window and task, applies the
# declared-pause exemption (a crew waiting on a known external dependency is not
# a surprise block - absorb it on the poll loop's long pause cadence instead),
# and otherwise enqueues an immediate `stale` wake and wakes the supervisor. The
# `stale` kind is deliberate: the supervisor's handler for it ("peek the pane to
# diagnose") is exactly right for a blocked crew, and the drain/dedupe/guard
# machinery already understands it (queued by key=window, so a later poll-path
# stale for the same pane collapses on drain).
handle_push_transition() {  # <backend> <session> <record>
  local backend=$1 session=$2 record=$3 pane_id to window task reason
  pane_id=$(fm_transition_pane_id "$record")
  to=$(fm_transition_to_status "$record")
  [ -n "$pane_id" ] || { sleep 1; return; }
  window="$session:$pane_id"
  task=$(window_to_task "$window" "$STATE")
  if status_is_paused "$(last_status_line "$STATE/$task.status")"; then
    triage_log "absorbed push $to (declared pause, awaiting external): $window"
    fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
    return
  fi
  reason="stale: $window (herdr: agent $to - waiting on human, escalated immediately, not via wedge timer)"
  fm_wake_append stale "$window" "$reason" || exit 1
  fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
  mark_surfaced "$STATE/$task.status"
  wake "$reason"
}

# --- Main entry: the runtime below runs only when this file is executed as a
# script. When sourced (unit tests loading the functions above), return here
# before acquiring the singleton lock or entering the blocking loop.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

# Invariant: POLL must stay below the beacon grace, or a cycle's wait could
# outlive the beacon and read as dead. beacon_sleep already slices the wait to
# hold this even when the invariant is violated, so this only warns rather than
# refusing to start - but a violated invariant means the operator-chosen poll
# cadence is fighting the grace and should be reconciled.
if [ "$POLL" -ge "$WATCHER_STALE_GRACE" ]; then
  echo "watcher: FM_POLL=${POLL}s >= grace ${WATCHER_STALE_GRACE}s; the beacon is kept fresh by slicing the wait, but set FM_POLL below the grace to match cadence to liveness." >&2
fi

# Before acquiring the watcher lock or enumerating any runnable check, replace
# or quarantine checks created by older versions. The migration compares bytes
# and reads data only; it never invokes legacy check files through Bash.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || {
  echo "watcher: PR check migration blocked; refusing to execute state checks" >&2
  exit 1
}

if ! fm_lock_try_acquire "$WATCH_LOCK"; then
  BEAT="$STATE/.last-watcher-beat"
  if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
    if [ -e "$BEAT" ]; then
      beat_age=$(fm_path_age "$BEAT")
      if [ "$beat_age" -ge "$WATCHER_STALE_GRACE" ]; then
        echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but heartbeat is stale for ${beat_age}s (>${WATCHER_STALE_GRACE}s); inspect or stop that watcher before re-arming." >&2
        exit 1
      fi
    elif [ "$(fm_path_age "$WATCH_LOCK")" -ge "$WATCHER_STALE_GRACE" ]; then
      echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but no heartbeat exists; inspect or stop that watcher before re-arming." >&2
      exit 1
    fi
    echo "watcher: already running pid $FM_LOCK_HELD_PID"
  else
    echo "watcher: already running"
  fi
  exit 0
fi
watcher_cleanup() {
  fm_active_check_stop || return 1
  fm_check_output_cleanup
  fm_custom_check_snapshot_cleanup
  fm_lock_release "$WATCH_LOCK"
}
trap watcher_cleanup EXIT
# On a stop signal, kill the backgrounded beacon_sleep child (if the loop is in
# its terminal wait) so the trap is not deferred behind a foreground sleep, then
# exit so the EXIT trap releases the lock. This is what lets --restart's SIGTERM
# clear a sleeping watcher promptly instead of waiting out the whole poll.
# shellcheck disable=SC2329 # Invoked indirectly by the signal trap below.
watcher_signal_exit() {
  [ -n "${_beacon_sleep_child:-}" ] && kill "$_beacon_sleep_child" 2>/dev/null
  exit 1
}
trap watcher_signal_exit HUP INT TERM
# This watcher's own pid, as recorded in the lock by fm_lock_claim (which writes
# ${BASHPID:-$$} from this same main shell). Read directly, never via a command
# substitution, so it matches the stored holder pid for the self-eviction check.
WATCHER_PID=${BASHPID:-$$}
printf '%s\n' "$FM_HOME" > "$WATCH_LOCK/fm-home" || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
fm_pid_identity "$WATCHER_PID" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true

[ -e "$STATE/.last-heartbeat" ] || touch "$STATE/.last-heartbeat"

[ "$RESOURCE_INTERVAL_FELL_BACK" = 0 ] || triage_log \
  "host-resource cadence unresolved ('$RESOURCE_INTERVAL_RAW'), using default ${RESOURCE_INTERVAL}s"

while :; do
  POLL_CYCLE=$(( POLL_CYCLE + 1 ))
  # Self-eviction: if the singleton lock no longer names this process, a second
  # watcher has taken over (e.g. a transient duplicate from a racy arm). Stand
  # down so the rightful singleton continues alone. The EXIT trap's release
  # no-ops because the lock pid is not ours, so the survivor's lock is untouched.
  # This makes any duplicate self-resolve within one poll instead of persisting
  # and doubling every wake.
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" != "$WATCHER_PID" ]; then
    exit 0
  fi

  # Liveness beacon for fm-guard.sh: a fresh mtime here means a watcher is
  # alive. Supervision scripts warn when this goes stale with tasks in flight.
  touch "$STATE/.last-watcher-beat"

  # Parent-owned secondmate pending-reply reconciliation: resolve correlated
  # parent reports, observe backend busy/idle turn completion, send one recovery
  # repost after grace, and escalate once if the recovery turn is also missed.
  # No conversation scraping; unresolved records are never silently expired.
  fm_pending_reply_tick "$STATE" || true

  # Slow per-task checks (firstmate writes these, e.g. a merged-PR poll).
  # Time-based via .last-check mtime so the cadence survives watcher restarts.
  # Evaluated BEFORE the signal scan: wake() exits the cycle, so a check placed
  # after the signal scan would be starved whenever a chatty sibling crewmate
  # keeps producing signals - the slow poll (e.g. merge detection) would then
  # never run until the fleet went quiet. Checks are due only every
  # CHECK_INTERVAL, so most cycles skip this block and fall straight through.
  if [ "$(age_of "$STATE/.last-check")" -ge "$CHECK_INTERVAL" ]; then
    rejected_checks=
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      if [ "$(basename "$c")" = x-watch.check.sh ]; then
        if fmx_poll_shim_valid "$c" "$FM_HOME" "$FM_ROOT" \
          && [ -f "$FM_ROOT/bin/fm-x-poll.sh" ] && [ ! -L "$FM_ROOT/bin/fm-x-poll.sh" ]; then
          FM_HOME="$FM_HOME" run_check_capture "$FM_ROOT/bin/fm-x-poll.sh" || exit 1
          out=$FM_CHECK_RESULT
        else
          rejected_checks="$rejected_checks $c"
          continue
        fi
      else
        id=$(basename "$c" .check.sh)
        if fm_pr_poll_artifacts_valid "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh"; then
          provider=$FM_PR_DATA_PROVIDER
          url=$FM_PR_DATA_URL
          host=$FM_PR_DATA_HOST
          path=$FM_PR_DATA_PATH
          number=$FM_PR_DATA_NUMBER
          run_check_capture "$SCRIPT_DIR/fm-pr-poll.sh" --validated \
            "$provider" "$url" "$host" "$path" "$number" || exit 1
          out=$FM_CHECK_RESULT
        elif fm_custom_check_snapshot_prepare "$STATE" "$id"; then
          custom_snapshot=$FM_CUSTOM_CHECK_SNAPSHOT
          run_check_capture "$custom_snapshot" || exit 1
          out=$FM_CHECK_RESULT
          fm_custom_check_snapshot_cleanup
        else
          fm_custom_check_snapshot_cleanup
          rejected_checks="$rejected_checks $c"
          continue
        fi
      fi
      if [ -n "$out" ]; then
        reason="check: $c: $out"
        fm_wake_append check "$c" "$reason" || exit 1
        touch "$STATE/.last-check"
        wake "$reason"
      fi
    done
    if [ -n "$rejected_checks" ]; then
      reason="check: rejected unauthenticated state checks:$rejected_checks"
      fm_wake_append check unauthenticated-state-checks "$reason" || exit 1
      touch "$STATE/.last-check"
      wake "$reason"
    fi
    # Slow-poll context monitor: wake once when a secondmate crosses the handoff
    # threshold. wake() exits the cycle when it fires (marker prevents re-fire).
    secondmate_context_sweep
    touch "$STATE/.last-check"
  fi

  # Host-resource sweep, on its own cadence (see RESOURCE_INTERVAL). Time-based
  # via .last-resource mtime so the cadence survives watcher restarts. Like the
  # check block above it runs before the signal scan, so a chatty crewmate cannot
  # starve it; unlike that block it is off entirely when the monitor is disabled.
  if [ "$RESOURCE_INTERVAL" -gt 0 ] \
    && [ "$(age_of "$STATE/.last-resource")" -ge "$RESOURCE_INTERVAL" ]; then
    touch "$STATE/.last-resource"
    resource_sweep
  fi

  # Hourly session passes, each on its own stamp cadence. Placed with the other
  # slow sweeps, before the signal scan, so a chatty crewmate cannot starve them.
  hourly_pass_sweep

  # On the first changed signal, linger one grace period and re-scan before
  # classifying: a crewmate's final status write and the same turn's turn-end
  # hook land seconds apart, and reporting them as separate actionable wakes
  # costs a full firstmate turn each. The re-scan also picks up a newer
  # signature for an already-pending file (last write wins below).
  pending=$(scan_signals)
  if [ -n "$pending" ]; then
    beacon_sleep "$SIGNAL_GRACE"
    pending=$(printf '%s\n%s' "$pending" "$(scan_signals)")
    files=""
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      case " $files " in *" $f "*) ;; *) files="$files $f" ;; esac
    done <<EOF
$pending
EOF
    reason="signal:$files"
    # Triage: a signal is ACTIONABLE when any of these holds (cheapest first):
    #   - a live away-mode daemon owns triage and wants every wake;
    #   - any status file carries a captain-relevant verb;
    #   - or it is a no-verb wake (a bare turn-end, a working: note) whose crew is
    #     NOT provably working - the crew stopped its turn with no actively-running
    #     pipeline and no busy pane, so it may be done (even via an interactive menu
    #     that wrote no done: status), waiting on a decision, or wedged. Absorbing
    #     such a turn-end is exactly the swallowed-finish this change guards against.
    # Actionable -> enqueue, advance .seen-* markers, exit. Benign (a no-verb wake
    # whose crew IS provably working) in always-on mode -> advance the markers so it
    # will not re-fire, log, and keep blocking without enqueuing. The provably-working
    # check is the only costly one (it may run a bounded no-mistakes call), so the ||
    # ordering evaluates it ONLY for a daemon-free, no-captain-verb signal.
    # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
    if afk_daemon_owns_triage || signal_reason_is_actionable $files || ! signal_crew_provably_working $files; then
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        fm_wake_append signal "$(basename "$f")" "$reason" || exit 1
      done <<EOF
$pending
EOF
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
        mark_surfaced "$f"
      done <<EOF
$pending
EOF
      wake "$reason"
    else
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
      done <<EOF
$pending
EOF
      triage_log "absorbed benign $reason"
      # Suppressors are advanced above, so this benign signal will not re-fire; a
      # tick (when enabled) surfaces it once as proof of life instead of exiting.
      absorb_tick "signal absorbed"
    fi
  fi

  # Layer 1 backbone: pane staleness. Two consecutive identical hashes with no busy
  # signature means the crewmate finished, is waiting, or is wedged. Each distinct
  # stale hash is surfaced, absorbed, or timed toward escalation once (.stale-*
  # remembers the hash already classified).
  while IFS= read -r w; do
    kind=$(window_kind "$w")
    task=$(window_to_task "$w" "$STATE")
    key=${w//:/_}
    key=${key//\//_}
    key=${key//./_}
    last=$(last_status_line "$STATE/$task.status")
    if ! status_is_paused_or_captain_held "$last" && [ -e "$STATE/.paused-$key" ]; then
      clear_pause_tracking "$w"
    fi
    if [ "$kind" = secondmate ] && ! status_is_paused "$last"; then
      continue
    fi
    tail40=$(fm_backend_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" 2>/dev/null) || continue
    h=$(printf '%s' "$tail40" | hash_pane)
    key=$(printf '%s' "$w" | tr ':/.' '___')
    hf="$STATE/.hash-$key"
    cf="$STATE/.count-$key"
    sf="$STATE/.stale-$key"
    ssf="$STATE/.stale-since-$key"
    ewf="$STATE/.wedge-escalations-$key"
    pf="$STATE/.paused-$key"   # flag: this key's stale is using the bounded pause cadence
    prev=$(cat "$hf" 2>/dev/null || true)
    if [ "$h" = "$prev" ]; then
      n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$cf"
      # Busy match: a backend's native semantic state when available (herdr),
      # else the last 6 non-blank lines only (the TUI footer area, where every
      # verified harness renders its busy indicator) so busy-looking strings
      # in displayed content cannot suppress stale detection.
      if [ "$n" -ge 2 ] && ! window_is_busy "$w" "$tail40"; then
        # The pane is idle/stale at hash $h. Triage decides whether this wakes
        # firstmate. Detection itself is unchanged from above.
        if [ "$kind" = secondmate ]; then
          case "$(pause_state_class "$w" "$task")" in
            paused) handle_paused_stale "$w" "$task" "$h" ;;
            *)      clear_pause_tracking "$w" ;;
          esac
        elif afk_daemon_owns_triage; then
          # Daemon owns triage: one-shot per distinct stale hash, as before.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            fm_wake_append stale "$w" "stale: $w" || exit 1
            printf '%s' "$h" > "$sf"
            wake "stale: $w"
          fi
        elif stale_is_terminal "$w" "$STATE"; then
          # The log's last line is captain-relevant - but that alone is not
          # proof the crew is actually done: a crew's own status log gets no
          # new entry once firstmate hands it to a no-mistakes validation
          # (AGENTS.md's sparse status-reporting contract), so the log can
          # keep showing a "done:"/needs-decision/blocked leftover from
          # BEFORE that validation started for the run's entire (possibly
          # many-minutes) duration, while stale_is_terminal - which has no
          # run-step awareness - keeps reporting it as still-current on every
          # poll. Root cause of the 2026-07 herdr false-surface incidents: a
          # validating crew was surfaced as stale every few minutes despite an
          # actively-running pipeline, purely because of this stale leftover
          # line. On a NEW hash, give an active run/busy pane (the same
          # authoritative source fm-crew-state.sh itself already prioritizes
          # over the log) a chance to override before trusting the log.
          vf="$STATE/.stale-verdict-$key"
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            # The pane changed, but a captain-relevant log line does not move once
            # firstmate hands a crew off, so the harness footer's live "Churned
            # for Xm Ys" / "Total:" counters advance the hash on every redraw and
            # would re-surface an already-handled terminal crew each poll. Decide
            # on the RECONCILED crew state, not the pixels: if fm-crew-state's
            # verdict is unchanged from the one already surfaced, this is pure
            # redraw churn - advance the hash and stay silent (keeping any running
            # wedge timer honest). Re-surface only when the verdict itself changes.
            verdict=$(crew_state_verdict "$(window_to_task "$w" "$STATE")")
            if [ -n "$verdict" ] && [ "$verdict" = "$(cat "$vf" 2>/dev/null || true)" ]; then
              printf '%s' "$h" > "$sf"
              [ -e "$ssf" ] && wedge_timer_check "$w" "$ssf" "stale (overridden terminal status)" "$ewf"
              triage_log "absorbed stale (terminal verdict unchanged - ${verdict}): $w"
            elif crew_is_provably_working "$(window_to_task "$w" "$STATE")"; then
              printf '%s' "$h" > "$sf"
              date +%s > "$ssf"
              [ -n "$verdict" ] && printf '%s' "$verdict" > "$vf"
              triage_log "absorbed stale (provably working, overriding a stale captain-relevant status): $w"
            else
              fm_wake_append stale "$w" "stale: $w" || exit 1
              printf '%s' "$h" > "$sf"
              rm -f "$ssf"
              [ -n "$verdict" ] && printf '%s' "$verdict" > "$vf"
              mark_surfaced "$STATE/$(window_to_task "$w" "$STATE").status"
              wake "stale: $w"
            fi
          elif [ -e "$ssf" ]; then
            # This exact hash was already overridden as provably-working (a
            # wedge timer is running for it) - keep treating it that way
            # without re-reading the crew state every poll, and without
            # letting the still-captain-relevant log line re-surface it.
            wedge_timer_check "$w" "$ssf" "stale (overridden terminal status)" "$ewf"
          fi
          # else: already surfaced as genuinely terminal on a prior poll of
          # this same hash - nothing left to do (matches the original,
          # unmodified terminal-status behavior).
        else
          # Non-terminal stale: a crew gone quiet without a captain-relevant status.
          # Decided once per distinct stale hash (the costly state reads run only
          # on first sight, never every poll) via pause_state_class, which returns:
          #   - working: an actively-running pipeline legitimately sits on a static
          #     pane (e.g. waiting on CI), so absorb and start the wedge timer so a
          #     genuinely frozen run still escalates past STALE_ESCALATE_SECS;
          #   - paused: the crew declared an external wait, or a declared pause or
          #     captain hold is paired with a confidently dead agent, so absorb on
          #     the long PAUSE_RESURFACE_SECS cadence instead of wedge-escalating;
          #   - none: no running pipeline, idle pane, no busy signature, no declared
          #     pause - the crew has STOPPED. Surface immediately so firstmate peeks
          #     (it may be done via an interactive menu that wrote no done: status,
          #     waiting on a decision, or wedged) instead of leaving the finish to
          #     wait out the timer.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            task=$(window_to_task "$w" "$STATE")
            case "$(pause_state_class "$w" "$task")" in
              working)
                clear_pause_tracking "$w"
                printf '%s' "$h" > "$sf"
                date +%s > "$ssf"
                triage_log "absorbed non-terminal stale (provably working): $w"
                ;;
              paused)
                handle_paused_stale "$w" "$task" "$h"
                ;;
              *)
                surface_nonterminal_stale "$w" "$h"
                ;;
            esac
          else
            task=$(window_to_task "$w" "$STATE")
            if [ -e "$pf" ] || status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")"; then
              case "$(pause_state_class "$w" "$task")" in
                paused)  handle_paused_stale "$w" "$task" "$h" ;;
                working) clear_pause_state "$w"
                         printf '%s' "$h" > "$sf"
                         wedge_timer_check "$w" "$ssf" "non-terminal stale (provably working after a declared pause)" "$ewf"
                         triage_log "absorbed non-terminal stale (provably working): $w" ;;
                *)       handle_paused_stale "$w" "$task" "$h" ;;
              esac
            else
              wedge_timer_check "$w" "$ssf" "non-terminal stale" "$ewf"
            fi
          fi
        fi
      else
        # Pane busy or not yet stably stale: reset pending escalation bookkeeping.
        rm -f "$ssf" "$ewf"
        if [ -e "$pf" ] && { [ "$n" -ge 2 ] || ! status_is_paused_or_captain_held "$(last_status_line "$STATE/$(window_to_task "$w" "$STATE").status")"; }; then
          clear_pause_tracking "$w"
        fi
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
      rm -f "$ssf" "$ewf"
      task=$(window_to_task "$w" "$STATE")
      if ! afk_daemon_owns_triage && status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")" && ! window_is_busy "$w" "$tail40"; then
        case "$(pause_state_class "$w" "$task")" in
          paused) handle_paused_stale "$w" "$task" "$h" ;;
          *)      clear_pause_tracking "$w" ;;
        esac
      else
        [ -e "$pf" ] && clear_pause_tracking "$w"
      fi
    fi
  done < <(recorded_windows)

  # Heartbeat: the watcher runs a cheap fleet-scan at a regular cadence no matter
  # what. Time-based via .last-heartbeat mtime; interval doubles per consecutive
  # no-change heartbeat (idle fleet) up to HEARTBEAT_MAX, and resets on any
  # surfaced non-heartbeat wake.
  streak=$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  if [ "$(age_of "$STATE/.last-heartbeat")" -ge "$hb" ]; then
    # Triage: in always-on mode a heartbeat is benign unless the cheap fleet-scan
    # turns up a captain-relevant status the per-wake path missed. Absorb the
    # no-change case (advance the schedule and back off exactly as wake() would,
    # without exiting); the away-mode daemon, when present, owns triage and wants
    # every heartbeat.
    # Every heartbeat carries the host's latest known pressure, so a fleet review
    # is never done against a machine whose state firstmate cannot see. The value
    # is the one resource_sweep already cached, so annotating costs no probe; a
    # healthy or disabled host annotates nothing. An unknown reading, on a host
    # whose probes stopped answering, deliberately leaves the last known level in
    # place: going quiet on a machine that was just critical would hide real
    # pressure, and the age gate below bounds how long that can persist.
    # .resource-status is only ever written, never cleared, so a disabled monitor
    # and a reading older than two sweeps are both ignored rather than annotating
    # the heartbeat with pressure that may have gone away long ago.
    # The annotated form keeps the
    # "heartbeat:" prefix, because fm-watch-arm.sh and fm-supervise-daemon.sh both
    # recognise an actionable heartbeat by that exact prefix; any other shape
    # would silently stop being a wake precisely while the host is under pressure.
    hb_reason=heartbeat
    if [ "$RESOURCE_INTERVAL" -gt 0 ] \
      && [ "$(age_of "$STATE/.resource-status")" -lt $(( RESOURCE_INTERVAL * 2 )) ]; then
      case "$(cat "$STATE/.resource-status" 2>/dev/null || true)" in
        degraded) hb_reason='heartbeat: host resources degraded' ;;
        critical) hb_reason='heartbeat: host resources critical' ;;
      esac
    fi
    if afk_daemon_owns_triage; then
      fm_wake_append heartbeat heartbeat "$hb_reason" || exit 1
      touch "$STATE/.last-heartbeat"
      wake "$hb_reason"
    elif heartbeat_scan_finds_actionable; then
      # Backstop: a captain-relevant status the per-wake path absorbed by mistake.
      # Enqueue first, then mark every captain-relevant status surfaced so the next
      # heartbeat does not re-fire them (enqueue-before-suppress preserved).
      fm_wake_append heartbeat heartbeat "$hb_reason" || exit 1
      touch "$STATE/.last-heartbeat"
      mark_all_captain_relevant_surfaced
      wake "$hb_reason"
    else
      touch "$STATE/.last-heartbeat"
      echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak"
      triage_log "absorbed heartbeat (no captain-relevant change)"
      # Schedule and backoff are advanced above, so the next heartbeat is bounded and
      # further out; a tick (when enabled) makes this quiet-fleet proof of life
      # visible once per heartbeat cadence instead of only in the debug log. Only
      # while work is under way: with nothing in flight nothing forces a re-arm, so
      # an idle home keeps absorbing silently and its watcher self-sustains.
      fm_supervision_status "$STATE"
      if [ "$FM_SUP_IN_FLIGHT" -gt 0 ]; then
        absorb_tick "heartbeat absorbed"
      fi
    fi
  fi

  # Terminal wait: a bounded native-event wait for push-capable homes (herdr),
  # else the blind poll sleep. See event_wait_or_sleep.
  event_wait_or_sleep
done
