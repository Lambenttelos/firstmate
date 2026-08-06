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
#                                     cache. The watcher's background probe cycle
#                                     (bin/fm-resource-probe.sh, launched off the
#                                     supervision main loop) is the ONLY caller
#                                     that may use it; see CEILING below.
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
#   swap used         >= 80% critical, >= 50% degraded  (NON-Darwin only)
#   available memory  <  1024 MB critical
# The worst of the three decides the status.
#
# On Darwin the swap-used percentage is INFORMATIONAL ONLY and never classifies
# the host. macOS uses fully dynamic swap: the swap file grows on demand, so a
# high used/total ratio just means the current file is small relative to what is
# paged, not that the host is starved. Keying pressure on that ratio produced
# false degraded/critical readings with gigabytes of RAM still free. On Darwin,
# memory pressure is keyed on AVAIL_MB alone (the <1024 MB critical floor below),
# which is the genuine binding constraint there. The percentage stays in the
# printed reading so the figure is still visible, it just drives no status. The
# swap percentage remains a real signal on non-Darwin hosts with fixed-size swap,
# so the >=80/>=50 thresholds are kept for them. The OS is resolved once from
# uname -s, overridable for tests with FM_RESOURCE_OS.
#
# CEILING - the smaller of what memory and CPU support. Both components, and the
# over-ceiling comparison that triggers the SHED line, are computed on the ACTIVE
# running agents (ordinary crews plus persistent secondmates that have work in
# flight), so the two sides of that comparison always share one basis; only the
# shed COUNT is capped at the number of ordinary crews:
#   by memory: one active agent per 560 MB of available memory, floor 1. Memory
#              is the binding constraint on a laptop-class host, and available
#              memory deliberately excludes anything that only exists because the
#              kernel is already swapping.
#   by CPU:    the current ACTIVE-agent count adjusted by load per core (+3 under
#              1.0, +1 under 2.0, -1 under 4.0, halved at or above 4.0), floor 1.
#
# The 560 MB figure is measured, not assumed. data/measure-ccstatusline-cost's
# report (2026-07-24, five idle agents added to a 16 GB host, 20 samples over 60s
# per condition) puts a working agent at 394-491 MB resident and an idle one at
# ~290 MB decaying toward ~180 MB over hours. The previous 1024 MB per agent
# over-charged even a working agent, and over-charged an idle one by roughly 3.5x.
# 560 MB sits about 14% above the 491 MB top of the measured working range: still
# headroom over a working agent, but trimmed from the earlier 640 MB (~30% over
# that top) so the recommendation is less falsely conservative and hands the same
# host a modestly higher ceiling (about 14% more agents for the same memory). The
# report measured never-prompted sessions, so ~290 MB is a FLOOR for a
# working-then-idle secondmate and context size is the variable that moves it; the
# retained headroom is what covers that variation without over-charging.
# Live agents are the RUNNING ones, and ONLY the watcher's slow sweep pays for
# that answer. Under --sweep every state/*.meta is probed with bin/fm-backend.sh's
# fm_backend_endpoint_live, only a CONFIDENT `dead` verdict is excluded - so a
# meta whose endpoint is gone but which has not been torn down yet stops inflating
# the count and the shed advice - and the resulting count is cached in
# state/.resource-live. fm_backend_endpoint_live is deliberately NOT
# fm_backend_agent_alive: the count asks "is this recorded lane still a live
# endpoint", so on herdr it reads pane presence (a jcode lane's turn runs in
# jcode's shared background server and registers no herdr agent, so the
# agent-process probe would call every live herdr lane `dead`), while tmux keeps
# its agent-process check unchanged. An ambiguous or unreadable probe counts that one agent as
# live rather than discarding the whole reading; each probe is bounded by
# FM_RESOURCE_PROBE_TIMEOUT seconds (default 5, malformed values falling back to
# it) and is terminated as a process group, so a wedged backend leaks no stuck
# process behind it.
# Probing for the sweep AS A WHOLE is bounded by FM_RESOURCE_SWEEP_BUDGET seconds
# (default 30, malformed values falling back to it), because per-probe bounding
# alone still lets a wedged backend hold the watcher's poll loop for one timeout
# per recorded crew. A probe started near the deadline gets only the budget that
# is left, so total probing costs the budget plus a sub-second stop grace however
# many crews are recorded and however wedged the backend is. Once the budget is
# spent the sweep stops probing and every remaining crew degrades to unknown,
# which counts it as live under the same only-a-confident-dead-verdict-excludes
# rule; the reading then says "liveness partly unverified", and that marker is
# cached with the count so a partly probed count is never shown as a fully
# verified one on any later synchronous reading either.
#
# CREWS vs PERSISTENT SECONDMATES - a kind=secondmate meta is a running agent, so
# it is always reported, but only a WORKING one is charged. Captain's ruling of
# 2026-07-24: an idle persistent secondmate counts toward neither the ceiling nor
# the overage, because the measurement above shows it costs no processor time, no
# swap, and a memory footprint that decays with idleness. IDLE means that
# secondmate's own home has no routed work in flight - no ordinary state/*.meta
# under the home= it records - which is a file-only test that costs no probe and
# is therefore safe on the synchronous path. That test reads the child home's
# records without probing them, so a secondmate still holding a torn-down task's
# record reads as working; like an unreadable home= it errs toward charging, and
# the child home's own sweep is what clears it.
# A secondmate is never a shed candidate either (AGENTS.md sections 7 and 8: an
# idle secondmate endpoint is healthy and retirement is an explicit captain or
# main-firstmate decision), so the shed COUNT is min(active agents - ceiling,
# ordinary crews) and no shed line is printed when that is zero or less. A home
# whose only running agents are persistent secondmates therefore never produces
# shed advice.
# Nothing becomes invisible by ceasing to be charged: the reading still names the
# all-agents total and then splits it ("live agents 8 = 6 active (4 crew(s) + 2
# persistent secondmate(s)) + 2 idle secondmate(s)"), next to a ceiling labelled
# in active agents, so the number the ceiling is compared against is on the line
# and the shed count below it needs no conversion in the reader's head.
#
# ACTIVE vs BLOCKED/PARKED CREWS - an ordinary crew is a running agent, so it is
# always reported, but only an ACTIVELY-WORKING one is charged against the
# ceiling. A crew that is BLOCKED (waiting on a captain decision or another
# lane's unlanded work) or PARKED (idling on a long declared external wait) holds
# a worktree but needs no active watching and wakes only when firstmate acts, so
# like an idle secondmate it counts toward neither the ceiling nor the overage.
# This is the captain's standing 2026-08-06 rule "6+6 COUNTS ONLY
# ACTIVELY-WORKING CREWS; BLOCKED/PARKED CREWS DO NOT" (data/captain.md), the
# bounded slice this script owns of the broader active-worker admission control
# that queues at the idle->active transition.
# The blocked/parked state comes from the durable status-event classifier, NOT a
# live pane probe: a crew's own state/<id>.status log, read last-event-wins
# through bin/fm-classify-lib.sh (needs-decision:/blocked: -> blocked,
# paused: -> parked), reconciled the same way bin/fm-crew-state.sh reads it.
# Probing a pane on the synchronous path is expensive and flaky - a crew
# mid-tool-call can read momentarily idle - so this is a file-only read. It is
# recomputed FRESH on every reading rather than cached with the liveness verdict,
# because the moment a crew resumes it appends a working:/resolved: line and must
# be re-counted immediately with no cache lag; the recompute is only a status
# file read, so it stays cheap even on the cached synchronous path. A
# BRIEFLY-waiting crew (heavy-run queue, CI, a short bounded wait) reports with
# working: lines, so it is NOT parked and STILL counts - it wakes fast and
# dropping it would over-dispatch and set two live lanes fighting for one watch.
# Any crew whose state cannot be resolved to a blocked/parked verb is charged as
# active, the same conservative default the idle-secondmate test uses. A
# blocked/parked crew, like an idle secondmate, is never a shed candidate: the
# shed count is measured on the ACTIVE crews alone. The reading names the count
# in the split too ("... + 1 blocked/parked crew(s)"), so nothing is hidden.
#
# Every OTHER caller (bin/fm-spawn.sh before a dispatch, bin/fm-session-start.sh
# inside its fast digest) READS that cache and never probes, so a wedged backend
# can never delay a dispatch or a session start. A cached verdict is accepted
# while it is younger than TWO sweep intervals (FM_RESOURCE_INTERVAL, default
# 900s, so 1800s at the default), which is the real bound on an unlabelled
# count: the watcher exits on every wake and is re-armed, so a home between arms
# routinely has no sweep running while the synchronous callers keep reading the
# cache, and one interval would degrade them on every ordinary wake. A cache
# that is missing, unreadable or older than that degrades
# immediately to the cheap count of recorded state/*.meta files, and the reading
# then says "liveness unverified" rather than passing recorded work off as a
# verified count, and a cached count the sweep could only partly probe keeps its
# "liveness partly unverified" label wherever it is read. The same honest label
# is used when bin/fm-backend.sh cannot be sourced during a sweep. An IDLE agent
# is cheap; concurrent test and browser runs are what exhaust a host, so the SHED
# line names those first.
#
# Every reading can be injected for tests via FM_RESOURCE_CORES,
# FM_RESOURCE_RAM_GB, FM_RESOURCE_LOAD1, FM_RESOURCE_AVAIL_MB,
# FM_RESOURCE_SWAP_USED_MB, FM_RESOURCE_SWAP_TOTAL_MB, FM_RESOURCE_LIVE,
# FM_RESOURCE_BLOCKED, and FM_RESOURCE_PROC_ROOT (alternate /proc root).
# FM_RESOURCE_LIVE injects the ordinary-crew count, with no persistent
# secondmates; when it is set the blocked/parked split defaults to 0 unless
# FM_RESOURCE_BLOCKED overrides it, so an injected reading needs no status files.
# FM_RESOURCE_BLOCKED injects how many of the live crews are blocked or parked
# and is used verbatim, never reading a status file. FM_RESOURCE_OS overrides
# the uname -s the swap classification keys on, so the Darwin informational-only
# swap behavior is testable on any host. Injection is a test seam, not an
# operating knob: an injected reading is used verbatim and never probed for.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# The shared status-event classifier supplies the file-only blocked/parked test
# (last_status_line, status_is_paused, status_open_decisions). It is a pure
# library - sourcing it defines functions and constants only, touches no backend,
# and adds no probe to the synchronous dispatch or session-start paths.
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh" 2>/dev/null || true
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

