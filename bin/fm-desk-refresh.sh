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
#
# DEGRADE QUIETLY. Every source is optional. A missing, failing, or unparseable
# source is recorded as a gap, shown in the page, and the rest of the page is
# still rendered. The page is written to a temp path in the destination
# directory and moved into place, so a reload never catches a partial page.
#
# LANGUAGE. The page is captain-facing, so AGENTS.md section 9 applies in full.
# Free text lifted from fleet records is passed through desk_plain(), which
# rewrites internal vocabulary into the captain's nouns; DESK_TERMS below is the
# single owner of that mapping.
#
# Test seams: FM_DESK_OUT overrides the output path, FM_DESK_TIMEOUT bounds each
# source command, FM_DESK_NOW injects the rendered timestamp.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# The stable output path. The SAME file every refresh, never a dated one: an
# already-open browser tab must stay valid so the captain only reloads.
OUT="${FM_DESK_OUT:-$FM_HOME/.lavish/captain-desk.html}"

# Per-source wall-clock bound. The fleet projection is the only source that
# takes real time, and the desk must never be the reason a watcher cycle stalls.
DESK_TIMEOUT=${FM_DESK_TIMEOUT:-120}
case "$DESK_TIMEOUT" in ''|*[!0-9]*) DESK_TIMEOUT=120 ;; esac

# How much of each unbounded list the page shows before it stops being scannable.
DESK_MAX_PARKED=${FM_DESK_MAX_PARKED:-12}
DESK_MAX_LANDED=${FM_DESK_MAX_LANDED:-8}
DESK_MAX_DECISIONS=${FM_DESK_MAX_DECISIONS:-12}

# The header comment IS the help text: from the description line down to the
# last comment line before the first executable line.
usage() {
  sed -n '2,56p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

if [ "$HAVE_JQ" -eq 1 ]; then
  if BEAR=$(desk_bound "$SCRIPT_DIR/fm-bearings-snapshot.sh" --json 2>/dev/null) \
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

# desk_json: read one jq expression out of the fleet projection, or nothing when
# that projection is missing.
desk_json() {
  [ -n "$BEAR" ] || return 0
  printf '%s' "$BEAR" | jq -r "$1" 2>/dev/null || printf ''
}

# --- render -----------------------------------------------------------------
#
# Design source: DaisyUI 5 on the Tailwind browser runtime, matching the
# hand-built desk this replaces, so a captain who had the earlier page open
# recognizes the new one immediately.

render_header() {
  local running decisions unmerged summary
  running=$(desk_json '[.in_flight[] | select(.state != "done")] | length')
  decisions=$(desk_json '.decisions_open | length')
  unmerged=0
  [ -n "$MERGEQ" ] && unmerged=$(printf '%s\n' "$MERGEQ" | grep -c .)
  summary=""
  case "${decisions:-0}" in
    ''|0) summary="Nothing needs your word." ;;
    1) summary="One thing needs your word." ;;
    *) summary="${decisions} things need your word." ;;
  esac
  case "${running:-0}" in
    ''|0) summary="$summary Nothing is running." ;;
    1) summary="$summary One job is running." ;;
    *) summary="$summary ${running} jobs are running." ;;
  esac
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

render_decisions() {
  local rows
  rows=$(desk_json ".decisions_open[:${DESK_MAX_DECISIONS}][] | [.id, .summary, .owner] | @tsv")
  echo '  <section class="mb-10">'
  echo '    <h2 class="text-lg font-semibold mb-3">Needs your word</h2>'
  if [ -z "$rows" ]; then
    echo '    <p class="text-sm opacity-60">Nothing is waiting on you.</p>'
    echo '  </section>'
    return 0
  fi
  echo '    <div class="grid gap-4 md:grid-cols-2">'
  printf '%s\n' "$rows" | while IFS=$'\t' read -r id summary owner; do
    [ -n "$id" ] || continue
    cat <<HTML
      <div class="card bg-base-200 rail" style="--rail: oklch(0.75 0.16 70)">
        <div class="card-body gap-2">
          <div class="flex items-start justify-between gap-2">
            <h3 class="card-title text-base">$(desk_title "$id")</h3>
            <span class="badge badge-warning badge-sm shrink-0">your call</span>
          </div>
          <p class="text-sm opacity-80">$(desk_text "$summary")</p>
          <div class="text-xs opacity-50">$(desk_text "$owner")</div>
        </div>
      </div>
HTML
  done
  echo '    </div>'
  echo '  </section>'
}

