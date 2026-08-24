#!/usr/bin/env bash
# fm-desk-event.sh - keep the captain's already-published desk current by
# rebuilding it in place on a task-lifecycle event (spawn, done/failed/blocked,
# PR recorded, teardown), so the live page reflects the fleet without firstmate
# having to remember to refresh it.
#
# WHY THIS EXISTS. The desk (bin/fm-desk-refresh.sh, .agents/skills/desk) renders
# this home's fleet state to ONE stable file ($FM_HOME/.lavish/captain-desk.html)
# and a lavish server publishes it on the captain's bookmark. Today that file is
# rebuilt only when firstmate runs the /desk skill by hand, so between refreshes
# the published page goes stale. This hooks the same in-place rebuild onto the
# events that actually change fleet state, so an open desk stays live on reload.
#
# WHAT IT IS, AND IS NOT. It is a per-EVENT trigger, not a daemon: an event fires
# a transient worker that rebuilds once (coalescing any concurrent events) and
# exits. There is no resident process and no supervision turn.
#   - It ONLY rebuilds the HTML file in place (bin/fm-desk-refresh.sh, temp+mv).
#   - It NEVER re-serves and NEVER runs `lavish-axi stop`/data/serve-desk.sh: one
#     shared lavish server hosts EVERY session on this host, including the
#     captain's other live pages, so restarting it would drop them. Rebuilding
#     the file is all that is needed; the open tab reloads from the same server.
#   - It NEVER wakes anyone: rendering a page is not captain-facing progress
#     (AGENTS.md section 8), exactly like bin/fm-desk-refresh.sh itself. It
#     appends to no status file and calls no wake/send helper.
#   - It NEVER binds a port.
#   - It is FAIL-SAFE for its callers: every hook invokes it best-effort
#     (`... || true`), it exits 0 on every internal problem, and it writes
#     nothing to the caller's stdout/stderr (the detached worker's output goes to
#     a capped log), so it cannot corrupt a hook's own output or exit status.
#
# NO-OP WITHOUT A LIVE DESK. If this home has never built a desk (the stable HTML
# file does not exist), there is nothing to keep current, so the trigger is an
# immediate no-op with zero cost: a home that does not use the desk pays nothing
# on every spawn/teardown. The desk file's existence is the whole gate; the
# builder is the single owner of that path, queried with `--path`.
#
# COALESCING / SINGLE-FLIGHT. A rebuild takes ~2 minutes (the fleet projection is
# slow by design). During a burst of events we must not run N sequential
# 2-minute builds. A mutex (state/.desk-event.lock) admits ONE worker at a time;
# a "dirty" marker (state/.desk-event.dirty) records that a rebuild is owed. The
# worker consumes the marker BEFORE each build, so any event during the build
# re-arms it and is serviced by exactly one trailing rebuild. After releasing the
# lock the worker re-checks the marker once, to service an event that arrived in
# the release window (when it could not have seen the lock free); if the marker
# is clear, no worker is running and a later event's own launch starts a fresh
# one. Net effect: a storm of events collapses to at most one in-flight build
# plus one trailing build, and no event is ever lost.
#
# Usage:
#   fm-desk-event.sh [event-label]     record an event and (re)build if a desk is
#                                      live. event-label is free text for the log
#                                      only (e.g. spawn, done, pr, teardown).
#   fm-desk-event.sh --run [label]     INTERNAL: the detached single-flight worker.
#   fm-desk-event.sh --help
#
# Always exits 0 for the entrypoint (best-effort by contract). The worker also
# exits 0 on every path; its build outcome is recorded only in the log.
#
# Env (all optional; test seams unless noted):
#   FM_HOME / FM_ROOT_OVERRIDE   home resolution, as every fm-* script.
#   FM_STATE_OVERRIDE            state dir holding the lock, marker, and log.
#   FM_DESK_REFRESH_BIN          the builder to query (--path) and run. Defaults
#                                to the sibling bin/fm-desk-refresh.sh. One owner
#                                of the desk path and the rebuild.
#   FM_DESK_EVENT_FOREGROUND=1   run the worker inline instead of detaching, so a
#                                test can assert the rebuild happened. Default:
#                                detach with setsid (perl setsid fallback).
#   FM_DESK_EVENT_BUILD_TIMEOUT  seconds to bound one rebuild so a wedged build
#                                cannot pin the single-flight lock (default 300).
#   FM_DESK_EVENT_LOG_MAX_BYTES  cap for the worker log (default 262144).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-mutex-lib.sh
. "$SCRIPT_DIR/fm-mutex-lib.sh"

DESK_BIN="${FM_DESK_REFRESH_BIN:-$SCRIPT_DIR/fm-desk-refresh.sh}"
LOCK="$STATE/.desk-event.lock"
DIRTY="$STATE/.desk-event.dirty"
LOG="$STATE/.desk-event.log"
BUILD_TIMEOUT="${FM_DESK_EVENT_BUILD_TIMEOUT:-300}"
case "$BUILD_TIMEOUT" in ''|*[!0-9]*) BUILD_TIMEOUT=300 ;; esac
LOG_MAX_BYTES="${FM_DESK_EVENT_LOG_MAX_BYTES:-262144}"
case "$LOG_MAX_BYTES" in ''|*[!0-9]*) LOG_MAX_BYTES=262144 ;; esac

