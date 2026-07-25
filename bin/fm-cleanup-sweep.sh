#!/usr/bin/env bash
# fm-cleanup-sweep.sh - the hourly cleanup pass.
#
# WHAT ACTUALLY ACCUMULATES IN A LONG-RUNNING HOME (established by reading the
# producers, not guessed):
#   - watcher temp files from a killed poll: state/.fm-check-output.* and
#     state/.fm-custom-check.* (bin/fm-watch.sh removes these on its own happy
#     path, so any survivor is crash residue)
#   - watcher suppression markers for tasks that no longer exist: .seen-*,
#     .hash-*, .count-*, .stale-*, .paused-*, .hb-surfaced-*,
#     .wedge-escalations-*, .sm-context-surfaced-*
#   - merge-queue entries whose branch has since been merged
#     (bin/fm-merge-queue-lib.sh owns the merged test)
#   - isolated copies still registered in a project clone after their task is
#     gone, and per-task temp roots under /tmp for tasks that are gone
#
# THE SAFETY LINE, AND WHY IT IS DRAWN HERE: the first three are pure
# bookkeeping - no work of any kind lives in them - so this pass reclaims them
# SILENTLY and logs what it did. The last two can hold unlanded work, so this
# pass never removes them and never runs a teardown to find out: it REPORTS
# them as candidates with the exact command, and bin/fm-teardown.sh stays the
# single owner of the landed-work test. That keeps a background sweep
# structurally incapable of discarding work: refusing costs a line of prose,
# and being wrong costs a crewmate's unlanded branch.
#
# Nothing here writes to a project. The project-clone inspection is a read-only
# `git worktree list`; even a `git worktree prune` (which would be safe in
# isolation) is deliberately not run, because it is a write into a clone
# firstmate must only read.
#
# Usage: fm-cleanup-sweep.sh
#   Prints one short headline line when something needs a decision, and nothing
#   at all when it only reclaimed bookkeeping or found nothing. The full report
#   is written to state/.hourly-cleanup.latest, reclaim actions to
#   state/.hourly-cleanup.log. Always exits 0: a reporting command, not a gate.
#
# Thresholds (seconds; see docs/configuration.md):
#   FM_CLEANUP_TEMP_SECS      default 3600    age before temp residue is reclaimed
#   FM_CLEANUP_MARKER_SECS    default 86400   age before dead markers are reclaimed
#   FM_CLEANUP_ORPHAN_SECS    default 86400   age before an orphan copy is reported
# FM_CLEANUP_TMP_ROOT (default /tmp) redirects the per-task temp-root scan; it
# exists so tests can point the scan at a fixture instead of the real /tmp.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

# shellcheck source=bin/fm-hourly-lib.sh
. "$SCRIPT_DIR/fm-hourly-lib.sh"

TEMP_SECS=${FM_CLEANUP_TEMP_SECS:-3600}
case "$TEMP_SECS" in ''|*[!0-9]*) TEMP_SECS=3600 ;; esac
MARKER_SECS=${FM_CLEANUP_MARKER_SECS:-86400}
case "$MARKER_SECS" in ''|*[!0-9]*) MARKER_SECS=86400 ;; esac
ORPHAN_SECS=${FM_CLEANUP_ORPHAN_SECS:-86400}
case "$ORPHAN_SECS" in ''|*[!0-9]*) ORPHAN_SECS=86400 ;; esac

[ -d "$STATE" ] || exit 0

LOG_PATH="$STATE/.hourly-cleanup.log"
RECLAIMED=0
SIGNATURE=
REPORT=
FINDINGS=0
HEADLINES=

log_reclaim() {
  RECLAIMED=$(( RECLAIMED + 1 ))
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$LOG_PATH" 2>/dev/null || true
}

# add_finding <signature-key> <headline> <report-line>: identity-only signature,
# so an unattended candidate stays silent after its first report
# (bin/fm-hourly-lib.sh owns the contract).
add_finding() {
  SIGNATURE="$SIGNATURE$1
"
  FINDINGS=$(( FINDINGS + 1 ))
  [ -n "$HEADLINES" ] && HEADLINES="$HEADLINES; "
  HEADLINES="$HEADLINES$2"
  REPORT="$REPORT- $3
"
}

INFLIGHT=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  INFLIGHT=$(( INFLIGHT + 1 ))
done

# --- reclaim 1: watcher temp residue -----------------------------------------
for tmpfile in "$STATE"/.fm-check-output.* "$STATE"/.fm-custom-check.*; do
  [ -f "$tmpfile" ] || continue
  [ "$(fm_hourly_age_of "$tmpfile")" -ge "$TEMP_SECS" ] || continue
  rm -f "$tmpfile" 2>/dev/null && log_reclaim "removed stale watcher temp file $(basename "$tmpfile")"
