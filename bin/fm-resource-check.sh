#!/usr/bin/env bash
# The single-quoted strings passed to awk below are awk programs, so their
# $1/$2/$3 are awk field references the shell must NOT expand.
# shellcheck disable=SC2016
# fm-resource-check.sh - one kernel-wide reading of host CPU, memory and swap
# pressure, plus the concurrent-crew ceiling that reading supports.
#
# Firstmate consults this before dispatch (bin/fm-spawn.sh), on its own slow
# sweep cadence inside the watcher (bin/fm-watch.sh), and at session start
# (bin/fm-session-start.sh). It is READ-ONLY and advisory: it never spawns,
# steers, pauses or kills anything, because shedding load is the captain's
# decision and never an automatic one.
#
# Readings are KERNEL-WIDE (sysctl/vm_stat on macOS, /proc on Linux), never
# process enumeration: firstmate's own `ps` view is sandboxed to a few dozen
# processes, so summing per-process usage would silently under-report the host.
# For the same reason this script reports totals and never attributes load to a
# particular crew.
#
# Usage:
#   fm-resource-check.sh              print one reading line, exit with its status
#   fm-resource-check.sh --sweep      same, but probe crew liveness and refresh the
#                                     cache. The watcher's slow sweep is the ONLY
#                                     caller that may use it; see CEILING below.
#   fm-resource-check.sh --interval   print the resolved sweep interval in seconds
#   fm-resource-check.sh --help
#
# Exit status:
#   0  healthy
#   1  degraded - shed load soon
#   2  critical - shed load now
#   3  unknown  - no kernel-wide reading is available on this host. Callers must
#                 treat this as "no signal" and never alarm on it, the same
#                 never-wake-on-an-unreadable-probe rule the secondmate context
#                 monitor uses.
#   4  disabled - host-resource monitoring is switched off for this home.
#   64 usage error. Deliberately NOT the repo's usual 2 for a bad argument: 2 is
#      already "critical" here, so a mistyped flag would otherwise be read by a
#      caller as a host in trouble.
#
# THRESHOLDS - this header owns them; docs/configuration.md owns the knobs:
#   load per core     >= 4.0 critical, >= 2.0 degraded
#   swap used         >= 80% critical, >= 50% degraded
#   available memory  <  1024 MB critical
# The worst of the three decides the status.
#
# CEILING - the smaller of what memory and CPU support:
#   by memory: one live crew per 1024 MB of available memory, floor 1. Memory is
#              the binding constraint on a laptop-class host, and available
#              memory deliberately excludes anything that only exists because the
#              kernel is already swapping.
#   by CPU:    the current live-crew count adjusted by load per core (+3 under
#              1.0, +1 under 2.0, -1 under 4.0, halved at or above 4.0), floor 1.
# Live crews are the RUNNING ones, and ONLY the watcher's slow sweep pays for
# that answer. Under --sweep every state/*.meta is probed with bin/fm-backend.sh's
# fm_backend_agent_alive, only a CONFIDENT `dead` verdict is excluded - so a meta
# whose agent has exited but which has not been torn down yet stops inflating the
# count and the shed advice - and the resulting count is cached in
# state/.resource-live. An ambiguous or unreadable probe counts that one crew as
# live rather than discarding the whole reading; each probe is bounded by
# FM_RESOURCE_PROBE_TIMEOUT seconds (default 5, malformed values falling back to
# it) and is terminated as a process group, so a wedged backend leaks no stuck
# process behind it.
# Probing for the sweep AS A WHOLE is bounded by FM_RESOURCE_SWEEP_BUDGET seconds
# (default 30, malformed values falling back to it), because per-probe bounding
# alone still lets a wedged backend hold the watcher's poll loop for one timeout
# per recorded crew. Once the budget is spent the sweep stops probing and every
# remaining crew degrades to unknown, which counts it as live under the same
# only-a-confident-dead-verdict-excludes rule; the reading then says "liveness
# partly unverified" so a partly probed count is never shown as a fully verified
# one. The budget therefore bounds the sweep no matter how many crews are
# recorded or how wedged the backend is.
#
# Every OTHER caller (bin/fm-spawn.sh before a dispatch, bin/fm-session-start.sh
# inside its fast digest) READS that cache and never probes, so a wedged backend
# can never delay a dispatch or a session start. The cached verdict is therefore
# at most one sweep interval old (FM_RESOURCE_INTERVAL, default 900s); a cache
# that is missing, unreadable or older than two sweep intervals degrades
# immediately to the cheap count of recorded state/*.meta files, and the reading
# then says "liveness unverified" rather than passing recorded work off as a
# verified count. The same honest label is used when bin/fm-backend.sh cannot be
# sourced during a sweep. An IDLE agent is cheap; concurrent test and browser
# runs are what exhaust a host, so the SHED line names those first.
#
# Every reading can be injected for tests via FM_RESOURCE_CORES,
# FM_RESOURCE_RAM_GB, FM_RESOURCE_LOAD1, FM_RESOURCE_AVAIL_MB,
# FM_RESOURCE_SWAP_USED_MB, FM_RESOURCE_SWAP_TOTAL_MB, FM_RESOURCE_LIVE, and
# FM_RESOURCE_PROC_ROOT (alternate /proc root). Injection is a test seam, not an
# operating knob: an injected reading is used verbatim and never probed for.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROC_ROOT="${FM_RESOURCE_PROC_ROOT:-/proc}"

