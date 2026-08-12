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
#               targets recorded in state/<id>.meta are targeted, each on the
#               backend that meta records (defaulting to tmux per the P1
#               compatibility contract in fm_backend_of_meta).
#
# For each target it first checks the pane's composer state and refuses to
# garble a half-typed prompt: if the composer already holds pending unsubmitted
# text it sends one Escape to clear it, settles, and re-checks. A composer that
# stays pending after the Escape is SKIPPED (never overwrite genuine human
# typing), as is a composer that reads `unknown` (dead shell / non-agent pane -
# never blind-inject). Only a confirmed-empty composer receives the switch
# command. It then types the slash command and submits it through the backend's
# verified send path, waits briefly, and prints each target's tail so the caller
# can confirm the switch landed.
#
# BACKEND AWARENESS: discovery reads each meta's recorded backend so this works
# on tmux-backed tasks (the common default) as well as herdr. Explicit pane-id
# args on the CLI have no meta to read a backend from and keep the historical
# herdr assumption (this script's original only caller).
#
# SAFETY: this only rotates a reversible account label. It never edits auth.json,
# never restarts the server, and never touches project code.
#
# NOTE ON no-args DISCOVERY: not every state/*.meta file records a target
# (for example a service sidecar meta such as state/.lavish-lan.meta records
# only port=/bind=/target=). Under `set -euo pipefail` a helper that resolves no
# target must not be fatal: the `|| true` guard on the extraction below is
# load-bearing - a meta with no resolvable target must be skipped, not fatal.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
here="$(cd "$script_dir/.." && pwd)"
cd "$here"

# shellcheck source=bin/fm-backend.sh
. "$script_dir/fm-backend.sh"

# Pacing between the send-text and Enter, and before reading confirmations.
# Overridable so tests can run without the real multi-second waits.
send_settle="${FM_SWITCH_SEND_SETTLE:-1}"
confirm_wait="${FM_SWITCH_CONFIRM_WAIT:-5}"
# Settle between the Escape that clears a pending composer and the re-check.
clear_settle="${FM_SWITCH_CLEAR_SETTLE:-0.5}"

label="${1:-}"
if [ -z "$label" ]; then
  echo "usage: $0 <label> [pane_id ...]" >&2
  exit 2
fi
shift || true

panes=("$@")
# target -> backend map. Explicit CLI panes default to herdr (see header).
declare -A target_backends=()

if [ "${#panes[@]}" -eq 0 ]; then
  # Derive live worker targets from task meta files, each on its recorded backend.
  while IFS= read -r metafile; do
    [ -f "$metafile" ] || continue
    backend="$(fm_backend_of_meta "$metafile" 2>/dev/null || true)"
    # A meta without a resolvable target is not a target; `|| true` keeps that
    # expected miss from tripping set -e/pipefail.
    target="$(fm_backend_target_of_meta "$metafile" 2>/dev/null || true)"
    # Strip an optional backend-session prefix (e.g. "default:") that herdr
    # pane commands do not accept; keep only the trailing "<ws>:<pane>" id.
    if [ "$backend" = herdr ]; then
      target="${target##*default:}"
    fi
    [ -n "$target" ] || continue
    panes+=("$target")
    target_backends["$target"]="${backend:-tmux}"
  done < <(find state -maxdepth 1 -name '*.meta' 2>/dev/null)
else
  for p in "${panes[@]}"; do
    target_backends["$p"]=herdr
  done
fi

if [ "${#panes[@]}" -eq 0 ]; then
  echo "no target panes found (pass pane ids explicitly)" >&2
  exit 1
fi

echo "switching to account '$label' in ${#panes[@]} pane(s): ${panes[*]}"

for p in "${panes[@]}"; do
  backend="${target_backends[$p]:-herdr}"

  # Composer guard: never garble a half-typed prompt or blind-inject a dead pane.
  state="$(fm_backend_composer_state "$backend" "$p" 2>/dev/null || echo unknown)"
  if [ "$state" = pending ]; then
    # One Escape to clear pending text, settle, then re-check once.
    fm_backend_send_key "$backend" "$p" Escape 2>/dev/null || true
    sleep "$clear_settle"
    state="$(fm_backend_composer_state "$backend" "$p" 2>/dev/null || echo unknown)"
    if [ "$state" = pending ]; then
      echo "  $p: SKIPPED - composer still has pending text after Escape (not overwriting)"
      continue
    fi
  fi
  if [ "$state" = unknown ]; then
    echo "  $p: SKIPPED - composer state unknown (dead/non-agent pane)"
    continue
  fi

  # Send the slash command through the backend's verified submit path.
  verdict="$(fm_backend_send_text_submit "$backend" "$p" "/account claude switch $label" \
    3 "$send_settle" "$send_settle" 2>/dev/null)" || {
    echo "  $p: send FAILED"; continue; }
  case "$verdict" in
    empty) echo "  $p: sent" ;;
    *) echo "  $p: sent (verdict=${verdict:-unknown})" ;;
  esac
done

echo "waiting for confirmations..."
sleep "$confirm_wait"

for p in "${panes[@]}"; do
  backend="${target_backends[$p]:-herdr}"
  echo "=== $p ==="
  fm_backend_capture "$backend" "$p" 6 2>/dev/null || echo "  (read failed)"
done
