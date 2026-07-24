#!/usr/bin/env bash
# fm-wake-brief.sh - one composed read for a wake-handling turn.
#
# Firstmate repeats the same read sequence at the top of every wake-handling
# turn (AGENTS.md section 8): drain the durable queue, read each woken task's
# status tail, reconcile its current state, read its metadata, take one host
# reading, and check whether the endpoints are still alive. Run separately that
# is five or more tool calls per turn. This script batches them into one
# invocation with one bounded, labeled output, so a typical wake turn is the
# brief plus whatever action it justifies.
#
# COMPOSITION, NOT REIMPLEMENTATION. Every section shells out to the script
# that already owns it: bin/fm-wake-drain.sh owns the drain and its annotations,
# bin/fm-crew-state.sh owns current-state reconciliation, bin/fm-resource-check.sh
# owns the host reading and its thresholds, and bin/fm-backend.sh owns endpoint
# liveness. Nothing here re-derives any of those contracts, so a change to an
# owner changes this brief with it.
#
# SIDE EFFECTS. The drain in section 1 is the only mutating component, and it is
# the same already-approved drain firstmate is required to run first anyway.
# Everything after it is strictly read-only. This script never arms, restarts,
# or touches the watcher: arming remains a separate call, because the supervision
# protocols require it to be its own background task and never bundled
# (docs/supervision-protocols/). fm-wake-drain.sh's own liveness assertion still
# fires from inside section 1, so a lapsed chain still surfaces here.
#
# Usage:
#   fm-wake-brief.sh              brief the tasks named by the drained wakes
#   fm-wake-brief.sh <id>...      also brief these tasks, whether or not they woke
#   fm-wake-brief.sh --help
#
# Environment:
#   FM_WAKE_BRIEF_TAIL   status-tail lines per task (default 5)
#
# Exit status is 0 whenever the reads themselves succeed. A missing file is a
# fact about the fleet, not an error: it prints an explicit ABSENT marker rather
# than failing the brief or silently omitting the task.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

# Same stub seam bin/fm-classify-lib.sh already publishes, so a test can fix the
# reconciled verdict without a real worktree or a real no-mistakes run.
CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"

TAIL_LINES=${FM_WAKE_BRIEF_TAIL:-5}
case "$TAIL_LINES" in
  ''|*[!0-9]*|0) TAIL_LINES=5 ;;
esac

usage() {
  cat <<'EOF'
usage: fm-wake-brief.sh [<id>...]

Compose one wake-handling turn's reads: drain the durable wake queue, then for
every task the wakes name (plus any id given explicitly) print its status tail,
reconciled current state, and key metadata, followed by one host-resource
reading and one endpoint-liveness sweep.

Read-only apart from the wake drain itself. Never arms or touches the watcher.

Environment:
  FM_WAKE_BRIEF_TAIL   status-tail lines per task (default 5)
EOF
}

EXPLICIT_IDS=
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    -*) echo "fm-wake-brief: unknown argument: $arg" >&2; usage >&2; exit 2 ;;
    *) EXPLICIT_IDS="$EXPLICIT_IDS $arg" ;;
  esac
done

section() { printf '\n=== %s ===\n' "$1"; }

