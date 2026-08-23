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
# HOST-GLOBAL CONCURRENCY. The probe lock is host-global by default, NOT scoped
# to one firstmate home's state dir. A fleet runs several operational homes and a
# treehouse spreads one home across several worktrees, each with its own watcher
# on the same cadence; a per-worktree lock caps overlap only within one worktree,
# so N worktrees launched N heavy sweeps at once and, when a sweep wedged under
# memory pressure, that multiplication is what took the whole host down (see
# data/20260823T031739Z-home-oom-fm-resource-probe-runaway). The default lock at
# ${TMPDIR:-/tmp}/fm-resource-probe-<uid>.lock (one per operating user, the same
# host-global pattern bin/fm-heavy-run.sh uses) serializes probes across every
# worktree and home on the host to exactly one at a time. A home that loses the
# race this cycle simply DEFERS - it exits 0 and publishes nothing, keeping its
# previous cached reading, and wins the lock on a later poll well within the
# two-interval freshness window every consumer already tolerates. Serializing is
# the point: while one probe is in flight (or wedged) no home launches a second
# heavy sweep into a host that may already be thrashing. FM_RESOURCE_PROBE_LOCK
# overrides the path (a test seam, and the way to scope a lock to something other
# than the whole host).
#
# BOUNDED FOOTPRINT. Two independent caps keep a single probe from ballooning:
#   - Address-space ceiling. A hard `ulimit -v` (FM_RESOURCE_PROBE_MEM_MB, default
#     1024) is set on this shell before it forks anything, so the probe AND every
#     child (fm-resource-check.sh, and the backend CLIs it spawns per crew) each
#     fail their allocations rather than growing without bound. A healthy probe
#     costs single-digit MB (the sweep) and a backend query tens of MB (herdr's
#     measured VmPeak is ~20MB), so 1 GiB is a wide margin that still kills a
#     genuine runaway long before it can OOM a swapless host. 0 disables it.
#   - Captured-output cap. The sweep's stdout is truncated to
#     FM_RESOURCE_PROBE_MAX_BYTES (default 1 MiB) before it is read into a shell
#     variable, so a backend that dumps a huge stream can never inflate this
#     process through the command capture itself. 0 disables it.
# Neither cap changes a normal reading; both exist only so a wedged backend
# degrades to a missing reading instead of a host lockup.
#
# LOW PRIORITY. The probe renices itself and drops to the idle I/O class
# (best-effort, no privilege required) before doing any work, so even a probe
# that is slow under load yields CPU and disk to interactive work - an ssh login
# on a thrashing host must not queue behind a liveness probe. Both are
# inherited by the sweep and its backend children.
#
# Usage:
#   fm-resource-probe.sh        run one probe cycle and publish its reading
#   fm-resource-probe.sh --lock-path   print the resolved host-global lock path
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

# resolve_lock_path: the host-global probe lock, one owner of the path so the
# watcher (which queries it via --lock-path) and the probe can never disagree.
# FM_RESOURCE_PROBE_LOCK overrides it for tests and for scoping a lock to
# something narrower than the whole host.
resolve_lock_path() {
  if [ -n "${FM_RESOURCE_PROBE_LOCK:-}" ]; then
    printf '%s' "$FM_RESOURCE_PROBE_LOCK"
  else
    printf '%s/fm-resource-probe-%s.lock' "${TMPDIR:-/tmp}" "$(id -u 2>/dev/null || printf '%s' 0)"
  fi
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --lock-path) resolve_lock_path; printf '\n'; exit 0 ;;
  '') : ;;
  *) echo "error: unknown argument '$1'" >&2; exit 64 ;;
esac

# Drop to low priority FIRST, before any work, so a slow probe under load never
# queues ahead of interactive work. Best-effort: a missing tool or a refusal is
# ignored, and both settings are inherited by the sweep and its backend children.
renice 19 -p "$$" >/dev/null 2>&1 || true
if command -v ionice >/dev/null 2>&1; then
  ionice -c 3 -p "$$" >/dev/null 2>&1 || true
fi

# Hard address-space ceiling on this shell and everything it forks, so a runaway
# probe (or a wedged backend child) fails its allocations instead of growing
# until the host OOMs. Set as both soft and hard so a child cannot raise it.
# 0 or a malformed value disables the cap; any other value is megabytes.
PROBE_MEM_MB=${FM_RESOURCE_PROBE_MEM_MB:-1024}
case "$PROBE_MEM_MB" in
  ''|*[!0-9]*) PROBE_MEM_MB=1024 ;;
esac
if [ "$PROBE_MEM_MB" -gt 0 ]; then
  ulimit -v $(( PROBE_MEM_MB * 1024 )) 2>/dev/null || true
fi

# Cap the sweep output read into a shell variable, so a backend dumping a huge
# stream cannot inflate this process through the command capture. 0 or a
# malformed value disables the cap; any other value is bytes.
PROBE_MAX_BYTES=${FM_RESOURCE_PROBE_MAX_BYTES:-1048576}
case "$PROBE_MAX_BYTES" in
  ''|*[!0-9]*) PROBE_MAX_BYTES=1048576 ;;
esac

# The probe lock keeps overlapping probes from double-reading one host. It is
# HOST-GLOBAL by default (see the header), and a DIFFERENT lock from the watcher
# singleton, so it can never contend with or evict the one supervision cycle. A
# crashed probe leaves a lock naming a dead pid, which fm_lock_try_acquire
# reclaims on the next attempt.
# shellcheck source=bin/fm-mutex-lib.sh
. "$SCRIPT_DIR/fm-mutex-lib.sh"

PROBE_LOCK=$(resolve_lock_path)
mkdir -p "$STATE" 2>/dev/null || true
mkdir -p "$(dirname "$PROBE_LOCK")" 2>/dev/null || true
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

# Run the sweep, capping its captured stdout so a backend dumping a huge stream
# cannot inflate this process through the command substitution. The cap runs in
# the pipeline so the sweep's own exit status is preserved (PIPESTATUS[0]); head
# closing its input early makes a runaway sweep exit on SIGPIPE rather than fill
# memory. A normal reading is a few hundred bytes, far under the cap.
if [ "$PROBE_MAX_BYTES" -gt 0 ]; then
  out=$( { "$SCRIPT_DIR/fm-resource-check.sh" --sweep 2>/dev/null | head -c "$PROBE_MAX_BYTES"; } ; exit "${PIPESTATUS[0]}" ) && rc=0 || rc=$?
else
  out=$("$SCRIPT_DIR/fm-resource-check.sh" --sweep 2>/dev/null) && rc=0 || rc=$?
fi
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