# probe_verdict: fm_backend_endpoint_live for one endpoint, bounded and tolerant.
# The probe runs in its own PROCESS GROUP (job control, restored immediately) so
# a timeout terminates the wedged backend command too, not just the shell waiting
# on it. Anything that is not a confident alive/dead answer degrades to unknown
# for that one crew rather than spoiling the whole reading. A malformed timeout
# knob falls back to the default instead of aborting the reading.
#
# It asks fm_backend_endpoint_live, NOT fm_backend_agent_alive: the count needs
# "is this recorded lane still a live endpoint", and on herdr a working
# jcode-hosted lane registers no herdr agent (its turn runs in jcode's shared
# background server), so agent_alive reads every live herdr lane as `dead` and
# zeroes the count. fm_backend_endpoint_live keeps tmux's agent-process check
# unchanged while reading herdr liveness from pane presence, the same signal
# session-start and the wake-brief endpoint sweep already trust. See
# bin/fm-backend.sh's fm_backend_endpoint_live header.
# bin/fm-watch.sh's run_check_capture is the hardened implementation of this same
# bounded process-group execution; consolidating the two into a shared helper is
# intended follow-on work, kept out of this path's change for now.
PROBE_TIMEOUT_DEFAULT=5
PROBE_TIMEOUT=${FM_RESOURCE_PROBE_TIMEOUT:-$PROBE_TIMEOUT_DEFAULT}
case "$PROBE_TIMEOUT" in ''|0|*[!0-9]*) PROBE_TIMEOUT=$PROBE_TIMEOUT_DEFAULT ;; esac
probe_signal() {  # <signal> <pid> <pgid>
  if [ -n "$3" ] && [ "$3" = "$2" ]; then
    kill -"$1" -"$3" 2>/dev/null || true
  else
    kill -"$1" "$2" 2>/dev/null || true
  fi
}
probe_verdict() {  # <backend> <target> <seconds>
  local out pid pgid waited=0 limit step inc verdict grace=0
  out=$(mktemp "${TMPDIR:-/tmp}/fm-resource-probe.XXXXXX" 2>/dev/null) || {
    printf 'unknown'
    return 0
  }
  # The watcher exits on every wake, so a sweep is routinely signalled mid-probe;
  # without these the temp file would survive. The signal traps still exit, so
  # trapping does not make this path outlive a TERM it used to die on. The path
  # is held in a non-local so the handlers read it when they fire.
  PROBE_TMP=$out
  trap 'rm -f "$PROBE_TMP" 2>/dev/null' EXIT
  trap 'rm -f "$PROBE_TMP" 2>/dev/null; exit 130' INT
  trap 'rm -f "$PROBE_TMP" 2>/dev/null; exit 143' TERM
  set -m
  ( fm_backend_endpoint_live "$1" "$2" 2>/dev/null || printf 'unknown' ) > "$out" 2>/dev/null &
  pid=$!
  set +m
  # Only signal the group once the child is confirmed to lead its own, the way
  # run_check_capture verifies it; otherwise a group kill would reach the watcher.
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  limit=$(( $3 * 100 ))
  [ "$limit" -ge 1 ] || limit=1
  # Centisecond slices, fine-grained at first so a backend that answers instantly
  # is not held for a fixed floor, coarser once the probe is clearly slow.
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      probe_signal TERM "$pid" "$pgid"
      # A short stop grace, then KILL: the wait below must never block on a
      # backend command that ignores TERM, or on a child whose own group could
      # not be confirmed above.
      while [ "$grace" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do
        sleep 0.01
        grace=$((grace + 1))
      done
      probe_signal KILL "$pid" "$pgid"
      break
    fi
    if [ "$waited" -lt 20 ]; then step=0.01; inc=1; else step=0.1; inc=10; fi
    sleep "$step"
    waited=$((waited + inc))
  done
  wait "$pid" 2>/dev/null || true
  verdict=$(cat "$out" 2>/dev/null || true)
  rm -f "$out" 2>/dev/null || true
  trap - EXIT INT TERM
  case "$verdict" in alive|dead) printf '%s' "$verdict" ;; *) printf 'unknown' ;; esac
}

