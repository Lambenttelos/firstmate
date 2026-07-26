#!/usr/bin/env bash
# fm-end-session.sh - close this firstmate home's session down in one pass:
# stand every ordinary live worker down safely, then append one durable record of
# the session to data/session-stats.log.
#
# Policy - stow before anything is stood down, and ask about the session report
# only after the record is written - lives in the end-session skill
# (.agents/skills/end-session/SKILL.md). This script owns only the mechanics.
#
# SAFETY: stand-down calls bin/fm-teardown.sh once per task and NEVER passes
# --force, so teardown's landed-work test stays the authority on what may be
# released. A refusal is reported by task id with the line teardown printed, and
# is never retried, forced, stashed, or worked around; the session closes with
# that worker still standing. Registered secondmates are persistent (AGENTS.md
# section 6), so they are listed as left running and never torn down: retiring
# one needs an explicit captain decision.
#
# Away-mode time is reported only from durable state. state/.afk holds the epoch
# second away mode was entered, so an away stretch still open at session close is
# measurable to the second. A stretch that already ended leaves no durable
# duration behind, so this script records away_source=unrecorded rather than
# inventing a number. See docs/configuration.md "Session stats".
#
# The model name and effort level are not discoverable from durable state either,
# so the caller passes them; any field not supplied records as "unrecorded".
#
# Record format, one tab-separated key=value line appended per closed session:
#   ended             session close time, ISO 8601 UTC
#   model effort      as supplied by the caller, else unrecorded
#   away_seconds      seconds in the away stretch still open at close, else 0
#   away_source       open-flag when away_seconds came from state/.afk, else
#                     unrecorded (no durable record of ended stretches)
#   released refused  counts of ordinary tasks stood down and refused
#   refused_ids       comma-separated task ids still standing, else -
#   secondmates_left  registered secondmates deliberately left running
#   merge_queue       branches still waiting to merge at close
# Fields are appended, never rewritten: the file is session history. Only durable
# identifiers and counts are recorded - no worktree paths, pane ids, tool
# versions, or other detail that rots (AGENTS.md section 10 note hygiene).
#
# Usage:
#   fm-end-session.sh standdown [--model <name>] [--effort <level>]
#                        stand the fleet down, append the session record, print
#                        the outcome. Exit 0 when every ordinary task was
#                        released, 3 when at least one teardown refused. The
#                        record is appended either way.
#   fm-end-session.sh report
#                        print the most recent session record in readable form,
#                        for the report the captain may ask for after close.
#
# Test overrides: FM_STATE_OVERRIDE, FM_DATA_OVERRIDE, FM_ROOT_OVERRIDE,
# FM_END_SESSION_TEARDOWN (teardown command), FM_END_SESSION_NOW (epoch now).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATS="$DATA/session-stats.log"
TEARDOWN="${FM_END_SESSION_TEARDOWN:-$SCRIPT_DIR/fm-teardown.sh}"
MERGE_QUEUE="$SCRIPT_DIR/fm-merge-queue.sh"

usage() {
  sed -n '/^# Usage:/,/^set -eu/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

now_epoch() {
  if [ -n "${FM_END_SESSION_NOW:-}" ]; then
    printf '%s\n' "$FM_END_SESSION_NOW"
  else
    date '+%s'
  fi
}

meta_field() {
  # meta_field <meta-file> <key> - print the last value of key=, or nothing.
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1
}

# Seconds spent in the away stretch that is still open at close, from the epoch
# second /afk recorded in state/.afk. Prints "<seconds> open-flag", or
# "0 unrecorded" when away mode is not open or the flag holds no usable epoch.
away_time() {
  local entered now
  entered=$(head -1 "$STATE/.afk" 2>/dev/null | tr -d '[:space:]' || true)
  case "$entered" in
    '' | *[!0-9]*) printf '0 unrecorded\n'; return 0 ;;
  esac
  now=$(now_epoch)
  if [ "$now" -lt "$entered" ]; then
    printf '0 unrecorded\n'
    return 0
  fi
  printf '%s open-flag\n' "$((now - entered))"
}

human_duration() {
  local secs=$1
  printf '%dh %dm\n' "$((secs / 3600))" "$(((secs % 3600) / 60))"
}

merge_queue_count() {
  local count
  count=$("$MERGE_QUEUE" count 2>/dev/null || echo 0)
  case "$count" in
    '' | *[!0-9]*) printf '0\n' ;;
    *) printf '%s\n' "$count" ;;
  esac
}

