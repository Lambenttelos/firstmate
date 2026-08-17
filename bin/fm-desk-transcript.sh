#!/usr/bin/env bash
# fm-desk-transcript.sh - the durable "desk transcript feed" producer.
#
# The captain's desk (bin/fm-desk-refresh.sh) has two catch-up panels: section
# 11 (recent questions) and section 12 (recent conversation). The captain queues
# messages and falls behind reading responses, so those two panels let them
# review recent conversation and recent questions over the LAN. Until now their
# only source was state/desk-judgment.json, a build-time model synthesis that
# exists only at the moment /desk runs. This script is the SEPARATE, durable,
# captain-private rolling feed: the running firstmate session appends real
# captain-facing turns (and questions) as they happen, so the panels reflect an
# actual recent transcript that persists across builds and needs no model pass.
#
# This script is the ONLY writer of the feed. It is captain-private by
# construction: the feed lives under state/, which is gitignored.
#
# Feed path: $FM_HOME/state/desk-transcript.jsonl (override: FM_DESK_TRANSCRIPT).
# One JSON object per line (jsonl). Two record kinds:
#
#   turn:      {"ts":1734127200,"kind":"turn","who":"captain","text":"...","unread":true}
#              who is "captain" or "firstmate"; unread drives section 12's orange
#              rail (#eb760f); text is the turn text.
#   question:  {"ts":1734127200,"kind":"question","q":"...","a":"..."}
#              q is the question firstmate asked; a is the captain's short answer
#              (empty when not answered yet). Drives section 11's Q/A cards.
#
# BOUNDED. The feed is capped at FM_DESK_TRANSCRIPT_MAX lines (default 200). Each
# append that pushes past the cap trims the OLDEST lines back to the cap. The
# trim is atomic (write a temp file in the same directory, then mv into place),
# so a concurrent reader never sees a torn file. When flock is available the
# whole append+trim runs under a per-feed lock so two writers cannot interleave;
# without flock the append is a single small write and the trim is still an
# atomic mv, which is safe because this script is the sole writer.
#
# jq is REQUIRED: it is the only correct way to encode arbitrary turn text into
# a JSON line. When jq is absent the producer refuses rather than write malformed
# JSON. The reader (bin/fm-desk-refresh.sh) tolerates malformed lines regardless.
#
# Usage:
#   fm-desk-transcript.sh turn <who> <text> [--unread]   append a turn record
#       <who> is captain or firstmate. --unread flags an unread turn (orange rail).
#   fm-desk-transcript.sh question <q> [<a>]              append a question record
#       <q> is the question; <a> is the optional answer (empty when omitted).
#   fm-desk-transcript.sh list [<n>]                      print the last <n> raw
#       jsonl lines (default: the full capped feed).
#   fm-desk-transcript.sh prune                           trim the feed to the cap
#   fm-desk-transcript.sh path                            print the feed file path
#   fm-desk-transcript.sh --help
#
# Exit status:
#   0  the record was appended / the read succeeded
#   1  a write failed, or jq is unavailable
#   2  a usage error (bad subcommand, missing/invalid argument)
#
# Test seams: FM_DESK_TRANSCRIPT overrides the feed path and
# FM_DESK_TRANSCRIPT_MAX overrides the line cap, mirroring the FM_DESK_JUDGMENT
# pattern the builder uses. FM_DESK_TRANSCRIPT_NOW injects the record timestamp.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

FEED="${FM_DESK_TRANSCRIPT:-$STATE/desk-transcript.jsonl}"

# The line cap. A recent-N bound keeps the feed from ever growing unbounded; 200
# lines is a generous few dozen turns for the two catch-up panels.
MAX=${FM_DESK_TRANSCRIPT_MAX:-200}
case "$MAX" in ''|*[!0-9]*) MAX=200 ;; esac
[ "$MAX" -ge 1 ] || MAX=200

