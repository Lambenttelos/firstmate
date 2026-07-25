#!/usr/bin/env bash
# fm-session-review.sh - the hourly session review pass.
#
# WHAT THIS IS FOR, AND HOW IT DIFFERS FROM THE HEARTBEAT: the watcher's
# heartbeat is a point-in-time backstop - it wakes firstmate to look at the
# fleet as it is right now. This pass is longitudinal instead: it only looks at
# what has NOT moved. Everything it reports is a fact about elapsed time
# (a worker silent for hours, a decision open and untouched, queued work with
# nothing running, finished branches piling up unmerged), which is exactly the
# class of problem a snapshot review cannot see and a busy session reliably
# misses.
#
# It is therefore QUIET by construction: it prints nothing unless a threshold
# has been crossed, and nothing again for a finding the fleet has already been
# told about (bin/fm-hourly-lib.sh owns that suppression contract). A report
# that fires every hour with no news would be turned off, which would cost the
# one report that matters.
#
# It is READ-ONLY over fleet state: it reads state/*.meta, state/*.status,
# data/backlog.md, and the merge-queue count, and writes only its own report
# and suppression markers under state/. It never steers, tears down, merges,
# or touches anything under projects/.
#
# Usage: fm-session-review.sh
#   Prints one short headline line when there is something worth firstmate's
#   attention, and nothing at all otherwise. The full report is written to
#   state/.hourly-review.latest either way, so a headline can stay one line.
#   Always exits 0: this is a reporting command, not a gate.
#
# Thresholds (seconds unless noted; see docs/configuration.md):
#   FM_REVIEW_DECISION_SECS   default 3600   open decision with no movement
#   FM_REVIEW_STALL_SECS      default 7200   worker with no status event
#   FM_REVIEW_MERGE_BATCH     default 3      unmerged branches that make a batch
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-hourly-lib.sh
. "$SCRIPT_DIR/fm-hourly-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

DECISION_SECS=${FM_REVIEW_DECISION_SECS:-3600}
case "$DECISION_SECS" in ''|*[!0-9]*) DECISION_SECS=3600 ;; esac
STALL_SECS=${FM_REVIEW_STALL_SECS:-7200}
case "$STALL_SECS" in ''|*[!0-9]*) STALL_SECS=7200 ;; esac
MERGE_BATCH=${FM_REVIEW_MERGE_BATCH:-3}
case "$MERGE_BATCH" in ''|*[!0-9]*|0) MERGE_BATCH=3 ;; esac

[ -d "$STATE" ] || exit 0

SIGNATURE=
REPORT=
FINDINGS=0
HEADLINES=

# add_finding <signature-key> <headline> <report-line>
# The signature key carries IDENTITY only - never an age or a count - so a
# finding that is still true an hour later produces the same signature and
# stays silent, while a genuinely new one surfaces.
add_finding() {
  SIGNATURE="$SIGNATURE$1
"
  FINDINGS=$(( FINDINGS + 1 ))
  [ -n "$HEADLINES" ] && HEADLINES="$HEADLINES; "
  HEADLINES="$HEADLINES$2"
  REPORT="$REPORT- $3
"
}

# --- work under way: open decisions and silent workers -----------------------
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  fm_hourly_meta_is_secondmate "$meta" && continue
  id=$(basename "$meta" .meta)
  status="$STATE/$id.status"
  if [ -f "$status" ]; then
    age=$(fm_hourly_age_of "$status")
    open=$(status_open_decisions "$status")
  else
    # A worker that wedged before writing its first status line is the worst
    # stall there is, so age it from its own record instead of skipping it.
    age=$(fm_hourly_age_of "$meta")
    open=
  fi
  if [ -n "$open" ] && [ "$age" -ge "$DECISION_SECS" ]; then
    while IFS=$(printf '\t') read -r key verb note; do
      [ -n "$key" ] || continue
      add_finding "decision:$id:$key" \
        "$id waiting on a decision" \
        "$id has an unanswered $verb open for $(fm_hourly_human_age "$age"): $note"
    done <<EOF
$open
EOF
  elif [ "$age" -ge "$STALL_SECS" ]; then
    add_finding "stall:$id" \
      "$id silent for $(fm_hourly_human_age "$age")" \
      "$id has reported nothing for $(fm_hourly_human_age "$age"); check its current state before assuming it is working"
  fi
done

# --- idle capacity: queued work with nothing running -------------------------
# The captain's standing rule is that an idle slot while work is queued is a
# failure, and that is invisible to any single-moment fleet view: nothing is
# wrong with any one task, the fleet has simply stopped dispatching.
INFLIGHT=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  fm_hourly_meta_is_secondmate "$meta" && continue
  INFLIGHT=$(( INFLIGHT + 1 ))
done
QUEUED=0
if [ -f "$DATA/backlog.md" ]; then
  QUEUED=$(awk '
    /^##[[:space:]]+/ { queued = ($0 ~ /^##[[:space:]]+Queued[[:space:]]*$/); next }
    queued && /^[-*][[:space:]]+/ { n++ }
    END { print n + 0 }
  ' "$DATA/backlog.md")
fi
case "$QUEUED" in ''|*[!0-9]*) QUEUED=0 ;; esac
if [ "$INFLIGHT" -eq 0 ] && [ "$QUEUED" -gt 0 ]; then
  add_finding "idle-capacity" \
    "nothing under way with $QUEUED queued" \
    "$QUEUED queued item(s) and no work under way; re-evaluate the queue and dispatch what is unblocked"
fi

# --- finished branches piling up ---------------------------------------------
MERGE_COUNT=$("$SCRIPT_DIR/fm-merge-queue.sh" count 2>/dev/null || printf 0)
case "$MERGE_COUNT" in ''|*[!0-9]*) MERGE_COUNT=0 ;; esac
if [ "$MERGE_COUNT" -ge "$MERGE_BATCH" ]; then
  add_finding "merge-batch" \
    "$MERGE_COUNT finished branches waiting to merge" \
    "$MERGE_COUNT finished branch(es) are pushed but unmerged - a batch worth landing; bin/fm-merge-queue.sh list has the compare links"
fi

# --- report -------------------------------------------------------------------
REPORT_PATH=$(fm_hourly_report_path "$STATE" review)
{
  printf 'hourly session review - %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  printf 'home: %s\n' "$FM_HOME"
  if [ "$FINDINGS" -eq 0 ]; then
    printf 'no findings: nothing has stalled, no decision is waiting, and the queue is moving.\n'
  else
    printf '%s finding(s):\n' "$FINDINGS"
    printf '%s' "$REPORT"
  fi
} > "$REPORT_PATH" 2>/dev/null || true

fm_hourly_should_surface "$STATE" review "$SIGNATURE" || exit 0
printf 'session review: %s (full report: %s)\n' "$HEADLINES" "$REPORT_PATH"
exit 0
