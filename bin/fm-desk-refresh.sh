#!/usr/bin/env bash
# fm-desk-refresh.sh - regenerate the captain's desk, a single reloadable page
# rendering this home's current fleet state in the captain's own vocabulary.
#
# The captain wanted one page carrying fleet status in their own vocabulary. The
# explicitly rejected alternative was a standing agent, so this is a plain
# script: no resident process, no memory cost, no supervision turn. It is
# READ-ONLY over fleet state and SILENT by construction - see NEVER WAKES below.
#
# Invoked MANUALLY, on request. It is deliberately not on any schedule and is not
# wired into the watcher cycle: the captain asks for the desk when they want it.
#
# Usage:
#   fm-desk-refresh.sh              render the desk to the stable output path
#   fm-desk-refresh.sh --path       print that stable output path and exit
#   fm-desk-refresh.sh --help
#
# Exit status:
#   0  the page was rendered and moved into place (possibly with noted gaps)
#   1  nothing was rendered - the output could not be written at all
#   64 usage error
#
# NEVER WAKES. This script must never call bin/fm-wake-lib.sh, fm_wake_append,
# bin/fm-send.sh, or append to a status file. Rendering a page is not
# captain-facing progress (AGENTS.md section 8), so it reports nothing and
# interrupts nobody; it just leaves a fresh page behind.
#
# DATA SOURCES - all LOCAL and cheap; no network call, no agent, no probe that
# costs more than a kernel read:
#   bin/fm-bearings-snapshot.sh --json   the canonical local fleet projection
#                                        (which itself wraps fm-fleet-snapshot.sh
#                                        and honors config/backlog-backend), for
#                                        work under way, open decisions, blocked
#                                        items, and recently landed work
#   bin/fm-merge-queue.sh list --raw     finished-but-unmerged branches
#   bin/fm-resource-check.sh             the host reading. NEVER --sweep: that
#                                        form probes every agent's liveness and
#                                        belongs to the watcher alone. The plain
#                                        form is a kernel read plus the
#                                        state/.resource-live cache the sweep
#                                        already wrote, so it costs milliseconds
#   state/.resource-status               the level the fleet is operating on
#   state/.afk                           whether the captain is away
#   data/completions.tsv                 the append-only completion ledger, for
#                                        the progress windows and per-repo stats.
#                                        It records the completion DATE only, not
#                                        an hour, so an hour-scale window is shown
#                                        by the calendar days it touches and the
#                                        page says so rather than implying a
#                                        precision the source does not carry
#   state/.last-watcher-beat             the monitoring liveness beacon, read by
#                                        mtime for the fleet-health line
#   tasks-axi (in FM_HOME)               the backlog, for the full captain-hold
#                                        list and the four ranked queue lists
#
# DEGRADE QUIETLY. Every source is optional. A missing, failing, or unparseable
# source is recorded as a gap, shown in the page, and the rest of the page is
# still rendered. The page is written to a temp path in the destination
# directory and moved into place, so a reload never catches a partial page.
#
# The page follows the captain-desk spec (data/captain-desk-spec.md): a sticky
# KPI strip pinned on scroll, then twelve sections in urgency order - decisions,
# blockers, ready-to-merge, slots and host, two progress windows, upcoming,
# captain-held tickets, four ranked queue lists, stats, recent questions, and a
# recent-conversation transcript panel. Sections 11 and 12 are transcript-
# sourced by design and render as marked gaps when no local transcript source is
# available to this read-only builder.
#
# LANGUAGE. The page is captain-facing, so AGENTS.md section 9 applies in full.
# Free text lifted from fleet records is passed through desk_plain(), which
# rewrites internal vocabulary into the captain's nouns; DESK_TERMS below is the
# single owner of that mapping.
#
# Test seams: FM_DESK_OUT overrides the output path, FM_DESK_TIMEOUT bounds each
# source command, FM_DESK_NOW injects the rendered timestamp, and
# FM_DESK_SNAPSHOT_BIN overrides the fleet-projection command (the canonical
# fm-bearings-snapshot.sh) so a test can drive the projection failure paths.
# FM_DESK_NOW_EPOCH injects the reference epoch the progress windows count back
# from, and FM_DESK_COMPLETIONS overrides the completion-ledger path.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# Export the resolved home so every child source (fm-bearings-snapshot.sh,
# fm-merge-queue.sh, fm-resource-check.sh) reads the SAME home this desk resolved.
# Those children each default FM_HOME to their own script-relative code root when
# it is unset, so an unexported FM_HOME let them silently read a different,
# possibly empty, home than the ticket band - which cd's into FM_HOME explicitly -
# and render confident-empty sections for a populated fleet.
export FM_HOME

# The stable output path. The SAME file every refresh, never a dated one: an
# already-open browser tab must stay valid so the captain only reloads.
OUT="${FM_DESK_OUT:-$FM_HOME/.lavish/captain-desk.html}"

# Per-source wall-clock bound. The fleet projection is the only source that
# takes real time, and the desk must never be the reason a watcher cycle stalls.
DESK_TIMEOUT=${FM_DESK_TIMEOUT:-120}
case "$DESK_TIMEOUT" in ''|*[!0-9]*) DESK_TIMEOUT=120 ;; esac

# How much of each unbounded list the page shows before it stops being scannable.
DESK_MAX_DECISIONS=${FM_DESK_MAX_DECISIONS:-12}

# The header comment IS the help text: from the description line down to the
# last comment line before the first executable line.
usage() {
  sed -n '2,79p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- internal-vocabulary translation ----------------------------------------
#
# AGENTS.md section 9 owns the rule; this table owns the mechanical rewrite for
# free text the page lifts out of fleet records. Longer forms come first so a
# plural or hyphenated form is not half-rewritten by its own singular. Scout and
# second mate are accepted house vocabulary and deliberately absent.
DESK_TERMS=$(cat <<'TERMS'
[Cc]rewmates	workers
[Cc]rewmate	worker
[Ss]econdmate agents	second mates
[Aa]gents	workers
[Aa]gent	worker
[Ww]orktrees	local copies
[Ww]orktree	local copy
[Pp]rimary checkout	main local copy
[Cc]heckouts	local copies
[Cc]heckout	local copy
[Tt]ear down	clean up
[Tt]eardown	cleanup
[Hh]eartbeats	routine checks
[Hh]eartbeat	routine check
[Ww]ake queue	notification queue
[Ww]akes	notifications
[Ww]ake	notification
[Ww]atchers	monitoring
[Ww]atcher	monitoring
[Ss]tale	unresponsive
[Hh]arnesses	worker tools
[Hh]arness	worker tool
[Bb]ackends	worker tools
[Bb]ackend	worker tool
[Aa]dapters	worker tools
[Aa]dapter	worker tool
[Bb]riefs	instructions
[Bb]rief	instructions
fails? clos(e|ed|es)	stops safely
[Ff]ail-closed	stops safely
fails? open	steps aside
[Ff]ail-open	steps aside
[Pp]ipelines	validation runs
[Pp]ipeline	validation
[Nn]o-mistakes	validation
fix-review	review findings
checks-passed	checks passed
needs-decision	waiting on your word
ask-user	your decision
[Ss]tatus files?	record
[Mm]etadata	record
TERMS
)
# Handed to awk through the environment rather than -v: the table is multi-line,
# and awk's -v assignment neither accepts a literal newline nor leaves backslash
# escapes alone.
export DESK_TERMS

# desk_plain: rewrite internal vocabulary in free text read from stdin.
desk_plain() {
  awk '
    BEGIN {
      n = split(ENVIRON["DESK_TERMS"], lines, "\n")
      for (i = 1; i <= n; i++) {
        if (lines[i] == "") continue
        split(lines[i], kv, "\t")
        pat[i] = kv[1]; rep[i] = kv[2]
      }
    }
    {
      for (i = 1; i <= n; i++) if (pat[i] != "") gsub(pat[i], rep[i])
      print
    }
  '
}

# desk_esc: HTML-escape stdin. Runs AFTER desk_plain so the mapping never has to
# reason about entities.
desk_esc() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# desk_text: the only way free text reaches the page - translate, then escape.
desk_text() {
  printf '%s' "$1" | desk_plain | desk_esc
}

# desk_title: turn a durable record id into a human title. Ids are internal, so
# they are never printed raw. Ids are also where internal vocabulary is most
# concentrated, so the same translation runs here, before capitalization.
desk_title() {
  printf '%s' "$1" \
    | tr '_-' '  ' \
    | sed -e 's/^ *//' -e 's/  */ /g' \
    | desk_plain \
    | awk '{ if (length($0) > 0) print toupper(substr($0,1,1)) substr($0,2); else print }' \
    | desk_esc
}

# desk_show_field: the FULL value of a named tasks-axi field for one id, read
# from `tasks-axi show <id> --full` so the desk never inherits the snapshot's
# 60-char description truncation. Prints nothing when the record or field is
# absent, so callers can fall back. The field value may be quoted and may carry
# escaped newlines from the backend; collapse them to spaces for one-line cards.
desk_show_field() {
  local id="$1" field="$2"
  (cd "$FM_HOME" 2>/dev/null && desk_bound tasks-axi show "$id" --full 2>/dev/null) \
    | awk -v f="$field" '
        $0 ~ "^[[:space:]]*" f ":" {
          sub("^[[:space:]]*" f ":[[:space:]]*", "")
          sub(/^"/, ""); sub(/"[[:space:]]*$/, "")
          gsub(/\\n/, " "); gsub(/[[:space:]]+/, " ")
          print; exit
        }'
}

# desk_full_title / desk_full_reason: full title / hold reason for an id,
# translated and escaped, falling back to the (possibly truncated) value the
# snapshot already provided when the record cannot be read.
desk_full_title() {
  local id="$1" fallback="$2" full
  full=$(desk_show_field "$id" title)
  [ -n "$full" ] && { printf '%s' "$full" | desk_plain | desk_esc; return 0; }
  desk_text "$fallback"
}
desk_full_reason() {
  local id="$1" fallback="$2" full
  full=$(desk_show_field "$id" hold_reason)
  [ -n "$full" ] && [ "$full" != "-" ] && { printf '%s' "$full" | desk_plain | desk_esc; return 0; }
  [ "$fallback" = "-" ] && return 0
  desk_text "$fallback"
}

# desk_state: the captain-facing rendering of a recorded work state.
desk_state() {
  case "$1" in
    working) printf 'under way' ;;
    needs-decision) printf 'waiting on your word' ;;
    blocked) printf 'stuck' ;;
    paused) printf 'waiting' ;;
    done) printf 'finished' ;;
    failed) printf 'failed' ;;
    no_active_work|idle) printf 'idle' ;;
    ''|unknown) printf 'unclear' ;;
    *) printf '%s' "$(printf '%s' "$1" | tr '_-' '  ')" ;;
  esac
}

