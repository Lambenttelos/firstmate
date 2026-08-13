#!/usr/bin/env bash
# fm-end-session.sh - close this firstmate home's session down in one pass:
# append one durable record of the session to data/session-stats.log, and, only
# when the caller opts in, also stand every ordinary live worker down safely.
#
# The default close (the `record` command) leaves every live worker running: a
# session close is a bookkeeping event, not a teardown, so workers keep working
# across it. Standing the fleet down is a separate, opt-in action (the
# `standdown` command) taken only on the captain's explicit word.
#
# Policy - stow before the record is written, and ask about the session report
# only after it - lives in the end-session skill
# (.agents/skills/end-session/SKILL.md). This script owns only the mechanics.
#
# SAFETY: `standdown` calls bin/fm-teardown.sh once per task and NEVER passes
# --force, so teardown's landed-work test stays the authority on what may be
# released. A refusal is reported by task id with the line teardown printed, and
# is never retried, forced, stashed, or worked around; the session closes with
# that worker still standing. Registered secondmates are persistent (AGENTS.md
# section 6), so they are listed as left running and never torn down: retiring
# one needs an explicit captain decision. `record` tears nothing down at all -
# it only counts what is live and writes the history line.
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
#   released refused  counts of ordinary tasks stood down and refused; both 0
#                     for a `record` close, which stands nothing down
#   refused_ids       comma-separated task ids still standing, else -
#   secondmates_left  registered secondmates deliberately left running
#   merge_queue       branches still waiting to merge at close
#   workers_live      ordinary tasks still running at close: every ordinary task
#                     for a `record` close, the refused (still-standing) tasks
#                     for a `standdown` close
# A reconstructed stub (see UNCLEAN TURNOVER below) carries two extra trailing
# fields after workers_live:
#   reconstructed     1, marking a stub the successor backfilled rather than a
#                     genuine clean close; a clean close never sets it
#   session_opened    ISO 8601 UTC time the unclean predecessor session opened,
#                     the one real datum recoverable from its open marker
# Fields are appended, never rewritten: the file is session history. Only durable
# identifiers and counts are recorded - no worktree paths, pane ids, tool
# versions, or other detail that rots (AGENTS.md section 10 note hygiene).
#
# UNCLEAN TURNOVER (the missing-record backfill).
# A clean close (`record`/`standdown`) writes an ended= line AND clears the
# per-home session-open marker (state/.session-open). An unclean turnover - a
# reload without a clean close - writes neither, so the marker survives. The
# successor session detects a surviving marker from a DIFFERENT session at
# session start (the `session-open` command) and appends exactly one
# reconstructed stub for the predecessor so the ledger stays truthful, then
# overwrites the marker with its own session identity. Marker presence at the
# next start is therefore equivalent to "the predecessor left no ended= record".
# Overwriting the marker on backfill makes the backfill idempotent: a repeated
# session-open in the same successor session finds its own identity and appends
# nothing more. This is only the backfill - it does not re-implement stow,
# compact, resume, or turn-end enforcement, which are owned elsewhere.
#
# Usage:
#   fm-end-session.sh record [--model <name>] [--effort <level>]
#                        append the session record and print the outcome, leaving
#                        every live worker running. Exit 0. This is the default
#                        session close.
#   fm-end-session.sh standdown [--model <name>] [--effort <level>]
#                        stand the fleet down AND append the session record, then
#                        print the outcome. Opt-in, taken only on the captain's
#                        explicit word. Exit 0 when every ordinary task was
#                        released, 3 when at least one teardown refused. The
#                        record is appended either way.
#   fm-end-session.sh session-open
#                        record this session's open marker, first backfilling one
#                        reconstructed stub if the marker shows the predecessor
#                        session turned over uncleanly. Prints a SESSION_STATS
#                        line only when it backfilled, and is otherwise silent.
#                        Called on the locked path of session start. Exit 0.
#   fm-end-session.sh report
#                        print the most recent session record in readable form,
#                        for the report the captain may ask for after close.
#
# Test overrides: FM_STATE_OVERRIDE, FM_DATA_OVERRIDE, FM_ROOT_OVERRIDE,
# FM_END_SESSION_TEARDOWN (teardown command), FM_END_SESSION_NOW (epoch now),
# FM_END_SESSION_CURRENT_ID (this session's identity, else derived from the lock).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATS="$DATA/session-stats.log"
SESSION_MARKER="$STATE/.session-open"
TEARDOWN="${FM_END_SESSION_TEARDOWN:-$SCRIPT_DIR/fm-teardown.sh}"
MERGE_QUEUE="$SCRIPT_DIR/fm-merge-queue.sh"

