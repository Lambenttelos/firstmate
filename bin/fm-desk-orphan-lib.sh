# shellcheck shell=bash
# Read-only detector for orphaned fm-desk processes leaked by validation runs.
# Usage: . bin/fm-desk-orphan-lib.sh
#
# THE LEAK this exists to surface (verified 2026-08-28): a no-mistakes validation
# run of the desk crate spawns the interactive TUI; when the run finishes and its
# worktree is DELETED, the interactive fm-desk can survive, reparent to init, and
# spin at 100% CPU. Those orphans ignore SIGTERM (the desk installs SA_RESTART
# signal handlers), so nothing but SIGKILL by exact PID stops them, and nothing
# surfaced them for five days. The desk crate's own hangup guard now closes the
# leak at its source; this detector is the cheap belt that flags any orphan that
# still slips through (an old build, a future regression), so it never hides for
# days again.
#
# SAFE IDENTIFICATION (critical - never a process-name match): an orphan is
# identified ONLY by its resolved /proc/<pid>/exe link, which for a leaked desk
# reads ".../.no-mistakes/worktrees/<id>/<run>/desk/target/release/fm-desk
# (deleted)" - a fm-desk binary whose validation worktree was deleted out from
# under it. A healthy captain-launched desk resolves to the REAL repo path and is
# never flagged. Deleted-exe alone is deliberately NOT the test: an in-place
# `cargo build` rebuild also unlinks a LIVE desk's binary (its exe reads
# "(deleted)" too), but that live desk still resolves under the real repo, not a
# .no-mistakes validation worktree - so requiring the validation-worktree path is
# what keeps a busy captain's rebuilt-but-healthy desk out of the report.
#
# SCOPE and SAFETY: this is READ-ONLY and ADVISORY - it reports, it never kills.
# readlink on /proc/<pid>/exe only succeeds for the caller's own processes, so
# the scan naturally stays within this user and cannot even read, let alone
# touch, another user's desk. It is not a broad process sweep: it rejects every
# pid whose exe is not a deleted fm-desk under a .no-mistakes validation worktree.

# fm_desk_orphan_pids: print the PID of each orphaned fm-desk, one per line.
# Silent (no output, return 0) when there are none. A single find process
# enumerates candidate exe links: forking readlink per pid costs seconds on a
# fleet-sized process table and this runs on every bootstrap, so the scan must
# stay one process. The -lname pattern is only a cheap prefilter;
# fm_desk_orphan_is_leaked confirms every candidate, so the classifier remains
# the one owner of the orphan signature. Best-effort: a pid that exits
# mid-scan, or whose exe cannot be read (a foreign owner), is simply skipped
# (find's permission noise is discarded). Honors FM_DESK_ORPHAN_PROC_ROOT like
# the classifier, so a test exercises this same scan against a fake /proc.
fm_desk_orphan_pids() {
  local proc_root=${FM_DESK_ORPHAN_PROC_ROOT:-/proc} exe_link pid
  # /proc is Linux-only; on any platform without it there is nothing to scan and
  # nothing to report (the leak itself is a Linux /proc-reparenting behavior).
  [ -d "$proc_root" ] || return 0
  find "$proc_root" -maxdepth 2 -name exe \
    -lname '*/.no-mistakes/worktrees/*fm-desk (deleted)' 2>/dev/null |
    while IFS= read -r exe_link; do
      pid=${exe_link#"$proc_root"/}
      pid=${pid%/exe}
      fm_desk_orphan_is_leaked "$pid" || continue
      printf '%s\n' "$pid"
    done
}

# fm_desk_orphan_is_leaked <pid>: true when this pid's resolved exe is a fm-desk
# binary whose validation worktree was deleted (the exact leak signature above).
# The FM_DESK_ORPHAN_PROC_ROOT override lets a test point the scan at a fake
# /proc so the classifier logic is exercised without a live orphan; unset in
# normal use it reads the real /proc.
fm_desk_orphan_is_leaked() {
  local pid=$1 proc_root=${FM_DESK_ORPHAN_PROC_ROOT:-/proc} target
  # readlink resolves the exe symlink to its target; a deleted target keeps the
  # literal " (deleted)" suffix the kernel appends, which is the signal we read.
  target=$(readlink "$proc_root/$pid/exe" 2>/dev/null) || return 1
  case "$target" in
    */fm-desk\ \(deleted\)) ;;
    *) return 1 ;;
  esac
  # Require the validation-worktree path so an in-place rebuild of a live captain
  # desk (real repo path, also "(deleted)") is never mistaken for an orphan.
  case "$target" in
    */.no-mistakes/worktrees/*) return 0 ;;
    *) return 1 ;;
  esac
}

# fm_desk_orphan_diagnostic: emit one advisory DESK_ORPHAN line when orphans
# exist, silent otherwise. The line names the exact PIDs and the SIGKILL remedy,
# because these orphans ignore SIGTERM; it never kills anything itself.
fm_desk_orphan_diagnostic() {
  local pids count
  pids=$(fm_desk_orphan_pids)
  [ -n "$pids" ] || return 0
  count=$(printf '%s\n' "$pids" | grep -c .)
  # Collapse the pid list onto one line for the single-line diagnostic contract.
  local pid_list
  pid_list=$(printf '%s' "$pids" | tr '\n' ' ')
  pid_list=${pid_list% }
  echo "DESK_ORPHAN: $count orphaned fm-desk process(es) from a deleted validation worktree are spinning at 100% CPU (pids: $pid_list); they ignore SIGTERM - after confirming each /proc/<pid>/exe ends in '(deleted)', stop it with kill -9 <pid>"
}