# desk_state_badge: the DaisyUI badge tone matching that state.
desk_state_badge() {
  case "$1" in
    working) printf 'badge-info' ;;
    needs-decision|blocked) printf 'badge-warning' ;;
    failed) printf 'badge-error' ;;
    done) printf 'badge-success' ;;
    *) printf 'badge-neutral' ;;
  esac
}

# --- bounded source execution -----------------------------------------------

# desk_bound: run a command under DESK_TIMEOUT when a timeout tool exists, and
# unbounded otherwise rather than refusing to render at all.
DESK_TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  DESK_TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  DESK_TIMEOUT_BIN=gtimeout
fi
desk_bound() {
  if [ -n "$DESK_TIMEOUT_BIN" ]; then
    "$DESK_TIMEOUT_BIN" "$DESK_TIMEOUT" "$@"
  else
    "$@"
  fi
}

# Gaps accumulate as one plain-English line each and are shown in the page, so a
# missing source is visible to the captain rather than silently rendering as
# "nothing to report".
GAPS=""
note_gap() { GAPS="${GAPS}${1}
"; }

# --- collect ----------------------------------------------------------------

BEAR=""
HAVE_JQ=0
if command -v jq >/dev/null 2>&1; then
  HAVE_JQ=1
else
  note_gap "Fleet records could not be read on this machine, so work under way, decisions, and finished work are missing."
fi

DESK_SNAPSHOT_BIN="${FM_DESK_SNAPSHOT_BIN:-$SCRIPT_DIR/fm-bearings-snapshot.sh}"
if [ "$HAVE_JQ" -eq 1 ]; then
  # The desk is a strictly READ-ONLY projection that itself displays away
  # status, so it must render a full fleet snapshot even while away mode is
  # active. Skip ONLY the bearings away-return guard for this read; the bypass
  # does not clear the away gate or mutate any catch-up state (see
  # fm-bearings-snapshot.sh). Away or not, the projection output is identical,
  # so a non-away render stays byte-unchanged.
  if BEAR=$(FM_BEARINGS_SKIP_AFK_GUARD=1 desk_bound "$DESK_SNAPSHOT_BIN" --json 2>/dev/null) \
    && [ -n "$BEAR" ] && printf '%s' "$BEAR" | jq -e . >/dev/null 2>&1; then
    :
  else
    BEAR=""
    note_gap "Current fleet state could not be read just now, so work under way, decisions, and finished work are missing from this page."
  fi
fi

MERGEQ=""
if ! MERGEQ=$(desk_bound "$SCRIPT_DIR/fm-merge-queue.sh" list --raw 2>/dev/null); then
  MERGEQ=""
  note_gap "The list of finished-but-unmerged work could not be read, so that section may be incomplete."
fi

RES_LINE=""
if ! RES_LINE=$(desk_bound "$SCRIPT_DIR/fm-resource-check.sh" 2>/dev/null | head -n 1); then
  RES_LINE=""
fi
RES_LEVEL=$(cat "$STATE/.resource-status" 2>/dev/null || printf '')
if [ -z "$RES_LINE" ] && [ -z "$RES_LEVEL" ]; then
  note_gap "No reading of this machine's capacity was available."
fi

AWAY=0
[ -e "$STATE/.afk" ] && AWAY=1

# The completion ledger, read for the two progress windows (sections 5 and 6)
# and the per-repo stats (section 10). It is append-only and never pruned, so a
# plain read is cheap. Absent is a real answer ("nothing recorded yet"), not a
# failure, so it does not raise a global gap; each consuming section notes its
# own gap when it genuinely cannot render.
COMPLETIONS="${FM_DESK_COMPLETIONS:-$FM_HOME/data/completions.tsv}"

# The reference epoch the progress windows count back from. FM_DESK_NOW is a
# display string and may be injected in any format, so the windows use a
# separate numeric seam and fall back to the wall clock.
NOW_EPOCH=${FM_DESK_NOW_EPOCH:-$(date +%s)}
case "$NOW_EPOCH" in ''|*[!0-9]*) NOW_EPOCH=$(date +%s) ;; esac

# The monitoring liveness beacon, read for the fleet-health line in section 2.
# The watcher touches it every poll, so a beacon older than a generous bound
# means the supervision cycle has lapsed. Empty when the beacon is absent.
WATCH_BEAT_AGE=""
if [ -e "$STATE/.last-watcher-beat" ]; then
  _beat_mtime=$(date -r "$STATE/.last-watcher-beat" +%s 2>/dev/null || printf '')
  if [ -n "$_beat_mtime" ]; then
    WATCH_BEAT_AGE=$(( NOW_EPOCH - _beat_mtime ))
    [ "$WATCH_BEAT_AGE" -lt 0 ] && WATCH_BEAT_AGE=0
  fi
fi

# --- ticket counts ----------------------------------------------------------
#
# The count band is REQUIRED and always rendered. Its figures come from the
# backlog through tasks-axi and are NEVER scraped out of prose.
#
# The definitions the captain fixed:
#   Landed     state done
#   In flight  state in_flight, whether or not it is also on hold - it is being
#              worked right now, which is what the figure claims
#   Queued     ONLY queued work that could actually start today
#   Blocked    every other queued item: waiting on a captain decision, or on
#              another ticket. Held-but-queued and dependency-blocked items are
#              blocked, never queued.
# Blocked breaks down into "needs the captain" (a captain hold) and "waiting on
# other work" (a dependency block, or a hold of any other kind).
#
# tasks-axi's held listing is an OVERLAY, not a fifth state: a held row still
# carries its own done/in_flight/queued state. So the grand total is
# done + in_flight + queued, and the four figures partition exactly that set.
# Both sums are computed independently and compared; a mismatch is shown rather
# than hidden.
TICKETS_OK=0
TK_LANDED=0; TK_INFLIGHT=0; TK_QUEUED=0; TK_BLOCKED=0
TK_CAPTAIN=0; TK_OTHER=0; TK_TOTAL=0; TK_DISCREPANCY=""