# Sweep cadence, deliberately SEPARATE from the watcher poll cadence (FM_POLL)
# and from the slow-check cadence (FM_CHECK_INTERVAL): host pressure changes on a
# scale of minutes, so re-reading it every poll would be pure waste, and tying it
# to the check sweep would couple it to a cadence X mode drives down to seconds.
# 0 switches host-resource monitoring off for this home; a malformed value falls
# back to the default rather than silently disabling the monitor.
RESOURCE_INTERVAL_DEFAULT=900
resolve_interval() {
  local raw=${FM_RESOURCE_INTERVAL:-$RESOURCE_INTERVAL_DEFAULT}
  case "$raw" in
    ''|*[!0-9]*) printf '%s\n' "$RESOURCE_INTERVAL_DEFAULT" ;;
    *) printf '%s\n' "$raw" ;;
  esac
}

# The header comment IS the help text, from the description line down to the last
# comment before the first executable line. Deriving that range beats hardcoding
# it, which silently truncates --help the moment the header grows a line.
usage() {
  awk '!started { if ($0 ~ /^# fm-resource-check\.sh /) started = 1; else next }
       /^#/ { sub(/^# ?/, ""); print; next }
       { exit }' "$0"
}

SWEEP=0
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --interval) resolve_interval; exit 0 ;;
  --sweep) SWEEP=1 ;;
  '') : ;;
  *) echo "error: unknown argument '$1'" >&2; exit 64 ;;
esac

[ "$(resolve_interval)" != 0 ] || {
  printf 'resources: monitoring disabled (FM_RESOURCE_INTERVAL=0)\n'
  exit 4
}

# --- kernel-wide probes ------------------------------------------------------
#
# Each metric resolves in one order: injected override, then sysctl/vm_stat, then
# /proc. A metric no probe can supply stays empty and makes the whole reading
# unknown, so a partial reading never masquerades as a healthy host.

sysctl_n() {
  command -v sysctl >/dev/null 2>&1 || return 1
  sysctl -n "$1" 2>/dev/null
}

proc_field() {  # <file> <awk program>
  local file="$PROC_ROOT/$1"
  [ -r "$file" ] || return 1
  awk "$2" "$file" 2>/dev/null
}

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
is_num()  { [ -n "$1" ] && [ "$(awk -v v="$1" 'BEGIN{print (v ~ /^[0-9]+(\.[0-9]+)?$/) ? 1 : 0}')" = 1 ]; }

read_cores() {
  local v
  v=${FM_RESOURCE_CORES:-}
  [ -n "$v" ] || v=$(sysctl_n hw.ncpu)
  [ -n "$v" ] || v=$(proc_field cpuinfo '/^processor[[:space:]]*:/{n++} END{if (n>0) print n}')
  printf '%s' "$v"
}

read_ram_gb() {
  local v bytes
  v=${FM_RESOURCE_RAM_GB:-}
  if [ -z "$v" ]; then
    bytes=$(sysctl_n hw.memsize)
    is_uint "$bytes" && v=$(( bytes / 1073741824 ))
  fi
  [ -n "$v" ] || v=$(proc_field meminfo '/^MemTotal:/{printf "%d", $2 / 1048576}')
  printf '%s' "$v"
}

