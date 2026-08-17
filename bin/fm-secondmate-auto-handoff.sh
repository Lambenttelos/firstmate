#!/usr/bin/env bash
# Detached driver for an AUTOMATIC secondmate context handoff. The watcher's
# secondmate_context_sweep launches this in the background (never waited on) when
# a live, IDLE secondmate crosses its context threshold AND this home has opted
# in (config/secondmate-auto-handoff), so the multi-minute steer+wait+respawn of
# bin/fm-secondmate-handoff.sh runs OUTSIDE the watcher's slow-poll cycle and can
# never stall fleet supervision. The sweep sets the per-window surfaced marker
# BEFORE launching, so a handoff in flight is not re-launched on the next poll.
#
# This wrapper adds nothing to the handoff's safety contract: it delegates the
# whole orderly sequence (fail-closed threshold gate, idle-only steer, bounded
# wait, harness-correct exit, guarded respawn via bin/fm-spawn.sh <id>
# --secondmate) to bin/fm-secondmate-handoff.sh unchanged. It owns only the
# after-the-fact PRIMARY notification, required so the primary learns its
# secondmate was replaced:
#   - success: enqueue exactly one `check: secondmate-handoff <id>` FYI wake so
#     the primary surfaces it at its next supervision cycle. The natural
#     under-threshold re-arm in secondmate_context_sweep clears the marker once
#     the fresh agent reports under threshold, so this wrapper never touches it.
#   - failure: enqueue one `check: secondmate-handoff-failed <id>` escalation so
#     the primary can run the handoff by hand - failing closed to today's
#     escalate-only behavior on any doubt. The marker is LEFT in place so a
#     failed handoff does not re-launch every poll (the old, still-over-threshold
#     agent keeps the crossing marked); the escalation fires exactly once.
#
# A per-id mkdir lock makes a double launch a no-op, belt-and-suspenders beyond
# the marker. Usage: fm-secondmate-auto-handoff.sh <id>
# Env: FM_SM_AUTO_HANDOFF_DRY_RUN=1 runs the handoff in FM_SM_HANDOFF_DRY_RUN
#      mode and prints the notification it WOULD enqueue instead of enqueuing it,
#      for tests. Standard handoff env knobs (FM_SM_HANDOFF_TIMEOUT, ...) pass
#      through.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

DRY_RUN=${FM_SM_AUTO_HANDOFF_DRY_RUN:-}

ID=${1:-}
[ -n "$ID" ] || { echo "error: usage: fm-secondmate-auto-handoff.sh <id>" >&2; exit 2; }

LOCK="$STATE/.sm-auto-handoff-$ID.lock"

# Notify the primary once. In dry-run, print instead of enqueue so tests can
# assert the exact wake without a real queue.
notify() {  # <kind-key> <reason>
  local key=$1 reason=$2
  if [ -n "$DRY_RUN" ]; then
    printf 'NOTIFY: %s | %s\n' "$key" "$reason"
    return 0
  fi
  fm_wake_append check "$key" "$reason" || return 0
  touch "$STATE/.last-check" 2>/dev/null || true
}

run_handoff() {
  if [ -n "$DRY_RUN" ]; then
    FM_SM_HANDOFF_DRY_RUN=1 "$SCRIPT_DIR/fm-secondmate-handoff.sh" "$ID"
  else
    "$SCRIPT_DIR/fm-secondmate-handoff.sh" "$ID"
  fi
}

# Belt-and-suspenders: refuse a concurrent run for the same id (the marker
# already serializes launches, this guards a racing double launch).
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "auto-handoff for '$ID' already in progress; skipping" >&2
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

if run_handoff; then
  notify "secondmate-handoff-$ID" \
    "check: secondmate-handoff $ID (automatic context handoff done; a fresh agent replaced the context-full one)"
  echo "auto-handoff complete for '$ID'"
else
  status=$?
  notify "secondmate-handoff-failed-$ID" \
    "check: secondmate-handoff-failed $ID (automatic context handoff failed, exit ${status}; run bin/fm-secondmate-handoff.sh $ID by hand)"
  echo "auto-handoff FAILED for '$ID' (exit ${status})" >&2
  exit "$status"
fi