# tasks_rows: "<id> <state> <last-field>" for each listed row. tasks-axi rows are
# indented by two spaces, comma-separated, id first and state second; neither an
# id nor a hold kind can contain a comma, so the first and last fields are safe
# to take positionally even when a quoted title contains commas.
tasks_rows() {
  (cd "$FM_HOME" 2>/dev/null && desk_bound tasks-axi "$@" 2>/dev/null) \
    | awk -F, '/^  [^ ]/ { id = $1; sub(/^ +/, "", id); print id, $2, $NF }'
}

# count_lines: number of non-empty lines, always exiting 0 (an empty listing is
# a real answer of zero, not a failure).
count_lines() { printf '%s\n' "$1" | awk 'NF { n++ } END { print n + 0 }'; }

collect_tickets() {
  local queued dep held blocked capheld queued_total four
  command -v tasks-axi >/dev/null 2>&1 || return 1
  # One probe that must succeed, so a broken or incompatible tasks-axi reads as
  # "unknown" rather than as an empty backlog.
  (cd "$FM_HOME" 2>/dev/null && desk_bound tasks-axi list --state 'done' --limit 1 >/dev/null 2>&1) || return 1

  TK_LANDED=$(count_lines "$(tasks_rows list --state 'done' --limit 100000)")
  TK_INFLIGHT=$(count_lines "$(tasks_rows list --state in_flight --limit 100000)")
  queued=$(tasks_rows list --state queued --limit 100000 | awk '{print $1}' | sort -u)
  dep=$(tasks_rows list --blocked --limit 100000 | awk '$2 == "queued" {print $1}')
  held=$(tasks_rows list --state held --limit 100000 --fields hold_kind | awk '$2 == "queued" {print $1}')
  capheld=$(tasks_rows list --state held --limit 100000 --fields hold_kind \
    | awk '$2 == "queued" && $3 == "captain" {print $1}')

  # A queued item can be BOTH dependency-blocked and held, so the blocked figure
  # is the union, never the sum of the two listings.
  blocked=$(printf '%s\n%s\n' "$dep" "$held" | awk 'NF' | sort -u)
  TK_BLOCKED=$(count_lines "$blocked")
  TK_CAPTAIN=$(count_lines "$capheld")
  TK_OTHER=$(( TK_BLOCKED - TK_CAPTAIN ))
  [ "$TK_OTHER" -lt 0 ] && TK_OTHER=0

  queued_total=$(count_lines "$queued")
  TK_QUEUED=$(( queued_total - TK_BLOCKED ))
  [ "$TK_QUEUED" -lt 0 ] && TK_QUEUED=0
  TK_TOTAL=$(( TK_LANDED + TK_INFLIGHT + queued_total ))

  four=$(( TK_LANDED + TK_INFLIGHT + TK_QUEUED + TK_BLOCKED ))
  if [ "$four" -ne "$TK_TOTAL" ]; then
    TK_DISCREPANCY="The four figures add up to ${four}, but the backlog holds ${TK_TOTAL} tickets - ${TK_TOTAL} is the true count and the difference is unexplained."
  fi
  TICKETS_OK=1
  return 0
}

if ! collect_tickets; then
  TICKETS_OK=0
  note_gap "The ticket counts could not be read from the backlog, so the count band is blank."
fi

NOW=${FM_DESK_NOW:-$(date '+%Y-%m-%d %H:%M')}

# A jq helper prepended to every desk_json filter: coerce a non-scalar value to a
# string so a single object/array-valued field (which jq's @tsv rejects for the
# WHOLE stream) degrades to a visible string instead of blanking the section.
DESK_JQ_PRELUDE='def z: if (type == "array" or type == "object") then tostring else . end;'

# desk_json: read one jq expression out of the fleet projection.
#
# Return status is the caller's signal, so an unreadable source is never confused
# with a source that genuinely holds nothing:
#   0  the query ran; stdout is the result, which may legitimately be empty
#   2  the fleet projection is absent (a global gap is already recorded for it)
#   3  the query itself failed against present data (a section-level gap is due)
desk_json() {
  [ -n "$BEAR" ] || return 2
  local out st
  out=$(printf '%s' "$BEAR" | jq -r "$DESK_JQ_PRELUDE $1" 2>/dev/null)
  st=$?
  printf '%s' "$out"
  [ "$st" -eq 0 ] || return 3
  return 0
}

# desk_section_gap: a visible, in-section gap line. Shown when a section's source
# could not be read, so the section reads as "unknown", never as a confident
# empty state.
desk_section_gap() {
  printf '    <p class="text-sm text-warning">%s</p>\n' "$(desk_text "$1")"
}

# --- render -----------------------------------------------------------------
#
# Design source: DaisyUI 5 on the Tailwind browser runtime, matching the
# hand-built desk this replaces, so a captain who had the earlier page open
# recognizes the new one immediately.

render_header() {
  local running running_st decisions decisions_st unmerged summary
  running=$(desk_json '[.in_flight[] | select(.state != "done")] | length'); running_st=$?
  decisions=$(desk_json '.decisions_open | length'); decisions_st=$?
  unmerged=0
  [ -n "$MERGEQ" ] && unmerged=$(printf '%s\n' "$MERGEQ" | grep -c .)
  summary=""
  # A count the projection could not supply must not be stated as zero: that
  # would read as a confident "nothing", the exact failure mode being fixed.
  if [ "$decisions_st" -ne 0 ]; then
    summary="Current fleet state could not be read, so this summary is incomplete."
  else
    case "${decisions:-0}" in
      ''|0) summary="Nothing needs your word." ;;
      1) summary="One thing needs your word." ;;
      *) summary="${decisions} things need your word." ;;
    esac
    case "${running:-0}" in
      ''|0) [ "$running_st" -eq 0 ] && summary="$summary Nothing is running." ;;
      1) summary="$summary One job is running." ;;
      *) summary="$summary ${running} jobs are running." ;;
    esac
  fi
  [ "${unmerged:-0}" -gt 0 ] && summary="$summary ${unmerged} finished branches are waiting to merge."
  [ "$AWAY" -eq 1 ] && summary="$summary You are marked away."

  cat <<HTML
  <header class="mb-8">
    <div class="flex flex-wrap items-baseline justify-between gap-3">
      <h1 class="text-3xl font-bold tracking-tight">Captain's desk</h1>
      <div class="text-sm opacity-60">as of $(desk_text "$NOW")</div>
    </div>
    <p class="mt-2 opacity-70 text-sm">$(desk_text "$summary")</p>
  </header>
HTML
}

# The count band. ALWAYS rendered, even when the backlog could not be read: an
# absent band would read as "no tickets", which is a different claim.
render_tickets() {
  local total landed inflight queued blocked split
  if [ "$TICKETS_OK" -eq 1 ]; then
    total=$TK_TOTAL; landed=$TK_LANDED; inflight=$TK_INFLIGHT
    queued=$TK_QUEUED; blocked=$TK_BLOCKED
    split="${TK_CAPTAIN} need your decision &middot; ${TK_OTHER} wait on other work"
  else
    total='&mdash;'; landed='&mdash;'; inflight='&mdash;'
    queued='&mdash;'; blocked='&mdash;'
    split='breakdown unavailable'
  fi
  cat <<HTML
  <section class="mb-10">
    <div class="card bg-base-200">
      <div class="card-body gap-4">
        <div class="flex items-baseline justify-between gap-3 flex-wrap">
          <h2 class="text-lg font-semibold">Ticket count</h2>
          <div class="text-sm opacity-60">${total} total</div>
        </div>
        <div class="grid gap-3 grid-cols-2 lg:grid-cols-4">

          <div class="rounded-lg bg-base-100 p-4">
            <div class="text-3xl font-semibold text-success">${landed}</div>
            <div class="text-sm font-medium mt-1">Landed</div>
            <div class="text-xs opacity-60 mt-0.5">finished and recorded</div>
          </div>

          <div class="rounded-lg bg-base-100 p-4">
            <div class="text-3xl font-semibold text-info">${inflight}</div>
            <div class="text-sm font-medium mt-1">In flight</div>
            <div class="text-xs opacity-60 mt-0.5">being worked right now</div>
          </div>

          <div class="rounded-lg bg-base-100 p-4">
            <div class="text-3xl font-semibold">${queued}</div>
            <div class="text-sm font-medium mt-1">Queued</div>
            <div class="text-xs opacity-60 mt-0.5">ready to start, waiting on capacity</div>
          </div>

          <div class="rounded-lg bg-base-100 p-4">
            <div class="text-3xl font-semibold text-warning">${blocked}</div>
            <div class="text-sm font-medium mt-1">Blocked</div>
            <div class="text-xs opacity-60 mt-0.5">${split}</div>
          </div>

        </div>
        <p class="text-xs opacity-50">
          Landed + in flight + queued + blocked = ${total}. Queued counts only work that could start today;
          anything waiting on you or on another ticket is counted as blocked, not queued.
        </p>
HTML
  if [ -n "$TK_DISCREPANCY" ]; then
    printf '        <div class="alert alert-warning text-sm py-2">%s</div>\n' \
      "$(desk_text "$TK_DISCREPANCY")"
  fi
  cat <<'HTML'
      </div>
    </div>
  </section>
HTML
}