read_load1() {
  local v
  v=${FM_RESOURCE_LOAD1:-}
  # macOS vm.loadavg reads "{ 1.23 4.56 7.89 }", so the 1-minute figure is $2.
  [ -n "$v" ] || v=$(sysctl_n vm.loadavg | awk '{print $2}')
  [ -n "$v" ] || v=$(proc_field loadavg '{print $1}')
  printf '%s' "$v"
}

read_avail_mb() {
  local v page
  v=${FM_RESOURCE_AVAIL_MB:-}
  if [ -z "$v" ] && command -v vm_stat >/dev/null 2>&1; then
    # Free + inactive + speculative is what the kernel can hand out without
    # swapping; "Pages free" alone reads alarmingly low on a healthy macOS host.
    # The page size comes from vm_stat's own header, because it describes the
    # numbers vm_stat just printed (16384 on Apple silicon, 4096 elsewhere).
    page=$(sysctl_n hw.pagesize)
    is_uint "$page" || page=
    v=$(vm_stat 2>/dev/null | awk -v page="$page" '
      /page size of/ { if (match($0, /[0-9]+ bytes/)) page = substr($0, RSTART, RLENGTH - 6) }
      /Pages free/{f=$3} /Pages inactive/{i=$3} /Pages speculative/{s=$3}
      END{
        if (page == "" || f == "") exit
        gsub(/\./,"",f); gsub(/\./,"",i); gsub(/\./,"",s)
        printf "%.0f", (f+i+s) * page / 1048576
      }')
  fi
  [ -n "$v" ] || v=$(proc_field meminfo '/^MemAvailable:/{printf "%d", $2 / 1024}')
  printf '%s' "$v"
}

# macOS vm.swapusage reads "total = 6144.00M  used = 5000.00M  free = 1144.00M".
read_swap_used_mb() {
  local v
  v=${FM_RESOURCE_SWAP_USED_MB:-}
  [ -n "$v" ] || v=$(sysctl_n vm.swapusage | awk '{print $6}' | tr -d 'M')
  [ -n "$v" ] || v=$(proc_field meminfo '
    /^SwapTotal:/{t=$2} /^SwapFree:/{f=$2}
    END{if (t != "") printf "%d", (t - f) / 1024}')
  printf '%s' "$v"
}

read_swap_total_mb() {
  local v
  v=${FM_RESOURCE_SWAP_TOTAL_MB:-}
  [ -n "$v" ] || v=$(sysctl_n vm.swapusage | awk '{print $3}' | tr -d 'M')
  [ -n "$v" ] || v=$(proc_field meminfo '/^SwapTotal:/{printf "%d", $2 / 1024}')
  printf '%s' "$v"
}

# probe_verdict: fm_backend_agent_alive for one endpoint, bounded and tolerant.
# The probe runs in its own PROCESS GROUP (job control, restored immediately) so
# a timeout terminates the wedged backend command too, not just the shell waiting
# on it. Anything that is not a confident alive/dead answer degrades to unknown
# for that one crew rather than spoiling the whole reading. A malformed timeout
# knob falls back to the default instead of aborting the reading.
# bin/fm-watch.sh's run_check_capture is the hardened implementation of this same
# bounded process-group execution; consolidating the two into a shared helper is
# intended follow-on work, kept out of this path's change for now.
PROBE_TIMEOUT_DEFAULT=5
PROBE_TIMEOUT=${FM_RESOURCE_PROBE_TIMEOUT:-$PROBE_TIMEOUT_DEFAULT}
case "$PROBE_TIMEOUT" in ''|0|*[!0-9]*) PROBE_TIMEOUT=$PROBE_TIMEOUT_DEFAULT ;; esac
probe_verdict() {  # <backend> <target>
  local out pid pgid waited=0 limit step inc verdict
  out=$(mktemp "${TMPDIR:-/tmp}/fm-resource-probe.XXXXXX" 2>/dev/null) || {
    printf 'unknown'
    return 0
  }
  set -m
  ( fm_backend_agent_alive "$1" "$2" 2>/dev/null || printf 'unknown' ) > "$out" 2>/dev/null &
  pid=$!
  set +m
  # Only signal the group once the child is confirmed to lead its own, the way
  # run_check_capture verifies it; otherwise a group kill would reach the watcher.
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  limit=$(( PROBE_TIMEOUT * 100 ))
  # Centisecond slices, fine-grained at first so a backend that answers instantly
  # is not held for a fixed floor, coarser once the probe is clearly slow.
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      if [ -n "$pgid" ] && [ "$pgid" = "$pid" ]; then
        kill -TERM -"$pgid" 2>/dev/null || true
      else
        kill -TERM "$pid" 2>/dev/null || true
      fi
      break
    fi
    if [ "$waited" -lt 20 ]; then step=0.01; inc=1; else step=0.1; inc=10; fi
    sleep "$step"
    waited=$((waited + inc))
  done
  wait "$pid" 2>/dev/null || true
  verdict=$(cat "$out" 2>/dev/null || true)
  rm -f "$out" 2>/dev/null || true
  case "$verdict" in alive|dead) printf '%s' "$verdict" ;; *) printf 'unknown' ;; esac
}