append_record() {
  # append_record <model> <effort> <away_secs> <away_src> <released> <refused>
  #               <refused_ids> <secondmates_left> <merge_queue>
  local ended
  if [ -n "${FM_END_SESSION_NOW:-}" ]; then
    ended=$(date -u -r "$FM_END_SESSION_NOW" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
      || date -u '+%Y-%m-%dT%H:%M:%SZ')
  else
    ended=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  fi
  mkdir -p "$DATA"
  if [ ! -e "$STATS" ]; then
    printf '# firstmate session stats - append-only history, one record per closed session.\n' \
      >"$STATS"
    printf '# Field meanings live in bin/fm-end-session.sh; never rewrite or prune a record.\n' \
      >>"$STATS"
  fi
  printf 'ended=%s\tmodel=%s\teffort=%s\taway_seconds=%s\taway_source=%s\treleased=%s\trefused=%s\trefused_ids=%s\tsecondmates_left=%s\tmerge_queue=%s\n' \
    "$ended" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" >>"$STATS"
}

last_record() {
  grep -v '^#' "$STATS" 2>/dev/null | grep '^ended=' | tail -1
}

record_field() {
  # record_field <record> <key>
  printf '%s\n' "$1" | tr '\t' '\n' | sed -n "s/^$2=//p" | tail -1
}

cmd_standdown() {
  local model=unrecorded effort=unrecorded
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --model) model=${2:-}; [ -n "$model" ] || { echo "error: --model needs a value" >&2; exit 2; }; shift 2 ;;
      --effort) effort=${2:-}; [ -n "$effort" ] || { echo "error: --effort needs a value" >&2; exit 2; }; shift 2 ;;
      *) echo "error: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    esac
  done

  local released=0 refused=0 secondmates=0
  local released_ids='' refused_ids='' refusal_report='' secondmate_ids=''
  local meta id kind out rc reason

  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(meta_field "$meta" kind)
    if [ "$kind" = secondmate ]; then
      secondmates=$((secondmates + 1))
      secondmate_ids="$secondmate_ids $id"
      continue
    fi
    echo "standing down: $id"
    rc=0
    out=$("$TEARDOWN" "$id" 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
      released=$((released + 1))
      released_ids="$released_ids $id"
      continue
    fi
    refused=$((refused + 1))
    reason=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1)
    [ -n "$reason" ] || reason="teardown exited $rc with no message"
    if [ -n "$refused_ids" ]; then
      refused_ids="$refused_ids,$id"
    else
      refused_ids="$id"
    fi
    refusal_report="$refusal_report$id: $reason
"
  done

  local away away_secs away_src queue
  away=$(away_time)
  away_secs=${away% *}
  away_src=${away#* }
  queue=$(merge_queue_count)

  append_record "$model" "$effort" "$away_secs" "$away_src" "$released" "$refused" \
    "${refused_ids:--}" "$secondmates" "$queue"

  echo
  echo "Session close:"
  printf -- '- workers stood down: %s%s\n' "$released" "${released_ids:+ -$released_ids}"
  printf -- '- workers still standing: %s\n' "$refused"
  if [ "$refused" -gt 0 ]; then
    printf '%s' "$refusal_report" | sed 's/^/  refused - /'
    echo "  Nothing was forced or discarded. Each refusal above needs the captain's word."
  fi
  printf -- '- secondmates left running: %s%s\n' "$secondmates" "${secondmate_ids:+ -$secondmate_ids}"
  if [ "$away_src" = open-flag ]; then
    printf -- '- away mode open at close: %s\n' "$(human_duration "$away_secs")"
  else
    echo "- away mode: no open stretch; ended stretches are not recorded durably"
  fi
  printf -- '- branches waiting to merge: %s\n' "$queue"
  printf -- '- session record appended: %s\n' "$STATS"

  [ "$refused" -eq 0 ] || exit 3
}

cmd_report() {
  local record
  record=$(last_record)
  if [ -z "$record" ]; then
    echo "No session record yet: run 'fm-end-session.sh standdown' first." >&2
    exit 1
  fi
  local away_secs away_src
  away_secs=$(record_field "$record" away_seconds)
  away_src=$(record_field "$record" away_source)
  echo "Session report"
  printf -- '- closed: %s\n' "$(record_field "$record" ended)"
  printf -- '- model: %s\n' "$(record_field "$record" model)"
  printf -- '- effort: %s\n' "$(record_field "$record" effort)"
  if [ "$away_src" = open-flag ]; then
    printf -- '- time in away mode: %s (the stretch open at close)\n' "$(human_duration "$away_secs")"
  else
    echo "- time in away mode: not recorded (no away stretch was open at close)"
  fi
  printf -- '- workers stood down: %s\n' "$(record_field "$record" released)"
  printf -- '- workers still standing: %s (%s)\n' \
    "$(record_field "$record" refused)" "$(record_field "$record" refused_ids)"
  printf -- '- secondmates left running: %s\n' "$(record_field "$record" secondmates_left)"
  printf -- '- branches waiting to merge: %s\n' "$(record_field "$record" merge_queue)"
}

cmd=${1:-}
[ "$#" -gt 0 ] && shift || true
case "$cmd" in
  standdown) cmd_standdown "$@" ;;
  report) cmd_report ;;
  -h | --help | help) usage ;;
  '') echo "error: needs a command" >&2; usage >&2; exit 2 ;;
  *) echo "error: unknown command '$cmd'" >&2; usage >&2; exit 2 ;;
esac