render_gaps() {
  [ -n "$GAPS" ] || return 0
  echo '  <div class="alert alert-warning mb-8 text-sm block">'
  echo '    <div class="font-medium mb-1">Some of this page is missing.</div>'
  echo '    <ul class="space-y-1">'
  printf '%s' "$GAPS" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '      <li>&bull; %s</li>\n' "$(desk_text "$line")"
  done
  echo '    </ul>'
  echo '  </div>'
}

# --- money detector ----------------------------------------------------------
# A cheap heuristic that flags a ticket or branch on the payment path so the
# captain can spot money-touching work at a glance, per the spec's "money-path
# flagged" requirement. It is deliberately generous: a false positive costs a
# harmless badge, a false negative hides a money change.
desk_is_money() {  # <free text...>
  printf '%s' "$*" | grep -qiE 'pay|price|charg|money|invoice|refund|billing|reprice|epdf|eplf|extrafee|dual.?pric'
}

# --- section 1: decisions needed --------------------------------------------
render_decisions() {
  local rows st
  rows=$(desk_json ".decisions_open[:${DESK_MAX_DECISIONS}][] | [.id, (.summary|z), (.owner|z)] | @tsv"); st=$?
  echo '  <section id="sec-decisions" class="mb-10">'
  echo '    <h2 class="text-lg font-semibold mb-3">1. Decisions needed</h2>'
  if [ "$st" -ne 0 ]; then
    desk_section_gap "The list of decisions waiting on you could not be read, so this section is unknown right now."
    echo '  </section>'
    return 0
  fi
  if [ -z "$rows" ]; then
    echo '    <p class="text-sm opacity-60">Nothing is waiting on you.</p>'
    echo '  </section>'
    return 0
  fi
  echo '    <div class="grid gap-4 md:grid-cols-2">'
  printf '%s\n' "$rows" | while IFS=$'\t' read -r id summary owner; do
    [ -n "$id" ] || continue
    local money=''
    desk_is_money "$id $summary" && money='<span class="badge badge-error badge-sm">money</span>'
    cat <<HTML
      <div class="card bg-base-200 rail" style="--rail: oklch(0.75 0.16 70)">
        <div class="card-body gap-2">
          <div class="flex items-start justify-between gap-2">
            <h3 class="card-title text-base">$(desk_title "$id")</h3>
            <span class="flex gap-1 shrink-0">${money}<span class="badge badge-warning badge-sm">your call</span></span>
          </div>
          <p class="text-sm opacity-80">$(desk_full_reason "$id" "$summary")</p>
          <div class="text-xs opacity-50">$(desk_text "$owner")</div>
        </div>
      </div>
HTML
  done
  echo '    </div>'
  echo '  </section>'
}

# --- section 2: blockers and failures ---------------------------------------
# Distinct from decisions: this is "something is broken", not "choose please".
# Sourced from in-flight work whose live state is blocked or failed, plus a
# fleet-health line that reports the monitoring beacon and away posture. The
# builder is read-only and cannot cheaply prove a background daemon is alive or
# that a clone has drifted, so it says so rather than inventing a green light.
render_fleet_health() {
  local mon away
  if [ -n "$WATCH_BEAT_AGE" ]; then
    if [ "$WATCH_BEAT_AGE" -le 1800 ]; then
      mon="Monitoring is alive (last check about ${WATCH_BEAT_AGE}s ago)."
    else
      mon="Monitoring may have lapsed (last check about ${WATCH_BEAT_AGE}s ago)."
    fi
  else
    mon="Monitoring status is unknown; no recent check was recorded."
  fi
  if [ "$AWAY" -eq 1 ]; then away="You are marked away."; else away="You are present."; fi
  printf '    <p class="text-sm opacity-70 mb-3">%s %s Background daemon liveness and clone drift are not checked by this read-only page.</p>\n' \
    "$(desk_text "$mon")" "$(desk_text "$away")"
}

render_blockers() {
  local rows st
  rows=$(desk_json '[.in_flight[] | select(.state == "blocked" or .state == "failed")][] | [.id, (.state|z), (.doing|z)] | @tsv'); st=$?
  echo '  <section id="sec-blockers" class="mb-10">'
  echo '    <h2 class="text-lg font-semibold mb-3">2. Blockers and failures</h2>'
  render_fleet_health
  if [ "$st" -ne 0 ]; then
    desk_section_gap "The list of stuck or failed work could not be read, so this section is unknown right now."
    echo '  </section>'
    return 0
  fi
  if [ -z "$rows" ]; then
    echo '    <p class="text-sm opacity-60">Nothing is broken or stuck right now.</p>'
    echo '  </section>'
    return 0
  fi
  echo '    <div class="grid gap-3 md:grid-cols-2">'
  printf '%s\n' "$rows" | while IFS=$'\t' read -r id state doing; do
    [ -n "$id" ] || continue
    cat <<HTML
      <div class="card bg-base-200 rail" style="--rail: oklch(0.6 0.2 25)">
        <div class="card-body py-4 gap-1">
          <div class="flex items-start justify-between gap-2">
            <h3 class="font-medium text-sm">$(desk_title "$id")</h3>
            <span class="badge $(desk_state_badge "$state") badge-sm shrink-0">$(desk_text "$(desk_state "$state")")</span>
          </div>
          <p class="text-sm opacity-70">$(desk_text "$doing")</p>
        </div>
      </div>
HTML
  done
  echo '    </div>'
  echo '  </section>'
}