# The live-crew readers run inside a command substitution, so they cannot set a
# variable for the caller: each prints "<note><TAB><count>" and the caller splits
# it. The note comes first because a command substitution strips trailing
# whitespace; it is empty for a verified count and names the degradation
# otherwise, so a recorded-work count is never displayed as a verified one.
UNVERIFIED_NOTE=' (recorded work, liveness unverified)'
PARTIAL_NOTE=' (liveness partly unverified, probe budget spent)'

count_metas() {  # <note>
  local meta n=0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && n=$((n + 1))
  done
  printf '%s\t%s' "$1" "$n"
}

mtime_of() {  # epoch seconds of <file>, empty when unreadable
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# Total probing budget for one sweep, so the watcher's poll loop is bounded by
# this many seconds however many crews are recorded and however wedged the
# backend is. Validated like the sweep interval: a malformed value falls back to
# the default rather than disabling the budget or taking the monitor dark.
SWEEP_BUDGET_DEFAULT=30
SWEEP_BUDGET=${FM_RESOURCE_SWEEP_BUDGET:-$SWEEP_BUDGET_DEFAULT}
case "$SWEEP_BUDGET" in ''|0|*[!0-9]*) SWEEP_BUDGET=$SWEEP_BUDGET_DEFAULT ;; esac

# sweep_live_crews: the probing path, watcher-only. Caches the verified count so
# every synchronous caller can read it without touching a backend. Crews left
# unprobed when the total budget runs out degrade to unknown, which counts them
# as live, and the note says the count is only partly verified.
sweep_live_crews() {
  local meta backend target n=0 deadline partial='' note=''
  # shellcheck source=bin/fm-backend.sh
  . "$FM_ROOT/bin/fm-backend.sh" 2>/dev/null || {
    count_metas "$UNVERIFIED_NOTE"
    return 0
  }
  deadline=$(( $(date +%s) + SWEEP_BUDGET ))
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    if [ -z "$partial" ] && [ "$(date +%s)" -ge "$deadline" ]; then
      partial=1
    fi
    if [ -z "$partial" ]; then
      backend=$(fm_backend_of_meta "$meta")
      target=$(fm_backend_target_of_meta "$meta")
      if [ -n "$target" ] && [ "$(probe_verdict "$backend" "$target")" = dead ]; then
        continue
      fi
    fi
    n=$((n + 1))
  done
  [ -z "$partial" ] || note=$PARTIAL_NOTE
  [ -d "$STATE" ] && printf '%s\n' "$n" > "$LIVE_CACHE" 2>/dev/null
  printf '%s\t%s' "$note" "$n"
}

# cached_live_crews: the synchronous path. Reads the sweep's verdict and NEVER
# probes, so a wedged backend cannot delay a dispatch or a session start.
cached_live_crews() {
  local cached age m now
  cached=$(cat "$LIVE_CACHE" 2>/dev/null || true)
  m=$(mtime_of "$LIVE_CACHE")
  now=$(date +%s)
  age=999999
  case "$m" in ''|*[!0-9]*) : ;; *) age=$(( now - m )) ;; esac
  if is_uint "$cached" && [ "$age" -lt $(( $(resolve_interval) * 2 )) ]; then
    printf '\t%s' "$cached"
    return 0
  fi
  count_metas "$UNVERIFIED_NOTE"
}

LIVE_CACHE="$STATE/.resource-live"
read_live_crews() {
  local v
  v=${FM_RESOURCE_LIVE:-}
  if [ -n "$v" ]; then
    printf '\t%s' "$v"
    return 0
  fi
  if [ "$SWEEP" = 1 ]; then
    sweep_live_crews
  else
    cached_live_crews
  fi
}