# The live-agent readers run inside a command substitution, so they cannot set a
# variable for the caller: each prints
# "<note><TAB><crews><TAB><active-secondmates><TAB><idle-secondmates>" and the
# caller splits it. The note comes first because a command substitution strips
# trailing whitespace; it is empty for a verified count and names the
# degradation otherwise, so a recorded-work count is never displayed as a
# verified one.
UNVERIFIED_NOTE=' (recorded work, liveness unverified)'
PARTIAL_NOTE=' (liveness partly unverified, probe budget spent)'

is_secondmate_meta() { grep -q '^kind=secondmate$' "$1" 2>/dev/null; }

# secondmate_idle <meta-file>: true when that secondmate's own home has no routed
# work in flight. Routed work is recorded in the secondmate's home exactly as it
# is here, one state/<id>.meta per dispatched task, so the presence of an
# ordinary meta under its home= is the whole test. It reads files only and never
# touches a backend, which is what makes it safe on the synchronous dispatch and
# session-start paths. A meta with no readable home= is charged as active, so an
# unreadable record can only over-report load, never hide it.
secondmate_idle() {  # <meta-file>
  local home child
  home=$(sed -n 's/^home=//p' "$1" 2>/dev/null | head -n 1)
  [ -n "$home" ] || return 1
  for child in "$home"/state/*.meta; do
    [ -f "$child" ] || continue
    is_secondmate_meta "$child" && continue
    return 1
  done
  return 0
}

count_metas() {  # <note>
  local meta crews=0 smates=0 idle=0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    if is_secondmate_meta "$meta"; then
      if secondmate_idle "$meta"; then idle=$((idle + 1)); else smates=$((smates + 1)); fi
    else
      crews=$((crews + 1))
    fi
  done
  printf '%s\t%s\t%s\t%s' "$1" "$crews" "$smates" "$idle"
}

# crew_blocked_or_parked <meta-file>: 0 when that ordinary crew is BLOCKED (its
# last status event is needs-decision or blocked - waiting on a captain decision
# or another lane's unlanded work) or PARKED (a declared long external wait,
# paused:). Both hold a worktree but need no active watching, so they are not
# charged against the ceiling, exactly as an idle secondmate is not.
#
# It is a FILE-ONLY read of the crew's own status event log through the shared
# classifier (last_status_line, status_line_verb, status_is_paused), never a
# pane probe: probing is expensive and flaky and a crew mid-tool-call can read
# momentarily idle, so the durable status signal is preferred. A crew that
# resumes appends a working: or resolved: line (task brief rule 6), which flips
# the last-event verb away from the blocked/parked set, so a resumed crew is
# re-counted on the very next reading with no probe and no cache lag.
#
# A BRIEFLY-waiting crew (heavy-run queue, CI, a short bounded wait) reports with
# working: lines, so it is NOT parked and STILL counts - it wakes fast and
# dropping it would over-dispatch. Anything the classifier cannot resolve to a
# blocked/parked verb (an empty log, a bare working:, an unreadable line, or an
# absent classifier library) charges the crew as active, the same conservative
# default the idle-secondmate test uses.
crew_blocked_or_parked() {  # <meta-file>
  local id log last verb
  declare -F last_status_line >/dev/null 2>&1 || return 1
  id=$(basename "$1"); id=${id%.meta}
  log="$STATE/$id.status"
  [ -f "$log" ] || return 1
  last=$(last_status_line "$log")
  [ -n "$last" ] || return 1
  status_is_paused "$last" && return 0
  verb=$(status_line_verb "$last")
  case "$verb" in
    needs-decision|blocked) return 0 ;;
    *) return 1 ;;
  esac
}

# count_blocked_parked_crews: how many ordinary (non-secondmate) crews are
# currently blocked or parked, read FRESH from the status logs on every call.
# It is deliberately NOT cached with the liveness verdict: the blocked/parked
# state is what changes the instant a crew resumes, so recomputing it every
# reading is what makes the "re-count a resumed crew immediately" guarantee hold
# even on the synchronous cached path, and it is only a file read so it stays
# cheap there. The caller clamps the result to the live crew count.
count_blocked_parked_crews() {
  local meta n=0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    is_secondmate_meta "$meta" && continue
    crew_blocked_or_parked "$meta" && n=$((n + 1))
  done
  printf '%s' "$n"
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

LIVE_CACHE="$STATE/.resource-live"

# The cache is replaced atomically, through a temp file in the same directory,
# because the synchronous callers read it with no coordination and must never
# observe a half-written record.
write_live_cache() {  # <crews> <active-secondmates> <idle-secondmates> <partial>
  local tmp
  [ -d "$STATE" ] || return 0
  tmp=$(mktemp "$LIVE_CACHE.XXXXXX" 2>/dev/null) || return 0
  # Same reason as probe_verdict: a sweep signalled mid-write must not leave the
  # half-written temp file behind next to the cache it never replaced.
  CACHE_TMP=$tmp
  trap 'rm -f "$CACHE_TMP" 2>/dev/null' EXIT
  trap 'rm -f "$CACHE_TMP" 2>/dev/null; exit 130' INT
  trap 'rm -f "$CACHE_TMP" 2>/dev/null; exit 143' TERM
  if printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$LIVE_CACHE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
  trap - EXIT INT TERM
}

# sweep_live_crews: the probing path, watcher-only. Caches the count AND whether
# it was fully probed, so every synchronous caller can read it without touching a
# backend and still sees an honest label. Crews left unprobed when the total
# budget runs out degrade to unknown, which counts them as live, and the note
# says the count is only partly verified. Each probe gets only the budget that is
# left, so the last probe cannot run past the deadline.
sweep_live_crews() {
  local meta backend target crews=0 smates=0 idle=0 deadline left partial='' note='' probe
  # shellcheck source=bin/fm-backend.sh
  . "$FM_ROOT/bin/fm-backend.sh" 2>/dev/null || {
    count_metas "$UNVERIFIED_NOTE"
    return 0
  }
  deadline=$(( $(date +%s) + SWEEP_BUDGET ))
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    left=$(( deadline - $(date +%s) ))
    [ "$left" -gt 0 ] || partial=1
    if [ -z "$partial" ]; then
      if [ "$left" -lt "$PROBE_TIMEOUT" ]; then probe=$left; else probe=$PROBE_TIMEOUT; fi
      backend=$(fm_backend_of_meta "$meta")
      target=$(fm_backend_target_of_meta "$meta")
      if [ -n "$target" ] && [ "$(probe_verdict "$backend" "$target" "$probe")" = dead ]; then
        continue
      fi
    fi
    if is_secondmate_meta "$meta"; then
      if secondmate_idle "$meta"; then idle=$((idle + 1)); else smates=$((smates + 1)); fi
    else
      crews=$((crews + 1))
    fi
  done
  [ -z "$partial" ] || note=$PARTIAL_NOTE
  write_live_cache "$crews" "$smates" "$idle" "${partial:-0}"
  printf '%s\t%s\t%s\t%s' "$note" "$crews" "$smates" "$idle"
}

# clamp_cached_to_metas: lower a cached count so it can never claim more agents in
# a class than that class still has meta files. A live agent always has a meta, so
# the moment teardown removes one the cached count that still counts it is simply
# wrong; the sweep that would refresh it may be up to two intervals away. This uses
# only count_metas' cheap file test, never a backend probe, so the synchronous path
# stays cheap while a torn-down worker stops inflating the count immediately. It
# only ever LOWERS: a crew spawned after the last sweep keeps the existing
# behaviour of not being counted until the next sweep, which errs toward
# under-reporting rather than over-reporting. Reads and rewrites crews/smates/idle
# in the caller's scope; the secondmate overage is capped on the total and trimmed
# idle-first, so a still-present secondmate whose idle/active class merely flipped
# since the sweep is never dropped, only a genuinely removed secondmate meta is.
clamp_cached_to_metas() {
  local rest nums fcrews fsmates fidle scap stot drop
  # count_metas prefixes a note field; parse the tab record by expansion rather
  # than read, because tab is IFS whitespace and read would collapse the empty
  # leading note into the first number (the same reason the main body splits the
  # live reading with %%/# below).
  rest=$(count_metas '')
  nums=${rest#*$'\t'}
  fcrews=${nums%%$'\t'*}
  nums=${nums#*$'\t'}
  fsmates=${nums%%$'\t'*}
  fidle=${nums##*$'\t'}
  is_uint "${fcrews:-}" && is_uint "${fsmates:-}" && is_uint "${fidle:-}" || return 0
  [ "$crews" -le "$fcrews" ] || crews=$fcrews
  scap=$(( fsmates + fidle ))
  stot=$(( smates + idle ))
  if [ "$stot" -gt "$scap" ]; then
    drop=$(( stot - scap ))
    if [ "$idle" -ge "$drop" ]; then
      idle=$(( idle - drop ))
    else
      drop=$(( drop - idle )); idle=0; smates=$(( smates - drop ))
    fi
  fi
}

# cached_live_crews: the synchronous path. Reads the sweep's verdict and NEVER
# probes, so a wedged backend cannot delay a dispatch or a session start. The
# sweep's partly-probed marker is cached with the counts and replayed here, so a
# budget-truncated count is never presented as a fully verified one. The cached
# count is clamped to the current meta files (clamp_cached_to_metas) so a worker
# torn down since the sweep stops inflating the count on the very next reading,
# without paying for a probe.
# A record written before the idle-secondmate split carries three fields, so it
# fails the four-field shape below and degrades to the honest recorded-work count
# rather than being misread; the next sweep replaces it.
cached_live_crews() {
  local cached age m now crews smates idle partial
  cached=$(cat "$LIVE_CACHE" 2>/dev/null || true)
  m=$(mtime_of "$LIVE_CACHE")
  now=$(date +%s)
  age=999999
  case "$m" in ''|*[!0-9]*) : ;; *) age=$(( now - m )) ;; esac
  read -r crews smates idle partial <<<"$cached"
  if is_uint "${crews:-}" && is_uint "${smates:-}" && is_uint "${idle:-}" \
    && [ "$age" -lt $(( $(resolve_interval) * 2 )) ]; then
    clamp_cached_to_metas
    case "${partial:-}" in
      0) printf '\t%s\t%s\t%s' "$crews" "$smates" "$idle"; return 0 ;;
      1) printf '%s\t%s\t%s\t%s' "$PARTIAL_NOTE" "$crews" "$smates" "$idle"; return 0 ;;
    esac
  fi
  count_metas "$UNVERIFIED_NOTE"
}

read_live_crews() {
  local v
  v=${FM_RESOURCE_LIVE:-}
  if [ -n "$v" ]; then
    printf '\t%s\t%s\t%s' "$v" 0 0
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
LIVE_NOTE=${LIVE_READING%%$'\t'*}
LIVE_COUNTS=${LIVE_READING#*$'\t'}
CREWS=${LIVE_COUNTS%%$'\t'*}
LIVE_REST=${LIVE_COUNTS#*$'\t'}
SECONDMATES=${LIVE_REST%%$'\t'*}
IDLE_SECONDMATES=${LIVE_REST##*$'\t'}

# How many of the live crews are blocked or parked, read fresh every reading so a
# resumed crew is re-counted immediately (see count_blocked_parked_crews). It is
# clamped to the live CREWS count below so a lingering blocked meta whose agent
# the sweep already excluded can never be subtracted twice. FM_RESOURCE_BLOCKED
# is the matching test seam: like FM_RESOURCE_LIVE it is used verbatim and never
# reads a status file, so a test can set the split without staging status logs.
BLOCKED_PARKED=${FM_RESOURCE_BLOCKED:-}
if [ -z "$BLOCKED_PARKED" ]; then
  if [ -n "${FM_RESOURCE_LIVE:-}" ]; then
    BLOCKED_PARKED=0
  else
    BLOCKED_PARKED=$(count_blocked_parked_crews)
  fi
fi

if ! is_uint "$CORES" || [ "$CORES" -lt 1 ] \
  || ! is_num "$LOAD1" || ! is_num "$AVAIL_MB" \
  || ! is_num "$SWAP_USED" || ! is_num "$SWAP_TOTAL" \
  || ! is_uint "$CREWS" || ! is_uint "$SECONDMATES" || ! is_uint "$IDLE_SECONDMATES"; then
  printf 'resources: unknown - no kernel-wide load/memory/swap reading is available on this host\n'
  exit 3
fi
is_uint "$RAM_GB" || RAM_GB=0
# A malformed blocked/parked count errs toward charging every crew as active (0),
# the same conservative default an unknown crew state uses; and it can never
# exceed the live crew count it is subtracted from.
is_uint "$BLOCKED_PARKED" || BLOCKED_PARKED=0
[ "$BLOCKED_PARKED" -le "$CREWS" ] || BLOCKED_PARKED=$CREWS
ACTIVE_CREWS=$(( CREWS - BLOCKED_PARKED ))

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
# macOS uses fully dynamic swap, so the swap-used percentage is not a memory
# pressure signal there (see the header). On Darwin the class is forced to ok so
# the percentage stays informational-only and memory pressure is keyed on
# AVAIL_MB alone; other platforms keep the >=80/>=50 percentage thresholds.
RESOURCE_OS="${FM_RESOURCE_OS:-$(uname -s)}"
if [ "$RESOURCE_OS" = Darwin ]; then
  SWAP_CLASS=ok
else
  SWAP_CLASS=$(awk -v p="$SWAP_PCT_EXACT" 'BEGIN{print (p >= 80) ? "crit" : ((p >= 50) ? "deg" : "ok")}')
fi
if [ "$SWAP_CLASS" = crit ] || [ "$AVAIL_MB" -lt 1024 ]; then
  STATUS=critical; RC=2
elif [ "$SWAP_CLASS" = deg ] && [ "$RC" -lt 1 ]; then
  STATUS=degraded; RC=1
fi

# ACTIVE is the charged basis; LIVE is the reported total. Neither an idle
# persistent secondmate NOR a blocked/parked crew is charged: both hold a
# resource footprint that needs no active watching (an idle secondmate costs no
# processor time and a decayed memory footprint; a blocked/parked crew is waiting
# on a captain decision, another lane's unlanded work, or a long declared
# external wait, and wakes only when firstmate acts), so both stay in LIVE and
# out of ACTIVE. See the header's CREWS vs PERSISTENT SECONDMATES section and the
# ACTIVE vs BLOCKED/PARKED CREWS section.
ACTIVE=$(( ACTIVE_CREWS + SECONDMATES ))
LIVE=$(( CREWS + SECONDMATES + IDLE_SECONDMATES ))
PER_AGENT_MB=560
BY_MEM=$(awk -v a="$AVAIL_MB" -v p="$PER_AGENT_MB" 'BEGIN{c=int(a/p); print (c < 1 ? 1 : c)}')
BY_CPU=$(awk -v l="$LOAD_PER_CORE_EXACT" -v n="$ACTIVE" 'BEGIN{
  if (l < 1.0) print n+3;
  else if (l < 2.0) print n+1;
  else if (l < 4.0) print (n-1 < 1 ? 1 : n-1);
  else { h = int(n/2); print (h < 1 ? 1 : h) }}')
if [ "$BY_MEM" -lt "$BY_CPU" ]; then CEILING=$BY_MEM; else CEILING=$BY_CPU; fi
[ "$CEILING" -ge 1 ] || CEILING=1

# The all-agents total is named first so nothing disappears from the reading just
# because it stopped being charged, then the active figure the ceiling and the
# overage are actually measured on, then its crew and secondmate breakdown,
# because only actively-working crews are ever shed candidates (see the header).
# Blocked/parked crews and idle secondmates follow the active figure so the split
# always sums back to the total.
SECONDMATE_NOTE=
[ "$SECONDMATES" -eq 0 ] || SECONDMATE_NOTE=" + $SECONDMATES persistent secondmate(s)"
BLOCKED_NOTE=
[ "$BLOCKED_PARKED" -eq 0 ] || BLOCKED_NOTE=" + $BLOCKED_PARKED blocked/parked crew(s)"
IDLE_NOTE=
[ "$IDLE_SECONDMATES" -eq 0 ] || IDLE_NOTE=" + $IDLE_SECONDMATES idle secondmate(s)"

printf 'resources: %s | load %s (%sx over %s cores) | avail %s MB of %s GB | swap %s%% of %sM | live agents %s = %s active (%s crew(s)%s)%s%s%s | recommended ceiling %s active agents\n' \
  "$STATUS" "$LOAD1" "$LOAD_PER_CORE" "$CORES" "$AVAIL_MB" "$RAM_GB" "$SWAP_PCT" "$SWAP_TOTAL" \
  "$LIVE" "$ACTIVE" "$ACTIVE_CREWS" "$SECONDMATE_NOTE" "$BLOCKED_NOTE" "$IDLE_NOTE" "$LIVE_NOTE" "$CEILING"

if [ "$RC" -ne 0 ] && [ "$ACTIVE" -gt "$CEILING" ]; then
  SHED=$(( ACTIVE - CEILING ))
  # Only actively-working crews are shed candidates: a blocked/parked crew is
  # already not being charged, so it is neither part of the overage nor something
  # to shed for load.
  [ "$SHED" -le "$ACTIVE_CREWS" ] || SHED=$ACTIVE_CREWS
  [ "$SHED" -lt 1 ] || printf 'resources: SHED %s crew(s) - stop the heaviest test and browser runs first, they cost far more than an idle agent\n' \
    "$SHED"
fi

exit "$RC"