# One owner for process identity; sourcing is side-effect free.
# shellcheck source=bin/fm-pid-lib.sh
. "$SCRIPT_DIR/fm-pid-lib.sh"

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
  #               <refused_ids> <secondmates_left> <merge_queue> <workers_live>
  local ended
  ended=$(now_iso)
  mkdir -p "$DATA"
  if [ ! -e "$STATS" ]; then
    printf '# firstmate session stats - append-only history, one record per closed session.\n' \
      >"$STATS"
    printf '# Field meanings live in bin/fm-end-session.sh; never rewrite or prune a record.\n' \
      >>"$STATS"
  fi
  printf 'ended=%s\tmodel=%s\teffort=%s\taway_seconds=%s\taway_source=%s\treleased=%s\trefused=%s\trefused_ids=%s\tsecondmates_left=%s\tmerge_queue=%s\tworkers_live=%s\n' \
    "$ended" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" >>"$STATS"
}

last_record() {
  grep -v '^#' "$STATS" 2>/dev/null | grep '^ended=' | tail -1
}

# now_iso - the close/open time as ISO 8601 UTC, honoring FM_END_SESSION_NOW.
now_iso() {
  if [ -n "${FM_END_SESSION_NOW:-}" ]; then
    date -u -r "$FM_END_SESSION_NOW" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
      || date -u '+%Y-%m-%dT%H:%M:%SZ'
  else
    date -u '+%Y-%m-%dT%H:%M:%SZ'
  fi
}

# current_session_id - a stable identity for THIS session, used to tell a
# predecessor's surviving open marker apart from our own. FM_END_SESSION_CURRENT_ID
# wins (tests, and any caller that already knows it); otherwise it is derived from
# the session lock holder's pid plus its process identity, so a reused pid never
# looks like the same session. Falls back to just the pid, then to "unknown".
current_session_id() {
  local pid ident
  if [ -n "${FM_END_SESSION_CURRENT_ID:-}" ]; then
    printf '%s\n' "$FM_END_SESSION_CURRENT_ID"
    return 0
  fi
  pid=$(head -1 "$STATE/.lock" 2>/dev/null | tr -d '[:space:]' || true)
  case "$pid" in
    '' | *[!0-9]*) printf 'unknown\n'; return 0 ;;
  esac
  ident=$(fm_pid_identity "$pid" 2>/dev/null || true)
  if [ -n "$ident" ]; then
    printf 'pid=%s identity=%s\n' "$pid" "$ident"
  else
    printf 'pid=%s\n' "$pid"
  fi
}

# marker_session_id / marker_opened - the two lines of the open marker.
marker_session_id() { sed -n '1p' "$SESSION_MARKER" 2>/dev/null; }
marker_opened() { sed -n '2p' "$SESSION_MARKER" 2>/dev/null; }

# write_session_marker - stamp the marker with this session's id and open time,
# overwriting any predecessor's. Best-effort: a non-writable state dir is not
# fatal to a close.
write_session_marker() {
  mkdir -p "$STATE" 2>/dev/null || return 0
  printf '%s\n%s\n' "$(current_session_id)" "$(now_iso)" > "$SESSION_MARKER" 2>/dev/null || true
}

# clear_session_marker - a clean close removes the marker, so the successor sees
# no surviving predecessor and backfills nothing.
clear_session_marker() {
  rm -f "$SESSION_MARKER" 2>/dev/null || true
}

# append_reconstructed_stub <session_opened> - append one stub line for a
# predecessor that left no ended= record, marked reconstructed=1 so it is never
# confused with a genuine clean close. Only fields recoverable from the marker are
# real (the open time); everything else records as unrecorded/0.
append_reconstructed_stub() {
  local opened=$1 ended
  ended=$(now_iso)
  mkdir -p "$DATA"
  if [ ! -e "$STATS" ]; then
    printf '# firstmate session stats - append-only history, one record per closed session.\n' \
      >"$STATS"
    printf '# Field meanings live in bin/fm-end-session.sh; never rewrite or prune a record.\n' \
      >>"$STATS"
  fi
  printf 'ended=%s\tmodel=%s\teffort=%s\taway_seconds=%s\taway_source=%s\treleased=%s\trefused=%s\trefused_ids=%s\tsecondmates_left=%s\tmerge_queue=%s\tworkers_live=%s\treconstructed=%s\tsession_opened=%s\n' \
    "$ended" unrecorded unrecorded 0 unrecorded 0 0 - unrecorded unrecorded unrecorded 1 "${opened:-unrecorded}" >>"$STATS"
}

record_field() {
  # record_field <record> <key>
  printf '%s\n' "$1" | tr '\t' '\n' | sed -n "s/^$2=//p" | tail -1
}