usage() {
  sed -n '2,58p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

have_jq() { command -v jq >/dev/null 2>&1; }

# now_epoch: the record timestamp, injectable for deterministic tests.
now_epoch() {
  local n="${FM_DESK_TRANSCRIPT_NOW:-}"
  case "$n" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s' "$n" ;;
  esac
}

# trim_feed: keep only the last MAX lines, atomically. A no-op when the feed is
# already within the cap. The temp file is in the SAME directory as the feed so
# the mv stays on one filesystem and is atomic for a concurrent reader.
trim_feed() {
  local count tmp
  [ -f "$FEED" ] || return 0
  count=$(wc -l < "$FEED" 2>/dev/null | tr -d ' ')
  case "$count" in ''|*[!0-9]*) return 0 ;; esac
  [ "$count" -gt "$MAX" ] || return 0
  tmp="$(dirname "$FEED")/.$(basename "$FEED").tmp.$$"
  if tail -n "$MAX" "$FEED" > "$tmp" 2>/dev/null && mv -f "$tmp" "$FEED" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# append_line: append one already-formed jsonl line, then trim. Serialized under
# a per-feed flock when flock exists so two writers never interleave; the trim's
# mv keeps a concurrent reader torn-free either way.
append_line() {
  local line="$1" dir lock
  dir=$(dirname "$FEED")
  mkdir -p "$dir" 2>/dev/null || { echo "fm-desk-transcript: cannot create $dir" >&2; return 1; }
  lock="$dir/.$(basename "$FEED").lock"
  if command -v flock >/dev/null 2>&1; then
    (
      flock 9 || exit 1
      printf '%s\n' "$line" >> "$FEED" || exit 1
      trim_feed || exit 1
    ) 9>"$lock"
  else
    printf '%s\n' "$line" >> "$FEED" || return 1
    trim_feed || return 1
  fi
}

cmd_turn() {
  local who="${1:-}" text="${2:-}" unread=false a
  [ -n "$who" ] || { echo "turn: missing <who>" >&2; return 2; }
  [ $# -ge 2 ] || { echo "turn: missing <text>" >&2; return 2; }
  case "$who" in
    captain|firstmate) : ;;
    *) echo "turn: <who> must be captain or firstmate" >&2; return 2 ;;
  esac
  shift 2 || true
  for a in "$@"; do
    case "$a" in
      --unread) unread=true ;;
      *) echo "turn: unknown option: $a" >&2; return 2 ;;
    esac
  done
  have_jq || { echo "fm-desk-transcript: jq is required" >&2; return 1; }
  local line
  line=$(jq -cn --argjson ts "$(now_epoch)" --arg who "$who" \
    --arg text "$text" --argjson unread "$unread" \
    '{ts:$ts,kind:"turn",who:$who,text:$text,unread:$unread}') \
    || { echo "turn: failed to encode record" >&2; return 1; }
  append_line "$line" || { echo "turn: append failed" >&2; return 1; }
}

cmd_question() {
  local q="${1:-}" a="${2:-}"
  [ -n "$q" ] || { echo "question: missing <q>" >&2; return 2; }
  have_jq || { echo "fm-desk-transcript: jq is required" >&2; return 1; }
  local line
  line=$(jq -cn --argjson ts "$(now_epoch)" --arg q "$q" --arg a "$a" \
    '{ts:$ts,kind:"question",q:$q,a:$a}') \
    || { echo "question: failed to encode record" >&2; return 1; }
  append_line "$line" || { echo "question: append failed" >&2; return 1; }
}

cmd_list() {
  local n="${1:-$MAX}"
  case "$n" in ''|*[!0-9]*) n=$MAX ;; esac
  [ -f "$FEED" ] || return 0
  tail -n "$n" "$FEED" 2>/dev/null
}

cmd_prune() {
  [ -f "$FEED" ] || return 0
  trim_feed || { echo "prune: trim failed" >&2; return 1; }
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    turn) cmd_turn "$@" ;;
    question) cmd_question "$@" ;;
    list) cmd_list "$@" ;;
    prune) cmd_prune "$@" ;;
    path) printf '%s\n' "$FEED" ;;
    -h|--help|help|'') usage ;;
    *) echo "unknown command: $cmd" >&2; usage >&2; return 2 ;;
  esac
}

main "$@"
