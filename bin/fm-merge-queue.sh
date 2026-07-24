#!/usr/bin/env bash
# Firstmate merge-queue CLI: surface, sweep, and prune the durable list of
# pushed-but-unmerged branches whose disposable worktree was already released by
# teardown (see bin/fm-merge-queue-lib.sh for the format and rationale).
#
# The queue is the safety guard behind release-on-pushed teardown: a released
# branch that still needs merging must be impossible to forget. Firstmate surfaces
# the batched set as one list of compare links rather than a trickle of asks, and -
# when a batch has accumulated for a repo AND merge authority exists - may spawn a
# merge worker on demand for that repo (no standing merge worker; idle workers cost
# memory, the binding limit on this host). See docs/merge-queue.md.
#
# Usage:
#   fm-merge-queue.sh list [--raw]     surface entries; grouped by repo with compare
#                                      links, or --raw for the tab-separated records
#   fm-merge-queue.sh sweep            drop every entry whose branch is now merged
#                                      into its base (fresh content-in-base check)
#   fm-merge-queue.sh remove <id>      drop one entry by task id
#   fm-merge-queue.sh count            print the number of queued branches
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-merge-queue-lib.sh
. "$SCRIPT_DIR/fm-merge-queue-lib.sh"

usage() {
  sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

cmd=${1:-list}
[ "$#" -gt 0 ] && shift || true

case "$cmd" in
  list)
    raw=0
    [ "${1:-}" = --raw ] && raw=1
    entries=$(fm_merge_queue_entries "$DATA")
    if [ -z "$entries" ]; then
      [ "$raw" -eq 1 ] || echo "Merge queue: empty."
      exit 0
    fi
    if [ "$raw" -eq 1 ]; then
      printf '%s\n' "$entries"
      exit 0
    fi
    echo "Merge queue: pushed branches waiting to merge."
    printf '%s\n' "$entries" | while IFS='	' read -r id project branch head base url; do
      [ -n "$id" ] || continue
      printf -- '- %s [%s -> %s] %s\n' "$id" "$branch" "$base" "$url"
    done
    ;;
  sweep)
    entries=$(fm_merge_queue_entries "$DATA")
    [ -n "$entries" ] || { echo "Merge queue: empty."; exit 0; }
    removed=0
    while IFS='	' read -r id project branch head base url; do
      [ -n "$id" ] || continue
      rc=0
      fm_merge_queue_branch_merged "$project" "$branch" "$head" "$base" || rc=$?
      case "$rc" in
        0) reason="$branch merged into $base" ;;
        "$FM_MERGE_QUEUE_BRANCH_GONE") reason="$branch gone from origin, merge unverified" ;;
        *) continue ;;
      esac
      if fm_merge_queue_remove "$DATA" "$id"; then
        echo "cleared: $id ($reason)"
        removed=$((removed + 1))
      else
        echo "kept: $id ($reason, but the queue could not be updated)" >&2
      fi
    done <<EOF
$entries
EOF
    echo "Merge queue: swept, $removed cleared."
    ;;
  remove)
    id=${1:-}
    [ -n "$id" ] || { echo "error: remove needs a task id" >&2; exit 2; }
    fm_merge_queue_remove "$DATA" "$id"
    echo "removed: $id"
    ;;
  count)
    entries=$(fm_merge_queue_entries "$DATA")
    if [ -z "$entries" ]; then
      echo 0
    else
      printf '%s\n' "$entries" | grep -c . || true
    fi
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "error: unknown command '$cmd'" >&2
    usage >&2
    exit 2
    ;;
esac