# --- section 4: slots and host ----------------------------------------------
# Per the spec, list EVERY occupied slot with what it is doing right now: crew
# and second mate, each naming the agent, its repo, and its current activity.
# The snapshot already carries the live per-item .doing/.state for in-flight
# crew work and a per-secondmate .doing/.state, so the desk draws the per-slot
# activity from that single projection rather than N slow fm-crew-state calls,
# which keeps the section inside the wall-clock bound. Idle second mates are
# listed and marked idle (idle is healthy).
render_slots() {
  local crew crew_st sm sm_st
  crew=$(desk_json '[.in_flight[] | select(.state != "done")][] | [.id, (.kind|z), (.state|z), (.doing|z)] | @tsv'); crew_st=$?
  sm=$(desk_json '.secondmates[]? | [.id, (.state|z), (.doing|z)] | @tsv'); sm_st=$?
  echo '  <section id="sec-slots" class="mb-10">'
  echo '    <h2 class="text-lg font-semibold mb-3">4. Slots and host</h2>'
  render_machine_card
  # Standing postures line.
  local posture
  if [ "$AWAY" -eq 1 ]; then posture="Away mode is on."; else posture="Away mode is off."; fi
  printf '    <p class="text-sm opacity-70 mt-3 mb-3">%s Self-landing lanes run per the backlog; this page does not track them individually.</p>\n' \
    "$(desk_text "$posture")"
  echo '    <div class="overflow-x-auto">'
  echo '      <table class="table table-sm">'
  echo '        <thead><tr class="text-xs uppercase tracking-wide opacity-60">'
  echo '          <th class="w-56">Agent</th><th class="w-24">Kind</th><th class="w-28">Standing</th><th>What it is doing</th>'
  echo '        </tr></thead>'
  echo '        <tbody>'
  if [ "$crew_st" -eq 0 ] && [ -n "$crew" ]; then
    printf '%s\n' "$crew" | while IFS=$'\t' read -r id kind state doing; do
      [ -n "$id" ] || continue
      [ "$kind" = "-" ] && kind="work"
      cat <<HTML
          <tr>
            <td class="font-medium align-top">$(desk_title "$id")</td>
            <td class="align-top text-sm opacity-70">$(desk_text "$kind")</td>
            <td class="align-top"><span class="badge $(desk_state_badge "$state") badge-sm">$(desk_text "$(desk_state "$state")")</span></td>
            <td class="text-sm opacity-80">$(desk_text "$doing")</td>
          </tr>
HTML
    done
  fi
  if [ "$sm_st" -eq 0 ] && [ -n "$sm" ]; then
    printf '%s\n' "$sm" | while IFS=$'\t' read -r id state doing; do
      [ -n "$id" ] || continue
      cat <<HTML
          <tr>
            <td class="font-medium align-top">$(desk_title "$id") <span class="badge badge-ghost badge-xs">second mate</span></td>
            <td class="align-top text-sm opacity-70">standing</td>
            <td class="align-top"><span class="badge $(desk_state_badge "$state") badge-sm">$(desk_text "$(desk_state "$state")")</span></td>
            <td class="text-sm opacity-80">$(desk_text "$doing")</td>
          </tr>
HTML
    done
  fi
  echo '        </tbody>'
  echo '      </table>'
  echo '    </div>'
  if [ "$crew_st" -ne 0 ] || [ "$sm_st" -ne 0 ]; then
    desk_section_gap "Part of the live per-slot activity could not be read, so this list may be incomplete."
  elif [ -z "$crew" ] && [ -z "$sm" ]; then
    echo '    <p class="text-sm opacity-60">No slots are occupied right now.</p>'
  fi
  echo '  </section>'
}

# --- section 8: captain-held tickets (full list) ----------------------------
# The complete Captain's Call list - every captain hold, a superset of the
# urgent decisions in section 1. Read straight from the backlog through
# tasks-axi so it is durable, never scraped from prose. Degrades to a gap when
# tasks-axi cannot be read.
render_captain_held() {
  local rows
  echo '  <section id="sec-held" class="mb-10">'
  echo '    <h2 class="text-lg font-semibold mb-3">8. Captain-held tickets</h2>'
  if ! command -v tasks-axi >/dev/null 2>&1; then
    desk_section_gap "The backlog could not be read, so the full captain-hold list is unknown right now."
    echo '  </section>'
    return 0
  fi
  # Held rows whose hold_kind is captain, id first and hold_kind last (positional
  # take is comma-safe as in collect_tickets).
  rows=$(tasks_rows list --state held --limit 100000 --fields hold_kind \
    | awk '$3 == "captain" {print $1}')
  if [ -z "$rows" ]; then
    echo '    <p class="text-sm opacity-60">You are holding nothing right now.</p>'
    echo '  </section>'
    return 0
  fi
  echo '    <div class="grid gap-2 md:grid-cols-2">'
  printf '%s\n' "$rows" | while IFS= read -r id; do
    [ -n "$id" ] || continue
    local money=''
    desk_is_money "$id" && money='<span class="badge badge-error badge-xs shrink-0">money</span>'
    cat <<HTML
      <div class="card bg-base-200/60">
        <div class="card-body py-3 gap-1">
          <div class="flex items-start justify-between gap-2">
            <h3 class="font-medium text-sm">$(desk_title "$id")</h3>
            ${money}
          </div>
          <p class="text-sm opacity-70">$(desk_full_title "$id" "$id")</p>
          <p class="text-xs opacity-50">$(desk_full_reason "$id" "-")</p>
        </div>
      </div>
HTML
  done
  echo '    </div>'
  echo '  </section>'
}

# --- section 3: ready to merge ----------------------------------------------
# Full compare URLs grouped BY REPO, each with green/red CI state and a money
# flag. The merge-queue rows carry an id, project path, branch, head, base, and
# compare URL. CI state is derived from a cheap gh-axi check, but only when a
# forge tool is present AND the whole section stays inside the wall-clock bound:
# a network probe on the hot path would break the "costs milliseconds" contract,
# so it is guarded hard and the branch renders without a CI badge (noted) when
# the check is unavailable or times out.
DESK_CI_BUDGET=${FM_DESK_CI_BUDGET:-20}
case "$DESK_CI_BUDGET" in ''|*[!0-9]*) DESK_CI_BUDGET=20 ;; esac

# desk_ci_state: print green/red/unknown for one compare URL's head branch. Uses
# gh-axi only when present and only within a tight per-call bound. Any failure
# yields "unknown" so the section never blocks on the network.
desk_ci_state() {  # <repo-slug-url> <head>
  local url="$1" head="$2" slug out
  command -v gh-axi >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  [ -n "$head" ] || { printf 'unknown'; return 0; }
  # Extract owner/repo from a github compare URL; anything else is unknown.
  slug=$(printf '%s' "$url" | sed -n -E 's#https?://github.com/([^/]+/[^/]+)/compare/.*#\1#p')
  [ -n "$slug" ] || { printf 'unknown'; return 0; }
  out=$("$DESK_TIMEOUT_BIN" "${DESK_TIMEOUT_BIN:+$DESK_CI_BUDGET}" gh-axi api \
    "repos/$slug/commits/$head/status" --jq '.state' 2>/dev/null) || { printf 'unknown'; return 0; }
  case "$out" in
    success) printf 'green' ;;
    failure|error) printf 'red' ;;
    *) printf 'unknown' ;;
  esac
}

render_ready_merge() {
  local count start_epoch elapsed do_ci
  count=0
  [ -n "$MERGEQ" ] && count=$(printf '%s\n' "$MERGEQ" | grep -c .)
  echo '  <section id="sec-merge" class="mb-10">'
  if [ "${count:-0}" -eq 0 ]; then
    echo '    <h2 class="text-lg font-semibold mb-3">3. Ready to merge</h2>'
    echo '    <p class="text-sm opacity-60">Nothing is waiting to merge.</p>'
    echo '  </section>'
    return 0
  fi
  cat <<HTML
    <h2 class="text-lg font-semibold mb-3 flex items-center gap-2">
      3. Ready to merge
      <span class="badge badge-neutral badge-sm">${count}</span>
    </h2>
    <p class="text-sm opacity-70 mb-3">All pushed and safe, grouped by repository. Review whenever you want them.</p>
HTML
  # Derive a repo label from the project path's basename and group rows under it.
  # CI state is checked only while the section-wide budget holds.
  start_epoch=$(date +%s)
  do_ci=1
  [ -n "$DESK_TIMEOUT_BIN" ] || do_ci=0
  printf '%s\n' "$MERGEQ" \
    | while IFS=$'\t' read -r id project branch head base url; do
        [ -n "$id" ] || continue
        : "$base"
        repo=$(basename "$project" 2>/dev/null); [ -n "$repo" ] || repo="(unknown repo)"
        printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$id" "$head" "$url" "$branch"
      done \
    | sort -t"$(printf '\t')" -k1,1 \
    | {
        cur=""
        while IFS=$'\t' read -r repo id head url branch; do
          [ -n "$repo" ] || continue
          if [ "$repo" != "$cur" ]; then
            [ -n "$cur" ] && echo '    </div>'
            cur="$repo"
            printf '    <h3 class="font-medium text-sm mt-4 mb-2 opacity-80">%s</h3>\n' "$(desk_esc <<<"$repo")"
            echo '    <div class="grid gap-2 sm:grid-cols-2">'
          fi
          # CI state, guarded by the elapsed budget.
          ci="unknown"
          if [ "$do_ci" -eq 1 ]; then
            elapsed=$(( $(date +%s) - start_epoch ))
            if [ "$elapsed" -lt "$DESK_CI_BUDGET" ]; then
              ci=$(desk_ci_state "$url" "$head")
            fi
          fi
          case "$ci" in
            green) badge='<span class="badge badge-success badge-xs">CI green</span>' ;;
            red) badge='<span class="badge badge-error badge-xs">CI red</span>' ;;
            *) badge='<span class="badge badge-ghost badge-xs">CI unknown</span>' ;;
          esac
          money=''
          desk_is_money "$id $branch" && money='<span class="badge badge-error badge-xs">money</span>'
          if [ -n "$url" ]; then
            printf '      <div class="flex items-center gap-2 flex-wrap"><a class="link link-hover text-sm" href="%s">%s</a>%s%s</div>\n' \
              "$(desk_esc <<<"$url")" "$(desk_title "$id")" "$badge" "$money"
          else
            printf '      <div class="flex items-center gap-2 flex-wrap"><span class="text-sm opacity-70">%s</span>%s%s</div>\n' \
              "$(desk_title "$id")" "$badge" "$money"
          fi
        done
        [ -n "$cur" ] && echo '    </div>'
      }
  echo '  </section>'
}

