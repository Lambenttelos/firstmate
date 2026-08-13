#!/usr/bin/env bash
# fm-update-nudge.sh - send each updated secondmate its /updatefirstmate re-read
# nudge AT MOST ONCE PER SESSION, as a no-reply-expected one-way message.
#
# WHY THIS EXISTS: /updatefirstmate used to nudge every secondmate on every
# update, and it did so with an ordinary reply-expected send. Over a few days of
# roughly-daily commits that produced dozens of "re-read your AGENTS.md" wakes -
# one per commit per secondmate - each opening a pending-reply expectation and
# each burning a secondmate turn to acknowledge. Two /updatefirstmate runs in one
# session, or thirteen commits pulled across a week, should still cost each
# secondmate at most one nudge, carrying the LATEST commit.
#
# TWO PROPERTIES, ONE OWNER:
#   1. Per-session dedup. A durable marker under state/ records that a given
#      secondmate was already nudged this session. The session is identified by
#      the current session-lock holder pid (state/.lock, written by fm-lock.sh
#      and living as long as the harness session), so a NEW session (new pid)
#      re-nudges, matching how session-lifetime arming is keyed. A stale marker
#      from a previous session's pid is superseded on first use.
#   2. No-reply-expected send. The nudge goes out with
#      FM_SEND_NO_REPLY_EXPECTED=1, so it keeps the from-firstmate reply-routing
#      marker but opens NO correlation id and NO pending-reply record - the desk
#      acknowledges with at most one line and nothing re-escalates.
#
# The re-read nudge is a gentle steer, not an interruption: the secondmate
# already received a safe tracked-files fast-forward from fm-update.sh.
#
# Usage:
#   fm-update-nudge.sh <window> [<window> ...]   nudge each listed window once
#                                                this session; prints one action
#                                                line per window (sent/skipped)
#   fm-update-nudge.sh --help
#
# Each <window> is a secondmate window label as emitted on fm-update.sh's
# `nudge-secondmates:` line (e.g. fm-sm1). The window IS the fm-send target.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() { echo "usage: fm-update-nudge.sh <window> [<window> ...]" >&2; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -ge 1 ] || { usage; exit 1; }

mkdir -p "$STATE"

# The message every nudge carries. The latest commit id and summary make it
# clear which update the secondmate is being asked to pick up (and dedups the
# reader against a repeat), while staying a single gentle line.
NUDGE_COMMIT=$(git -C "$FM_ROOT" rev-parse --short HEAD 2>/dev/null || printf 'unknown')
NUDGE_SUMMARY=$(git -C "$FM_ROOT" log -1 --pretty=%s 2>/dev/null || printf '')
NUDGE_MSG="firstmate was updated to the latest ($NUDGE_COMMIT"
[ -n "$NUDGE_SUMMARY" ] && NUDGE_MSG="$NUDGE_MSG: $NUDGE_SUMMARY"
NUDGE_MSG="$NUDGE_MSG) - please re-read your AGENTS.md to pick up the new instructions."

# Session identity: the session-lock holder pid. A missing/empty lock (no locked
# session) collapses to a stable "nolock" token so the dedup still holds within
# one unlocked run set; a new locked session gets a fresh pid and re-nudges.
session_token() {
  local pid=""
  [ -f "$STATE/.lock" ] && pid=$(cat "$STATE/.lock" 2>/dev/null || printf '')
  case "$pid" in
    ''|*[!0-9]*) printf 'nolock' ;;
    *) printf '%s' "$pid" ;;
  esac
}

# Marker path for one window this session. The window is mangled the same way
# the watcher mangles its own marker keys so a label with a ':' is filesystem
# safe.
marker_key() { printf '%s' "$1" | tr './:' '___'; }
nudged_marker() {  # <window>
  printf '%s/.updatefirstmate-nudged-%s-%s' \
    "$STATE" "$(session_token)" "$(marker_key "$1")"
}

status=0
for window in "$@"; do
  marker=$(nudged_marker "$window")
  if [ -f "$marker" ]; then
    echo "nudge $window: skipped (already nudged this session)"
    continue
  fi
  if FM_HOME="$FM_HOME" FM_SEND_NO_REPLY_EXPECTED=1 \
      "$SCRIPT_DIR/fm-send.sh" "$window" "$NUDGE_MSG"; then
    # Record the nudge only after a confirmed send, so a failed delivery is
    # retried next run rather than silently suppressed.
    touch "$marker" 2>/dev/null || true
    echo "nudge $window: sent ($NUDGE_COMMIT)"
  else
    echo "nudge $window: send failed" >&2
    status=1
  fi
done

exit "$status"