render_running() {
  local rows
  rows=$(desk_json '[.in_flight[] | select(.state != "done")][] | [.id, .state, .doing] | @tsv')
  echo '  <section class="mb-10">'
  echo '    <h2 class="text-lg font-semibold mb-3">Running now</h2>'
  if [ -z "$rows" ]; then
    echo '    <p class="text-sm opacity-60">Nothing is running.</p>'
    echo '  </section>'
    return 0
  fi
  echo '    <div class="overflow-x-auto">'
  echo '      <table class="table table-sm">'
  echo '        <thead><tr class="text-xs uppercase tracking-wide opacity-60">'
  echo '          <th class="w-56">Work</th><th class="w-32">Standing</th><th>Where it stands</th>'
  echo '        </tr></thead>'
  echo '        <tbody>'
  printf '%s\n' "$rows" | while IFS=$'\t' read -r id state doing; do
    [ -n "$id" ] || continue
    cat <<HTML
          <tr>
            <td class="font-medium align-top">$(desk_title "$id")</td>
            <td class="align-top"><span class="badge $(desk_state_badge "$state") badge-sm">$(desk_text "$(desk_state "$state")")</span></td>
            <td class="text-sm opacity-80">$(desk_text "$doing")</td>
          </tr>
HTML
  done
  echo '        </tbody>'
  echo '      </table>'
  echo '    </div>'
  echo '  </section>'
}

render_parked() {
  local rows
  rows=$(desk_json "[.gates[] | select(.id | startswith(\"(\") | not)][:${DESK_MAX_PARKED}][] | [.id, .title, .reason, .blocked_by] | @tsv")
  echo '  <section class="mb-10">'
  echo '    <h2 class="text-lg font-semibold mb-3">Parked on purpose</h2>'
  if [ -z "$rows" ]; then
    echo '    <p class="text-sm opacity-60">Nothing is parked.</p>'
    echo '  </section>'
    return 0
  fi
  echo '    <div class="grid gap-3 md:grid-cols-2">'
  printf '%s\n' "$rows" | while IFS=$'\t' read -r id title reason blocked; do
    [ -n "$id" ] || continue
    # The projection uses "-" for an absent field; it is a placeholder, not
    # something to show the captain.
    local waiting=""
    [ "$reason" = "-" ] && reason=""
    [ -n "$blocked" ] && [ "$blocked" != "-" ] && waiting="Waiting on $(desk_title "$blocked")."
    cat <<HTML
      <div class="card bg-base-200/60">
        <div class="card-body py-4 gap-1">
          <h3 class="font-medium text-sm">$(desk_title "$id")</h3>
          <p class="text-sm opacity-70">$(desk_text "$title") $(desk_text "$reason")</p>
          <p class="text-xs opacity-50">${waiting}</p>
        </div>
      </div>
HTML
  done
  echo '    </div>'
  echo '  </section>'
}

render_finished() {
  local rows
  rows=$(desk_json ".landed[:${DESK_MAX_LANDED}][] | [.id, .what] | @tsv")
  echo '  <section class="mb-10">'
  echo '    <h2 class="text-lg font-semibold mb-3">Finished recently</h2>'
  if [ -z "$rows" ]; then
    echo '    <p class="text-sm opacity-60">Nothing has finished recently.</p>'
    echo '  </section>'
    return 0
  fi
  echo '    <ul class="space-y-2 text-sm">'
  printf '%s\n' "$rows" | while IFS=$'\t' read -r id what; do
    [ -n "$id" ] || continue
    cat <<HTML
      <li class="flex gap-3">
        <span class="badge badge-success badge-sm shrink-0 mt-0.5">closed</span>
        <span><strong>$(desk_title "$id")</strong> &mdash; $(desk_text "$what")</span>
      </li>
HTML
  done
  echo '    </ul>'
  echo '  </section>'
}

render_unmerged() {
  local count
  count=0
  [ -n "$MERGEQ" ] && count=$(printf '%s\n' "$MERGEQ" | grep -c .)
  echo '  <section class="mb-10">'
  if [ "${count:-0}" -eq 0 ]; then
    echo '    <h2 class="text-lg font-semibold mb-3">Finished but not merged</h2>'
    echo '    <p class="text-sm opacity-60">Nothing is waiting to merge.</p>'
    echo '  </section>'
    return 0
  fi
  cat <<HTML
    <h2 class="text-lg font-semibold mb-3 flex items-center gap-2">
      Finished but not merged
      <span class="badge badge-neutral badge-sm">${count}</span>
    </h2>
    <p class="text-sm opacity-70 mb-3">All pushed and safe. Batched for review whenever you want them.</p>
    <div class="grid gap-2 sm:grid-cols-2">
HTML
  printf '%s\n' "$MERGEQ" | while IFS=$'\t' read -r id project branch head base url; do
    [ -n "$id" ] || continue
    : "$project" "$branch" "$head" "$base"
    if [ -n "$url" ]; then
      printf '      <a class="link link-hover text-sm" href="%s">%s</a>\n' "$(desk_esc <<<"$url")" "$(desk_title "$id")"
    else
      printf '      <span class="text-sm opacity-70">%s</span>\n' "$(desk_title "$id")"
    fi
  done
  echo '    </div>'
  echo '  </section>'
}

render_machine() {
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

  echo '  <section class="mb-6">'
  echo '    <h2 class="text-lg font-semibold mb-3">The machine</h2>'
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
  echo '  </section>'
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
</style>
</head>
<body class="bg-base-100 text-base-content">
<div class="max-w-6xl mx-auto px-5 py-8">
HTML
  render_header
  render_gaps
  render_tickets
  render_decisions
  render_running
  render_parked
  render_finished
  render_unmerged
  render_machine
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
exit 0