CORES=$(read_cores)
RAM_GB=$(read_ram_gb)
LOAD1=$(read_load1)
AVAIL_MB=$(read_avail_mb)
SWAP_USED=$(read_swap_used_mb)
SWAP_TOTAL=$(read_swap_total_mb)
LIVE_READING=$(read_live_crews)
LIVE=${LIVE_READING##*$'\t'}
LIVE_NOTE=${LIVE_READING%$'\t'*}

if ! is_uint "$CORES" || [ "$CORES" -lt 1 ] \
  || ! is_num "$LOAD1" || ! is_num "$AVAIL_MB" \
  || ! is_num "$SWAP_USED" || ! is_num "$SWAP_TOTAL" || ! is_uint "$LIVE"; then
  printf 'resources: unknown - no kernel-wide load/memory/swap reading is available on this host\n'
  exit 3
fi
is_uint "$RAM_GB" || RAM_GB=0

# --- classification ----------------------------------------------------------

AVAIL_MB=$(awk -v v="$AVAIL_MB" 'BEGIN{printf "%.0f", v}')
SWAP_USED=$(awk -v v="$SWAP_USED" 'BEGIN{printf "%.0f", v}')
SWAP_TOTAL=$(awk -v v="$SWAP_TOTAL" 'BEGIN{printf "%.0f", v}')
# Classify on the EXACT ratio and display the rounded one. Rounding first would
# push 1.99x per core over the degraded threshold as a display artifact.
LOAD_PER_CORE_EXACT=$(awk -v l="$LOAD1" -v c="$CORES" 'BEGIN{print l/c}')
LOAD_PER_CORE=$(awk -v v="$LOAD_PER_CORE_EXACT" 'BEGIN{printf "%.1f", v}')
SWAP_PCT_EXACT=$(awk -v u="$SWAP_USED" -v t="$SWAP_TOTAL" 'BEGIN{if (t > 0) print u*100/t; else print 0}')
SWAP_PCT=$(awk -v v="$SWAP_PCT_EXACT" 'BEGIN{printf "%.0f", v}')

STATUS=healthy
RC=0
case "$(awk -v l="$LOAD_PER_CORE_EXACT" 'BEGIN{print (l >= 4) ? "crit" : ((l >= 2) ? "deg" : "ok")}')" in
  crit) STATUS=critical; RC=2 ;;
  deg)  STATUS=degraded; RC=1 ;;
esac
SWAP_CLASS=$(awk -v p="$SWAP_PCT_EXACT" 'BEGIN{print (p >= 80) ? "crit" : ((p >= 50) ? "deg" : "ok")}')
if [ "$SWAP_CLASS" = crit ] || [ "$AVAIL_MB" -lt 1024 ]; then
  STATUS=critical; RC=2
elif [ "$SWAP_CLASS" = deg ] && [ "$RC" -lt 1 ]; then
  STATUS=degraded; RC=1
fi

BY_MEM=$(awk -v a="$AVAIL_MB" 'BEGIN{c=int(a/1024); print (c < 1 ? 1 : c)}')
BY_CPU=$(awk -v l="$LOAD_PER_CORE_EXACT" -v n="$LIVE" 'BEGIN{
  if (l < 1.0) print n+3;
  else if (l < 2.0) print n+1;
  else if (l < 4.0) print (n-1 < 1 ? 1 : n-1);
  else { h = int(n/2); print (h < 1 ? 1 : h) }}')
if [ "$BY_MEM" -lt "$BY_CPU" ]; then CEILING=$BY_MEM; else CEILING=$BY_CPU; fi
[ "$CEILING" -ge 1 ] || CEILING=1

printf 'resources: %s | load %s (%sx over %s cores) | avail %s MB of %s GB | swap %s%% of %sM | live crews %s%s | recommended ceiling %s\n' \
  "$STATUS" "$LOAD1" "$LOAD_PER_CORE" "$CORES" "$AVAIL_MB" "$RAM_GB" "$SWAP_PCT" "$SWAP_TOTAL" "$LIVE" "$LIVE_NOTE" "$CEILING"

if [ "$RC" -ne 0 ] && [ "$LIVE" -gt "$CEILING" ]; then
  printf 'resources: SHED %s crew(s) - stop the heaviest test and browser runs first, they cost far more than an idle agent\n' \
    "$(( LIVE - CEILING ))"
fi

exit "$RC"
