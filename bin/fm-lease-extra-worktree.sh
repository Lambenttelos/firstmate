#!/usr/bin/env bash
# fm-lease-extra-worktree.sh - lease a SECOND treehouse worktree for a task and
# record it durably in the task's meta, so teardown can return it to its pool.
#
# WHY THIS EXISTS
# Some lanes need a second isolated checkout beyond the one worktree fm-spawn
# records as the task's PRIMARY worktree. The canonical case is full-stack product
# work: a hyfin-server lane that also needs a paired hyfin backend checkout to
# stand up a live local stack. Each such checkout is a treehouse worktree leased
# from that clone's pool, and every leased worktree occupies a pool slot until it
# is returned. fm-teardown.sh returns only the primary worktree, so a
# separately-leased second worktree was never recorded anywhere teardown could see
# and its lease was never returned. Those orphaned leases accumulate until the pool
# hits max_trees and new spawns can no longer get a worktree.
#
# The fix is durable recording at lease time: this helper leases the worktree AND
# appends an `extra_worktree=<clone-abs>\t<worktree-abs>` line to the task's meta
# in the same step, so the lease can never exist without a record teardown reads.
# fm-teardown.sh returns every recorded extra worktree alongside the primary,
# through the same guarded `treehouse return` path, with the same unlanded-work
# refusal, and never a raw rm and never --force.
#
# WHAT IT DOES
# Runs `treehouse get --lease --lease-holder <task-id>` from inside <clone-dir>, so
# the slot is leased from that clone's own (home-pinned) pool and persists with no
# live process. It records the returned worktree path against the task, then prints
# only that path to stdout (treehouse banners go to stderr), so a caller can
# `cd "$(fm-lease-extra-worktree.sh <id> <clone>)"`.
#
# The recorded line is one meta line per extra worktree:
#   extra_worktree=<clone-abs-path>\t<worktree-abs-path>
# fm_meta_get returns only the LAST value of a key, so teardown reads every
# extra_worktree line directly rather than through that helper. The clone path is
# recorded too because teardown returns the worktree by running `treehouse return`
# from that clone, matching how the primary worktree is returned from its project.
#
# Usage: fm-lease-extra-worktree.sh <task-id> <clone-dir>
# Exits non-zero with an explanation on stderr when the lease cannot be recorded
# safely (unknown task, missing clone, treehouse failure). It never records a line
# it could not lease, and never leases without recording.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

ID=${1:-}
CLONE=${2:-}
if [ -z "$ID" ] || [ -z "$CLONE" ] || ! fm_task_id_path_safe "$ID"; then
  echo "usage: fm-lease-extra-worktree.sh <task-id> <clone-dir>" >&2
  exit 2
fi

META="$STATE/$ID.meta"
if [ ! -f "$META" ]; then
  echo "error: no meta for task $ID at $META; lease it after the task is spawned" >&2
  exit 1
fi

clone_abs=$(cd "$CLONE" 2>/dev/null && pwd -P) || {
  echo "error: clone dir $CLONE does not exist or is not a directory" >&2
  exit 1
}
if ! git -C "$clone_abs" rev-parse --git-dir >/dev/null 2>&1; then
  echo "error: clone dir $clone_abs is not a git repository" >&2
  exit 1
fi

command -v treehouse >/dev/null 2>&1 || {
  echo "error: treehouse command not found; cannot lease an extra worktree" >&2
  exit 1
}

# treehouse prints only the worktree path to stdout (banners go to stderr), so
# command substitution captures the path.
wt=$(cd "$clone_abs" && treehouse get --lease --lease-holder "$ID") || {
  echo "error: treehouse get --lease failed to lease an extra worktree from $clone_abs" >&2
  exit 1
}
[ -n "$wt" ] || {
  echo "error: treehouse get --lease did not report a worktree path" >&2
  exit 1
}
wt_abs=$(cd "$wt" 2>/dev/null && pwd -P) || {
  echo "error: leased worktree path $wt is not an inspectable directory" >&2
  exit 1
}

# Record the lease durably before returning to the caller, so a leased slot can
# never exist without a meta line teardown reads. A tab separates the fields; a
# path cannot contain a tab in any layout firstmate supports.
printf 'extra_worktree=%s\t%s\n' "$clone_abs" "$wt_abs" >> "$META"

printf '%s\n' "$wt_abs"