# parse_model_effort <args...> - set OPT_MODEL and OPT_EFFORT from --model/--effort.
OPT_MODEL=unrecorded
OPT_EFFORT=unrecorded
parse_model_effort() {
  OPT_MODEL=unrecorded
  OPT_EFFORT=unrecorded
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --model) OPT_MODEL=${2:-}; [ -n "$OPT_MODEL" ] || { echo "error: --model needs a value" >&2; exit 2; }; shift 2 ;;
      --effort) OPT_EFFORT=${2:-}; [ -n "$OPT_EFFORT" ] || { echo "error: --effort needs a value" >&2; exit 2; }; shift 2 ;;
      *) echo "error: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    esac
  done
}

# count_live_ordinary - print "<ordinary> <secondmate> <secondmate_ids>": the
# number of ordinary tasks and of registered secondmates with a state/*.meta.
count_live_ordinary() {
  local meta id kind ordinary=0 secondmates=0 secondmate_ids=''
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(meta_field "$meta" kind)
    if [ "$kind" = secondmate ]; then
      secondmates=$((secondmates + 1))
      secondmate_ids="$secondmate_ids $id"
    else
      ordinary=$((ordinary + 1))
    fi
  done
  printf '%s %s%s\n' "$ordinary" "$secondmates" "$secondmate_ids"
}

cmd_record() {
  parse_model_effort "$@"
  local model=$OPT_MODEL effort=$OPT_EFFORT

  local counts ordinary secondmates secondmate_ids
  counts=$(count_live_ordinary)
  ordinary=${counts%% *}
  counts=${counts#* }
  secondmates=${counts%% *}
  case "$counts" in *' '*) secondmate_ids=${counts#* } ;; *) secondmate_ids='' ;; esac

  local away away_secs away_src queue
  away=$(away_time)
  away_secs=${away% *}
  away_src=${away#* }
  queue=$(merge_queue_count)

  append_record "$model" "$effort" "$away_secs" "$away_src" 0 0 - \
    "$secondmates" "$queue" "$ordinary"
  clear_session_marker

  echo
  echo "Session close (record only, no worker stood down):"
  printf -- '- workers left running: %s\n' "$ordinary"
  printf -- '- secondmates left running: %s%s\n' "$secondmates" "$secondmate_ids"
  if [ "$away_src" = open-flag ]; then
    printf -- '- away mode open at close: %s\n' "$(human_duration "$away_secs")"
  else
    echo "- away mode: no open stretch; ended stretches are not recorded durably"
  fi
  printf -- '- branches waiting to merge: %s\n' "$queue"
  printf -- '- session record appended: %s\n' "$STATS"
}

cmd_standdown() {
  parse_model_effort "$@"
  local model=$OPT_MODEL effort=$OPT_EFFORT

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
    "${refused_ids:--}" "$secondmates" "$queue" "$refused"
  clear_session_marker

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

# cmd_session_open - the missing-record backfill, run on the locked path of
# session start. If the open marker survives from a DIFFERENT session, that
# predecessor left no ended= record (an unclean turnover), so append exactly one
# reconstructed stub for it. Then stamp the marker with this session's identity,
# which both records this session as open and makes the backfill idempotent: a
# repeated session-open in the same session finds its own identity and does
# nothing. A marker that is absent, empty, or already ours triggers no stub.
cmd_session_open() {
  [ "$#" -eq 0 ] || { echo "error: session-open takes no options" >&2; usage >&2; exit 2; }
  local me predecessor opened
  me=$(current_session_id)
  if [ -f "$SESSION_MARKER" ]; then
    predecessor=$(marker_session_id)
    if [ -n "$predecessor" ] && [ "$predecessor" != "$me" ]; then
      opened=$(marker_opened)
      append_reconstructed_stub "$opened"
      printf 'SESSION_STATS: backfilled one reconstructed stub for a predecessor session that left no clean close (opened %s); ledger stays truthful.\n' \
        "${opened:-unrecorded}"
    fi
  fi
  write_session_marker
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
  local live
  live=$(record_field "$record" workers_live)
  [ -n "$live" ] && printf -- '- workers left running: %s\n' "$live"
  printf -- '- secondmates left running: %s\n' "$(record_field "$record" secondmates_left)"
  printf -- '- branches waiting to merge: %s\n' "$(record_field "$record" merge_queue)"
}

cmd=${1:-}
[ "$#" -gt 0 ] && shift || true
case "$cmd" in
  record) cmd_record "$@" ;;
  standdown) cmd_standdown "$@" ;;
  session-open) cmd_session_open "$@" ;;
  report) cmd_report ;;
  -h | --help | help) usage ;;
  '') echo "error: needs a command" >&2; usage >&2; exit 2 ;;
  *) echo "error: unknown command '$cmd'" >&2; usage >&2; exit 2 ;;
esac
