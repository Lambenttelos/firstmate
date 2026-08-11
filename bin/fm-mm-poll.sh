#!/usr/bin/env bash
# fm-mm-poll.sh - one short poll of the Mattermost control channel for new captain
# messages, for the watcher's custom-check path (state/<id>.check.sh).
#
# Inert by default: a HARD no-op (exit 0, no output) unless MM_TOKEN is set. This
# is what keeps a registered check shim silent until the home opts in.
#
# Contract, identical to any watcher custom check: "output => wake firstmate,
# silence => keep sleeping". On each poll it fetches posts in the control channel
# newer than the durable cursor (state/mm-cursor, epoch ms), keeps only posts
# authored by the CAPTAIN (any user that is not firstmate's own bot account) with
# non-empty message, stashes each verbatim to state/mm-inbox/<post_id>.json,
# advances the cursor, and prints one line "mm-message <post_id>" per new post.
# Those lines become the watcher wake payload, so firstmate handles a captain
# Mattermost message exactly like any other wake - which is what puts it on the
# existing supervision and away-mode escalation path with no parallel loop.
#
# Safety: an inbound message is a captain STEER, never an approval. Ingesting it
# here does not and must not elevate any approval authority; that boundary lives
# in how firstmate handles the wake (AGENTS.md sections 8 and 9), not here.
#
# See docs/mattermost-messaging.md for the design and docs/configuration.md for
# the config contract.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-mm-lib.sh
. "$SCRIPT_DIR/fm-mm-lib.sh"

fm_mm_load_config
# Hard no-op when the feature is off.
fm_mm_enabled || exit 0

ERROR_FILE="$STATE/mm-poll.error"

# Print one diagnostic line only when the error text changed, so a persistent
# misconfiguration wakes firstmate once rather than every cycle. The line is a
# check output, so it becomes a wake the same way a mention does.
emit_error_once() {
  local msg=$1
  if [ -f "$ERROR_FILE" ] && [ "$(cat "$ERROR_FILE" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  ( umask 077; printf '%s\n' "$msg" > "$ERROR_FILE" ) 2>/dev/null || true
  printf 'mm-mode-error %s\n' "$msg"
}

clear_error() {
  rm -f "$ERROR_FILE" 2>/dev/null || true
}

command -v curl >/dev/null 2>&1 || { emit_error_once "missing curl"; exit 0; }
command -v jq   >/dev/null 2>&1 || { emit_error_once "missing jq"; exit 0; }
[ -n "$MM_SERVER" ] || { emit_error_once "missing MM_SERVER_URL"; exit 0; }

AUTH_HEADER_FILE=
BODY_FILE=
trap 'rm -f "$AUTH_HEADER_FILE" "$BODY_FILE"' EXIT
AUTH_HEADER_FILE=$(fm_mm_auth_header_file) || { emit_error_once "invalid MM_TOKEN"; exit 0; }

CHANNEL_ID=$(fm_mm_channel_id "$STATE" "$AUTH_HEADER_FILE") \
  || { emit_error_once "cannot resolve control channel (set MM_CHANNEL_ID or MM_TEAM+MM_CHANNEL)"; exit 0; }
SELF_ID=$(fm_mm_self_user_id "$STATE" "$AUTH_HEADER_FILE") \
  || { emit_error_once "cannot resolve own Mattermost user"; exit 0; }

CURSOR_FILE="$STATE/mm-cursor"
CURSOR=$(head -n 1 "$CURSOR_FILE" 2>/dev/null || true)
case "$CURSOR" in
  ''|*[!0-9]*) CURSOR=0 ;;
esac

# First run (no cursor): do not replay channel history. Anchor the cursor to now
# so only messages the captain sends AFTER opt-in are ingested, then exit without
# a wake. `date +%s%3N` is GNU; fall back to seconds*1000 for portability.
if [ "$CURSOR" -eq 0 ]; then
  NOW_MS=$(date +%s%3N 2>/dev/null)
  case "$NOW_MS" in
    ''|*[!0-9]*) NOW_MS=$(( $(date +%s) * 1000 )) ;;
  esac
  ( umask 077; printf '%s\n' "$NOW_MS" > "$CURSOR_FILE" ) 2>/dev/null || true
  clear_error
  exit 0
fi

BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-mm-poll.XXXXXX") || exit 0
# `since` returns posts created at or after the given epoch-ms. Mattermost caps
# the page; a captain conversation never approaches that in one 30s window.
CODE=$(fm_mm_api_get "/api/v4/channels/$CHANNEL_ID/posts?since=$CURSOR" "$BODY_FILE" "$AUTH_HEADER_FILE") \
  || exit 0
case "$CODE" in
  200) ;;
  401|403) emit_error_once "Mattermost returned HTTP $CODE (token unauthorized for the control channel)"; exit 0 ;;
  404) emit_error_once "Mattermost returned HTTP 404 (control channel not found)"; exit 0 ;;
  *) exit 0 ;;
esac
[ -s "$BODY_FILE" ] || { clear_error; exit 0; }

# Emit, oldest first, "<create_at> <post_id>" for every captain-authored post with
# non-empty message that is strictly newer than the cursor. Filtering here (not in
# the loop) keeps the pipeline a single jq pass. `.order` preserves Mattermost's
# ordering; sorting by create_at makes the cursor advance monotonic regardless.
ROWS=$(jq -r --arg self "$SELF_ID" --argjson cur "$CURSOR" '
  .posts // {}
  | to_entries
  | map(.value)
  | map(select(.user_id != $self and (.create_at // 0) > $cur and ((.message // "") | gsub("[[:space:]]";"") | length) > 0))
  | sort_by(.create_at)
  | .[]
  | "\(.create_at) \(.id)"
' "$BODY_FILE" 2>/dev/null) || { emit_error_once "cannot parse Mattermost response"; exit 0; }

if [ -z "$ROWS" ]; then
  clear_error
  exit 0
fi

MAX_TS=$CURSOR
WOKE=0
while IFS=' ' read -r ts pid; do
  [ -n "$pid" ] || continue
  case "$ts" in ''|*[!0-9]*) continue ;; esac
  # Defend the inbox filename: post ids are Mattermost-issued slugs, but never
  # trust one into a path.
  case "$pid" in
    ''|.*|*[!A-Za-z0-9._-]*) continue ;;
  esac
  # Stash the single post object verbatim so a later agent turn can read it (and
  # reach the full thread via the MCP with the recorded id) with full fidelity.
  ( umask 077; mkdir -p "$STATE/mm-inbox" ) 2>/dev/null || true
  chmod 700 "$STATE/mm-inbox" 2>/dev/null || true
  if ( umask 077; jq --arg id "$pid" '.posts[$id]' "$BODY_FILE" 2>/dev/null > "$STATE/mm-inbox/$pid.json" ) \
    && [ -s "$STATE/mm-inbox/$pid.json" ]; then
    printf 'mm-message %s\n' "$pid"
    WOKE=1
    [ "$ts" -gt "$MAX_TS" ] && MAX_TS=$ts
  fi
done <<EOF
$ROWS
EOF

# Advance the cursor past the newest ingested post so the next poll never replays
# it. Only advance on a real ingest, so a run that stashed nothing keeps the
# window open for a post that arrives between the fetch and now.
if [ "$WOKE" -eq 1 ] && [ "$MAX_TS" -gt "$CURSOR" ]; then
  ( umask 077; printf '%s\n' "$MAX_TS" > "$CURSOR_FILE" ) 2>/dev/null || true
fi
clear_error
exit 0