# A task id is only ever used to build a path under this home's state dir, so
# reject anything that could escape it or name a dotfile before it is used.
valid_id() {
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

known_id() {
  [ -f "$STATE/$1.meta" ] || [ -f "$STATE/$1.status" ]
}

# Map one drained wake key to the task it is about, or print nothing.
#
# The queue's key is kind-specific (bin/fm-wake-lib.sh): `signal` keys are the
# status filename, `stale` keys are the backend window label, and `check` keys
# are the check name, which for the per-task checks is the id or an id suffixed
# onto a check prefix. Rather than encoding each producer's naming, this peels
# the known decorations off and accepts the first candidate this home actually
# has a record for - so an unrecognized or fleet-wide key (heartbeat,
# host-resources) simply yields no task, and no key can ever conjure one.
id_for_wake_key() {
  local key=$1 candidate
  for candidate in \
    "$key" \
    "${key%.status}" \
    "${key%.turn-ended}" \
    "${key#fm-}" \
    "${key#secondmate-context-}"; do
    valid_id "$candidate" || continue
    known_id "$candidate" || continue
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

# --- 1. wake queue ----------------------------------------------------------
# Print the drained records first and verbatim: they are this turn's work queue,
# and fm-wake-drain.sh's own annotation lines are part of its output contract.
section "WAKE QUEUE (drained)"
DRAIN_OUT=$("$SCRIPT_DIR/fm-wake-drain.sh" 2>&1)
if [ -n "$DRAIN_OUT" ]; then
  printf '%s\n' "$DRAIN_OUT"
else
  printf '(no queued wakes)\n'
fi

# --- 2. tasks named by the wakes -------------------------------------------
IDS=
add_id() {
  local id=$1 seen
  valid_id "$id" || return 0
  for seen in $IDS; do
    [ "$seen" = "$id" ] && return 0
  done
  IDS="$IDS $id"
}

for id in $EXPLICIT_IDS; do
  add_id "$id"
done

# Only the raw TSV records carry a key; the annotation lines fm-wake-drain.sh
# appends are prose and are deliberately not mined for ids.
WAKE_KEYS=$(printf '%s\n' "$DRAIN_OUT" | awk -F '\t' 'NF >= 5 { print $4 }')
for key in $WAKE_KEYS; do
  resolved=$(id_for_wake_key "$key") || continue
  add_id "$resolved"
done

section "TASKS"
if [ -z "$IDS" ]; then
  printf '(no task named by a drained wake, and no id given)\n'
fi
for id in $IDS; do
  printf '\n--- %s ---\n' "$id"

  status="$STATE/$id.status"
  if [ -f "$status" ]; then
    printf 'status tail (last %s line(s), wake-EVENT history, not current state; full log: %s):\n' \
      "$TAIL_LINES" "$status"
    tail -n "$TAIL_LINES" "$status"
  else
    printf 'status tail: ABSENT (%s)\n' "$status"
  fi

  printf 'current: '
  "$CREW_STATE_BIN" "$id" 2>&1 || true

  meta="$STATE/$id.meta"
  if [ -f "$meta" ]; then
    printf 'meta:'
    for key in window worktree project harness model effort kind mode yolo pr; do
      value=$(fm_meta_get "$meta" "$key")
      [ -n "$value" ] || continue
      printf ' %s=%s' "$key" "$value"
    done
    printf '\n'
  else
    printf 'meta: ABSENT (%s)\n' "$meta"
  fi
done

# --- 3. host resources ------------------------------------------------------
# No --sweep: that flag belongs to the watcher's own slow sweep, which is the
# only caller allowed to pay for a full backend probe (bin/fm-resource-check.sh).
section "HOST RESOURCES"
RESOURCE_OUT=$("$SCRIPT_DIR/fm-resource-check.sh" 2>/dev/null) || true
if [ -n "$RESOURCE_OUT" ]; then
  printf '%s\n' "$RESOURCE_OUT"
else
  printf 'unavailable\n'
fi

# --- 4. endpoint liveness sweep --------------------------------------------
# One sweep over every recorded endpoint in this home, not just the woken ones,
# because a crew that died quietly never appends a wake.
#
# For tmux this takes ONE `tmux list-windows -a` reading and compares the
# recorded window against it with an EXACT string compare. Deliberately not
# `tmux display-message -p -t <window>`: display-message resolves its target
# with tmux's own fuzzy name matching, so a recorded window whose pane is gone
# can still resolve onto a different live window and read as alive. The same
# reading carries `pane_current_command`, so a live harness process and a bare
# `zsh` husk are distinguishable at a glance without a second call.
section "ENDPOINTS"
TAB=$(printf '\t')
TMUX_WINDOWS=
TMUX_READ=0
tmux_windows_load() {
  [ "$TMUX_READ" -eq 0 ] || return 0
  TMUX_READ=1
  command -v tmux >/dev/null 2>&1 || return 0
  TMUX_WINDOWS=$(tmux list-windows -a -F "#{session_name}:#{window_name}${TAB}#{pane_current_command}" 2>/dev/null) || TMUX_WINDOWS=
}

# Print "<presence> <command>" for an exact recorded window, or "absent -".
tmux_window_row() {
  local want=$1 line name command
  tmux_windows_load
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name=${line%%"$TAB"*}
    command=${line#*"$TAB"}
    [ "$name" = "$want" ] || continue
    printf 'alive %s' "${command:--}"
    return 0
  done <<EOF
$TMUX_WINDOWS
EOF
  printf 'dead -'
}

META_FOUND=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  META_FOUND=1
  id=$(basename "$meta" .meta)
  backend=$(fm_backend_of_meta "$meta")
  window=$(fm_meta_get "$meta" window)
  target=$(fm_backend_target_of_meta "$meta")
  if [ -z "$window" ]; then
    printf '%s backend=%s endpoint=unknown (no window recorded)\n' "$id" "$backend"
    continue
  fi
  if [ "$backend" = tmux ]; then
    row=$(tmux_window_row "${target:-$window}")
    printf '%s backend=tmux window=%s endpoint=%s pane=%s\n' \
      "$id" "$window" "${row%% *}" "${row#* }"
  else
    # Non-tmux backends expose no equivalent single-listing sweep, so reuse the
    # liveness primitives bin/fm-backend.sh already publishes rather than
    # inventing a probe this script would then own.
    if fm_backend_target_exists "$backend" "${target:-$window}" "fm-$id"; then
      exists=alive
    else
      exists=dead
    fi
    printf '%s backend=%s window=%s endpoint=%s agent=%s\n' \
      "$id" "$backend" "$window" "$exists" "$(fm_backend_agent_alive "$backend" "${target:-$window}")"
  fi
done
[ "$META_FOUND" -eq 1 ] || printf '(no recorded endpoints)\n'

exit 0
