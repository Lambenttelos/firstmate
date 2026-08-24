#!/usr/bin/env bash
# Print the exact resume command for a stuck/dead crewmate task, so recovery can
# resume the harness session in place instead of restarting from scratch.
# Usage: fm-resume-cmd.sh <task-id>
#
# Reads the task's recorded harness and resume token from state/<id>.meta and maps
# them to the verified by-id resume command (bin/fm-resume-lib.sh, which mirrors
# the harness-adapters adapter table). On success prints ONE line - the command to
# run in the task's own worktree pane - and exits 0. FAIL-CLOSED with a clear
# diagnostic and non-zero exit when there is no meta, no captured resume token
# (only jcode captures one today; see fm-resume-lib.sh), or the recorded harness
# has no verified by-id resume command: recovery must then fall back to a fresh
# spawn rather than guess a command. The resume TOKEN itself is captured at spawn
# by bin/fm-spawn.sh (resume= in meta) and mirrored into the task record by
# tasks-axi --resume; this script never writes anything.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-resume-lib.sh
. "$SCRIPT_DIR/fm-resume-lib.sh"

if [ "$#" -ne 1 ] || ! fm_task_id_creation_valid "$1"; then
  echo "error: usage: fm-resume-cmd.sh <task-id>" >&2
  exit 2
fi
ID=$1
META="$STATE/$ID.meta"
if [ ! -f "$META" ]; then
  echo "error: no metadata for '$ID' at $META; cannot resume - relaunch with a fresh spawn instead" >&2
  exit 1
fi

HARNESS=$(fm_meta_get "$META" harness)
TOKEN=$(fm_meta_get "$META" resume)
if [ -z "$TOKEN" ]; then
  echo "error: task '$ID' has no captured resume token (harness=${HARNESS:-unknown}); resume is unavailable, relaunch with a fresh spawn instead" >&2
  exit 1
fi
if ! CMD=$(fm_resume_command "$HARNESS" "$TOKEN"); then
  echo "error: harness '${HARNESS:-unknown}' has no verified by-id resume command for task '$ID'; relaunch with a fresh spawn instead" >&2
  exit 1
fi
printf '%s\n' "$CMD"