done

# --- reclaim 2: suppression markers for a fleet that no longer exists ---------
# Only with NOTHING under way: with no task, no marker can be suppressing a live
# wake, which makes removal provably safe. With work in flight the mapping from
# a mangled marker key back to a task is not worth trusting, so nothing is
# touched - a few stale markers are harmless, a wrongly cleared one is not.
if [ "$INFLIGHT" -eq 0 ]; then
  for marker in "$STATE"/.seen-* "$STATE"/.hash-* "$STATE"/.count-* \
    "$STATE"/.stale-* "$STATE"/.paused-* "$STATE"/.hb-surfaced-* \
    "$STATE"/.wedge-escalations-* "$STATE"/.sm-context-surfaced-*; do
    [ -f "$marker" ] || continue
    [ "$(fm_hourly_age_of "$marker")" -ge "$MARKER_SECS" ] || continue
    rm -f "$marker" 2>/dev/null && log_reclaim "removed dead suppression marker $(basename "$marker")"
  done
fi

# --- reclaim 3: merge-queue entries whose branch has landed -------------------
# fm-merge-queue.sh sweep owns the merged test and only ever drops entries whose
# content is already in the base branch.
if [ -f "$DATA/merge-queue.tsv" ] && [ -s "$DATA/merge-queue.tsv" ]; then
  SWEEP_OUT=$("$SCRIPT_DIR/fm-merge-queue.sh" sweep 2>&1 || true)
  case "$SWEEP_OUT" in
    *'removed'*|*'Removed'*) log_reclaim "merge queue sweep: $(printf '%s' "$SWEEP_OUT" | tr '\n' ' ')" ;;
  esac
fi

# --- report 1: isolated copies still registered after their task is gone ------
LIVE_WORKTREES=
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  wt=$(grep '^worktree=' "$meta" 2>/dev/null | head -1 | cut -d= -f2- || true)
  [ -n "$wt" ] || continue
  LIVE_WORKTREES="$LIVE_WORKTREES|$wt|"
done

if [ -d "$PROJECTS" ]; then
  for clone in "$PROJECTS"/*; do
    [ -d "$clone/.git" ] || [ -f "$clone/.git" ] || continue
    while IFS= read -r line; do
      case "$line" in worktree\ *) ;; *) continue ;; esac
      wt=${line#worktree }
      [ "$wt" = "$clone" ] && continue
      case "$LIVE_WORKTREES" in *"|$wt|"*) continue ;; esac
      [ -d "$wt" ] || continue
      [ "$(fm_hourly_age_of "$wt")" -ge "$ORPHAN_SECS" ] || continue
      add_finding "worktree:$wt" \
        "an isolated copy in $(basename "$clone") outlived its task" \
        "$wt is still registered in $clone with no task recorded for it; NOT removed - it may hold unlanded work, so clean it up with bin/fm-teardown.sh <id> (which owns the landed-work test) or inspect it first"
    done <<EOF
$(git -C "$clone" worktree list --porcelain 2>/dev/null || true)
EOF
  done
fi

# --- report 2: per-task temp roots whose task is gone -------------------------
TASKTMP_ROOT=${FM_CLEANUP_TMP_ROOT:-/tmp}
for tasktmp in "$TASKTMP_ROOT"/fm-*; do
  [ -d "$tasktmp" ] || continue
  id=$(basename "$tasktmp")
  id=${id#fm-}
  [ -n "$id" ] || continue
  [ -f "$STATE/$id.meta" ] && continue
  [ "$(fm_hourly_age_of "$tasktmp")" -ge "$ORPHAN_SECS" ] || continue
  add_finding "tasktmp:$id" \
    "leftover build temp for $id" \
    "$tasktmp survives a task that is gone; NOT removed - bin/fm-teardown.sh owns per-task temp roots, so remove it only through a cleanup of $id"
done

# --- report --------------------------------------------------------------------
REPORT_PATH=$(fm_hourly_report_path "$STATE" cleanup)
{
  printf 'hourly cleanup sweep - %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  printf 'home: %s\n' "$FM_HOME"
  printf 'reclaimed silently: %s bookkeeping item(s) (see %s)\n' "$RECLAIMED" "$LOG_PATH"
  if [ "$FINDINGS" -eq 0 ]; then
    printf 'no candidates needing a decision.\n'
  else
    printf '%s candidate(s) left in place for a decision:\n' "$FINDINGS"
    printf '%s' "$REPORT"
  fi
} > "$REPORT_PATH" 2>/dev/null || true

fm_hourly_should_surface "$STATE" cleanup "$SIGNATURE" || exit 0
printf 'cleanup: %s (nothing was removed; full report: %s)\n' "$HEADLINES" "$REPORT_PATH"
exit 0
