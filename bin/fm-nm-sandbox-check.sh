#!/usr/bin/env bash
# fm-nm-sandbox-check.sh - startup alarm for a root no-mistakes daemon that lost
# IS_SANDBOX=1.
#
# WHY THIS EXISTS. The no-mistakes daemon's review step invokes
# `claude --dangerously-skip-permissions`, which claude refuses under root
# without IS_SANDBOX=1. bin/fm-nm-daemon.sh injects IS_SANDBOX=1 into the daemon
# environment when it launches the daemon as root, so a start/restart through the
# wrapper is durable. But a daemon started any other way (a bare
# `no-mistakes daemon start`, an older restart) drops the flag, which
# instant-fails EVERY claude review lane fleet-wide until a manual restart. This
# regressed twice (2026-07-31, 2026-08-01). This detector reads the LIVE daemon
# pid's environment and SHOUTS one actionable line when a root daemon is running
# without the flag, so the next session sees it loudly instead of discovering it
# only after every review lane has failed.
#
# ROOT GATED. The refusal only happens under root (uid 0), the exact gate
# bin/fm-nm-daemon.sh and bin/fm-spawn.sh use. A non-root host is never probed and
# never alarmed: its daemon needs no sandbox hint.
#
# CONFIDENT-ONLY. It alarms ONLY on a confident reading - running as root, a live
# daemon pid resolved, its environment readable, and IS_SANDBOX absent from it. It
# stays silent on every uncertainty (not root, no no-mistakes binary, no running
# daemon, an unreadable environment such as a non-Linux host with no /proc), so a
# blind spot is never reported as a fault.
#
# It never mutates anything and never fails the session: it is detect-only,
# exactly like the rest of the bootstrap detect section, and exits 0. It never
# restarts the shared daemon - that kills other lanes' in-flight runs and is a
# firstmate decision, not this detector's.
#
# Override the daemon binary for testing with FM_NM_BIN (defaults to
# `no-mistakes`) and the proc root with FM_PROC_DIR (defaults to `/proc`).
set -u

NM=${FM_NM_BIN:-no-mistakes}
PROC_DIR=${FM_PROC_DIR:-/proc}

# Resolve the live daemon pid from `no-mistakes daemon status`, or print nothing.
# The status line reads "● daemon running (pid <N>)"; a stopped daemon prints no
# such pid, so an empty result means "no daemon to check".
fm_nm_daemon_pid() {
  "$NM" daemon status 2>/dev/null \
    | sed -nE 's/.*\(pid[[:space:]]+([0-9]+)\).*/\1/p' \
    | head -n 1
}

# True when the process's environment contains an IS_SANDBOX assignment.
fm_nm_environ_has_sandbox() {  # <environ-file>
  tr '\0' '\n' < "$1" 2>/dev/null | grep -q '^IS_SANDBOX='
}

# Print the alarm line when a root daemon lacks IS_SANDBOX, and nothing on every
# uncertainty or when the flag is present.
fm_nm_sandbox_report() {
  [ "$(id -u)" = 0 ] || return 0                 # non-root: never probed
  command -v "$NM" >/dev/null 2>&1 || return 0   # no binary: cannot check
  local pid environ
  pid=$(fm_nm_daemon_pid)
  [ -n "$pid" ] || return 0                       # no running daemon: nothing to check
  environ="$PROC_DIR/$pid/environ"
  [ -r "$environ" ] || return 0                   # unreadable environ: cannot check
  fm_nm_environ_has_sandbox "$environ" && return 0 # flag present: silent
  printf 'NM_SANDBOX: no-mistakes daemon (pid %s) is running under root without IS_SANDBOX=1; every claude review lane will instant-fail until the daemon is relaunched through bin/fm-nm-daemon.sh restart (which reinjects the flag) - a restart kills in-flight runs, so treat it as a firstmate decision\n' \
    "$pid"
}

# Running as a script (not sourced) prints the report and exits 0. Sourcing for
# unit tests loads the functions and returns before doing anything.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_nm_sandbox_report
  exit 0
fi
