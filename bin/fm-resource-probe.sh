#!/usr/bin/env bash
# fm-resource-probe.sh - the watcher's host/crew-liveness probe CYCLE, run OFF
# the supervision main loop.
#
# WHY THIS EXISTS. bin/fm-watch.sh used to run the slow --sweep reading of
# bin/fm-resource-check.sh inline on its poll loop. That reading probes every
# recorded crew's backend for liveness and is bounded by seconds, not
# milliseconds (FM_RESOURCE_SWEEP_BUDGET, default 30s), so it was lumpier than
# the loop's real job of noticing and dispatching wakes promptly. A slow probe
# on the main loop delays every wake behind it. This script moves the probe into
# its own short-lived process, launched by the watcher on the resource cadence
# and never waited on, so the main loop only ever READS the published reading and
# never performs the probe itself.
#
# THIS IS NOT A SECOND SUPERVISION CYCLE. It handles no wakes, enqueues nothing
# on the durable wake queue, and never touches the watcher singleton lock
# (state/.watch.lock). It takes its OWN advisory lock (state/.resource-probe.lock)
# only so two of these - a rapid watcher re-arm launching a fresh probe while a
# prior one still runs - cannot double-probe the same host; the second exits at
# once. Exactly one supervision cycle (the watcher) still owns all wakes.
#
# FRESHNESS CONTRACT. The reading is a CACHE the main loop trusts only while it
# is fresh, and the age is carried IN the record, not inferred from a file mtime:
# state/.resource-reading holds one line "<epoch>\t<status>\t<reading>" where
# <epoch> is this probe's completion time. A consumer computes age = now - epoch
# and treats a reading at least two sweep intervals old (2 * FM_RESOURCE_INTERVAL)
# as stale - never surfaced, never annotated - which is the same bound the
# heartbeat annotation and the state/.resource-live count already use. The bare
# state/.resource-status word is written FIRST and the timestamped record LAST,
# so a consumer that sees a fresh .resource-reading always finds .resource-status
# already in place. Both are written atomically through a temp file in the same
# directory, because the main loop reads them with no coordination.
#
# WHAT IT PUBLISHES (only for a real reading - a healthy/degraded/critical run):
#   state/.resource-status    bare status word, for the heartbeat annotation and
#                             external readers (bin/fm-desk-refresh.sh)
#   state/.resource-reading   "<epoch>\t<status>\t<reading>", the timestamped
#                             record the surface decision reads
#   state/.last-resource      cadence stamp, touched on completion so the next
#                             probe is measured from when this one finished
# An unknown (no kernel-wide reading) or disabled reading publishes NOTHING and
# leaves every cache file untouched, the same never-write-on-an-unreadable-probe
# rule the inline sweep followed; the disabled case is already gated off before
# launch by the watcher, so reaching it here is only belt-and-suspenders.
#
# Usage:
#   fm-resource-probe.sh        run one probe cycle and publish its reading
#   fm-resource-probe.sh --help
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  awk '!started { if ($0 ~ /^# fm-resource-probe\.sh /) started = 1; else next }
       /^#/ { sub(/^# ?/, ""); print; next }
       { exit }' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') : ;;
  *) echo "error: unknown argument '$1'" >&2; exit 64 ;;
esac

# The probe lock keeps two overlapping probes from double-reading one host. It is
# a DIFFERENT lock from the watcher singleton, so it can never contend with or
# evict the one supervision cycle. A crashed probe leaves a lock naming a dead
# pid, which fm_lock_try_acquire reclaims on the next attempt.
# shellcheck source=bin/fm-mutex-lib.sh
. "$SCRIPT_DIR/fm-mutex-lib.sh"

PROBE_LOCK="$STATE/.resource-probe.lock"
mkdir -p "$STATE" 2>/dev/null || true
fm_lock_try_acquire "$PROBE_LOCK" || exit 0
trap 'fm_lock_release "$PROBE_LOCK"' EXIT

# Atomic publish through a temp file in $STATE, so a main loop reading the cache
# with no coordination never observes a half-written record.
write_atomic() {  # <path> <content>
  local dest=$1 content=$2 tmp
  tmp=$(mktemp "$dest.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n' "$content" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$dest" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; return 1; }
  else
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

out=$("$SCRIPT_DIR/fm-resource-check.sh" --sweep 2>/dev/null) && rc=0 || rc=$?
case "$rc" in
  0) status=healthy ;;
  1) status=degraded ;;
  2) status=critical ;;
  *) exit 0 ;;   # unknown/disabled/usage: publish nothing, leave the cache as is
esac

# .resource-status first (bare word), then the timestamped record last, so a
# consumer that sees a fresh .resource-reading always finds .resource-status in
# place. The reading is flattened onto one line the way a wake record holds it.
reading=$(printf '%s\n' "$out" | awk '{sub(/^resources: /, ""); printf "%s%s", sep, $0; sep="; "}')
write_atomic "$STATE/.resource-status" "$status" || exit 0
write_atomic "$STATE/.resource-reading" "$(printf '%s\t%s\t%s' "$(date +%s)" "$status" "$reading")" || exit 0
touch "$STATE/.last-resource" 2>/dev/null || true