# render_machine_card: the host reading as a bare card (no section wrapper), so
# section 4 can place it under its own heading alongside the per-slot list.
render_machine_card() {
  local avail total swap agents ceiling level tone prose
  avail=$(printf '%s' "$RES_LINE" | sed -n -E 's/.*avail ([0-9]+) MB of ([0-9]+) GB.*/\1/p')
  total=$(printf '%s' "$RES_LINE" | sed -n -E 's/.*avail ([0-9]+) MB of ([0-9]+) GB.*/\2/p')
  swap=$(printf '%s' "$RES_LINE" | sed -n -E 's/.*swap ([0-9]+)%.*/\1/p')
  agents=$(printf '%s' "$RES_LINE" | sed -n -E 's/.*live agents ([0-9]+).*/\1/p')
  ceiling=$(printf '%s' "$RES_LINE" | sed -n -E 's/.*recommended ceiling ([0-9]+).*/\1/p')
  level=${RES_LEVEL:-$(printf '%s' "$RES_LINE" | sed -n -E 's/^resources: ([a-z]+).*/\1/p')}
  case "$level" in
    critical) tone="text-error"; prose="More is running than this machine comfortably carries; everything feels slow because of it." ;;
    degraded) tone="text-warning"; prose="This machine is getting tight. Nothing has misbehaved; it is simply carrying a lot." ;;
    healthy) tone="text-success"; prose="This machine has room to spare." ;;
    *) tone=""; prose="No clear reading of this machine was available." ;;
  esac

  echo '    <div class="card bg-base-200"><div class="card-body gap-3">'
  echo '      <div class="grid gap-4 sm:grid-cols-3">'
  if [ -n "$avail" ]; then
    printf '        <div><div class="text-xs uppercase tracking-wide opacity-60">Memory free</div><div class="text-2xl font-semibold">%s <span class="text-base opacity-60">MB of %s GB</span></div></div>\n' \
      "$(desk_esc <<<"$avail")" "$(desk_esc <<<"$total")"
  fi
  if [ -n "$swap" ]; then
    printf '        <div><div class="text-xs uppercase tracking-wide opacity-60">Swap in use</div><div class="text-2xl font-semibold %s">%s<span class="text-base opacity-60">%%</span></div></div>\n' \
      "$tone" "$(desk_esc <<<"$swap")"
  fi
  if [ -n "$agents" ]; then
    printf '        <div><div class="text-xs uppercase tracking-wide opacity-60">Workers</div><div class="text-2xl font-semibold">%s <span class="text-base opacity-60">/ %s comfortable</span></div></div>\n' \
      "$(desk_esc <<<"$agents")" "$(desk_esc <<<"${ceiling:-?}")"
  fi
  echo '      </div>'
  printf '      <p class="text-sm opacity-70">%s</p>\n' "$(desk_text "$prose")"
  echo '    </div></div>'
}

# --- sections 5 and 6: progress windows -------------------------------------
# The completion ledger records a completion DATE, not an hour, so an hour-scale
# window is honestly reported by the calendar days it spans and the page says so
# rather than implying a precision the source does not carry. Each window counts
# completions whose date falls on or after the window's start day and summarizes
# throughput by repo. Degrades to a gap when the ledger is unreadable.
#
# desk_progress_window <label> <days-back> : render one progress card. days-back
# is 0 for "today" (the 3h window's calendar day) and 1 for "today and
# yesterday" (the 12h window may span a day boundary).
desk_progress_window() {  # <heading> <intro> <start-yyyy-mm-dd>
  local heading="$1" intro="$2" start="$3" rows total by_repo
  printf '    <h2 class="text-lg font-semibold mb-1">%s</h2>\n' "$(desk_esc <<<"$heading")"
  printf '    <p class="text-sm opacity-60 mb-3">%s</p>\n' "$(desk_esc <<<"$intro")"
  if [ ! -f "$COMPLETIONS" ]; then
    desk_section_gap "The completion record could not be read, so this progress window is unknown right now."
    return 0
  fi
  # Data lines: <id>\t<date>\t<kind>\t<repo>\t<sha>. Filter date >= start.
  rows=$(awk -F'\t' -v s="$start" '/^#/ {next} NF>=4 && $2 >= s {print}' "$COMPLETIONS" 2>/dev/null)
  total=$(printf '%s\n' "$rows" | awk 'NF{n++} END{print n+0}')
  if [ "$total" -eq 0 ]; then
    echo '    <p class="text-sm opacity-60">Nothing has landed in this window.</p>'
    return 0
  fi
  by_repo=$(printf '%s\n' "$rows" | awk -F'\t' 'NF>=4{c[$4]++} END{for(r in c) printf "%s\t%d\n", r, c[r]}' | sort -t"$(printf '\t')" -k2,2 -rn -k1,1)
  printf '    <p class="text-sm opacity-80 mb-2"><strong>%s</strong> landed.</p>\n' "$total"
  echo '    <ul class="text-sm space-y-1">'
  printf '%s\n' "$by_repo" | while IFS=$'\t' read -r repo n; do
    [ -n "$repo" ] || continue
    printf '      <li class="flex justify-between gap-3"><span>%s</span><span class="opacity-60">%s</span></li>\n' \
      "$(desk_esc <<<"$repo")" "$n"
  done
  echo '    </ul>'
}

render_progress_3h() {
  local start
  start=$(date -d "@$NOW_EPOCH" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
  echo '  <section id="sec-progress-3h" class="mb-10">'
  desk_progress_window "5. Progress - last 3 hours" \
    "The completion record is dated by day, so this counts what landed today (the last-3-hours calendar day)." \
    "$start"
  echo '  </section>'
}

render_progress_12h() {
  local start
  start=$(date -d "@$(( NOW_EPOCH - 86400 ))" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
  echo '  <section id="sec-progress-12h" class="mb-10">'
  desk_progress_window "6. Progress - last 12 hours" \
    "Wider window: what landed today and yesterday, since the record is dated by day and 12 hours can span a day boundary." \
    "$start"
  echo '  </section>'
}

# --- section 7: most important upcoming progress ----------------------------
# Forward look: what is about to land (branches waiting to merge), what firstmate
# is watching (recorded PRs), and the next dispatch intentions (the top of the
# ready queue). All read from projections already collected, so it adds no cost.
render_upcoming() {
  local about landing watching next
  echo '  <section id="sec-upcoming" class="mb-10">'
  echo '    <h2 class="text-lg font-semibold mb-3">7. Most important upcoming progress</h2>'
  echo '    <div class="grid gap-4 md:grid-cols-3">'
  # About to land: the merge queue count.
  about=0
  [ -n "$MERGEQ" ] && about=$(printf '%s\n' "$MERGEQ" | grep -c .)
  landing="Nothing is queued to merge."
  [ "${about:-0}" -gt 0 ] && landing="${about} finished branch(es) are ready to land."
  printf '      <div class="card bg-base-200/60"><div class="card-body py-4 gap-1"><h3 class="font-medium text-sm">About to land</h3><p class="text-sm opacity-70">%s</p></div></div>\n' \
    "$(desk_text "$landing")"
  # Watching: recorded PRs from the snapshot.
  watching=$(desk_json '.recorded_prs | length' 2>/dev/null)
  case "${watching:-0}" in
    ''|0) watching="No open pull requests are being watched." ;;
    1) watching="One pull request is being watched for its checks." ;;
    *) watching="${watching} pull requests are being watched for their checks." ;;
  esac
  printf '      <div class="card bg-base-200/60"><div class="card-body py-4 gap-1"><h3 class="font-medium text-sm">Watching</h3><p class="text-sm opacity-70">%s</p></div></div>\n' \
    "$(desk_text "$watching")"
  # Next dispatch: top ready-to-start queued item, if the backlog can be read.
  next="No further ready work is queued to start."
  if command -v tasks-axi >/dev/null 2>&1; then
    local top
    top=$(tasks_rows list --state queued --limit 100000 | awk '{print $1; exit}')
    [ -n "$top" ] && next="Next up to dispatch: $(printf '%s' "$top" | tr '_-' '  ')."
  fi
  printf '      <div class="card bg-base-200/60"><div class="card-body py-4 gap-1"><h3 class="font-medium text-sm">Next dispatch</h3><p class="text-sm opacity-70">%s</p></div></div>\n' \
    "$(desk_text "$next")"
  echo '    </div>'
  echo '  </section>'
}

