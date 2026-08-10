#!/bin/bash
# fm-switch-account.sh - switch the Claude sub-account for live jcode worker sessions.
#
# jcode's `/account claude switch <label>` is a PER-SESSION slash command, not a
# server-global setting. To move the whole fleet you must send it into every live
# worker's jcode session individually. This script does exactly that.
#
# Usage:
#   bin/fm-switch-account.sh <label> [pane_id ...]
#
#   <label>     required, e.g. claude-2 or claude-4
#   pane_id...  optional explicit herdr pane ids; if omitted, all live worker
#               panes recorded in state/<id>.meta (window=...) are targeted.
#
# It types the slash command and presses Enter in each pane, then waits briefly
# and prints each pane's tail so the caller can confirm the switch landed.
#
# SAFETY: this only rotates a reversible account label. It never edits auth.json,
# never restarts the server, and never touches project code.
#
# NOTE ON no-args DISCOVERY: not every state/*.meta file records a window=
# line (for example a service sidecar meta such as state/.lavish-lan.meta records
# only port=/bind=/target=). Under `set -euo pipefail` a grep that finds no
# window= line exits non-zero, and without a guard that non-zero status would
# propagate through the command substitution and kill the whole script silently
# with exit 1 before it ever reaches a real target. The `|| true` guard on the
# extraction below is load-bearing for that reason: a meta with no window= must
# be skipped, not fatal.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"

# Pacing between the send-text and Enter, and before reading confirmations.
# Overridable so tests can run without the real multi-second waits.
send_settle="${FM_SWITCH_SEND_SETTLE:-1}"
confirm_wait="${FM_SWITCH_CONFIRM_WAIT:-5}"

label="${1:-}"
if [ -z "$label" ]; then
  echo "usage: $0 <label> [pane_id ...]" >&2
  exit 2
fi
shift || true

panes=("$@")

if [ "${#panes[@]}" -eq 0 ]; then
  # Derive live worker panes from task meta files (window=<pane_id>).
  while IFS= read -r metafile; do
    [ -f "$metafile" ] || continue
    # A meta without a window= line is not a target (grep exits non-zero on no
    # match); `|| true` keeps that expected miss from tripping set -e/pipefail.
    win="$(grep -oE '^window=.*' "$metafile" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    # Strip an optional backend-session prefix (e.g. "default:") that herdr
    # pane commands do not accept; keep only the trailing "<ws>:<pane>" id.
    win="${win##*default:}"
    [ -n "$win" ] && panes+=("$win")
  done < <(find state -maxdepth 1 -name '*.meta' 2>/dev/null)
fi

if [ "${#panes[@]}" -eq 0 ]; then
  echo "no target panes found (pass pane ids explicitly)" >&2
  exit 1
fi

echo "switching to account '$label' in ${#panes[@]} pane(s): ${panes[*]}"

for p in "${panes[@]}"; do
  # Type the slash command, then Enter.
  herdr pane send-text "$p" "/account claude switch $label" 2>/dev/null || {
    echo "  $p: send-text FAILED"; continue; }
  sleep "$send_settle"
  herdr pane send-keys "$p" Enter 2>/dev/null || {
    echo "  $p: enter FAILED"; continue; }
  echo "  $p: sent"
done

echo "waiting for confirmations..."
sleep "$confirm_wait"

for p in "${panes[@]}"; do
  echo "=== $p ==="
  herdr pane read "$p" 2>/dev/null | tail -6 || echo "  (read failed)"
done