usage() {
  sed -n '2,71p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Append one line to the capped worker log. Best-effort: a logging hiccup never
# affects behavior. Never written by the entrypoint's fast path (it stays silent
# on the caller's terminal); only the worker and its launch record here.
desk_event_log() {
  local sz
  mkdir -p "$STATE" 2>/dev/null || return 0
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)" "$1" >> "$LOG" 2>/dev/null || return 0
  sz=$(wc -c < "$LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$LOG_MAX_BYTES" ]; then
    tail -n 500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG" 2>/dev/null
    rm -f "$LOG.tmp" 2>/dev/null || true
  fi
}

# The stable desk output path, from the builder (its single owner). Cheap: the
# builder parses --path before its fleet gather. Empty on any failure, which the
# liveness gate treats as "no desk".
desk_path() {
  "$DESK_BIN" --path 2>/dev/null || true
}

# 0 iff a desk has been built for this home (the stable file exists). That file's
# existence is the entire "is the desk live" gate: it is what the lavish server
# publishes, so if it is absent nothing is being served and there is nothing to
# refresh.
desk_is_live() {
  local p
  p=$(desk_path)
  [ -n "$p" ] && [ -f "$p" ]
}

# Bounded rebuild wrapper: cap the build so a wedged builder cannot hold the
# single-flight lock indefinitely. Uses timeout/gtimeout when present, else runs
# unbounded (the builder still self-bounds each source at 120s).
desk_build() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$BUILD_TIMEOUT" "$DESK_BIN"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$BUILD_TIMEOUT" "$DESK_BIN"
  else
    "$DESK_BIN"
  fi
}

# The single-flight worker loop. Admits one builder via the mutex; drains the
# dirty marker (consume-before-build so events during a build re-arm); after
# releasing, re-checks the marker once to service the release-window event.
# Always returns 0.
run_worker() {
  local rc
  # Safety net: release the lock on any abnormal exit. fm_lock_release is a
  # no-op when this process does not own the lock, so it is safe even after we
  # have already released or never acquired.
  trap 'fm_lock_release "$LOCK" 2>/dev/null || true' EXIT INT TERM

  # A desk that vanished between the entrypoint check and here: nothing to do.
  desk_is_live || return 0

  while true; do
    # Non-blocking: if another worker holds the lock it is (or will be) building,
    # and the dirty marker we were launched for will be serviced by that worker's
    # own loop or its post-release re-check. So we simply stand down.
    if ! fm_lock_try_acquire "$LOCK"; then
      desk_event_log "worker: another build holds the lock; standing down"
      return 0
    fi

    while [ -e "$DIRTY" ]; do
      # Consume BEFORE building: an event that arrives during the build re-creates
      # the marker and is picked up by the next iteration, so no refresh is lost
      # and a burst collapses to one trailing rebuild.
      rm -f "$DIRTY" 2>/dev/null || true
      if ! desk_is_live; then
        desk_event_log "worker: desk file disappeared; stopping"
        break
      fi
      desk_event_log "worker: rebuild start"
      if desk_build >/dev/null 2>&1; then
        desk_event_log "worker: rebuild ok"
      else
        rc=$?
        desk_event_log "worker: rebuild failed (exit $rc)"
      fi
    done

    fm_lock_release "$LOCK" 2>/dev/null || true

    # Post-release re-check: an event that set the marker after our last `[ -e
    # DIRTY ]` test but before this release could not have launched a new worker
    # (the lock was held) and would otherwise be lost. If the marker is set, loop
    # and re-acquire to service it. If it is clear, the lock is now free, so any
    # later event's own launch will start a fresh worker.
    [ -e "$DIRTY" ] || return 0
    desk_event_log "worker: event in release window; re-acquiring"
  done
}

# Detach the worker into its own session leader so it outlives the hook process
# that triggered it (the spawn/teardown/watcher call returns immediately) and
# holds none of the caller's stdio. Mirrors bin/fm-liveness-watchdog.sh: setsid
# where available, a perl POSIX::setsid fork fallback for hosts without setsid
# (macOS). All output goes to the capped log, never the caller's terminal.
launch_detached() {
  local label=$1
  if command -v setsid >/dev/null 2>&1; then
    setsid "$SELF" --run "$label" >> "$LOG" 2>&1 < /dev/null &
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
  ' "$SELF" --run "$label" >> "$LOG" 2>&1 < /dev/null
}

# --- entry point ------------------------------------------------------------

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --run)
    # Internal detached worker. Never prints to a caller.
    run_worker
    exit 0
    ;;
esac

EVENT_LABEL="${1:-event}"

# No live desk -> nothing to keep current -> immediate zero-cost no-op. This is
# the common case for a home that does not use the desk, and it must stay cheap
# because it runs on every spawn and teardown.
desk_is_live || exit 0

# Record that a rebuild is owed, THEN start (or defer to) a worker. Setting the
# marker before the launch decision is what makes the single-flight race-free:
# whichever worker holds the lock will observe this marker, and if none holds it
# the launch below starts one.
mkdir -p "$STATE" 2>/dev/null || exit 0
: > "$DIRTY" 2>/dev/null || exit 0

if [ "${FM_DESK_EVENT_FOREGROUND:-}" = 1 ]; then
  # Test/inline mode: run the worker synchronously so a caller can observe the
  # rebuild. Still silent on stdout; still exits 0.
  run_worker
  exit 0
fi

desk_event_log "event: $EVENT_LABEL"
launch_detached "$EVENT_LABEL" || desk_event_log "event: $EVENT_LABEL (detach unavailable; no worker started)"
exit 0