# --- section 9: four categorized top-10 queue lists -------------------------
# Four separate ranked cards drawn from the LIVE backlog: product ship, product
# scout, tooling, and quick/cheap wins. Held or blocked tickets are excluded.
# Ranking uses tasks-axi priority (lower number is higher value). Each entry:
# id, repo, kind tag, one-line why. Degrades to a gap when the backlog is
# unreadable.
DESK_PRODUCT_REPOS='hyfin hyfin-server integration-server'
DESK_TOOLING_REPOS='firstmate no-mistakes herdr jcode claude-swap tasks-axi'

# desk_queue_rows: dispatchable queued rows as "<pri>\t<id>\t<repo>\t<kind>",
# excluding held and dependency-blocked items, sorted by priority ascending.
desk_queue_rows() {
  # tasks-axi list default fields are id,state,kind,repo,priority,title. Take the
  # first five comma-safe leading fields (title is last and may hold commas).
  (cd "$FM_HOME" 2>/dev/null && desk_bound tasks-axi list --state queued --limit 100000 --fields priority 2>/dev/null) \
    | awk -F, '
        /^  [^ ]/ {
          id=$1; sub(/^ +/,"",id);
          kind=$3; repo=$4; pri=$5;
          gsub(/^ +| +$/,"",pri); gsub(/"/,"",repo);
          if (pri=="" || pri !~ /^[0-9]+$/) pri=5;
          print pri "\t" id "\t" repo "\t" kind
        }'
}

# desk_top10_card: render one ranked card. <title> <intro> then rows on stdin.
desk_top10_card() {  # <title> <intro>
  local title="$1" intro="$2" any=0 line pri id repo kind
  printf '      <div class="card bg-base-200"><div class="card-body gap-2">\n'
  printf '        <h3 class="font-semibold text-sm">%s</h3>\n' "$(desk_esc <<<"$title")"
  printf '        <p class="text-xs opacity-50">%s</p>\n' "$(desk_esc <<<"$intro")"
  echo '        <ul class="text-sm space-y-1">'
  while IFS=$'\t' read -r pri id repo kind; do
    [ -n "$id" ] || continue
    : "$pri"
    any=1
    [ "$repo" = "-" ] || [ -z "$repo" ] && repo="?"
    line=$(desk_show_field "$id" title)
    [ -n "$line" ] || line="$id"
    printf '          <li><span class="font-medium">%s</span> <span class="badge badge-ghost badge-xs">%s</span> <span class="opacity-50 text-xs">%s</span><br><span class="opacity-70 text-xs">%s</span></li>\n' \
      "$(desk_title "$id")" "$(desk_esc <<<"$kind")" "$(desk_esc <<<"$repo")" "$(printf '%s' "$line" | desk_plain | desk_esc)"
  done
  [ "$any" -eq 0 ] && echo '          <li class="opacity-50">Nothing queued in this category.</li>'
  echo '        </ul>'
  echo '      </div></div>'
}

render_queue_lists() {
  echo '  <section id="sec-queue" class="mb-10">'
  echo '    <h2 class="text-lg font-semibold mb-3">9. Next queue tickets</h2>'
  if ! command -v tasks-axi >/dev/null 2>&1; then
    desk_section_gap "The backlog could not be read, so the ranked queue lists are unknown right now."
    echo '  </section>'
    return 0
  fi
  local rows
  rows=$(desk_queue_rows | sort -t"$(printf '\t')" -k1,1n)
  echo '    <div class="grid gap-4 md:grid-cols-2">'
  # Product ship: product repos, kind ship.
  printf '%s\n' "$rows" | awk -F'\t' -v R=" $DESK_PRODUCT_REPOS " '{if (index(R," "$3" ")>0 && $4=="ship") print}' | head -10 \
    | desk_top10_card "Top product ship" "Product changes, highest value first."
  # Product scout.
  printf '%s\n' "$rows" | awk -F'\t' -v R=" $DESK_PRODUCT_REPOS " '{if (index(R," "$3" ")>0 && $4=="scout") print}' | head -10 \
    | desk_top10_card "Top product scout" "Product investigation and audit, most-unblocking first."
  # Tooling.
  printf '%s\n' "$rows" | awk -F'\t' -v R=" $DESK_TOOLING_REPOS " '{if (index(R," "$3" ")>0) print}' | head -10 \
    | desk_top10_card "Top tooling" "Fleet-tooling work, highest leverage first."
  # Quick wins: highest priority across all repos regardless of category.
  printf '%s\n' "$rows" | head -10 \
    | desk_top10_card "Quick and cheap wins" "Highest value-to-effort across every repo."
  echo '    </div>'
  echo '  </section>'
}

# --- section 10: stats ------------------------------------------------------
# Ambient closing stats from durable local records: worker efficiency (landed vs
# spawned this window), oldest-unmerged-branch presence, and a per-repo landed
# breakdown from the completion ledger. Token burn is not recorded locally to
# this read-only builder, so it is named as a courtesy gap rather than invented.
render_stats() {
  echo '  <section id="sec-stats" class="mb-10">'
  echo '    <h2 class="text-lg font-semibold mb-3">10. Stats</h2>'
  echo '    <div class="grid gap-4 sm:grid-cols-2">'
  # Landed today by repo (reuses the ledger).
  if [ -f "$COMPLETIONS" ]; then
    local today total per
    today=$(date -d "@$NOW_EPOCH" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
    total=$(awk -F'\t' -v s="$today" '/^#/ {next} NF>=4 && $2 >= s {n++} END{print n+0}' "$COMPLETIONS")
    per=$(awk -F'\t' -v s="$today" '/^#/ {next} NF>=4 && $2 >= s {c[$4]++} END{for(r in c) print r" ("c[r]")"}' "$COMPLETIONS" | sort | tr '\n' ' ')
    printf '      <div class="card bg-base-200/60"><div class="card-body py-4 gap-1"><h3 class="font-medium text-sm">Landed today</h3><p class="text-2xl font-semibold">%s</p><p class="text-xs opacity-60">%s</p></div></div>\n' \
      "$total" "$(desk_esc <<<"${per:-none}")"
  else
    desk_section_gap "The completion record could not be read, so the landed-work stats are unknown."
  fi
  # Waiting to merge + oldest.
  local wait
  wait=0
  [ -n "$MERGEQ" ] && wait=$(printf '%s\n' "$MERGEQ" | grep -c .)
  printf '      <div class="card bg-base-200/60"><div class="card-body py-4 gap-1"><h3 class="font-medium text-sm">Waiting to merge</h3><p class="text-2xl font-semibold">%s</p><p class="text-xs opacity-60">finished branches not yet landed</p></div></div>\n' \
    "$wait"
  echo '    </div>'
  echo '    <p class="text-xs opacity-50 mt-3">Token burn this window is not recorded locally to this page, so it is not shown; ask for it in chat if you want a courtesy figure.</p>'
  echo '  </section>'
}

# --- sections 11 and 12: reference catch-up panels --------------------------
# Both are transcript-sourced by design (the sole deliberate exception to the
# never-scraped-chat rule). This read-only builder has NO cheap, reliable local
# source for the running session's own transcript: it is a plain script with no
# session identity, and the harness session logs live outside FM_HOME in an
# undocumented location that cannot be mapped to THIS captain-firstmate session
# safely. So both render as clearly-marked gaps, and a single needs-decision
# line (appended once at render time) names the exact source hook that would be
# needed to wire them. The other ten sections do not depend on this.
render_recent_questions() {
  echo '  <section id="sec-questions" class="mb-10">'
  echo '    <h2 class="text-lg font-semibold mb-3">11. Recent questions</h2>'
  desk_section_gap "Your recent questions and their short answers are not available: this page has no local transcript source to read them from. See the note below on wiring one."
  echo '  </section>'
}

render_recent_conversation() {
  echo '  <section id="sec-conversation" class="mb-10">'
  echo '    <h2 class="text-lg font-semibold mb-3">12. Recent conversation</h2>'
  desk_section_gap "The last ten exchanges are not available: this page has no local transcript source to read the live session from. This panel is transcript-sourced by design, so it needs a source hook the builder does not yet have. See the note below."
  echo '  </section>'
}

# render_transcript_note: the single visible note explaining WHY sections 11 and
# 12 are gaps and naming the exact source hook needed to wire them. Also drives
# the machine-readable needs-decision line appended to stderr in the entry point.
TRANSCRIPT_HOOK_NOTE='Sections 11 and 12 need a local transcript source hook: the running session must publish its own last-N captain/firstmate turns (and recent questions) to a file under this home, e.g. state/desk-transcript.jsonl, that the builder can read cheaply. Without such a hook the read-only builder has no safe way to identify and read THIS session'"'"'s transcript, so both panels stay gaps.'
render_transcript_note() {
  printf '  <div class="alert alert-info mb-8 text-sm block"><div><strong>About the two catch-up panels.</strong> %s</div></div>\n' \
    "$(desk_esc <<<"$TRANSCRIPT_HOOK_NOTE")"
}

# --- sticky KPI strip -------------------------------------------------------
# Pinned to the top on scroll (position: sticky) so the headline counts survive
# on a phone over the LAN. Carries the KPI counts and jump links to every
# section, calling out sections 11 and 12 as the spec requires. A count the
# projection could not supply is shown as a dash, never a confident zero.
render_sticky_strip() {
  local decisions decisions_st unmerged blockers held tokens
  decisions=$(desk_json '.decisions_open | length'); decisions_st=$?
  blockers=$(desk_json '[.in_flight[] | select(.state == "blocked" or .state == "failed")] | length')
  unmerged=0; [ -n "$MERGEQ" ] && unmerged=$(printf '%s\n' "$MERGEQ" | grep -c .)
  if [ "$TICKETS_OK" -eq 1 ]; then held=$TK_CAPTAIN; else held='&mdash;'; fi
  [ "$decisions_st" -eq 0 ] || decisions='&mdash;'
  # Active workers / free slots / ceiling from the host reading.
  local agents ceiling free
  agents=$(printf '%s' "$RES_LINE" | sed -n -E 's/.*live agents ([0-9]+).*/\1/p')
  ceiling=$(printf '%s' "$RES_LINE" | sed -n -E 's/.*recommended ceiling ([0-9]+).*/\1/p')
  if [ -n "$agents" ] && [ -n "$ceiling" ]; then
    free=$(( ceiling - agents )); [ "$free" -lt 0 ] && free=0
  else
    free='&mdash;'
  fi
  [ -n "$agents" ] || agents='&mdash;'
  [ -n "$ceiling" ] || ceiling='&mdash;'
  tokens='not tracked here'
  cat <<HTML
  <div class="sticky top-0 z-30 -mx-5 px-5 py-3 mb-8 bg-base-100/95 backdrop-blur border-b border-base-300">
    <div class="flex flex-wrap items-center gap-x-5 gap-y-1 text-sm">
      <span><strong class="text-warning">${decisions}</strong> need your word</span>
      <span><strong>${unmerged}</strong> ready to merge</span>
      <span><strong>${agents}</strong> working &middot; <strong>${free}</strong> free &middot; ceiling ${ceiling}</span>
      <span><strong class="text-error">${blockers}</strong> blocked or failed</span>
      <span><strong>${held}</strong> on hold by you</span>
      <span class="opacity-60">tokens: ${tokens}</span>
    </div>
    <nav class="flex flex-wrap gap-x-3 gap-y-1 text-xs mt-2 opacity-70">
      <a class="link link-hover" href="#sec-decisions">1 Decisions</a>
      <a class="link link-hover" href="#sec-blockers">2 Blockers</a>
      <a class="link link-hover" href="#sec-merge">3 Merge</a>
      <a class="link link-hover" href="#sec-slots">4 Slots</a>
      <a class="link link-hover" href="#sec-progress-3h">5 Last 3h</a>
      <a class="link link-hover" href="#sec-progress-12h">6 Last 12h</a>
      <a class="link link-hover" href="#sec-upcoming">7 Upcoming</a>
      <a class="link link-hover" href="#sec-held">8 Held</a>
      <a class="link link-hover" href="#sec-queue">9 Queue</a>
      <a class="link link-hover" href="#sec-stats">10 Stats</a>
      <a class="link link-hover font-medium text-warning" href="#sec-questions">11 Questions</a>
      <a class="link link-hover font-medium text-warning" href="#sec-conversation">12 Conversation</a>
    </nav>
  </div>
HTML
}

render_page() {
  cat <<'HTML'
<!DOCTYPE html>
<html lang="en" data-theme="luxury">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Captain's desk</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/daisyui@5.5.19/daisyui.css">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/daisyui@5.5.19/themes.css">
<script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4.2.4/dist/index.global.js"></script>
<style>
  *, *::before, *::after { box-sizing: border-box; }
  :where(.grid, .flex) > * { min-width: 0; }
  :where(p, h1, h2, h3, h4, h5, h6, li, dd, blockquote, td, th, .badge, .label) { overflow-wrap: anywhere; }
  :where(img, svg, video, canvas, iframe) { max-width: 100%; height: auto; }
  .card { border: 1px solid color-mix(in oklab, currentColor 12%, transparent); }
  .rail { border-left: 3px solid var(--rail, transparent); }
  .sticky { position: sticky; }
</style>
</head>
<body class="bg-base-100 text-base-content">
<div class="max-w-6xl mx-auto px-5 py-8">
HTML
  render_sticky_strip
  render_header
  render_gaps
  render_tickets
  render_decisions
  render_blockers
  render_ready_merge
  render_slots
  render_progress_3h
  render_progress_12h
  render_upcoming
  render_captain_held
  render_queue_lists
  render_stats
  render_transcript_note
  render_recent_questions
  render_recent_conversation
  cat <<'HTML'
  <footer class="text-xs opacity-50 pt-4 border-t border-base-300">
    This page shows the picture at the time above. Ask for a refresh to see the current one.
    Nothing is stopped automatically on a capacity reading.
  </footer>
</div>
</body>
</html>
HTML
}

# --- entry point ------------------------------------------------------------

case "${1:-}" in
  --path) printf '%s\n' "$OUT"; exit 0 ;;
  -h|--help) usage; exit 0 ;;
  '') ;;
  *) printf 'fm-desk-refresh: unknown argument: %s\n' "$1" >&2; usage >&2; exit 64 ;;
esac

OUT_DIR=$(dirname "$OUT")
if ! mkdir -p "$OUT_DIR" 2>/dev/null; then
  printf 'fm-desk-refresh: cannot create %s\n' "$OUT_DIR" >&2
  exit 1
fi

# Write to a temp path in the SAME directory, then move it into place, so a
# reload never catches a half-written page and the move stays on one filesystem.
TMP="$OUT_DIR/.$(basename "$OUT").tmp.$$"
if ! render_page > "$TMP" 2>/dev/null; then
  rm -f "$TMP"
  printf 'fm-desk-refresh: render failed\n' >&2
  exit 1
fi
if ! mv -f "$TMP" "$OUT" 2>/dev/null; then
  rm -f "$TMP"
  printf 'fm-desk-refresh: cannot write %s\n' "$OUT" >&2
  exit 1
fi

# Sections 11 and 12 have no local transcript source, so surface the exact hook
# firstmate would need to wire them as a machine-readable needs-decision line on
# STDOUT. This is NOT a status-file write and NOT a wake: it is one printed line
# on the manual invocation, so the NEVER WAKES invariant holds.
printf 'needs-decision: %s\n' "$TRANSCRIPT_HOOK_NOTE"
exit 0
