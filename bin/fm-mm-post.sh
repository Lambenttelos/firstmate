#!/usr/bin/env bash
# fm-mm-post.sh - post one message from firstmate to the Mattermost control
# channel (the captain-facing outbound path).
#
# Usage:
#   fm-mm-post.sh [--root <post_id>] <<<'message text'   # message on stdin
#   fm-mm-post.sh [--root <post_id>] --message 'text'
#
# The message body is read from stdin by default (so a multi-line escalation
# digest is passed cleanly without shell-quoting), or from --message. --root
# threads the post as a reply to the given captain post id, so a phone shows the
# escalation under the message it answers; omit it for an unprompted escalation
# posted as a new root.
#
# Inert by default: absent MM_TOKEN this is a HARD no-op (exit 0, no output, no
# network call), so a home that has not opted in can call it unconditionally.
#
# SAFETY. The token authorizes posting escalations and firstmate's own answers to
# the control channel. It does NOT expand any approval authority: this helper only
# POSTS text, it never merges, executes, or approves anything. A captain-directed
# destructive/irreversible/security-sensitive action is never carried out by
# receiving or posting a message. See docs/mattermost-messaging.md and AGENTS.md
# sections 8 and 9.
#
# Set MM_DRY_RUN to preview the payload to state/mm-outbox/ without posting.
#
# Exit codes: 0 posted (or inert no-op, or dry-run preview written); 1 a
# configuration or network failure the caller should surface.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-mm-lib.sh
. "$SCRIPT_DIR/fm-mm-lib.sh"

ROOT_ID=
MESSAGE=
HAVE_MESSAGE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) ROOT_ID=${2-}; shift 2 ;;
    --message) MESSAGE=${2-}; HAVE_MESSAGE=1; shift 2 ;;
    -h|--help)
      sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) printf 'fm-mm-post.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [ -z "$HAVE_MESSAGE" ]; then
  MESSAGE=$(cat; printf x)
  MESSAGE=${MESSAGE%x}
  # Drop exactly one trailing newline, the shell/heredoc convention, so a piped
  # single-line message is not posted with a stray blank line. Interior newlines
  # in a multi-line digest are preserved.
  MESSAGE=${MESSAGE%$'\n'}
fi
[ -n "$MESSAGE" ] || { printf 'fm-mm-post.sh: empty message\n' >&2; exit 2; }

case "$ROOT_ID" in
  '') ;;
  *[!A-Za-z0-9._-]*) printf 'fm-mm-post.sh: invalid --root post id\n' >&2; exit 2 ;;
esac

fm_mm_load_config
# Hard no-op when the feature is off, so callers post unconditionally.
fm_mm_enabled || exit 0

command -v curl >/dev/null 2>&1 || { printf 'fm-mm-post.sh: missing curl\n' >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { printf 'fm-mm-post.sh: missing jq\n' >&2; exit 1; }
[ -n "$MM_SERVER" ] || { printf 'fm-mm-post.sh: missing MM_SERVER_URL\n' >&2; exit 1; }

AUTH_HEADER_FILE=
PAYLOAD_FILE=
BODY_FILE=
trap 'rm -f "$AUTH_HEADER_FILE" "$PAYLOAD_FILE" "$BODY_FILE"' EXIT
AUTH_HEADER_FILE=$(fm_mm_auth_header_file) || { printf 'fm-mm-post.sh: invalid MM_TOKEN\n' >&2; exit 1; }

CHANNEL_ID=$(fm_mm_channel_id "$STATE" "$AUTH_HEADER_FILE") \
  || { printf 'fm-mm-post.sh: cannot resolve control channel\n' >&2; exit 1; }

# Build the JSON payload with jq so the message is escaped correctly regardless of
# its content. root_id is included only when threading.
PAYLOAD_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-mm-post.XXXXXX") || exit 1
if [ -n "$ROOT_ID" ]; then
  jq -n --arg ch "$CHANNEL_ID" --arg msg "$MESSAGE" --arg root "$ROOT_ID" \
    '{channel_id:$ch, message:$msg, root_id:$root}' > "$PAYLOAD_FILE" || exit 1
else
  jq -n --arg ch "$CHANNEL_ID" --arg msg "$MESSAGE" \
    '{channel_id:$ch, message:$msg}' > "$PAYLOAD_FILE" || exit 1
fi

# Dry run: write the payload for inspection and post nothing.
if [ -n "$MM_DRY" ]; then
  ( umask 077; mkdir -p "$STATE/mm-outbox" ) 2>/dev/null || true
  chmod 700 "$STATE/mm-outbox" 2>/dev/null || true
  preview="$STATE/mm-outbox/preview.$(date +%s).$$.json"
  cp "$PAYLOAD_FILE" "$preview" 2>/dev/null || true
  printf 'dry-run: wrote %s\n' "$preview"
  exit 0
fi

BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-mm-post-body.XXXXXX") || exit 1
CODE=$(fm_mm_api_post /api/v4/posts "$PAYLOAD_FILE" "$BODY_FILE" "$AUTH_HEADER_FILE") \
  || { printf 'fm-mm-post.sh: post request failed\n' >&2; exit 1; }
case "$CODE" in
  200|201)
    POSTED=$(jq -r '.id // empty' "$BODY_FILE" 2>/dev/null) || POSTED=
    printf 'posted %s\n' "${POSTED:-ok}"
    exit 0
    ;;
  *)
    printf 'fm-mm-post.sh: Mattermost returned HTTP %s\n' "$CODE" >&2
    exit 1
    ;;
esac
