#!/usr/bin/env bash
# fm-desk-lib.sh - the captain's-desk data layer: the ONE owner of reading fleet
# state, translating internal vocabulary into the captain's nouns, and shaping it
# into a single normalized display model both desk boards render off.
#
# SOURCED ONLY, never executed. It matches the bin/*-lib.sh convention and, like
# every desk source, is READ-ONLY but for two owned throttle caches:
# desk_jcode_usage_cached writes only state/desk-jcode-usage.json and
# desk_token_cost_cached writes only state/desk-token-cost.json. Otherwise it
# writes nothing under state/, appends no status, and calls no wake path.
# Rendering a board is not captain-facing progress (AGENTS.md section 8), so
# nothing here interrupts anybody.
#
# WHY THIS EXISTS. The desk once interleaved three concerns in a single script:
# reading+bounding the sources, shaping+translating the data, and emitting the
# board. A second board that re-derived the first two concerns would silently
# drift from the first the moment either was edited - which field a section shows,
# how an absent source degrades to a gap, which words get rewritten. This library
# owns those first two concerns so there is exactly one owner of each (the
# one-owner rule in firstmate-coding-guidelines). Each board then owns only its
# own painting.
#
# THE THREE CONCERN GROUPS THIS LIBRARY OWNS
#   1. The vocabulary map + rewriters: DESK_TERMS, desk_plain, desk_text. Note
#      desk_text here stops at TRANSLATE and does NOT HTML-escape - escaping is
#      board-specific (a TUI must not emit &amp;), so each board escapes on its
#      own way out. The view model carries translated-but-raw strings.
#   2. The bounded source readers + gap policy: desk_bound, note_gap, the
#      away-first read order, the projection read with its away/read-failure
#      branch, the watcher-beat age read, desk_json with its 0/2/3 status
#      contract, and the plain-English gap sentences.
#   3. The single normalized view-model producer: desk_project. It runs the
#      bearings snapshot (FM_DESK_SNAPSHOT_BIN seam) + merge queue
#      (FM_DESK_MERGEQ_BIN seam) + away flag + watcher beat ONCE and emits one
#      stable JSON document, schema fm-desk.v1, carrying every field each section
#      needs - already bounded to DESK_MAX, already desk_text-translated, already
#      RANKED (the rows that matter first), carrying a per-section status
#      (ok / empty / gap / away), the collapse shape (total / shown / more /
#      more_hint under DESK_CAP) plus each section's honest full_total count, and
#      the header glance summary, counts, and the optional Claude usage line and
#      accounts block (every managed Claude account + which credential store
#      marks which). Both
#      boards read THIS document and
#      paint at most .shown rows; the HTML board shows .more_hint for the
#      collapsed tail, while the TUI paints no "+N more" line and folds full_total
#      into each section header instead (an accepted TUI/HTML paint divergence).
#      Neither board ranks, caps, or re-derives state in a paint function.
#
# Seams (shared with the HTML board): FM_DESK_SNAPSHOT_BIN overrides the fleet
# projection command, FM_DESK_MERGEQ_BIN overrides the merge-queue command,
# FM_DESK_CSWAP_BIN overrides the account-roster (cswap) command,
# FM_DESK_JCODE_USAGE_BIN overrides the account-usage (jcode) command and
# FM_DESK_JCODE_USAGE_CACHE its disk-cache path (throttled by
# FM_DESK_JCODE_USAGE_TTL; a reading at or above FM_DESK_JCODE_USAGE_AGE_FLOOR
# carries an "(Nm old)" age token), FM_DESK_NOW injects the timestamp, FM_DESK_TIMEOUT
# bounds each source, and FM_DESK_MAX bounds each list the lib reads, while
# FM_DESK_CAP bounds how many ranked rows a board paints before collapsing the
# tail (0 = no cap). A board sources this file, then calls desk_project to obtain
# the fm-desk.v1 document. A fixed-pane board (the TUI) then optionally re-shapes
# it with desk_fit to a PHYSICAL painted-line budget (FM_DESK_BUDGET), which is
# the ONE owner of per-row and per-chrome line cost. The TUI clips every painted
# line to its width, so one painted line is one physical row and the budget is a
# plain line count.

# --- resolved paths / knobs --------------------------------------------------
# A board that sources this may already have resolved these; only set what is
# unset so the sourcing board stays authoritative over its own home/paths.
FM_DESK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${FM_ROOT:=${FM_ROOT_OVERRIDE:-$(cd "$FM_DESK_LIB_DIR/.." && pwd)}}"
: "${FM_HOME:=${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
: "${STATE:=${FM_STATE_OVERRIDE:-$FM_HOME/state}}"
export FM_HOME

# Live per-crew state basis (DEFECT 1/2 root cause). A secondmate is "running"
# when it has a LIVE working child crew: a child task whose endpoint is alive AND
# whose current turn is busy - the same authoritative basis bin/fm-crew-state.sh
# uses - NOT merely the last word its status LOG happens to carry (a crew mid-work
# between status appends looks paused/done in the log while genuinely building).
# fm_busy_classify_live is that basis in one cheap, timeout-robust filesystem +
# endpoint read (per-task state/<id>.busy-state record, gen-checked, plus one
# bounded endpoint liveness probe), with NO no-mistakes call, so a full build
# night never stalls the desk. Sourced here so desk_secondmate_child_activity can
# read a child home's crews the same way the watcher does. READ-ONLY libraries.
# shellcheck source=bin/fm-backend.sh
. "$FM_DESK_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$FM_DESK_LIB_DIR/fm-busy-lib.sh"

# Per-source wall-clock bound. The fleet projection is the only slow source, and
# the desk must never be why a watcher cycle stalls.
DESK_TIMEOUT=${FM_DESK_TIMEOUT:-120}
case "$DESK_TIMEOUT" in ''|*[!0-9]*) DESK_TIMEOUT=120 ;; esac

# How much of each unbounded list a board shows before it stops being scannable.
DESK_MAX=${FM_DESK_MAX:-20}
case "$DESK_MAX" in ''|*[!0-9]*) DESK_MAX=20 ;; esac

# jcode-usage disk-cache floor, in seconds. WHY a disk cache: each `jcode usage
# --json` process starts COLD and makes one LIVE Anthropic usage-API call per
# account (always all 3 accounts: no single-account fetch exists). jcode's own
# 300s cache is in-process memory only, so calling it on the desk's ~30s repaint
# cadence would be a proactive-polling storm (~360 Anthropic calls/hour, enough
# to 429). This floor never lets the desk fetch fresher than the throttle allows.
# The 30s repaint reads the DISK cache many times per real fetch. WHY 120, not
# 300: 3 calls / 120s = ~90 Anthropic calls/hour fleet-wide, modest and far from
# the continuous per-account polling that 429'd a fork. It halves the worst-case
# stale window from ~5min to ~2min and keeps the storm-safety floor.
DESK_JCODE_USAGE_TTL=${FM_DESK_JCODE_USAGE_TTL:-120}
case "$DESK_JCODE_USAGE_TTL" in ''|*[!0-9]*) DESK_JCODE_USAGE_TTL=120 ;; esac

# jcode-usage age-marker floor, in seconds. WHY separate from the TTL: the cache
# REFRESHES at the TTL, so a reading is almost always 0..TTL old. Gating the
# "(Nm old)" token on the TTL meant it NEVER fired and a stale-but-under-TTL
# number posed as live, breaking the desk's honesty rule. This floor surfaces the
# age well below the TTL, so a mid-climb reading shows its age; a genuinely fresh
# (<floor) reading still stays clean. Floor MUST stay below the TTL by design.
DESK_JCODE_USAGE_AGE_FLOOR=${FM_DESK_JCODE_USAGE_AGE_FLOOR:-60}
case "$DESK_JCODE_USAGE_AGE_FLOOR" in ''|*[!0-9]*) DESK_JCODE_USAGE_AGE_FLOOR=60 ;; esac

# Per-section DISPLAY cap: how many ranked rows a board paints before collapsing
# the rest behind a "+N more" pointer. Distinct from DESK_MAX (which bounds what
# the lib reads): DESK_MAX is the working set, DESK_CAP is what fits a glance. 0
# means no cap (the HTML board, which has a scrollbar, shows every row).
DESK_CAP=${FM_DESK_CAP:-6}
case "$DESK_CAP" in *[!0-9]*) DESK_CAP=6 ;; esac

# The column budget for ONE composed account line, and the ONE owner of it. Every
# surface that paints an account row prepends its own chrome and then clips at the
# pane width, which falls back to 80 columns - the captain's SSH width. So the
# string this lib composes gets 80 minus the WIDEST chrome any surface adds, and
# the same already-safe string is then safe on all of them:
#
#   surface                                   chrome  clip
#   bash board (bin/fm-desk-tui.sh)           2  bullet          clip_frame
#   Rust static board (render.rs frame)       2  bullet          clip_line
#   Rust nav board (render.rs nav_frame)      4  gutter+bullet   clip_line
#   Rust switch overlay (render.rs            5  "  " + 3-col    clip_line
#     switch_frame, the 'w' key)                 number key
#
# 80 - 5 = 75. The switch overlay is the tightest because it reuses these exact
# lines behind its own pick-list key column. desk/src/render.rs mirrors this number
# as ACCOUNT_LINE_COLS for its own tests; tests/fm-desk-lib.test.sh asserts the two
# agree, so the budget and the chrome that justifies it cannot drift apart.
#
# The budget lives HERE, in the model, because every board must receive the SAME
# already-safe line: a board that trimmed on its own would drift from the others
# the moment either was edited - the duplicate-logic drift this file keeps fighting.
DESK_ACCOUNT_COLS=${FM_DESK_ACCOUNT_COLS:-75}
case "$DESK_ACCOUNT_COLS" in ''|*[!0-9]*) DESK_ACCOUNT_COLS=75 ;; esac

# token-cost disk-cache floor, in seconds. WHY a disk cache: the coster
# (bin/fm-token-report.sh) and the per-landed-ticket rollup
# (bin/fm-ticket-cost-rollup.sh) each scan the WHOLE jcode session store in a
# python pass (~2s per call on a store of a few hundred sessions). Calling them on
# the desk's ~30s repaint cadence would tax every repaint for a figure that barely
# moves between spawns. This floor lets the desk read a cached cost blob many times
# per real recompute, exactly like desk_jcode_usage_cached does for quota. WHY 900:
# cost accrues over a session's whole life and lands in the ledger at teardown, so
# a 15-minute staleness window is invisible to a glance and keeps the recompute off
# the repaint path. A reading at or above DESK_TOKEN_COST_AGE_FLOOR carries an
# "(Nm old)" age token so a stale blob is never painted as live.
DESK_TOKEN_COST_TTL=${FM_DESK_TOKEN_COST_TTL:-900}
case "$DESK_TOKEN_COST_TTL" in ''|*[!0-9]*) DESK_TOKEN_COST_TTL=900 ;; esac

# token-cost age-marker floor, in seconds. Separate from the TTL for the same
# reason as the jcode-usage floor: the cache refreshes AT the TTL, so a reading is
# almost always under it and a TTL-gated age token would never fire. This floor
# surfaces the age well below the TTL so a mid-window reading shows its age; a
# genuinely fresh (<floor) reading stays clean. MUST stay below the TTL.
DESK_TOKEN_COST_AGE_FLOOR=${FM_DESK_TOKEN_COST_AGE_FLOOR:-300}
case "$DESK_TOKEN_COST_AGE_FLOOR" in ''|*[!0-9]*) DESK_TOKEN_COST_AGE_FLOOR=300 ;; esac

# token-cost burn-rate window, in days. The header burn figure and the heaviest
# engines both read this trailing window so the glance reflects RECENT spend, not
# a fleet-lifetime total that never moves. The rollup's cost-per-landed-ticket is
# lifetime by default (its own window), because a landed ticket's cost is a fixed
# historical fact, not a rate.
DESK_TOKEN_COST_WINDOW_DAYS=${FM_DESK_TOKEN_COST_WINDOW_DAYS:-7}
case "$DESK_TOKEN_COST_WINDOW_DAYS" in ''|*[!0-9]*) DESK_TOKEN_COST_WINDOW_DAYS=7 ;; esac

# --- concern 1: internal-vocabulary translation ------------------------------
# AGENTS.md section 9 owns the rule; this table owns the mechanical rewrite for
# free text a board lifts out of fleet records. Longer forms come first so a
# plural or hyphenated form is not half-rewritten by its own singular.
DESK_TERMS=$(cat <<'TERMS'
[Cc]rewmates	workers
[Cc]rewmate	worker
[Ss]econdmate agents	second mates
[Ww]orktrees	local copies
[Ww]orktree	local copy
[Pp]rimary checkout	main local copy
[Cc]heckouts	local copies
[Cc]heckout	local copy
[Tt]eardown	cleanup
[Hh]eartbeats	routine checks
[Hh]eartbeat	routine check
[Ww]ake queue	notification queue
[Ww]akes	notifications
[Ss]tale	unresponsive
[Hh]arnesses	worker tools
[Hh]arness	worker tool
[Bb]riefs	instructions
[Bb]rief	instructions
fails? clos(e|ed|es)	stops safely
[Ff]ail-closed	stops safely
[Pp]ipelines	validation runs
[Pp]ipeline	validation
[Nn]o-mistakes	validation
needs-decision	waiting on your word
ask-user	your decision
TERMS
)
export DESK_TERMS

# DESK_XLATE_PRELUDE: the ONE owner of the vocabulary rewrite (AGENTS.md section 9
# owns the rule). desk_plain and _desk_tsv_translate both inject this so they can
# never drift. It translates PROSE but never a literal a human might copy: a term
# fires only outside a protected span. Without this guard the unanchored gsub
# rewrote command text - `no-mistakes --skip pr,ci` became `validation --skip
# pr,ci`, trading a copy-pastable command for a friendlier word (exactly what the
# captain's writing profile forbids: exactness beats a plain word).
#
# xlate(s): mask every literal-shaped span to a control-char sentinel, translate
# what remains, then restore each span verbatim. A sentinel is \001<idx>\001;
# \001 is neither [[:graph:]] nor [[:space:]], so it is a hard barrier no later
# mask pass or term pattern can cross. Protected, in order: a backticked span; a
# command head glued to its flag (`cmd --flag`); a residual flag; a path- or
# branch-shaped token (has `/`); and a comma-joined identifier list (`pr,ci`). A
# plain-prose `no-mistakes` with no flag, slash, or backtick still translates.
# shellcheck disable=SC2016  # awk program: $-refs are awk fields, not shell vars
DESK_XLATE_PRELUDE='
  BEGIN {
    SENT = "\001"
    n = split(ENVIRON["DESK_TERMS"], _lines, "\n")
    for (_i = 1; _i <= n; _i++) {
      if (_lines[_i] == "") continue
      split(_lines[_i], _kv, "\t")
      pat[_i] = _kv[1]; rep[_i] = _kv[2]
    }
  }
  function mask(s, re,   res, lit) {
    res = ""
    while (match(s, re)) {
      lit = substr(s, RSTART, RLENGTH)
      store[++store_n] = lit
      res = res substr(s, 1, RSTART - 1) SENT store_n SENT
      s = substr(s, RSTART + RLENGTH)
    }
    return res s
  }
  function unmask(s,   i, key, p) {
    for (i = store_n; i >= 1; i--) {
      key = SENT i SENT
      while ((p = index(s, key)) > 0)
        s = substr(s, 1, p - 1) store[i] substr(s, p + length(key))
    }
    return s
  }
  function xlate(s,   i) {
    delete store; store_n = 0
    s = mask(s, "`[^`]*`")
    s = mask(s, "[[:graph:]]+[[:space:]]+--[[:graph:]]+")
    s = mask(s, "--[[:graph:]]+")
    s = mask(s, "[[:graph:]]*/[[:graph:]]*")
    s = mask(s, "[[:alnum:]_]+(,[[:alnum:]_]+)+")
    for (i = 1; i <= n; i++) if (pat[i] != "") gsub(pat[i], rep[i], s)
    return unmask(s)
  }
'

# desk_plain: rewrite internal vocabulary in free text read from stdin.
desk_plain() {
  awk "$DESK_XLATE_PRELUDE"'
    { print xlate($0) }
  '
}

# desk_text: translate free text (TRANSLATE ONLY - no escaping). The view model
# carries translated-but-raw strings; each board applies its own escaping.
desk_text() {
  printf '%s' "$1" | desk_plain
}

# --- concern 2: bounded source readers + gap policy --------------------------
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

# Gaps accumulate as one plain-English line each so a missing source is visible
# rather than silently rendering as "nothing".
DESK_GAPS=""
note_gap() { DESK_GAPS="${DESK_GAPS}${1}
"; }

# desk_json: read one jq expression out of the fleet projection in DESK_BEAR.
#   0  the query ran; stdout is the result (may legitimately be empty)
#   2  the fleet projection is absent (a global gap is already recorded)
#   3  the query failed against present data (a section-level gap is due)
# Shared jq prelude for every projection read. z stringifies non-scalars.
# bclass is the ONE owner of the status->bullet CLASS map (the glyph/color are
# paint, in each board): one of blocked/waiting/running/done/idle, per section.
# stripkind drops a redundant leading kind label ("ship:", "scout:", "ship+nm:")
# from a headline - the section and bullet already carry that, so it is noise.
# shellcheck disable=SC2016  # jq program: $-refs are jq params, not shell vars
DESK_JQ_PRELUDE='def z: if (type == "array" or type == "object") then tostring else . end;
def bclass($sec; $state; $verb):
  if $sec == "under_way" or $sec == "secondmates" then
    (if ($state == "blocked" or $state == "failed" or $state == "attention") then "blocked"
     elif ($state == "working" or $state == "active_child_work" or $state == "running") then "running"
     elif ($state == "captain_decision" or $state == "paused" or $verb == "needs-decision") then "waiting"
     else "idle" end)
  elif $sec == "captains_call" then "waiting"
  elif $sec == "charted" then "idle"
  elif $sec == "landed" or $sec == "merge" then "done"
  else "idle" end;
def stripkind: gsub("^(ship\\+nm|ship|scout|build|fix)(\\+nm)?:[[:space:]]*"; "");'
desk_json() {
  [ -n "$DESK_BEAR" ] || return 2
  local out st
  out=$(printf '%s' "$DESK_BEAR" | jq -r "$DESK_JQ_PRELUDE $1" 2>/dev/null)
  st=$?
  printf '%s' "$out"
  [ "$st" -eq 0 ] || return 3
  return 0
}

# The plain-English gap sentences (no board markup), each with exactly one owner
# here so the model builder and any jq-free board fallback cannot drift. The
# away-mode substitute replaces every fleet-section sentence when the projection
# is absent because away mode is active.
DESK_SENT_CAPTAINS="The list of decisions waiting on you could not be read, so this panel is unknown right now."
DESK_SENT_UNDER="Work under way could not be read right now."
DESK_SENT_CHARTED="The charted and queued work could not be read right now."
DESK_SENT_LANDED="Recently landed work could not be read right now."
DESK_SENT_SECOND="Second-mate state could not be read right now."
DESK_SENT_AWAY_SECTION="This is unavailable while away mode is active; fleet state is not read until you return."

# The whole-page gap-banner sentences a missing source records.
DESK_GAP_NO_JQ="Fleet records could not be read on this machine (jq is missing), so work under way, decisions, and finished work are missing."
DESK_GAP_AWAY="Fleet state is not read while away mode is active, so work under way, decisions, and finished work are unavailable until you return."
DESK_GAP_UNREAD="Current fleet state could not be read just now, so work under way, decisions, and finished work are missing from this page."
DESK_GAP_MERGEQ="The list of finished-but-unmerged work could not be read, so that section may be incomplete."
DESK_GAP_QUOTA="Your Claude session usage could not be read just now, so the usage line is unavailable on this page."
DESK_GAP_ACCOUNTS="Your Claude accounts could not be read just now, so the account list is unavailable on this page."
DESK_GAP_TOKEN_COST="The token-cost figures could not be read just now, so the spend panel is unavailable on this page."

# The header summary sentences for the projection-absent cases.
DESK_SUMMARY_AWAY="You are marked away; fleet state is not read while away mode is active."
DESK_SUMMARY_UNREAD="Current fleet state could not be read, so this summary is incomplete."

# desk_section_sentence resolves the away-mode substitution for a fleet section.
desk_section_sentence() {
  if [ "${DESK_AWAY:-0}" -eq 1 ] && [ -z "$DESK_BEAR" ]; then
    printf '%s' "$DESK_SENT_AWAY_SECTION"
  else
    printf '%s' "$1"
  fi
}

# --- concern 2b: second-mate live reads (context usage + idle) ---------------
# Tier-2 facts the fm-desk.v1 model carries so the MODEL, not any board, stays
# the schema owner (build plan tier 2). Both are cheap LOCAL file reads, never a
# reprojection: current context usage and idle time per registered second mate,
# sourced from that home's most-recently-active jcode session file. READ-ONLY.
#
# Sessions dir is large (~151MB, files up to ~1.8MB), so this never slurps every
# file: grep -lF prefilters to only the files that mention a target home (a
# streaming, low-memory scan), and jq parses ONLY those few matches, with the
# working_dir re-checked exactly so a text-body false positive is dropped.
# A missing or unreadable session yields an "unknown" entry (null figures),
# never a crash and never a hidden second mate.
: "${FM_DESK_SESSIONS_DIR:=$HOME/.jcode/sessions}"

# _desk_secondmate_homes: emit "<id>\t<home>" for each registered second mate,
# parsed from data/secondmates.md ("- <id> - ... (home: <path>; ...)"). Empty
# when the file is absent.
_desk_secondmate_homes() {
  local f="$FM_HOME/data/secondmates.md"
  [ -r "$f" ] || return 0
  sed -n 's/^- \([^ ]*\) .*(home: \([^;)]*\).*/\1\t\2/p' "$f" \
    | sed 's/[[:space:]]*$//'
}

# desk_secondmate_usage: emit a JSON object keyed by second-mate id, each value
# { context_tokens, idle_seconds, session_id, context_source }. A home with no
# readable session maps to nulls + "unknown". Requires jq.
desk_secondmate_usage() {
  local homes now_epoch
  homes=$(_desk_secondmate_homes)
  # Reference "now" for idle: honor FM_DESK_NOW (the same pinned clock the rest
  # of the model uses) so idle is reproducible in tests, else the wall clock.
  now_epoch=$(date -d "${FM_DESK_NOW:-now}" +%s 2>/dev/null || date +%s)
  [ -n "$homes" ] || { printf '{}'; return 0; }

  # Per-mate activity floor from the mate's OWN status file mtime (DEFECT 3).
  # A long-lived jcode session does NOT rewrite its session JSON every turn, so
  # both updated_at and the session-file mtime freeze while the agent works - an
  # actively-building mate then reads a huge idle. The mate's status stream is an
  # independent real-write signal (a routed reply, a mirrored child line), so its
  # mtime is folded in as another activity source below. Not sufficient alone
  # (the mate may build quietly for a while too), which is why the working-mate
  # idle suppression in desk_project is the decisive half of this fix.
  local statmt="" tabm mid sfile smt
  tabm=$(printf '\t')
  while IFS=$'\t' read -r mid _mhome; do
    [ -n "$mid" ] || continue
    sfile="$STATE/$mid.status"
    smt=$(date -r "$sfile" +%s 2>/dev/null || stat -c %Y "$sfile" 2>/dev/null || true)
    [ -n "$smt" ] || smt=0
    statmt="${statmt}${mid}${tabm}${smt}
"
  done <<EOF
$homes
EOF

  # Prefilter: find session files that mention any target home (streaming grep,
  # no whole-file load). Without a match list we emit unknown for every home.
  local -a pats=() files=()
  local home
  while IFS=$'\t' read -r _id home; do
    [ -n "$home" ] && pats+=(-e "$home")
  done <<EOF
$homes
EOF
  if [ "${#pats[@]}" -gt 0 ] && [ -d "$FM_DESK_SESSIONS_DIR" ]; then
    local matchlist
    matchlist=$(grep -lF "${pats[@]}" "$FM_DESK_SESSIONS_DIR"/session_*.json 2>/dev/null || true)
    if [ -n "$matchlist" ]; then
      while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done <<EOF
$matchlist
EOF
    fi
  fi

  # Per matched file, extract one compact record: working_dir, both activity
  # timestamps (updated_at and last_active_at, kept separate), and the last
  # token_usage sum. jq touches only the prefiltered files, not the whole dir.
  local records="" tab
  tab=$(printf '\t')
  local wd upd la ctx sid act line fpath rest
  for fpath in "${files[@]}"; do
    line=$(jq -r '
      (.working_dir // "") as $wd
      | ([.messages[]?.token_usage // empty] | last) as $tu
      | (if $tu == null then ""
         else (( ($tu.cache_read_input_tokens // 0)
               + ($tu.input_tokens // 0)
               + ($tu.output_tokens // 0) ) | tostring) end) as $ctx
      | [$wd, (.updated_at // ""), (.last_active_at // ""), $ctx, (.id // "")] | @tsv
    ' "$fpath" 2>/dev/null) || continue
    [ -n "$line" ] || continue
    wd=${line%%"$tab"*}; rest=${line#*"$tab"}
    upd=${rest%%"$tab"*}; rest=${rest#*"$tab"}
    la=${rest%%"$tab"*}; rest=${rest#*"$tab"}
    ctx=${rest%%"$tab"*}; sid=${rest#*"$tab"}
    [ -n "$wd" ] || continue
    # Activity epoch: measure REAL freshness, not session-start time.
    # last_active_at is frozen at session start, so an actively-working agent
    # would look idle for its whole session if we trusted it. Derive activity
    # from max(updated_at, file mtime) - both track real writes - and keep
    # last_active_at ONLY as a last-resort fallback when neither is readable.
    local upd_e="" mtime_e=""
    [ -n "$upd" ] && upd_e=$(date -d "$upd" +%s 2>/dev/null || true)
    mtime_e=$(date -r "$fpath" +%s 2>/dev/null || stat -c %Y "$fpath" 2>/dev/null || true)
    act=""
    if [ -n "$upd_e" ] || [ -n "$mtime_e" ]; then
      act=$upd_e
      if [ -z "$act" ] || { [ -n "$mtime_e" ] && [ "$mtime_e" -gt "$act" ]; }; then
        act=$mtime_e
      fi
    fi
    if [ -z "$act" ] && [ -n "$la" ]; then
      act=$(date -d "$la" +%s 2>/dev/null || true)
    fi
    [ -n "$act" ] || act=0
    records="${records}${wd}${tab}${act}${tab}${ctx}${tab}${sid}
"
  done

  # Fold: for each registered id/home, pick the record whose working_dir matches
  # that home with the newest activity, compute idle from now, and emit an
  # "unknown" entry (null figures) when no session matched that home.
  jq -Rn \
    --argjson now "$now_epoch" \
    --arg homes "$homes" \
    --arg statmt "$statmt" \
    --arg records "$records" '
    ($records | split("\n") | map(select(length > 0) | split("\t"))
      | map({wd: .[0], act: (.[1] | tonumber? // 0),
             ctx: (if (.[2] // "") == "" then null else (.[2] | tonumber? // null) end),
             sid: .[3]})) as $recs
    | ($statmt | split("\n") | map(select(length > 0) | split("\t"))
        | reduce .[] as $s ({}; .[$s[0]] = ($s[1] | tonumber? // 0))) as $smt
    | reduce ($homes | split("\n")[] | select(length > 0)) as $h ({};
        ($h | split("\t")) as $c
        | $c[0] as $id | ($c[1] // "") as $home
        | ([ $recs[] | select(.wd == $home) ] | sort_by(.act) | last) as $r
        | (($smt[$id] // 0)) as $mstat
        | ([ (if $r == null then 0 else $r.act end), $mstat ] | max) as $act
        | .[$id] = (if $r == null
            then {context_tokens: null,
                  idle_seconds: (if $act > 0 then ([$now - $act, 0] | max) else null end),
                  session_id: null, context_source: "unknown"}
            else {context_tokens: $r.ctx,
                  idle_seconds: (if $act > 0 then ([$now - $act, 0] | max) else null end),
                  session_id: $r.sid,
                  context_source: (if $r.ctx == null then "unknown" else "session" end)}
          end))
  '
}

# desk_secondmate_child_activity: emit a JSON object keyed by second-mate id, each
# value { child_running, home_read, children }. This is the cheap, timeout-ROBUST cross-tree
# running signal DEFECT 1 needs: the structured home snapshot (bearings) routinely
# times out under a full build night, so its active_children count reads empty even
# when a mate has crews building.
#
# The count is keyed on LIVE per-crew state, NOT the trailing word of a crew's
# status LOG. A status log is an append-only EVENT log: a crew mid-work between
# appends (exactly like a crew that appended `paused:`/`done:` earlier and then
# resumed, or one that has not appended since it started) carries a stale last
# word while its endpoint is genuinely busy. So for each readable LOCAL home we
# read each child task's AUTHORITATIVE current busy verdict the same way
# bin/fm-crew-state.sh does - fm_busy_classify_live: the endpoint must be alive
# AND the recorded turn state busy - and count the crews that verdict proves are
# working. This is filesystem + one bounded endpoint probe per task, no LLM, no
# no-mistakes call, no projection. A kind=secondmate child (a nested mate, not a
# building crew) is skipped so a mate is never counted as its own running work.
# A remote or unreadable home reports child_running 0 with home_read false, so the
# caller can fall back to that mate's bearings active-child row. READ-ONLY.
desk_secondmate_child_activity() {
  local homes
  homes=$(_desk_secondmate_homes)
  [ -n "$homes" ] || { printf '{}'; return 0; }
  local id home running read_ok m cid backend target harness kind verdict pairs="" kids="" tab
  tab=$(printf '\t')
  while IFS=$'\t' read -r id home; do
    [ -n "$id" ] || continue
    running=0
    read_ok=0
    if [ -n "$home" ] && [ -d "$home/state" ]; then
      read_ok=1
      for m in "$home"/state/*.meta; do
        [ -e "$m" ] || continue
        cid=${m##*/}; cid=${cid%.meta}
        kind=$(fm_meta_get "$m" kind)
        [ "$kind" = secondmate ] && continue
        backend=$(fm_backend_of_meta "$m")
        target=$(fm_backend_target_of_meta "$m")
        harness=$(fm_meta_get "$m" harness)
        [ -n "$target" ] || continue
        verdict=$(FM_HOME="$home" fm_busy_classify_live \
          "$backend" "$target" "$harness" "$cid" "$home/state" "fm-$cid" 2>/dev/null)
        # Only a provably-busy child counts and gets surfaced as a task under way.
        # Carry its id + kind (never free-text status - DEFECT A: a status headline
        # can be an internal diagnostic; a kind-derived verb is safe and terse).
        case "${verdict%% *}" in busy)
          running=$((running + 1))
          kids="${kids}${id}${tab}${cid}${tab}${kind}
"
        ;; esac
      done
    fi
    pairs="${pairs}${id}${tab}${running}${tab}${read_ok}
"
  done <<EOF
$homes
EOF
  # Fold the per-mate running count + read flag with the busy-child list, keyed by
  # mate id, so the caller reads one object. children[] is the fs-verified live work
  # the desk surfaces in Under Way; child_running is its length for a readable home.
  jq -n --arg pairs "$pairs" --arg kids "$kids" '
    ( [ ($kids | split("\n")[] | select(length > 0) | split("\t"))
        | {mate:.[0], id:.[1], kind:.[2]} ]
      | group_by(.mate)
      | map({key:.[0].mate, value:[ .[] | {id, kind} ]})
      | from_entries ) as $childmap
    | reduce ($pairs | split("\n")[] | select(length > 0) | split("\t")) as $p ({};
        .[$p[0]] = {child_running: ($p[1] | tonumber? // 0),
                    home_read: (($p[2] // "0") == "1"),
                    children: ($childmap[$p[0]] // [])})'
}

# desk_main_live_running_ids: emit a JSON array of THIS home's own direct-report
# task ids whose endpoint is LIVE busy right now. DEFECT 2 (a separate path from
# MR !30): the header running count keyed on `.in_flight[].state`, which is
# fm-crew-state.sh's verdict, so a live crew the projection does not carry as a
# running row dropped out of the count and the header read "Nothing is running".
# MR !30 fixed only the secondmate CHILD-tree count (desk_secondmate_child_activity);
# the main home's own crews were never on that path. This is the same cheap,
# timeout-robust fs + one-probe live basis, applied to the main home's own tasks.
# The consumer in desk_project decides which live ids may count: a task whose
# crew-state is `done` (its run terminally passed) is a departed Under Way row and
# is never counted, even while its pane keeps working on follow-up, so the header
# and the section agree. A kind=secondmate meta is skipped (a mate is not a
# running job; its child tree is counted separately). READ-ONLY.
desk_main_live_running_ids() {
  [ -d "$STATE" ] || { printf '[]'; return 0; }
  local m cid backend target harness kind verdict ids=""
  for m in "$STATE"/*.meta; do
    [ -e "$m" ] || continue
    cid=${m##*/}; cid=${cid%.meta}
    kind=$(fm_meta_get "$m" kind)
    [ "$kind" = secondmate ] && continue
    backend=$(fm_backend_of_meta "$m")
    target=$(fm_backend_target_of_meta "$m")
    harness=$(fm_meta_get "$m" harness)
    [ -n "$target" ] || continue
    verdict=$(fm_busy_classify_live \
      "$backend" "$target" "$harness" "$cid" "$STATE" "fm-$cid" 2>/dev/null)
    case "${verdict%% *}" in busy) ids="${ids}${cid}
" ;; esac
  done
  printf '%s' "$ids" | jq -R -s '[ split("\n")[] | select(length > 0) ]'
}

# desk_jcode_usage_cached: return the fleet's LIVE per-account usage from the
# jcode plane (`jcode usage --json`), read through a desk-owned DISK cache at
# state/desk-jcode-usage.json. This is the source for BOTH the header usage line
# and the per-account 5h/7d numbers, replacing the two Claude-Code-plane sources
# (quota-axi, cswap .usage) the fleet no longer runs on.
#
# WHY the jcode plane, not Claude Code: the fleet runs 100% on ~/.jcode/auth.json,
# while cswap/quota-axi read ~/.claude/.credentials.json. cswap only refreshes the
# account IT last activated, so inactive accounts froze and the desk painted stale
# numbers as live. `jcode usage --json` returns ALL accounts every call.
#
# WHY the disk cache: each invocation makes one LIVE Anthropic usage-API call per
# account and jcode's 300s TTL is in-process only, so a one-shot CLI always starts
# cold. Re-invoking on the ~30s repaint cadence is a polling storm. So we re-fetch
# ONLY when the cache file is older than DESK_JCODE_USAGE_TTL; otherwise we reuse
# it. The write is atomic (temp + rename) and jq-guarded; a slow/absent/failing
# jcode is bounded by desk_bound. A stale-but-readable cache is USED (a known-age
# number beats a gap), and its age is surfaced by the caller.
#
# Output on success: the cache age in whole seconds on the FIRST line, then the
# cached providers[] JSON on the following lines. Any hard failure (no jq, no
# usable cache and no live fetch) prints nothing and returns 1, so the caller
# shows the existing GAP line. READ-ONLY except for the single cache file it owns.
desk_jcode_usage_cached() {
  command -v jq >/dev/null 2>&1 || return 1
  local cache bin now_epoch mtime fetched_at age fa_age raw
  cache="${FM_DESK_JCODE_USAGE_CACHE:-$FM_HOME/state/desk-jcode-usage.json}"
  bin="${FM_DESK_JCODE_USAGE_BIN:-jcode}"
  now_epoch=$(date -d "${FM_DESK_NOW:-now}" +%s 2>/dev/null || date +%s)

  # Cache age by mtime (primary), an empty age when the file is absent. Also read
  # the embedded fetched_at: mtime is unavailable when stat fails, and implausible
  # when a copy without -t resets it newer. In both cases fetched_at is the honest
  # floor on the reading's age, so we take the OLDER of the two below - a stale
  # reading must never paint younger than when it was fetched.
  mtime=""
  fetched_at=""
  if [ -f "$cache" ]; then
    mtime=$(date -r "$cache" +%s 2>/dev/null \
      || stat -c %Y "$cache" 2>/dev/null \
      || stat -f %m "$cache" 2>/dev/null || printf '')
    case "$mtime" in ''|*[!0-9]*) mtime="" ;; esac
    fetched_at=$(jq -r '.fetched_at // empty' "$cache" 2>/dev/null)
    case "$fetched_at" in ''|*[!0-9]*) fetched_at="" ;; esac
  fi
  age=""
  if [ -n "$mtime" ]; then
    age=$((now_epoch - mtime)); [ "$age" -lt 0 ] && age=0
  fi
  if [ -n "$fetched_at" ]; then
    fa_age=$((now_epoch - fetched_at)); [ "$fa_age" -lt 0 ] && fa_age=0
    if [ -z "$age" ] || [ "$fa_age" -gt "$age" ]; then age=$fa_age; fi
  fi

  # A cache is FRESH when it exists, is valid JSON, and is younger than the TTL.
  local fresh=false
  if [ -n "$age" ] && [ "$age" -lt "$DESK_JCODE_USAGE_TTL" ] \
    && jq -e . "$cache" >/dev/null 2>&1; then
    fresh=true
  fi

  # Re-fetch only when the cache is stale, absent, or corrupt. A failed fetch is
  # NOT fatal on its own: a stale-but-readable cache is still used below.
  if [ "$fresh" != true ] && command -v "$bin" >/dev/null 2>&1; then
    raw=$(desk_bound "$bin" usage --json 2>/dev/null)
    if [ -n "$raw" ] && printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
      local dir tmp prev
      dir=$(dirname "$cache")
      # Prior cache (may be absent/corrupt -> null) supplies LAST-KNOWN-GOOD window
      # readings for any provider whose fresh fetch errored or returned empty limits.
      # WHY: a provider under load - usually the ACTIVE account - can 429, and jcode
      # then yields EMPTY limits for it. Painting that as blank LOSES a number the
      # desk already knows. So an errored/empty provider INHERITS the matching prior
      # provider's limits plus their ORIGINAL per-provider fetched_at, and the age
      # token mechanism paints the inherited number AS stale ("(Nm old)") - never as
      # live. A provider with NO prior good reading still shows nothing (never a
      # fabricated number). Inheritance chains safely: a prior inherited provider
      # already carries the true original fetched_at, so the age keeps growing.
      prev=null
      if [ -f "$cache" ] && jq -e 'type == "object"' "$cache" >/dev/null 2>&1; then
        prev=$(cat "$cache")
      fi
      if mkdir -p "$dir" 2>/dev/null; then
        tmp="$dir/.$(basename "$cache").tmp.$$"
        # Stamp each provider with a per-provider fetched_at: now for a fresh good
        # reading, the inherited original for an errored/empty one that inherits.
        # The top-level fetched_at still marks THIS write (the throttle/age source).
        # Providers are keyed by the STABLE animal alias in provider_name (the ✦
        # active marker moves between accounts, so the whole name is not a stable
        # key). A prior provider is eligible to lend its reading only when it HAD
        # real limits, so an empty-inheriting-empty case correctly shows nothing.
        if printf '%s' "$raw" \
          | jq --argjson t "$now_epoch" --argjson prev "$prev" '
              def alias_of: (.provider_name // "") | (capture("Anthropic - (?<a>[^ ]+)").a // "");
              ($prev // {}) as $p
              | ($p.fetched_at // null) as $pbf
              | ( [ (($p.providers // [])[]
                     | select((.limits // []) | length > 0)
                     | select((. | alias_of) != "")
                     | { key: (. | alias_of),
                         value: { limits: .limits, fetched_at: (.fetched_at // $pbf) } }) ]
                  | from_entries ) as $prior
              | .providers = [ .providers[]?
                  | (. | alias_of) as $a
                  | if ((.limits // []) | length) > 0
                    then . + { fetched_at: $t }
                    else ($prior[$a] // null) as $inh
                      | if $inh != null and ($inh.fetched_at != null)
                        then . + { limits: $inh.limits, fetched_at: $inh.fetched_at }
                        else .
                        end
                    end ]
              | . + { fetched_at: $t }' > "$tmp" 2>/dev/null \
          && mv -f "$tmp" "$cache" 2>/dev/null; then
          age=0
        else
          rm -f "$tmp" 2>/dev/null
        fi
      fi
    fi
  fi

  # Emit whatever readable cache we now hold (fresh, just-written, or stale). Only
  # a genuinely unusable cache (absent or corrupt) is a hard failure -> the gap.
  # Age leads so a caller reads it with one `head -1` without parsing the JSON.
  jq -e . "$cache" >/dev/null 2>&1 || return 1
  printf '%s\n' "${age:-0}"
  cat "$cache"
}

# --- the reset-time vocabulary, shared by BOTH usage renderers ---------------
# ONE owner for "when does this window reset", used by desk_claude_usage (the
# header's active-account line) and desk_claude_accounts (the per-account lines).
# These two renderers each carried a byte-identical private copy, which is how a
# rule fixed on one line stayed broken on the other; there is one copy now.
#
# now_epoch is read from the CALLING renderer's local of that name (both set it
# from FM_DESK_NOW at entry), so a call site reads exactly as it did when the
# helper was nested inside it. An unset or non-numeric now_epoch yields "" - no
# reset rather than an invented one - so a future caller that forgot to set it
# cannot fabricate a horizon out of a raw epoch.
#
# _desk_reset_in: a terse "Nm"/"Nh"/"Nd" until an ISO resets_at, or "" when it is
# absent or unparseable. It keeps the clamp on a past instant, so callers that
# want the honest "already rolled over" answer ask _desk_reset_passed.
_desk_reset_in() {
  local iso=$1 e d
  [ -n "$iso" ] && [ "$iso" != null ] || { printf ''; return; }
  case "${now_epoch:-}" in ''|*[!0-9]*) printf ''; return ;; esac
  e=$(date -d "$iso" +%s 2>/dev/null) || { printf ''; return; }
  d=$((e - now_epoch)); [ "$d" -lt 0 ] && d=0
  if [ "$d" -lt 3600 ]; then printf '%dm' $((d / 60))
  elif [ "$d" -lt 86400 ]; then printf '%dh' $((d / 3600))
  else printf '%dd' $((d / 86400)); fi
}

# _desk_reset_passed: true when an ISO resets_at lies strictly BEFORE now, so a
# window that has ALREADY rolled over is distinguishable from one resetting
# within the minute - _desk_reset_in renders both as "0m". An absent or
# unparseable instant reads false: unknown is not passed.
_desk_reset_passed() {
  local iso=$1 e
  [ -n "$iso" ] && [ "$iso" != null ] || return 1
  case "${now_epoch:-}" in ''|*[!0-9]*) return 1 ;; esac
  e=$(date -d "$iso" +%s 2>/dev/null) || return 1
  case "$e" in ''|*[!0-9-]*) return 1 ;; esac
  [ "$e" -lt "$now_epoch" ]
}

# desk_claude_usage: emit the compact usage line for the header, for the ACTIVE
# account (ITEM 4). The captain wants his session usage on the desk. The source is
# the jcode plane the fleet runs on: `jcode usage --json`, read through the
# desk-owned disk cache (desk_jcode_usage_cached). The active account is the
# provider whose provider_name carries the ✦ marker; its "5-hour window" and
# "7-day window" limits carry usage_percent + resets_at.
#
# WHY the jcode plane, not quota-axi: quota-axi reads ~/.claude/.credentials.json,
# but the fleet runs 100% on ~/.jcode/auth.json, so quota-axi froze on whatever
# account it last saw. See desk_jcode_usage_cached for the plane + throttle WHY.
#
# WHY here, in the MODEL: gathering it in the lib means BOTH boards render the
# same line off state/desk-model.json, and the Rust crate stays file-driven - it
# never shells out on its interactive path (the load-bearing design point).
#
# Args: $1 the cached jcode providers JSON, $2 its age in seconds. The line ages
# from the OLDER of that blob age and the active provider's own fetched_at (an
# inherited last-known-good reading keeps its original fetch time); at or above
# the age floor a terse "(Nm old)" token trails the line so a stale reading is
# never painted as live (the desk's honesty rule). Returns empty (exit 2) when the
# active account carries no usable window; the caller treats that as "nothing to
# show", NOT a gap. Exit 1 only when the cache itself is missing (a real gap).
#
# Output: a JSON object { line, session:{...}, week:{...} } on success. The
# one-line form is "session Np (resets Nh) · week Mp (resets Md) (Xm old)".
desk_claude_usage() {
  command -v jq >/dev/null 2>&1 || return 1
  local raw="$1" age="${2:-0}" now_epoch
  [ -n "$raw" ] || return 1
  printf '%s' "$raw" | jq -e . >/dev/null 2>&1 || return 1
  now_epoch=$(date -d "${FM_DESK_NOW:-now}" +%s 2>/dev/null || date +%s)
  # The active provider carries the ✦ marker in provider_name; read its two named
  # limits by name. Only limits with a real usage_percent are shown.
  local sess_p sess_reset week_p week_reset
  sess_p=$(printf '%s' "$raw" | jq -r '(.providers[]? | select((.provider_name // "") | test("✦")) | .limits[]? | select(.name=="5-hour window") | .usage_percent) // empty' 2>/dev/null | head -1)
  sess_reset=$(printf '%s' "$raw" | jq -r '(.providers[]? | select((.provider_name // "") | test("✦")) | .limits[]? | select(.name=="5-hour window") | .resets_at) // empty' 2>/dev/null | head -1)
  week_p=$(printf '%s' "$raw" | jq -r '(.providers[]? | select((.provider_name // "") | test("✦")) | .limits[]? | select(.name=="7-day window") | .usage_percent) // empty' 2>/dev/null | head -1)
  week_reset=$(printf '%s' "$raw" | jq -r '(.providers[]? | select((.provider_name // "") | test("✦")) | .limits[]? | select(.name=="7-day window") | .resets_at) // empty' 2>/dev/null | head -1)
  # Percentages are integers on the board (no decimals bloat a tight line).
  [ -n "$sess_p" ] && sess_p=$(printf '%.0f' "$sess_p" 2>/dev/null || printf '%s' "$sess_p")
  [ -n "$week_p" ] && week_p=$(printf '%.0f' "$week_p" 2>/dev/null || printf '%s' "$week_p")
  # Nothing usable -> no line (the active account has no window). The caller treats
  # a non-zero return as "no usage to show", NOT a gap.
  [ -n "$sess_p" ] || [ -n "$week_p" ] || return 2
  # Per-provider age: the ACTIVE provider carries its OWN fetched_at (now for a
  # fresh reading, the older original when it INHERITED a last-known-good reading
  # after its live fetch errored). So its honest age is the OLDER of the blob age
  # and (now - its fetched_at), never younger than when its number was really read.
  # A provider without a fetched_at (older cache format) simply falls back to the
  # blob age. This is what paints an inherited stale number AS stale, not live.
  local act_bf act_age
  act_bf=$(printf '%s' "$raw" | jq -r '(.providers[]? | select((.provider_name // "") | test("✦")) | .fetched_at) // empty' 2>/dev/null | head -1)
  case "$act_bf" in ''|*[!0-9]*) act_bf="" ;; esac
  if [ -n "$act_bf" ]; then
    act_age=$((now_epoch - act_bf)); [ "$act_age" -lt 0 ] && act_age=0
    [ "$act_age" -gt "$age" ] && age=$act_age
  fi
  # age_token: a terse "(Nm old)"/"(Nh old)" once the reading reaches the age
  # floor, so a mid-climb reading surfaces its age instead of posing as live and a
  # genuinely fresh (<floor) number stays clean. WHY the floor, not the TTL: the
  # cache refreshes AT the TTL, so a reading is almost always under the TTL and a
  # TTL gate never fired - the desk's own honesty rule for a glanceable surface.
  local age_tok=""
  if [ "$age" -ge "$DESK_JCODE_USAGE_AGE_FLOOR" ]; then
    if [ "$age" -lt 3600 ]; then age_tok="$((age / 60))m old"
    elif [ "$age" -lt 86400 ]; then age_tok="$((age / 3600))h old"
    else age_tok="$((age / 86400))d old"; fi
  fi
  # A reset instant already in the PAST is OMITTED, never painted as "(resets 0m)"
  # - that affirms "this window resets right now" about a window that has in fact
  # already rolled over. It is the ACTIVE account's routine steady state, not a
  # corner case: a provider under load (usually this one) 429s and INHERITS the
  # prior reading's limits with their ORIGINAL resets_at, which then recedes into
  # the past while the percent keeps painting. The "(Nm old)" token beside it
  # already discloses that staleness honestly; a wrong reset does not.
  local parts="" sr wr
  sr=$(_desk_reset_in "$sess_reset"); wr=$(_desk_reset_in "$week_reset")
  _desk_reset_passed "$sess_reset" && sr=""
  _desk_reset_passed "$week_reset" && wr=""
  if [ -n "$sess_p" ]; then
    parts="session ${sess_p}%"
    [ -n "$sr" ] && parts="$parts (resets ${sr})"
  fi
  if [ -n "$week_p" ]; then
    [ -n "$parts" ] && parts="$parts · "
    parts="${parts}week ${week_p}%"
    [ -n "$wr" ] && parts="$parts (resets ${wr})"
  fi
  [ -n "$age_tok" ] && parts="$parts ($age_tok)"
  jq -n --arg line "$parts" \
    --arg sp "${sess_p:-}" --arg sr "$sr" \
    --arg wp "${week_p:-}" --arg wr "$wr" --arg age "$age_tok" \
    '{ line: $line,
       age: (if $age == "" then null else $age end),
       session: (if $sp == "" then null else { percent_used: ($sp | tonumber? // null), resets_in: $sr } end),
       week: (if $wp == "" then null else { percent_used: ($wp | tonumber? // null), resets_in: $wr } end) }'
}

# _desk_vwidth: the VISIBLE column count of a plain (escape-free) line, answered
# in _DESK_VWIDTH so a per-row check costs no subshell. It measures the way the
# boards do: a UTF-8 continuation byte (0x80-0xBF) continues the current column
# rather than starting a new one, so a multibyte glyph like the "·" separator
# counts as ONE column. The C locale is scoped to this call, so the answer does
# not change with the ambient locale the desk happens to run under.
_DESK_VWIDTH=0
_desk_vwidth() {
  local LC_ALL=C s=$1 bare
  bare=${s//[$'\x80'-$'\xbf']/}
  _DESK_VWIDTH=${#bare}
}

# _desk_clamp: cut a plain line to at most <cols> VISIBLE columns, answered in
# _DESK_CLAMPED. It cuts on a CHARACTER boundary using the same byte semantics as
# _desk_vwidth - a multibyte glyph is kept whole or dropped whole, never split
# into a mojibake half - and drops any space the cut left dangling. This is the
# last-resort rung of the account fit ladder: the ladder drops whole decorations
# first, so a clamp only fires on input no arrangement of decorations can fit,
# and it exists so the emitted string is ALWAYS within budget rather than trusting
# a board's clip to be the correctness boundary.
_DESK_CLAMPED=""
_desk_clamp() {
  local LC_ALL=C s=$1 cols=$2 n i c w out
  case "$cols" in ''|*[!0-9]*) cols=0 ;; esac
  n=${#s}; out=""; w=0; i=0
  while [ "$i" -lt "$n" ]; do
    c=${s:i:1}
    case "$c" in
      [$'\x80'-$'\xbf']) out="$out$c" ;;
      *) [ "$w" -ge "$cols" ] && break; w=$((w + 1)); out="$out$c" ;;
    esac
    i=$((i + 1))
  done
  while [ "${out% }" != "$out" ]; do out="${out% }"; done
  _DESK_CLAMPED=$out
}

# desk_claude_accounts: emit ALL managed Claude accounts plus which credential
# store points at which, for the header (the captain asked to see all three
# accounts, mark which store uses which, and switch the global account).
#
# WHY two sources (two separate stores, deliberately not bridged by captain
# ruling):
#   - the Claude Code store (~/.claude/.credentials.json) - what `cswap` rotates.
#   - the jcode store (~/.jcode/auth.json) - anthropic_accounts[] + one global
#     active_anthropic_account.
# The two planes can legitimately sit on DIFFERENT accounts, so the board shows
# both and says which is which.
#
# WHY cswap for ROSTER only: quota-axi reports only the ACTIVE credential, so it
# cannot list all three. `cswap list --json` (schemaVersion 1) is the source for
# the ROSTER: activeAccountNumber + accounts[] each with number, email, active,
# and (when held out) disabled. The USAGE numbers no longer come from cswap: cswap
# only refreshes the account it last activated, so inactive accounts froze and the
# desk painted stale numbers as live. The 5h/7d usage + last-used now come from the
# jcode plane the fleet runs on (`jcode usage --json`), matched to each roster
# account by EMAIL. See desk_jcode_usage_cached for the plane + throttle WHY.
#
# HONESTY (hard requirement): the markers are CONFIGURED store state, NOT proof
# of what a live session uses. A running jcode caches its token in process for
# hours, so the file does not prove the live account. The caption says so, and
# the model never asserts "this session is on X".
#
# SECRETS: only number, email, percentages, reset times, and last-used are read.
# Tokens, refresh tokens, and organizationUuid are never touched.
#
# WHY here, in the MODEL: gathering in the lib means BOTH boards render the same
# block off state/desk-model.json and the Rust crate stays file-driven. Bounded
# by DESK_TIMEOUT like every other source: a slow/absent/failing cswap is a GAP
# line, never a crash or hang.
#
# Args: $1 the cached jcode providers JSON (may be empty), $2 its age in seconds.
# An account whose email has no jcode provider match simply shows no usage (never
# a crash). Each account ages from the OLDER of the blob age and its provider's
# own fetched_at (an inherited last-known-good reading keeps its original fetch
# time); at or above the age floor its line carries a terse "(Nm old)" age token.
#
# Return codes (mirroring desk_claude_usage):
#   0  stdout is a JSON object { caption, lines:[...], line_classes:[...],
#      accounts:[...], cswap_active_number, jcode_active_email, jcode_active_label }.
#      line_classes is parallel to lines: one usage-severity bullet class per line
#      (done/waiting/blocked/idle) so a board colours the glance without re-parsing
#      the rendered percentages; each structured account also carries usage_class.
#   1  cswap absent, slow, or failing -> the caller notes a gap
#   2  cswap ran but reported no accounts -> nothing to show, NOT a gap
desk_claude_accounts() {
  command -v jq >/dev/null 2>&1 || return 1
  local bin raw now_epoch jusage jage
  jusage="$1"; jage="${2:-0}"
  bin="${FM_DESK_CSWAP_BIN:-cswap}"
  command -v "$bin" >/dev/null 2>&1 || return 1
  raw=$(desk_bound "$bin" list --json 2>/dev/null) || return 1
  [ -n "$raw" ] || return 1
  printf '%s' "$raw" | jq -e . >/dev/null 2>&1 || return 1
  now_epoch=$(date -d "${FM_DESK_NOW:-now}" +%s 2>/dev/null || date +%s)

  # jcode store: the active account's email, resolved from its label. A missing
  # or unreadable auth.json simply yields no jcode marker (best-effort, never a
  # crash). Only label + email are read; tokens are never touched.
  local auth="${FM_DESK_JCODE_AUTH:-$HOME/.jcode/auth.json}"
  local jc_label="" jc_email=""
  # Per-email -> jcode animal label map, so each account line can show WHICH
  # alias it is (claude-panda/claude-fox/...) the captain reads on the line, not
  # only the single active one. Best-effort: a missing or unreadable auth.json,
  # or an email absent from anthropic_accounts[], simply yields no label - never
  # a crash. Only .label and .email are read; no token is ever touched. The map
  # is parsed ONCE into a bash associative array (a jq-per-email lookup inside the
  # loop measurably slows the periodic repaint).
  local -A jc_labels=()
  if [ -r "$auth" ]; then
    jc_label=$(jq -r '.active_anthropic_account // ""' "$auth" 2>/dev/null || printf '')
    if [ -n "$jc_label" ]; then
      jc_email=$(jq -r --arg l "$jc_label" \
        '(.anthropic_accounts[]? | select(.label == $l) | .email) // ""' \
        "$auth" 2>/dev/null || printf '')
    fi
    # Emit "email<TAB>label" pairs once, then fold into the associative array.
    local _le _e _l
    while IFS=$'\t' read -r _e _l; do
      [ -n "$_e" ] && jc_labels["$_e"]="$_l"
    done < <(jq -r '.anthropic_accounts[]? | select(.email and .label) | "\(.email)\t\(.label)"' "$auth" 2>/dev/null || printf '')
    unset _le _e _l
  fi

  # jcode-plane usage map, keyed by the account EMAIL. WHY: the fleet runs on the
  # jcode plane, so the 5h/7d usage + last-used are read from `jcode usage --json`
  # (via the cached blob passed in), NOT from cswap's frozen .usage. jcode's
  # provider_name carries a REDACTED email (e.g. "r***e@gmail.com"), so a literal
  # match against cswap's full email is impossible. Instead we resolve each jcode
  # provider to a FULL email through the same auth.json label map above: the
  # provider_name carries the alias (claude-panda/...), and jc_email_of_label maps
  # alias -> full email. A provider we cannot resolve simply contributes no usage
  # (best-effort, never a crash). Only percentages, both windows' reset times, and
  # last-used are read; no token is touched. The blob is parsed ONCE into these
  # arrays so no per-account jq lookup slows the periodic repaint.
  local -A ju_five=() ju_fiver=() ju_seven=() ju_sevenr=() ju_last=() ju_bf=()
  if [ -n "$jusage" ] && printf '%s' "$jusage" | jq -e . >/dev/null 2>&1; then
    # alias -> full email, folded from auth.json (best-effort, empty when absent).
    local -A jc_alias_email=()
    if [ -r "$auth" ]; then
      local _al _em
      while IFS=$'\t' read -r _al _em; do
        [ -n "$_al" ] && jc_alias_email["$_al"]="$_em"
      done < <(jq -r '.anthropic_accounts[]? | select(.email and .label) | "\(.label)\t\(.email)"' "$auth" 2>/dev/null || printf '')
      unset _al _em
    fi
    # Emit "alias<US>5h<US>5h_reset<US>7d<US>7d_reset<US>last_used<US>fetched_at"
    # per jcode provider, joined with the ASCII unit separator U+001F (NOT a tab).
    # WHY U+001F: a tab is IFS-whitespace, so `read` COLLAPSES consecutive empty
    # fields and shifts later values left - a 429 provider (empty 5h/7d/resets)
    # would slide its "Last used" into the 5h slot and paint a garbled token.
    # U+001F is non-whitespace, so `read` keeps every empty field in place. The
    # alias is the first token of provider_name after "Anthropic - ", before the
    # " (". A provider with an error (e.g. 429) yields empty windows UNLESS it
    # INHERITED a last-known-good reading at cache-write time; in that case it
    # carries the inherited limits plus their ORIGINAL fetched_at, so its own age
    # token paints the number AS stale. A provider with no prior good reading
    # still yields empty windows -> no number.
    local _pa _p5 _p5r _p7 _pr _pl _pf
    while IFS=$'\037' read -r _pa _p5 _p5r _p7 _pr _pl _pf; do
      [ -n "$_pa" ] || continue
      local _pe="${jc_alias_email[$_pa]:-}"
      [ -n "$_pe" ] || continue
      ju_five["$_pe"]="$_p5"
      ju_fiver["$_pe"]="$_p5r"
      ju_seven["$_pe"]="$_p7"
      ju_sevenr["$_pe"]="$_pr"
      ju_last["$_pe"]="$_pl"
      ju_bf["$_pe"]="$_pf"
    done < <(printf '%s' "$jusage" | jq -r '
      .providers[]?
      | (.provider_name // "") as $pn
      | ($pn | capture("Anthropic - (?<a>[^ ]+)").a // "") as $alias
      | select($alias != "")
      | ((.limits[]? | select(.name=="5-hour window") | .usage_percent) // "") as $five
      | ((.limits[]? | select(.name=="5-hour window") | .resets_at) // "") as $fiver
      | ((.limits[]? | select(.name=="7-day window") | .usage_percent) // "") as $seven
      | ((.limits[]? | select(.name=="7-day window") | .resets_at) // "") as $sevenr
      | ((.extra_info[]? | select(.[0]=="Last used") | .[1]) // "") as $last
      | ((.fetched_at) // "") as $bf
      | [$alias, ($five|tostring), ($fiver|tostring), ($seven|tostring), ($sevenr|tostring), $last, ($bf|tostring)]
      | join([31]|implode)' 2>/dev/null || printf '')
    unset _pa _p5 _p5r _p7 _pr _pl _pf
  fi

  # age_tok_for: the terse "(Nm old)" for ONE account, surfaced once its reading
  # reaches the age floor so a mid-climb number is never painted as live (the
  # desk's honesty rule). WHY the floor, not the TTL: the cache refreshes AT the
  # TTL, so a reading is almost always under the TTL and a TTL gate never fired. A
  # fresh (<floor) reading carries no token, keeping the line clean.
  #
  # WHY per account, not one blob age: a provider that INHERITED a last-known-good
  # reading after its live fetch errored carries its OWN older fetched_at, so its
  # honest age is (now - that fetched_at), OLDER than the freshly-written blob. An
  # account paints the OLDER of the blob age and its own per-provider age, so an
  # inherited number shows AS stale while a genuinely fresh sibling stays clean. A
  # provider without a per-provider fetched_at falls back to the blob age.
  age_tok_for() {
    local bf="$1" a="$jage"
    case "$bf" in ''|*[!0-9]*) bf="" ;; esac
    if [ -n "$bf" ]; then
      local pa=$((now_epoch - bf)); [ "$pa" -lt 0 ] && pa=0
      [ "$pa" -gt "$a" ] && a=$pa
    fi
    [ "$a" -ge "$DESK_JCODE_USAGE_AGE_FLOOR" ] || { printf ''; return; }
    if [ "$a" -lt 3600 ]; then printf '%dm old' $((a / 60))
    elif [ "$a" -lt 86400 ]; then printf '%dh old' $((a / 3600))
    else printf '%dd old' $((a / 86400)); fi
  }

  # No accounts -> nothing to show (rc 2), distinct from a read failure (rc 1).
  local n
  n=$(printf '%s' "$raw" | jq -r '(.accounts // []) | length' 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  [ "$n" -gt 0 ] || return 2

  # pct_class: the usage-severity CLASS for ONE percentage, so the 5h and 7d
  # windows are each classed independently on their own token. It reuses the
  # SAME thresholds and bullet vocabulary MR !35 established for the per-line
  # bullet, so no second colour language is invented:
  #   >= 90%  spent      -> blocked (red)
  #   >= 70%  tight       -> waiting (yellow)
  #   >= 0%   headroom    -> done    (green)
  #   ""      unmeasured  -> idle    (dim)
  # An empty or non-numeric percent reads idle, never a false green.
  pct_class() {
    local p=$1
    case "$p" in ''|*[!0-9]*) printf 'idle'; return ;; esac
    if [ "$p" -ge 90 ]; then printf 'blocked'
    elif [ "$p" -ge 70 ]; then printf 'waiting'
    else printf 'done'; fi
  }

  # Build one compact line per account plus the structured account list. The
  # markers name the STORE that points at each account: "cc" (the Claude Code
  # store, i.e. the cswap active number) and "jcode" (the jcode active email).
  # Both may point at the same account, or at different ones. "disabled" is shown
  # ONLY when the JSON literally carries disabled:true - never inferred from text.
  local active_num lines_json line_classes_json accounts_json line email active disabled fivep fiver sevenp sevenr last_used i
  active_num=$(printf '%s' "$raw" | jq -r '.activeAccountNumber // empty' 2>/dev/null)

  lines_json='[]'
  line_classes_json='[]'
  # Parallel to lines[], one entry per account: the exact 5h/7d token strings and
  # their per-window classes, so a board colours EACH window's token from the
  # model (never by re-deriving state from the rendered line). An empty token
  # means that window is unmeasured and gets no colour. These arrays are DERIVED
  # from the structured accounts once at emit time, so no per-account jq append
  # slows the periodic repaint.
  accounts_json='[]'
  i=0
  while [ "$i" -lt "$n" ]; do
    email=$(printf '%s' "$raw" | jq -r ".accounts[$i].email // \"\"" 2>/dev/null)
    local number
    number=$(printf '%s' "$raw" | jq -r ".accounts[$i].number // \"\"" 2>/dev/null)
    active=$(printf '%s' "$raw" | jq -r ".accounts[$i].active // false" 2>/dev/null)
    disabled=$(printf '%s' "$raw" | jq -r ".accounts[$i].disabled // false" 2>/dev/null)
    # Usage + last-used come from the jcode plane (matched by EMAIL), NOT cswap's
    # frozen .usage. An email with no jcode match yields empty tokens -> no number
    # rather than a stale one. A jcode limit of 0.0 is a real reading and kept.
    fivep="${ju_five[$email]:-}"
    fiver="${ju_fiver[$email]:-}"
    sevenp="${ju_seven[$email]:-}"
    sevenr="${ju_sevenr[$email]:-}"
    last_used="${ju_last[$email]:-}"
    case "$fivep" in null|'') fivep="" ;; esac
    case "$fiver" in null|'') fiver="" ;; esac
    case "$sevenp" in null|'') sevenp="" ;; esac
    case "$sevenr" in null|'') sevenr="" ;; esac
    # This account's own age token, from ITS per-provider fetched_at (an inherited
    # last-known-good reading is older than the blob), so a stale-but-known number
    # paints AS stale while a fresh sibling stays clean.
    local acct_age_tok
    acct_age_tok=$(age_tok_for "${ju_bf[$email]:-}")

    # Percentages are integers on the board (no decimals bloat a tight line).
    local fivep_i="" sevenp_i=""
    [ -n "$fivep" ] && fivep_i=$(printf '%.0f' "$fivep" 2>/dev/null || printf '%s' "$fivep")
    [ -n "$sevenp" ] && sevenp_i=$(printf '%.0f' "$sevenp" 2>/dev/null || printf '%s' "$sevenp")
    # A reset instant already in the PAST is OMITTED, never painted as "(0m)" -
    # that reads as an affirmative "this window resets right now" beside the very
    # number the captain picks an account by. It is a routine steady state, not a
    # corner case: a 429/errored provider INHERITS the prior reading's limits with
    # their ORIGINAL resets_at (see desk_jcode_usage_cached), so a 5-hour window
    # recedes into the past while its percent keeps painting. The account's own
    # "(Nh old)" token already discloses that staleness honestly; a reset number
    # that is simply wrong does not. Applied to BOTH windows for one rule.
    local wr wr5; wr=$(_desk_reset_in "$sevenr"); wr5=$(_desk_reset_in "$fiver")
    _desk_reset_passed "$sevenr" && wr=""
    _desk_reset_passed "$fiver" && wr5=""

    # Store markers. cc = the Claude Code store (the cswap active number); jcode =
    # the jcode active email. A jcode active email absent from cswap's list still
    # marks the matching account here (both stores name the same email).
    local is_cc=false is_jc=false
    [ -n "$active_num" ] && [ "$number" = "$active_num" ] && is_cc=true
    [ -n "$jc_email" ] && [ "$email" = "$jc_email" ] && is_jc=true

    # The jcode animal alias for THIS email, from the per-email label map above.
    # A missing label is simply "" and shows nothing (best-effort, never a crash).
    local jc_lbl=""
    [ -n "$email" ] && jc_lbl="${jc_labels[$email]:-}"

    # The identifier, leading with the animal label so the captain reads WHICH
    # alias each account is directly on its line:
    #   "<n> claude-panda <email>  5h N% (Xh) · 7d M% (Xd)  markers".
    # ONE representation only: the label plus the email, never a third aligned
    # column and never a duplicated email. The label is written WHOLE - it is the
    # account's real name (jcode's own anthropic_accounts[].label, the name
    # fm-claude-switch resolves by), so it is never shortened into a name the
    # account does not have. The narrow form drops it outright instead.
    local ident="$number"
    [ -n "$jc_lbl" ] && ident="$ident $jc_lbl"
    ident="$ident $email"
    local ident_narrow="$number $email"
    # Per-window usage class (5h and 7d each on its own), so a spent five-hour
    # window and a fresh seven-day one are visibly different at a glance. Each
    # metric token carries a compact ascii SHAPE glyph (the shared bullet
    # vocabulary: blocked x / waiting ? / done +) baked INTO the token, so a
    # NO_COLOR or colour-blind reader still reads each window's state without
    # colour. The class is emitted structured alongside so both boards colour the
    # exact token from the MODEL, never by re-deriving state from the string.
    local five_class seven_class five_glyph seven_glyph
    five_class=$(pct_class "$fivep_i")
    seven_class=$(pct_class "$sevenp_i")
    # A disabled account carries no usable capacity, so each window reads idle
    # (dim) rather than a false green, matching the leading bullet's rule. The
    # override sits BEFORE the glyph so a disabled token shows the idle '.' shape.
    if [ "$disabled" = true ]; then five_class="idle"; seven_class="idle"; fi
    case "$five_class" in blocked) five_glyph=x ;; waiting) five_glyph='?' ;; done) five_glyph='+' ;; *) five_glyph='.' ;; esac
    case "$seven_class" in blocked) seven_glyph=x ;; waiting) seven_glyph='?' ;; done) seven_glyph='+' ;; *) seven_glyph='.' ;; esac
    local five_tok="" seven_tok=""
    [ -n "$fivep_i" ] && five_tok="5h ${fivep_i}%${five_glyph}"
    [ -n "$sevenp_i" ] && seven_tok="7d ${sevenp_i}%${seven_glyph}"

    local metrics=""
    if [ -n "$five_tok" ]; then
      metrics="$five_tok"
      [ -n "$wr5" ] && metrics="$metrics ($wr5)"
    fi
    if [ -n "$seven_tok" ]; then
      [ -n "$metrics" ] && metrics="$metrics · "
      metrics="${metrics}${seven_tok}"
      [ -n "$wr" ] && metrics="$metrics ($wr)"
    fi
    # "Last used" from the jcode plane - the real "what is using this account" the
    # frozen cswap numbers could never show. It rides the STRUCTURED account only
    # and is deliberately NOT on the rendered line: the line is read over SSH at
    # 80 columns (the board's fallback width, and clip_frame cuts with an ellipsis
    # past it), and alias + email + two windows with their resets + the store
    # marker already spend that budget. Legibility of the numbers the captain
    # decides on outranks a soft "used 5m ago" that a board can surface elsewhere.
    local last_disp=""
    case "$last_used" in null|'') last_disp="" ;; *) last_disp="$last_used" ;; esac
    # The age token surfaces a STALE reading once, on the line, so no per-account
    # number older than the TTL poses as live (the desk's honesty rule).
    [ -n "$metrics" ] && [ -n "$acct_age_tok" ] && metrics="$metrics ($acct_age_tok)"
    # The store markers are abbreviated on the line - "cc" for the Claude Code
    # store, "cc+jcode" when both stores point here. Spelled out they cost 9 to 11
    # columns of the same 80-column budget the numbers need, and a marker clipped
    # to "<- Claude Co…" names no store at all.
    local marks=""
    [ "$is_cc" = true ] && marks="cc"
    if [ "$is_jc" = true ]; then
      [ -n "$marks" ] && marks="$marks+jcode" || marks="jcode"
    fi
    local metrics_tok="" marks_tok="" dis_tok=""
    [ -n "$metrics" ] && metrics_tok="  $metrics"
    [ -n "$marks" ] && marks_tok="  <- $marks"
    [ "$disabled" = true ] && dis_tok="  (disabled)"

    # Fit the row to DESK_ACCOUNT_COLS by DROPPING whole decorations, worst-first,
    # rather than handing the boards a line their clip cuts mid-word: a clipped
    # "<- cc…" names no store and a clipped email names no account, so a decoration
    # that will not fit is not painted at all. Worst-first:
    #   1. the store marker - which store points here is the least of the row, and
    #      both stores stay readable structured (claude_code_marked/jcode_active).
    #   2. the animal label - a CUT, never a rename; the full label stays in
    #      jcode_label, and the email still names the account uniquely.
    #   3. the "(disabled)" suffix - the row already reads idle on both windows and
    #      its own bullet, and the structured `disabled` flag stays authoritative.
    # Then a terminal clamp, so the emitted string is within budget for ANY input
    # (an email long enough to blow the budget on its own has no decoration left to
    # give). The clamp is the only rung that can cut mid-word, and no realistic row
    # reaches it - the three drops above land the widest production row at 67.
    # What the captain decides on is never dropped by a rung: the number, the
    # email, both windows with their resets, and the "(Nm old)" staleness token, so
    # a row can lose a decoration but can never pose a stale number as live. Most
    # rows fit whole and lose nothing; only the widest spend a step of this.
    line="$ident$metrics_tok$marks_tok$dis_tok"
    _desk_vwidth "$line"
    if [ "$_DESK_VWIDTH" -gt "$DESK_ACCOUNT_COLS" ]; then
      line="$ident$metrics_tok$dis_tok"
      _desk_vwidth "$line"
      if [ "$_DESK_VWIDTH" -gt "$DESK_ACCOUNT_COLS" ]; then
        line="$ident_narrow$metrics_tok$dis_tok"
        _desk_vwidth "$line"
        if [ "$_DESK_VWIDTH" -gt "$DESK_ACCOUNT_COLS" ]; then
          line="$ident_narrow$metrics_tok"
          _desk_vwidth "$line"
          if [ "$_DESK_VWIDTH" -gt "$DESK_ACCOUNT_COLS" ]; then
            _desk_clamp "$line" "$DESK_ACCOUNT_COLS"
            line="$_DESK_CLAMPED"
          fi
        fi
      fi
    fi

    # Usage severity CLASS for the glance colour/shape (the captain asked to see
    # headroom vs nearly-spent at a glance). It reuses the SAME bullet vocabulary
    # both boards already own (bclass -> done/waiting/blocked), so no second colour
    # language is invented: green = headroom, yellow = getting tight, red = spent.
    # The class is derived ONLY from the structured percentages, never by scanning
    # the rendered line. The worse of the two windows decides, so a spent five-hour
    # window is not hidden behind a fresh seven-day one; both windows share ONE set
    # of thresholds so "80%" means the same thing in either. Thresholds:
    #   >= 90%  spent/near-limit   -> blocked (red)
    #   >= 70%  getting tight      -> waiting (yellow)
    #   else    headroom           -> done    (green)
    # A disabled account carries no usable capacity, so it reads idle (dim) rather
    # than a false green. No percentage at all -> idle, so an unmeasured account is
    # never painted as if it had headroom.
    local usage_class="idle" worst=-1
    if [ "$disabled" != true ]; then
      [ -n "$fivep_i" ] && [ "$fivep_i" -gt "$worst" ] && worst=$fivep_i
      [ -n "$sevenp_i" ] && [ "$sevenp_i" -gt "$worst" ] && worst=$sevenp_i
      if [ "$worst" -ge 90 ]; then usage_class="blocked"
      elif [ "$worst" -ge 70 ]; then usage_class="waiting"
      elif [ "$worst" -ge 0 ]; then usage_class="done"
      fi
    fi

    lines_json=$(printf '%s' "$lines_json" | jq --arg l "$line" '. + [$l]')
    line_classes_json=$(printf '%s' "$line_classes_json" | jq --arg c "$usage_class" '. + [$c]')
    accounts_json=$(printf '%s' "$accounts_json" | jq \
      --arg num "$number" --arg email "$email" \
      --argjson active "$active" --argjson disabled "$disabled" \
      --arg five "${fivep_i:-}" --arg seven "${sevenp_i:-}" --arg wr "$wr" --arg wr5 "$wr5" \
      --argjson cc "$is_cc" --argjson jc "$is_jc" --arg uc "$usage_class" \
      --arg lbl "$jc_lbl" --arg fc "$five_class" --arg sc "$seven_class" \
      --arg ft "$five_tok" --arg st "$seven_tok" \
      --arg lu "$last_disp" --arg agetok "$acct_age_tok" \
      '. + [{ number: ($num|tonumber? // $num), email: $email,
              jcode_label: (if $lbl == "" then null else $lbl end),
              claude_code_active: $active, disabled: $disabled,
              jcode_active: $jc, claude_code_marked: $cc,
              five_hour_pct: ($five|tonumber? // null),
              seven_day_pct: ($seven|tonumber? // null),
              five_hour_resets_in: (if $wr5 == "" then null else $wr5 end),
              seven_day_resets_in: (if $wr == "" then null else $wr end),
              five_hour_class: $fc, seven_day_class: $sc,
              five_hour_token: (if $ft == "" then null else $ft end),
              seven_day_token: (if $st == "" then null else $st end),
              last_used: (if $lu == "" then null else $lu end),
              data_age: (if $agetok == "" then null else $agetok end),
              usage_class: $uc }]')
    i=$((i + 1))
  done

  jq -n \
    --arg caption "Claude accounts (configured stores, a running session may differ)" \
    --argjson lines "$lines_json" \
    --argjson line_classes "$line_classes_json" \
    --argjson accounts "$accounts_json" \
    --arg cswap_active "${active_num:-}" \
    --arg jc_email "$jc_email" --arg jc_label "$jc_label" \
    '{ caption: $caption, lines: $lines, line_classes: $line_classes,
       # The per-window parallel arrays are DERIVED from the structured accounts
       # here (one pass), so no extra jq call per account slows the periodic
       # repaint. A null token/class stays "" so a board treats it as unmeasured.
       five_hour_tokens: [ $accounts[] | .five_hour_token // "" ],
       five_hour_classes: [ $accounts[] | .five_hour_class // "idle" ],
       seven_day_tokens: [ $accounts[] | .seven_day_token // "" ],
       seven_day_classes: [ $accounts[] | .seven_day_class // "idle" ],
       accounts: $accounts,
       cswap_active_number: ($cswap_active|tonumber? // null),
       jcode_active_email: (if $jc_email == "" then null else $jc_email end),
       jcode_active_label: (if $jc_label == "" then null else $jc_label end) }'
}

# desk_token_cost_recompute: run the coster ONCE per figure and combine the
# results into a single cost blob. This is the SLOW path (two full session-store
# scans), so it is called only when the disk cache is stale - the desk repaint
# never pays it. Every dollar figure is produced by the coster
# (bin/fm-token-report.sh / bin/fm-ticket-cost-rollup.sh, which cost through
# bin/fm-token-lib.sh); this function only SELECTS and RESHAPES what they emit, so
# the one-owner-per-contract rule holds - the desk never re-costs a token.
#
# TWO sources, deliberately separate:
#   - the trailing-window --by-model report gives the burn rate (period totals),
#     the cache-hit ratio (period token sums), and the heaviest engines (rows).
#   - the per-landed-ticket rollup gives cost-per-landed-ticket, joined to the
#     home's OWN durable landed records + ledger. It is OPTIONAL: on a home where
#     the rollup tool is not present yet (it lands with its own change), the burn/
#     cache/heaviest half still renders and per_ticket is marked unavailable,
#     never fabricated.
#
# cost_if_api and cost_if_api_covered stay SEPARATE facts throughout (captain
# ruling, mirrored from the coster): this function never sums them into one total.
#
# The report reads the home's ledger + landed records through the standard
# firstmate data-dir chain, so with FM_HOME pointed at the live home (as the desk
# always runs it) the panel reads the REAL ledger, never a worktree copy. Bounded
# by desk_bound like every other slow source. Emits the combined blob on stdout,
# or nothing + return 1 when the burn half itself could not be read (a real gap).
desk_token_cost_recompute() {
  command -v jq >/dev/null 2>&1 || return 1
  local report_bin rollup_bin window burn
  report_bin="${FM_DESK_TOKEN_REPORT_BIN:-$FM_DESK_LIB_DIR/fm-token-report.sh}"
  rollup_bin="${FM_DESK_TICKET_ROLLUP_BIN:-$FM_DESK_LIB_DIR/fm-ticket-cost-rollup.sh}"
  window="${DESK_TOKEN_COST_WINDOW_DAYS}d"

  # The burn/cache/heaviest half. A missing or failing report is the hard failure:
  # the panel has nothing to show, so the caller notes a gap.
  [ -x "$report_bin" ] || command -v "$report_bin" >/dev/null 2>&1 || return 1
  burn=$(desk_bound bash "$report_bin" --period "$window" --by-model --json 2>/dev/null)
  [ -n "$burn" ] && printf '%s' "$burn" | jq -e . >/dev/null 2>&1 || return 1

  # The per-landed-ticket half. OPTIONAL: absence or failure yields a null rollup,
  # which the formatter renders as "not available", never a fabricated number. The
  # rollup blob can be large (one row per landed ticket), so it is passed to the
  # combine step through a temp file (--slurpfile), never argv - a big fleet's
  # rollup would blow the ARG_MAX limit if inlined as --argjson.
  local rollup_tmp
  rollup_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-desk-rollup.XXXXXX" 2>/dev/null) || return 1
  printf 'null' > "$rollup_tmp"
  if [ -x "$rollup_bin" ] || command -v "$rollup_bin" >/dev/null 2>&1; then
    local rraw
    rraw=$(desk_bound bash "$rollup_bin" --json 2>/dev/null)
    if [ -n "$rraw" ] && printf '%s' "$rraw" | jq -e . >/dev/null 2>&1; then
      printf '%s' "$rraw" > "$rollup_tmp"
    fi
  fi

  # Combine. The heaviest list is capped to the top few engines by if-API cost so
  # the drill-down stays a glance; the caller keeps the full structured facts.
  # --slurpfile wraps the file contents in a 1-element array, so $rollup[0] is the
  # rollup object (or null when the rollup half was unavailable).
  local combined
  combined=$(printf '%s' "$burn" | jq -c \
    --argjson window "$DESK_TOKEN_COST_WINDOW_DAYS" \
    --slurpfile rollup_arr "$rollup_tmp" '
    ($rollup_arr[0]) as $rollup
    | def hit:
      (.totals.token_cache_read // 0) as $r
      | (.totals.token_input // 0) as $i
      | (.totals.token_cache_write // 0) as $w
      | ($r + $i + $w) as $d
      | if $d > 0 then (100 * $r / $d) else null end;
    {
      window_days: $window,
      price_source: (.price_source // null),
      price_cached_at: (.price_cached_at // null),
      burn: {
        cost_if_api: (.totals.cost_if_api // null),
        cost_if_api_billed: (.totals.cost_if_api_billed // null),
        cost_if_api_covered: (.totals.cost_if_api_covered // null),
        sessions: (.totals.sessions // 0),
        unknown_model_tokens: (.totals.unknown_model_tokens // 0)
      },
      cache_hit_percent: hit,
      heaviest: [
        .rows
        | sort_by(.cost_if_api // 0) | reverse | .[]
        | { name: (.dimension // "unknown"),
            cost_if_api: (.cost_if_api // null),
            cost_if_api_billed: (.cost_if_api_billed // null),
            cost_if_api_covered: (.cost_if_api_covered // null),
            sessions: (.sessions // 0) }
      ][0:5],
      per_ticket: (
        if $rollup == null then { available: false }
        else {
          available: true,
          tickets: ($rollup.totals.tickets // 0),
          unattributable_tickets: ($rollup.totals.unattributable_tickets // 0),
          attributable_tickets: (((($rollup.totals.tickets // 0)) - (($rollup.totals.unattributable_tickets // 0)))),
          sessions: ($rollup.totals.sessions // 0),
          cost_if_api: ($rollup.totals.cost_if_api // null),
          cost_if_api_billed: ($rollup.totals.cost_if_api_billed // null),
          cost_if_api_covered: ($rollup.totals.cost_if_api_covered // null),
          # Costliest attributable landed tickets, top few, for the drill-down.
          top: [
            ($rollup.tickets // [])
            | map(select(.unattributable | not))
            | sort_by(.cost_if_api // 0) | reverse | .[]
            | { ticket: .ticket, repo: (.repo // null), close_date: (.close_date // null),
                cost_if_api: (.cost_if_api // null),
                cost_if_api_covered: (.cost_if_api_covered // null) }
          ][0:5]
        } end)
    }')
  rm -f "$rollup_tmp" 2>/dev/null
  [ -n "$combined" ] || return 1
  printf '%s' "$combined"
}

# desk_token_cost_cached: return the combined cost blob through a desk-owned DISK
# cache, so the ~30s repaint reads a cheap file instead of paying the ~4s of
# store-scanning recompute. Mirrors desk_jcode_usage_cached exactly: recompute
# ONLY when the cache is stale/absent/corrupt, embed fetched_at so the age survives
# an mtime-resetting copy, and USE a stale-but-readable cache rather than failing.
# Output on success: the cache age in whole seconds on the FIRST line, then the
# cached blob on the following lines. Hard failure (no usable cache and no
# recompute) prints nothing and returns 1, so the caller shows the gap line.
# READ-ONLY except for the single cache file it owns.
desk_token_cost_cached() {
  command -v jq >/dev/null 2>&1 || return 1
  local cache now_epoch mtime fetched_at age fa_age fresh raw
  cache="${FM_DESK_TOKEN_COST_CACHE:-$STATE/desk-token-cost.json}"
  now_epoch=$(date -d "${FM_DESK_NOW:-now}" +%s 2>/dev/null || date +%s)

  mtime=""
  fetched_at=""
  if [ -f "$cache" ]; then
    mtime=$(date -r "$cache" +%s 2>/dev/null \
      || stat -c %Y "$cache" 2>/dev/null \
      || stat -f %m "$cache" 2>/dev/null || printf '')
    case "$mtime" in ''|*[!0-9]*) mtime="" ;; esac
    fetched_at=$(jq -r '.fetched_at // empty' "$cache" 2>/dev/null)
    case "$fetched_at" in ''|*[!0-9]*) fetched_at="" ;; esac
  fi
  age=""
  if [ -n "$mtime" ]; then
    age=$((now_epoch - mtime)); [ "$age" -lt 0 ] && age=0
  fi
  if [ -n "$fetched_at" ]; then
    fa_age=$((now_epoch - fetched_at)); [ "$fa_age" -lt 0 ] && fa_age=0
    if [ -z "$age" ] || [ "$fa_age" -gt "$age" ]; then age=$fa_age; fi
  fi

  fresh=false
  if [ -n "$age" ] && [ "$age" -lt "$DESK_TOKEN_COST_TTL" ] \
    && jq -e . "$cache" >/dev/null 2>&1; then
    fresh=true
  fi

  if [ "$fresh" != true ]; then
    raw=$(desk_token_cost_recompute 2>/dev/null)
    if [ -n "$raw" ] && printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
      local dir tmp
      dir=$(dirname "$cache")
      if mkdir -p "$dir" 2>/dev/null; then
        tmp="$dir/.$(basename "$cache").tmp.$$"
        if printf '%s' "$raw" \
          | jq --argjson t "$now_epoch" '. + {fetched_at: $t}' > "$tmp" 2>/dev/null \
          && mv -f "$tmp" "$cache" 2>/dev/null; then
          age=0
        else
          rm -f "$tmp" 2>/dev/null
        fi
      fi
    fi
  fi

  jq -e . "$cache" >/dev/null 2>&1 || return 1
  printf '%s\n' "${age:-0}"
  cat "$cache"
}

# desk_token_cost: format the cached cost blob into the header model object BOTH
# boards paint. Reads the combined blob (from desk_token_cost_cached), derives the
# terse header glance line plus the drill-down detail lines, and rides the
# structured facts along for tests and future surfaces. Every number here is a
# passthrough of a coster-produced figure - this function only SELECTS, ROUNDS for
# display, and LAYS OUT; it never costs a token.
#
# The header carries ONE glance line (burn + the if-API/billed/covered split +
# cache-hit) because the desk is a glance; the heaviest engines and the
# cost-per-landed-ticket breakdown live in the drill-down (one keystroke away),
# per legibility-over-density. cost_if_api and cost_if_api_covered are shown as
# SEPARATE labeled facts, never summed.
#
# THIN/EMPTY LEDGER: a home whose ledger has not filled yet reports every landed
# ticket UNATTRIBUTABLE (correct-by-design until spawns accrue). This renders it
# honestly as "unattributable / thin ledger", never $0 and never broken.
#
# Args: $1 the cached combined blob, $2 its age in seconds. A reading at or above
# the age floor trails an "(Nm old)" token so a stale blob is never painted as
# live. Returns empty (exit 1) only when the blob is missing/corrupt (a real gap);
# an empty store (no billed activity) is NOT a gap - it renders an honest "no
# billed activity yet" line.
desk_token_cost() {
  command -v jq >/dev/null 2>&1 || return 1
  local raw="$1" age="${2:-0}"
  [ -n "$raw" ] || return 1
  printf '%s' "$raw" | jq -e . >/dev/null 2>&1 || return 1
  case "$age" in ''|*[!0-9]*) age=0 ;; esac

  # The age token, gated on the floor (mirrors the usage/accounts age token).
  local age_tok=""
  if [ "$age" -ge "$DESK_TOKEN_COST_AGE_FLOOR" ]; then
    if [ "$age" -lt 3600 ]; then age_tok="$((age / 60))m old"
    elif [ "$age" -lt 86400 ]; then age_tok="$((age / 3600))h old"
    else age_tok="$((age / 86400))d old"; fi
  fi

  # All display formatting lives in this one jq pass so the two boards render
  # byte-identical text off the model. money() humanizes a dollar figure to a
  # compact glance token ($1.2k / $340 / $4.05); a null cost is "n/a" (an
  # unpriced/absent figure, never a fabricated $0).
  printf '%s' "$raw" | jq -c \
    --arg age "$age_tok" '
    def money($v):
      if $v == null then "n/a"
      elif ($v | fabs) >= 1000 then "$" + (($v / 1000) | (. * 10 | round / 10 | tostring)) + "k"
      elif ($v | fabs) >= 100 then "$" + (($v | round) | tostring)
      else "$" + (($v * 100 | round / 100) | tostring)
      end;
    (.window_days // 7) as $wd
    | (.cache_hit_percent) as $hit
    | .burn as $b
    | .per_ticket as $pt
    | (if $b.cost_if_api == null and (($b.sessions // 0) == 0)
       then "no billed activity yet"
       else ("spend " + ($wd|tostring) + "d: if-API " + money($b.cost_if_api)
             + " (billed " + money($b.cost_if_api_billed)
             + " / covered " + money($b.cost_if_api_covered) + ")"
             + (if $hit != null then " \u00b7 cache " + (($hit | round) | tostring) + "%" else "" end))
       end) as $core
    | ($core + (if $age != "" then " (" + $age + ")" else "" end)) as $line
    # --- drill-down detail lines ---------------------------------------------
    | ([ "Fleet spend and efficiency"
         + (if $age != "" then "  (" + $age + ")" else "" end),
         "",
         "Burn (last " + ($wd|tostring) + "d): if-API " + money($b.cost_if_api)
           + "  billed " + money($b.cost_if_api_billed)
           + "  covered " + money($b.cost_if_api_covered)
           + "  (" + (($b.sessions // 0)|tostring) + " sessions)",
         (if $hit != null then "Cache hit ratio: " + (($hit | round)|tostring) + "%  (cache reads vs fresh input)"
          else "Cache hit ratio: n/a" end),
         "",
         "Heaviest engines (last " + ($wd|tostring) + "d):" ]
       + ( if (.heaviest | length) > 0
           then [ .heaviest[]
                  | "  " + (.name)
                    + "  if-API " + money(.cost_if_api)
                    + " / covered " + money(.cost_if_api_covered)
                    + "  (" + ((.sessions // 0)|tostring) + " sessions)" ]
           else [ "  no billed activity yet" ] end)
       + [ "",
           "Cost per landed ticket:" ]
       + ( if ($pt.available | not)
           then [ "  not available on this home yet" ]
           elif (($pt.attributable_tickets // 0) == 0)
           then [ "  thin ledger: all " + (($pt.tickets // 0)|tostring)
                  + " landed tickets are unattributable (no ledger rows yet).",
                  "  This fills in as new work spawns; it is not $0 and not an error." ]
           else [ "  " + (($pt.attributable_tickets // 0)|tostring) + " of "
                  + (($pt.tickets // 0)|tostring) + " landed tickets attributed"
                  + " (" + (($pt.unattributable_tickets // 0)|tostring) + " unattributable)",
                  "  attributed spend: if-API " + money($pt.cost_if_api)
                  + " / covered " + money($pt.cost_if_api_covered) ]
                + ( if (($pt.top // []) | length) > 0
                    then [ "  costliest landed tickets:" ]
                         + [ $pt.top[]
                             | "    " + (.ticket)
                               + "  if-API " + money(.cost_if_api)
                               + " / covered " + money(.cost_if_api_covered) ]
                    else [] end)
           end)
       ) as $detail
    | { line: $line,
        detail: $detail,
        age: (if $age == "" then null else $age end),
        window_days: $wd,
        cache_hit_percent: $hit,
        burn: $b,
        heaviest: .heaviest,
        per_ticket: $pt }'
}

# --- concern 3: the normalized view model (schema fm-desk.v1) ----------------
# _desk_tsv_translate: read a TSV on stdin and apply the DESK_TERMS vocabulary
# rewrite ONLY to the 1-based columns named in $1 (comma-separated), leaving
# every other column verbatim. This preserves the HTML board's split: text
# fields were translated (desk_text) while ids, freshness, branch, dest, and
# URLs were carried verbatim (desk_raw). An empty $1 translates nothing.
_desk_tsv_translate() {
  awk -v cols="$1" "$DESK_XLATE_PRELUDE"'
    BEGIN {
      FS = "\t"; OFS = "\t"
      m = split(cols, ca, ",")
      for (j = 1; j <= m; j++) if (ca[j] != "") tr[ca[j]+0] = 1
    }
    {
      for (c = 1; c <= NF; c++) if (c in tr) $c = xlate($c)
      print
    }
  '
}

# _desk_rows: turn a TSV blob (stdin, selected columns already translated) into
# a JSON array of objects, one per non-empty line, keyed by the comma-separated
# field names in $1.
_desk_rows() {
  jq -R -s --arg fields "$1" '
    ($fields | split(",")) as $f
    | [ split("\n")[]
        | select(length > 0)
        | (split("\t")) as $c
        | reduce range(0; ($f | length)) as $i ({}; .[$f[$i]] = ($c[$i] // "")) ]
  '
}

# _desk_collapse: given a rows array and DESK_CAP, add the shaping fields both
# boards read: total (ranked rows the lib holds), cap, shown, more, and a
# ready-to-paint more_hint. cap 0 = no cap (shown=total), so a board with a
# scrollbar reveals everything by running with FM_DESK_CAP=0. The hint names
# where the rest is, so a collapsed tail is never confusable with a failed source.
_desk_collapse() {
  jq -c --argjson cap "$DESK_CAP" '
    (. | length) as $total
    | (if $cap > 0 and $total > $cap then $cap else $total end) as $shown
    | ($total - $shown) as $more
    | { rows: ., total: $total, cap: $cap, shown: $shown, more: $more,
        more_hint: (if $more > 0
          then "+\($more) more - open the full desk"
          else "" end) }'
}

# --- concern 3b: the line-budget fit model (one owner of line cost) ----------
# desk_fit re-shapes a fully-built fm-desk.v1 model to fit a PHYSICAL painted-line
# budget, rather than a per-section row count. A board with a fixed pane (the TUI)
# hands its pane height (FM_DESK_BUDGET, in physical lines) to this ONE owner of
# how many lines each row and each piece of chrome cost; the board never
# re-derives that (the one-owner rule). The TUI's width owner (fm-desk-tui.sh
# clip_frame) clips every painted line to the wrap width, so a logical line never
# wraps and each one costs exactly one physical row. That makes the budget
# honest: the old wrapped-cost model silently under-counted whenever a line
# overran COLS and the terminal wrapped it. It:
#   - counts each painted line as one physical row (a row with a second detail
#     line costs 2: its lead line + its detail line),
#   - subtracts fixed chrome honestly (header, gaps banner, each section's
#     blank + title + rule, the "+N more" line, health, unavailable notice),
#   - fills sections in paint order, and DROPS a section (its header included)
#     when no row fits, instead of paying 3 lines for a bare collapse notice,
#   - so a SHORTER pane shows FEWER rows (no inverted floor).
# The row-cost formulas mirror exactly what the TUI paints (see fm-desk-tui.sh
# lead_line/body_line: a lead is "  {head}  {id}[  {meta}]" or "  {id}[  {meta}]",
# a detail is "      {text}"); ANSI color is zero-width so it is not counted, and
# an over-wide line is clipped rather than wrapped. Applied only when
# FM_DESK_BUDGET is set and FM_DESK_CAP is unset; an explicit FM_DESK_CAP (a test,
# the HTML board's uncap) bypasses it.
desk_fit() {  # <model-json>  (reads FM_DESK_BUDGET)
  printf '%s' "$1" | jq -c --argjson budget "${FM_DESK_BUDGET:-49}" '
    # Every painted line is clipped to the wrap width by the width owner in
    # fm-desk-tui.sh (clip_frame), so a logical line never wraps: each one costs
    # exactly one physical row. phys therefore returns 1 per painted line (its
    # $len argument is kept for call-site clarity about which line it names).
    def phys($len): 1;
    # Section-header title lengths - the exact strings rule() paints in the TUI.
    # Line-cost knowledge lives in this lib, so title cost sits beside phys/rowcost.
    def titlelen($k):
      if $k == "captains_call" then 14
      elif $k == "under_way" then 9
      elif $k == "charted" then 21
      elif $k == "landed" then 15
      elif $k == "merge" then 41
      elif $k == "secondmates" then 12
      else 0 end;
    # A section header costs blank(1) + the WRAPPED title + dashes(1).
    def hcost($k): 2 + phys(titlelen($k));
    # compose {h:head, m:meta, d:detail} exactly as the TUI paints each section.
    # Every row now leads with a 2-col bullet in place of the old 2-col indent, so
    # the leading cost is unchanged. State/kind words the bullet carries are cut:
    # under_way trails only kind, secondmates only freshness, merge only "-> dest"
    # (the branch is redundant with the id, and the URL is dropped entirely).
    def compose($k; $r):
      if $k == "captains_call" then {h:($r.summary//""), m:"", d:""}
      elif $k == "under_way" then {h:($r.doing//""), m:($r.kind//""), d:""}
      elif $k == "charted" then {h:($r.title//""), m:"",
        d:((if (($r.blocked_by//"-")!="-" and ($r.blocked_by//"")!="") then "waits on "+$r.blocked_by else "" end) as $w1
           | (if (($r.reason//"-")!="-" and ($r.reason//"")!="") then (if $w1!="" then $w1+" - "+$r.reason else $r.reason end) else $w1 end))}
      elif $k == "landed" then {h:($r.what//""), m:"",
        d:(if (($r.artifact//"-")!="-" and ($r.artifact//"")!="") then $r.artifact else "" end)}
      elif $k == "merge" then {h:"", m:("-> "+($r.dest//"")), d:""}
      elif $k == "secondmates" then {h:($r.doing//""), m:($r.freshness//""), d:""}
      else {h:"", m:"", d:""} end;
    def rowcost($k; $r):
      compose($k; $r) as $c
      | phys(2 + (if ($c.h|length)>0 then ($c.h|length)+2 else 0 end)
             + ($r.id|length) + (if ($c.m|length)>0 then 2+($c.m|length) else 0 end))
        + (if ($c.d|length)>0 then phys(6+($c.d|length)) else 0 end);
    3 as $rule                       # single-line-title header cost (gaps banner)
    # Fleet health now paints NOTHING when fine (monitoring alive AND present) and
    # a SINGLE dim line otherwise - no rule, no unavailable notice. Reserve that
    # one line only in the cases the model shows it, computed exactly as
    # paint_health decides (beat missing/stale, or away), so a healthy board pays
    # zero chrome here and spends the budget on rows.
    | (if ((.health.beat_age_seconds == null) or (.health.beat_age_seconds > 1800) or (.away))
       then phys(90) else 0 end) as $health
    # The TUI no longer paints a "+N more" collapse row: each section TOTAL
    # count now folds into its header (fm-desk-tui.sh rule()), so a collapsed
    # tail costs zero extra lines. desk_fit budgets only what the TUI paints, so
    # a held-back tail reserves nothing here. (The "+N more" hint stays in the
    # model for the HTML board, which runs uncapped and does not use desk_fit.)
    | 0 as $morecost                 # the TUI paints no "+N more" line
    # fixed non-section chrome. The title and the "as of <now>" stamp now share
    # ONE line (clipped to width, never wrapped), then the summary line. When the
    # model carries a Claude usage line (ITEM 4) the TUI paints ONE more line for
    # it, so reserve it exactly when paint_header would show it. The accounts
    # block (caption + one line per account) is likewise fixed chrome paint_header
    # emits, so reserve those lines too when the model carries them.
    | (phys(22 + (.now|length)) + phys(.header.summary|length)
       + (if ((.header.usage.line // "") | length) > 0 then phys(.header.usage.line|length) else 0 end)
       + (if ((.header.accounts.lines // []) | length) > 0
          then (if ((.header.accounts.caption // "") | length) > 0 then phys(.header.accounts.caption|length) else 0 end)
               + ([.header.accounts.lines[] | phys(2 + length)] | add)
          else 0 end)) as $header
    | (if (.gaps|length) > 0 then $rule + ([.gaps[] | phys(2 + length)] | add) else 0 end) as $gapblock
    | ($budget - $header - $health - $gapblock) as $avail0
    | ["captains_call","under_way","charted","landed","merge","secondmates"] as $order
    | (["captains_call","merge"]) as $always
    | . as $model
    | ($model.sections) as $S
    # Per-section metadata: status, gap sentence, row count, and the running
    # cumulative content cost cum[s] = physical lines for the first s rows.
    | (reduce $order[] as $k ({};
        ($S[$k]) as $sec
        | ($sec.status // "ok") as $st
        | .[$k] = { st:$st, gap:($sec.gap // ""), hcost:hcost($k),
            total:(if $st == "ok" then ($sec.rows | length) else 0 end),
            cum:(if $st == "ok"
                 then ([0] + [foreach $sec.rows[] as $r (0; . + rowcost($k; $r))])
                 else [0] end) })) as $meta
    # secost: content lines a section adds when showing s of its rows. For an
    # ordinary section this is header + content (the "+N more" collapse line is
    # gone, so $morecost is 0). For an always-shown section the header is
    # PRE-RESERVED in init - together with its one trailing empty-message line,
    # but only when it holds no rows - so here only the content lines count: it
    # can never be dropped and its header never competes with its own rows.
    | def secost($k; $s):
        (($always | index($k)) != null) as $isalways
        | if $s <= 0 then 0
          elif $isalways then $meta[$k].cum[$s]
          else $meta[$k].hcost + $meta[$k].cum[$s]
               + (if $s < $meta[$k].total then $morecost else 0 end) end;
    # Init pass. A gap/away section is SAFETY: always rendered, chrome reserved,
    # even over budget. An always-shown section (open decisions, ready-to-merge)
    # always renders too - it carries the two things the captain acts on - so its
    # header is reserved here, plus one trailing line ONLY when it holds no rows
    # (the empty message, e.g. "No finished branches waiting to merge."). When it
    # has rows, those compete in the fill below on content cost alone and no
    # "+N more" line is painted. Every other empty section folds away (its state
    # is already in the top summary).
    (reduce $order[] as $k ({left:$avail0, base:{}};
        $meta[$k] as $mk
        | (($always | index($k)) != null) as $isalways
        | if ($mk.st == "gap" or $mk.st == "away") then
            .base[$k] = {render:true, shown:0} | .left -= ($mk.hcost + (phys(2 + ($mk.gap|length))))
          elif $k == "captains_call" then
            # Counts-only section: header + exactly ONE trailing line (the pointer
            # to the full desk, or the empty message), NEVER any rows. So it never
            # competes in the fill and never pays per-row cost - it just reserves
            # its fixed two-part cost and always renders.
            .left -= ($mk.hcost + 1)
            | .base[$k] = {render:true, shown:0}
          elif $isalways then
            # header + one trailing empty-message line, reserved ONLY when the
            # section holds no rows (a populated always-shown section paints its
            # rows and no trailing line now that the "+N more" pointer is gone).
            .left -= ($mk.hcost + (if $mk.total == 0 then 1 else 0 end))
            | .base[$k] = null            # rows still compete in the fill
          elif ($mk.st == "empty") then .base[$k] = {render:false, shown:0}
          else .base[$k] = null end)) as $init
    # Round-robin fill: repeatedly walk the ok sections in priority order adding
    # ONE row wherever the marginal line cost fits, until a whole pass adds none.
    # This balances the glance across the fleet instead of one section eating the
    # budget, while priority order still seats the first row of higher sections
    # first. A shorter pane simply completes fewer passes -> fewer rows.
    | ({left:$init.left, shown:(reduce $order[] as $k ({}; .[$k]=0)), done:false}
       | until(.done;
           (reduce $order[] as $k (. + {adv:false};
             if ($k != "captains_call") and ($meta[$k].st == "ok") and (.shown[$k] < $meta[$k].total) then
               (secost($k; .shown[$k] + 1) - secost($k; .shown[$k])) as $delta
               | if $delta <= .left then .left -= $delta | .shown[$k] += 1 | .adv = true
                 else . end
             else . end))
           | if .adv then . else .done = true end)
      ) as $rr
    | $rr.shown as $shown
    | $model
    | .sections = (reduce $order[] as $k (.sections;
        $meta[$k] as $mk
        | (($always | index($k)) != null) as $isalways
        | if ($init.base[$k] != null) then .[$k] += $init.base[$k]
          else
            ($shown[$k]) as $sh
            | ($mk.total - $sh) as $more
            | if ($sh <= 0 and (($isalways | not))) then .[$k] += {render:false, shown:0}
              else .[$k] += {render:true, shown:$sh, more:$more,
                  more_hint:(if $more > 0
                    then "+\($more) more - open the full desk"
                    else "" end)}
              end
          end))';
}

# _desk_section: emit the JSON for one bearings-backed section. st 2/3 -> gap (or
# away), empty raw -> empty, else ok with ranked rows whose text columns are
# translated, plus the collapse fields. Ranking lives in the row expression ($1)
# so it happens once here, never in a paint function.
#   $1 jq row expression   $2 comma field names   $3 gap sentence
#   $4 comma 1-based column numbers to translate (text fields only)
_desk_section() {
  local raw st status gap rows shaped
  raw=$(desk_json "$1"); st=$?
  gap=""
  if [ "$st" -eq 2 ] || [ "$st" -eq 3 ]; then
    gap=$(desk_section_sentence "$3")
    if [ "${DESK_AWAY:-0}" -eq 1 ] && [ -z "$DESK_BEAR" ]; then status="away"; else status="gap"; fi
    rows='[]'
  elif [ -z "$raw" ]; then
    status="empty"; rows='[]'
  else
    status="ok"
    rows=$(printf '%s' "$raw" | _desk_tsv_translate "$4" | _desk_rows "$2")
  fi
  shaped=$(printf '%s' "$rows" | _desk_collapse)
  jq -n --arg status "$status" --arg gap "$gap" --argjson shaped "$shaped" \
    '{status: $status, gap: $gap} + $shaped'
}

# _desk_fold_under_children: FEATURE 2. Take a built under_way section (stdin) and
# the timeout-robust cross-tree child-activity object ($1, from
# desk_secondmate_child_activity), and surface each secondmate's LIVE child task as
# its own under_way row tagged with the owner.
#
# The base section already carries ONE aggregate row per active mate (bearings
# folds an active_child_work mate into .in_flight as kind=secondmate). For a mate
# whose home the fs scan READ (home_read true) we DROP that aggregate and add one
# row per fs-verified busy child, id "[mate] <child-id>", so the captain sees the
# actual tasks being built. For a remote/unreadable mate (home_read false) the
# aggregate stays untouched - it is the only signal, and the header counts it via
# sec_remote, so replacing it would double-count. A mate that is NOT an aggregate
# row in the base (already surfaced some other way) is left alone.
#
# The child row's headline is a terse kind-derived verb (building / investigating /
# working), NEVER the child's free-text status (DEFECT A: that can be a diagnostic).
# The bullet is running (a provably-busy child). Rows re-collapse so shown/more stay
# honest. A gap/away/empty base, or an empty child object, passes through unchanged.
_desk_fold_under_children() {  # <child-activity-json>   reads DESK_CAP
  local child=$1
  [ -n "$child" ] || child='{}'
  local sec folded
  sec=$(cat)
  folded=$(printf '%s' "$sec" | jq -c --argjson child "$child" '
    # A verb per child kind: what is being built, terse and glanceable.
    def kindverb($k):
      if ($k == "ship" or $k == "build" or $k == "fix") then "building"
      elif $k == "scout" then "investigating"
      else "working" end;
    if (.status != "ok" and .status != "empty") then .
    else
      # Which mates the fs scan read AND has busy children for: their aggregate
      # row is replaced by real child rows. A read mate with zero busy children
      # simply drops its (now stale) aggregate; the header agrees (child_running 0).
      ( [ $child | to_entries[] | select(.value.home_read == true) | .key ] ) as $read_mates
      | ( [ $child | to_entries[]
            | .key as $mate | (.value.children // [])[]
            | { id: ("[" + $mate + "] " + .id),
                kind: "",
                state: "working",
                doing: kindverb(.kind),
                bullet: "running" } ] ) as $childrows
      | .rows = ( [ (.rows // [])[]
                    | select( (.state // "") as $st
                              | ($st == "active_child_work"
                                 and (.id as $mid | $read_mates | index($mid))) | not ) ]
                  + $childrows )
      | .status = (if (.rows | length) > 0 then "ok" else "empty" end)
    end') || { printf '%s' "$sec"; return 0; }
  printf '%s' "$folded" | _desk_recollapse
}

# _desk_recollapse: recompute total/shown/more/more_hint after a section rows
# array is edited in place, so a fold that adds or drops rows keeps the collapse
# fields honest (mirrors _desk_collapse, applied to an already-shaped section).
_desk_recollapse() {
  jq -c --argjson cap "$DESK_CAP" '
    .rows as $rows
    | ($rows | length) as $total
    | (if $cap > 0 and $total > $cap then $cap else $total end) as $shown
    | ($total - $shown) as $more
    | . + { total: $total, cap: $cap, shown: $shown, more: $more,
            more_hint: (if $more > 0
              then "+\($more) more - open the full desk"
              else "" end) }'
}

# desk_read_sources: read every source ONCE into DESK_* shell state. It is
# jq-free except at the projection read, where (jq present) it validates the
# projection is JSON and normalizes it at this single consumption point: the
# synthetic main-inventory gate row is dropped and Under Way is re-homed to real
# crew state (the rules live inline at that read). A board can render off this
# state directly (the jq-absent fallback) or hand it to desk_project for the
# fm-desk.v1 JSON. READ-ONLY but for two owned throttle caches:
# desk_jcode_usage_cached writes only state/desk-jcode-usage.json and
# desk_token_cost_cached writes only state/desk-token-cost.json.
# Sets: DESK_AWAY, DESK_HAVE_JQ, DESK_BEAR, DESK_MERGEQ, DESK_BEAT_AGE,
#       DESK_NOW, DESK_GAPS (accumulated).
desk_read_sources() {
  local snapshot_bin mergeq_bin beat_m
  DESK_NOW="${FM_DESK_NOW:-$(date -u '+%Y-%m-%d %H:%M:%S UTC')}"

  # Away status is read first: while away mode is active the shared away-return
  # guard refuses ordinary captain reads, so DESK_BEAR stays empty and the fleet
  # sections must say why.
  DESK_AWAY=0
  [ -e "$STATE/.afk" ] && DESK_AWAY=1
  DESK_GAPS=""

  DESK_BEAR=""
  DESK_HAVE_JQ=0
  if command -v jq >/dev/null 2>&1; then
    DESK_HAVE_JQ=1
  else
    note_gap "$DESK_GAP_NO_JQ"
  fi

  snapshot_bin="${FM_DESK_SNAPSHOT_BIN:-$FM_DESK_LIB_DIR/fm-bearings-snapshot.sh}"
  if [ "$DESK_HAVE_JQ" -eq 1 ]; then
    if DESK_BEAR=$(desk_bound "$snapshot_bin" --json --all-unhealthy 2>/dev/null) \
      && [ -n "$DESK_BEAR" ] && printf '%s' "$DESK_BEAR" | jq -e . >/dev/null 2>&1; then
      # The snapshot prepends a synthetic "(main-inventory)" gate row whenever a
      # main-home backlog<->task check fails (fm-bearings-snapshot.sh:405). That is
      # a fleet-integrity signal for firstmate, not captain-facing queued work, and
      # its wording ("no child metadata", "main inventory") is internal jargon. Drop
      # it from .gates here, at the single point the desk consumes the projection,
      # so both the header queued count and the Charted section stay clean. The
      # underlying check stays live in .main_inventory / .omitted for firstmate.
      #
      # Re-home Under Way to real state, not the trailing status word. `.in_flight`
      # carries fm-crew-state.sh's reconciled verdict, so key the membership on that
      # verdict plus the endpoint fact, never on the status headline (a status line
      # is a wake event, not current state). Three rules, applied here so the header
      # counts and the Under Way section read the same rows:
      #   - A terminal `done` crew-state leaves Under Way. Its deliverable is the
      #     pushed branch, so the merge section is the single awaiting-merge owner;
      #     dropping it here removes the double-listing and the "run passed" row that
      #     masqueraded as live work. A `done` task with no pushed branch (its work
      #     rode another task's branch) simply falls away - fewer rows, never a
      #     phantom awaiting-merge row for a branch that does not exist. The dropped
      #     ids are kept in `.departed` so the header's live-pane union (DEFECT 2 in
      #     desk_project) can keep agreeing with this section: a departed task is
      #     never counted as running, even while its pane is busy on follow-up.
      #   - A dead-endpoint task that is not itself terminal surfaces as an
      #     `attention` row: the worker is gone but its work is preserved. The raw
      #     endpoint id ("backend target gone: default:w6:pCC") is internal, so the
      #     headline becomes a plain-English "worker gone, work preserved" and the
      #     dead target string is dropped. The dead set is read from the uncapped
      #     `--all-unhealthy` list, so a dead worker past the default unhealthy cap
      #     still re-homes instead of keeping its raw headline.
      #   - A live-endpoint or genuinely active/paused task stays untouched, so a
      #     declared paused wait still reads as waiting (bclass) rather than idle.
      # kind=secondmate rows are folded child aggregates, never a direct report, so
      # they pass through unchanged. A projection without `in_flight` degrades to
      # an empty list rather than failing the whole pass.
      DESK_BEAR=$(printf '%s' "$DESK_BEAR" \
        | jq -c '
            .gates |= map(select(.id != "(main-inventory)"))
            | ([ (.unhealthy_endpoints // [])[]
                 | select(.exists == false) | .id ]) as $dead
            | .departed = [ (.in_flight // [])[]
                | select(.kind != "secondmate" and .state == "done") | .id ]
            | .in_flight = [ (.in_flight // [])[]
                | if (.kind == "secondmate") then .
                  elif (.state == "done") then empty
                  elif ((.state == "unknown")
                        and (.id as $i | ($dead | index($i)) != null)) then
                    .state = "attention"
                    | .doing = "worker gone, work preserved"
                  else . end ]' 2>/dev/null)
      if [ -z "$DESK_BEAR" ]; then
        note_gap "$DESK_GAP_UNREAD"
      fi
    elif [ "$DESK_AWAY" -eq 1 ]; then
      DESK_BEAR=""
      note_gap "$DESK_GAP_AWAY"
    else
      DESK_BEAR=""
      note_gap "$DESK_GAP_UNREAD"
    fi
  fi

  mergeq_bin="${FM_DESK_MERGEQ_BIN:-$FM_DESK_LIB_DIR/fm-merge-queue.sh}"
  if ! DESK_MERGEQ=$(desk_bound "$mergeq_bin" list --raw 2>/dev/null); then
    DESK_MERGEQ=""
    note_gap "$DESK_GAP_MERGEQ"
  fi

  # jcode-plane usage, fetched ONCE per repaint through the desk-owned disk cache
  # (desk_jcode_usage_cached). WHY once: the cache is the throttle, and calling the
  # fetch once here means BOTH the header usage line and the per-account numbers
  # read the SAME blob, so a single repaint never triggers two fetches. The blob's
  # age (line 1) drives the stale-reading age token in both consumers.
  local jcode_out jcode_json="" jcode_age=0
  if jcode_out=$(desk_jcode_usage_cached 2>/dev/null); then
    jcode_age=$(printf '%s' "$jcode_out" | head -1)
    jcode_json=$(printf '%s' "$jcode_out" | tail -n +2)
    case "$jcode_age" in ''|*[!0-9]*) jcode_age=0 ;; esac
  fi

  # Account usage line for the header (ITEM 4), for the ACTIVE account. A missing
  # cache (rc 1) is a GAP line, like every other source. "No usable window" (rc 2:
  # the active account carries no window) is NOT a gap - there is simply nothing to
  # show, so the header carries no usage line and says nothing.
  DESK_USAGE=""
  local usage_rc
  DESK_USAGE=$(desk_claude_usage "$jcode_json" "$jcode_age" 2>/dev/null); usage_rc=$?
  if [ "$usage_rc" -eq 1 ]; then
    DESK_USAGE=""
    note_gap "$DESK_GAP_QUOTA"
  elif [ "$usage_rc" -ne 0 ]; then
    DESK_USAGE=""
  fi

  # Claude accounts (all three) + which store points at which. The ROSTER comes
  # from cswap; the USAGE numbers come from the jcode blob above. A read FAILURE
  # (cswap absent, slow, or erroring: rc 1) is a GAP line. "No accounts" (rc 2)
  # is NOT a gap - there is simply nothing to show. Same policy as DESK_USAGE.
  DESK_ACCOUNTS=""
  local accounts_rc
  DESK_ACCOUNTS=$(desk_claude_accounts "$jcode_json" "$jcode_age" 2>/dev/null); accounts_rc=$?
  if [ "$accounts_rc" -eq 1 ]; then
    DESK_ACCOUNTS=""
    note_gap "$DESK_GAP_ACCOUNTS"
  elif [ "$accounts_rc" -ne 0 ]; then
    DESK_ACCOUNTS=""
  fi

  # Token-cost / efficiency panel: burn rate, cache-hit ratio, heaviest engines,
  # and cost per landed ticket. Read ONCE per repaint through the desk-owned disk
  # cache (desk_token_cost_cached), so the ~30s repaint reads the cheap cached blob
  # while the ~4s store-scanning recompute runs at most once per TTL. A missing or
  # unreadable blob is a GAP line, like every other source; a genuinely empty store
  # is NOT a gap (desk_token_cost renders an honest "no billed activity yet" line).
  DESK_TOKEN_COST=""
  local tc_out tc_age=0 tc_rc
  if tc_out=$(desk_token_cost_cached 2>/dev/null); then
    tc_age=$(printf '%s' "$tc_out" | head -1)
    local tc_blob
    tc_blob=$(printf '%s' "$tc_out" | tail -n +2)
    case "$tc_age" in ''|*[!0-9]*) tc_age=0 ;; esac
    DESK_TOKEN_COST=$(desk_token_cost "$tc_blob" "$tc_age" 2>/dev/null); tc_rc=$?
    [ "$tc_rc" -eq 0 ] || { DESK_TOKEN_COST=""; note_gap "$DESK_GAP_TOKEN_COST"; }
  else
    note_gap "$DESK_GAP_TOKEN_COST"
  fi

  # Fleet-health beacon age, by mtime.
  DESK_BEAT_AGE=""
  if [ -e "$STATE/.last-watcher-beat" ]; then
    beat_m=$(date -r "$STATE/.last-watcher-beat" +%s 2>/dev/null \
      || stat -c %Y "$STATE/.last-watcher-beat" 2>/dev/null \
      || stat -f %m "$STATE/.last-watcher-beat" 2>/dev/null || printf '')
    if [ -n "$beat_m" ]; then
      DESK_BEAT_AGE=$(( $(date +%s) - beat_m ))
      [ "$DESK_BEAT_AGE" -lt 0 ] && DESK_BEAT_AGE=0
    fi
  fi
}

# desk_project: read every source ONCE and emit the fm-desk.v1 view model.
# Requires jq (the model is JSON); a jq-free board reads desk_read_sources state
# directly. READ-ONLY but for two owned throttle caches: desk_jcode_usage_cached
# writes only state/desk-jcode-usage.json and desk_token_cost_cached writes only
# state/desk-token-cost.json.
desk_project() {
  desk_read_sources
  local away=$DESK_AWAY now=$DESK_NOW
  # Re-resolve the display cap each call so a board can set FM_DESK_CAP (from its
  # own pane height, or 0 for a scrollbar board) after sourcing the lib.
  DESK_CAP=${FM_DESK_CAP:-6}
  case "$DESK_CAP" in *[!0-9]*) DESK_CAP=6 ;; esac

  # --- header: the glance summary + the counts both boards read --------------
  # One screen must answer: what needs me (and how much is urgent), is anything
  # running, is anything broken, and how much is stacked behind.
  local decisions urgent running broken queued summary
  decisions=$(desk_json '.decisions_open | length' 2>/dev/null)
  urgent=$(desk_json '[.decisions_open[] | select(.verb == "needs-decision")] | length' 2>/dev/null)
  running=$(desk_json '[.in_flight[] | select(.state != "done" and .state != "attention" and .kind != "secondmate")] | length' 2>/dev/null)
  broken=$(desk_json '[.in_flight[] | select(.state == "blocked" or .state == "failed" or .state == "attention")] | length' 2>/dev/null)
  queued=$(desk_json '.gates | length' 2>/dev/null)
  decisions=${decisions:-0}; urgent=${urgent:-0}; running=${running:-0}
  broken=${broken:-0}; queued=${queued:-0}

  # DEFECT B: the running count must reflect work under way in secondmate CHILD
  # trees, not just the main home's direct reports. `.in_flight` counts only the
  # main home's own crews, so a full build night where a secondmate has crews
  # building read "Nothing is running". Add the timeout-robust per-mate child
  # count (built once here and reused to enrich the section below).
  local child_act sec_running sec_remote
  child_act=$(desk_secondmate_child_activity 2>/dev/null)
  [ -n "$child_act" ] || child_act='{}'
  sec_running=$(printf '%s' "$child_act" | jq '[.[].child_running] | add // 0' 2>/dev/null)
  case "$sec_running" in ''|*[!0-9]*) sec_running=0 ;; esac
  running=$((running + sec_running))
  # For a mate whose home the local scan could not read (a remote/unreadable home,
  # home_read false), the fs signal is silent, so fall back to its bearings
  # active_child_work in_flight row - excluded from the base count above - so its
  # child work still counts. A home the scan read (home_read true) is already
  # tallied by sec_running, so it is skipped here: never double-counted.
  sec_remote=0
  if [ -n "$DESK_BEAR" ]; then
    sec_remote=$(printf '%s' "$DESK_BEAR" | jq --argjson child "$child_act" '
      [ .in_flight[]
        | select(.kind == "secondmate" and .state == "active_child_work")
        | select(($child[.id].home_read // false) != true) ] | length' 2>/dev/null)
    case "$sec_remote" in ''|*[!0-9]*) sec_remote=0 ;; esac
  fi
  running=$((running + sec_remote))

  # DEFECT 2 (separate path from MR !30): add THIS home's own crews that are LIVE
  # busy but which the `.in_flight` projection does not carry as a running row.
  # Count a live id only when the base `.in_flight` running filter did NOT already
  # count it, so a normal working task is never double-counted, and never when it
  # is a `.departed` done task (desk_read_sources dropped it from Under Way): the
  # header must agree with the section, so a task whose run terminally passed is
  # not "running" even while its pane stays busy on follow-up work.
  local live_ids main_extra
  live_ids=$(desk_main_live_running_ids 2>/dev/null)
  [ -n "$live_ids" ] || live_ids='[]'
  main_extra=0
  if [ -n "$DESK_BEAR" ]; then
    main_extra=$(printf '%s' "$DESK_BEAR" | jq --argjson live "$live_ids" '
      ([ .in_flight[] | select(.kind != "secondmate" and .state != "done") | .id ]) as $counted
      | (.departed // []) as $departed
      | [ $live[] | select(($counted | index(.)) == null and ($departed | index(.)) == null) ] | length' 2>/dev/null)
    case "$main_extra" in ''|*[!0-9]*) main_extra=0 ;; esac
  fi
  running=$((running + main_extra))

  # --- per-section TRUE totals (the honest full count each header shows) ------
  # Every section header carries its section's true item count, not the ranked
  # working set (which each row expression bounds to DESK_MAX). These are the
  # captains_call/charted reuse decisions/queued; landed and secondmates read their
  # own source list length here. under_way's honest count is computed AFTER the
  # secondmate-child fold below (the fold adds/drops rows), from the folded section.
  local landed_count second_count
  landed_count=$(desk_json '.landed | length' 2>/dev/null)
  second_count=$(desk_json '.secondmates | length' 2>/dev/null)
  landed_count=${landed_count:-0}; second_count=${second_count:-0}
  if [ -z "$DESK_BEAR" ]; then
    if [ "$away" -eq 1 ]; then summary="$DESK_SUMMARY_AWAY"; else summary="$DESK_SUMMARY_UNREAD"; fi
  else
    local urg=""
    [ "$urgent" -gt 0 ] && [ "$urgent" -lt "$decisions" ] && urg=" (${urgent} urgent)"
    case "$decisions" in
      0) summary="Nothing needs your word." ;;
      1) summary="One thing needs your word${urg}." ;;
      *) summary="${decisions} things need your word${urg}." ;;
    esac
    case "$running" in
      0) summary="$summary Nothing is running." ;;
      1) summary="$summary One job is running" ;;
      *) summary="$summary ${running} jobs are running" ;;
    esac
    [ "$running" -gt 0 ] && { [ "$broken" -gt 0 ] && summary="$summary, ${broken} blocked." || summary="$summary."; }
    [ "$queued" -gt 0 ] && summary="$summary ${queued} stacked behind."
    [ "$away" -eq 1 ] && summary="$summary You are marked away."
  fi
  summary=$(desk_text "$summary")

  # --- merge rows (ids/branch/dest/url all verbatim, per the HTML board) ------
  local merge_count merge_rows
  merge_count=0
  [ -n "$DESK_MERGEQ" ] && merge_count=$(printf '%s\n' "$DESK_MERGEQ" | grep -c .)
  # Field order matches fm-merge-queue.sh list --raw: id repo branch sha dest url.
  # The HTML board rendered every merge field with desk_raw (no translation), so
  # the model carries them verbatim. url stays in the model (the HTML board paints
  # it as a real link); the TUI drops it as unusable terminal text. bullet is the
  # ready-to-land class both boards may lead the row with.
  merge_rows=$(printf '%s' "$DESK_MERGEQ" \
    | jq -R -s '
        [ split("\n")[] | select(length > 0) | split("\t") as $c
          | {id: ($c[0] // ""), branch: ($c[2] // ""), dest: ($c[4] // ""), url: ($c[5] // ""), bullet: "done"} ]')
  # The merge section carries raw rows, so it collapses through the same helper.
  local merge_section
  merge_section=$(printf '%s' "$merge_rows" | _desk_collapse)

  # --- per-section models ----------------------------------------------------
  # Each row expression RANKS (sort_by, stable) so the top rows are the ones that
  # matter, then bounds to DESK_MAX; _desk_section then applies DESK_CAP + the
  # collapse count. The last arg names the 1-based text columns to translate, so
  # ids and freshness stay verbatim exactly as the HTML board carried them. Only
  # priorities the data supports: decision urgency (verb), blocked/failed work
  # state, ready-vs-blocked gates, and active-vs-idle second mates.
  # Each row also carries a bullet CLASS (bclass) so a board can lead the row with
  # a status glyph without re-deriving state; the last @tsv column is that class,
  # excluded from the translate column list so it stays a stable token. Headlines
  # run through stripkind so a redundant leading "ship:"/"scout:" label is dropped.
  local s_call s_under s_charted s_landed s_second
  s_call=$(_desk_section \
    "[.decisions_open[]] | sort_by([(if .verb == \"needs-decision\" then 0 else 1 end), ((.priority // 9) | tonumber? // 9), (.since // \"9999\"), .id]) | .[:${DESK_MAX}][] | [.id, ((.summary // \"\")|z), bclass(\"captains_call\"; \"\"; .verb)] | @tsv" \
    "id,summary,bullet" \
    "$DESK_SENT_CAPTAINS" \
    "2")
  s_under=$(_desk_section \
    '[.in_flight[]] | sort_by(if (.state == "blocked" or .state == "failed" or .state == "attention") then 0 else 1 end) | .[] | [.id, (.kind // ""), (.state // ""), ((.doing // "")|z|stripkind), bclass("under_way"; .state; "")] | @tsv' \
    "id,kind,state,doing,bullet" \
    "$DESK_SENT_UNDER" \
    "4")
  # FEATURE 2: fold each secondmate's LIVE child task into Under Way with an owner
  # tag, so "what are we actively working on" is answered in one place. The base
  # rows carry this home's own crews plus bearings' ONE aggregate row per active
  # mate. For a mate whose home the fs scan READ (home_read true) we replace that
  # aggregate with its fs-verified busy child tasks, each tagged "[mate]"; for a
  # remote/unreadable mate (home_read false) the aggregate row stays, since it is
  # the only signal. This mirrors the header running count exactly (sec_running for
  # readable homes counts the same children, sec_remote counts the same remaining
  # aggregates), so the section and the header agree and nothing is double-counted.
  # The child KIND drives a terse verb (what is being built); the owner tag + child
  # id ride verbatim in the id column - never the child's free-text status, which
  # can be an internal diagnostic (DEFECT A). Only an ok/empty base is folded; a
  # gap/away base (fleet unread, e.g. away mode) is left untouched.
  s_under=$(printf '%s' "$s_under" | _desk_fold_under_children "$child_act")
  # under_way's honest header count now comes from the FOLDED section (child rows
  # added, stale mate aggregates dropped), not the raw .in_flight length, so the
  # header " (N)" matches the rows the captain can actually scroll.
  local inflight
  inflight=$(printf '%s' "$s_under" | jq '.rows | length' 2>/dev/null)
  case "$inflight" in ''|*[!0-9]*) inflight=0 ;; esac
  s_charted=$(_desk_section \
    "[.gates[]] | sort_by(if (.blocked_by // \"-\") == \"-\" then 0 else 1 end) | .[:${DESK_MAX}][] | [.id, ((.title // \"\")|z|stripkind), ((.blocked_by // \"\")|z), ((.reason // \"\")|z), bclass(\"charted\"; \"\"; \"\")] | @tsv" \
    "id,title,blocked_by,reason,bullet" \
    "$DESK_SENT_CHARTED" \
    "2,3,4")
  s_landed=$(_desk_section \
    ".landed[:${DESK_MAX}][] | [.id, ((.what // \"\")|z|stripkind), ((.artifact // \"\")|z), bclass(\"landed\"; \"\"; \"\")] | @tsv" \
    "id,what,artifact,bullet" \
    "$DESK_SENT_LANDED" \
    "2,3")
  s_second=$(_desk_section \
    '[.secondmates[]] | sort_by(if .state == "active_child_work" then 0 else 1 end) | .[] | [.id, (.state // ""), ((.doing // "")|z|stripkind), (.freshness // ""), bclass("secondmates"; .state; "")] | @tsv' \
    "id,state,doing,freshness,bullet" \
    "$DESK_SENT_SECOND" \
    "3")
  # Tier-2 enrichment: fold the live context-usage/idle reads into each second
  # mate row by id, so the MODEL owns those fields (the app never derives them).
  # A registered mate with no row still contributes usage; a row with no usage
  # entry gets an explicit unknown. This keeps the section the schema owner.
  local usage
  usage=$(desk_secondmate_usage 2>/dev/null)
  [ -n "$usage" ] || usage='{}'
  # child_act (the timeout-robust cross-tree running signal) was already built for
  # the header running count above; reuse it here so the section and the summary
  # can never disagree about which mate is working.
  # Fold usage + child activity in, then derive the captain-facing display fields.
  # DEFECT A: the raw bearings `doing`/`reason` free text can be an internal
  # diagnostic ("structured home state invalid: ..."), which must NEVER reach the
  # captain's board. So the secondmates section does NOT carry that free text: the
  # headline (doing) becomes a short plain-English status derived only from state
  # + child activity, and the trailing meta becomes the context+idle usage line
  # the captain actually asked for. context_tokens/idle_seconds stay on the row so
  # a consumer (the app drill-down) has the raw figures.
  s_second=$(printf '%s' "$s_second" | jq -c \
    --argjson usage "$usage" --argjson child "$child_act" '
    def humk($n): if $n == null then null
      elif $n >= 1000000 then (($n / 100000 | floor) / 10 | tostring) + "M"
      elif $n >= 1000 then (($n / 1000) | round | tostring) + "k"
      else ($n | tostring) end;
    def humdur($s): if $s == null then null
      elif $s < 60 then "just now"
      elif $s < 3600 then (($s / 60) | floor | tostring) + "m"
      elif $s < 86400 then (($s / 3600) | floor | tostring) + "h"
      else (($s / 86400) | floor | tostring) + "d" end;
    .rows = ((.rows // []) | map(
      (.id) as $id
      | . + ($usage[$id] //
          {context_tokens: null, idle_seconds: null,
           session_id: null, context_source: "unknown"})
      | .child_running = (($child[$id].child_running) // 0)
      | .home_read = (($child[$id].home_read) // false)
      | (humk(.context_tokens)) as $ctx
      | (humdur(.idle_seconds)) as $idle
      # Plain-English status, never a diagnostic. A readable home is fs-authoritative:
      # working iff a crew is building (child_running). Trust the bearings active-child
      # state only for a home the fs scan could not read (home_read false), so the row
      # agrees with the fs-authoritative header. A readable home the scan resolved to
      # 0 crews reads idle even if a stale snapshot still says active_child_work. Tracks
      # ACTIVITY, not context: a known idle state with no session file is idle, not
      # unknown; "unknown" is reserved for a genuinely unresolvable state.
      | .status_display = (
          if (.child_running > 0)
             or ((.home_read | not) and (.state == "active_child_work" or .state == "working" or .state == "running"))
            then "working"
          elif .state == "captain_decision" then "waiting on you"
          elif (.state == "no_active_work" or .state == "externally_held" or .state == "idle") then "idle"
          elif (.home_read and (.state == "active_child_work" or .state == "working" or .state == "running")) then "idle"
          else "unknown" end)
      # The usage line the captain asked for: context usage + time idle, terse.
      | .context_display = (if $ctx == null then "context unknown" else ($ctx + " ctx") end)
      # DEFECT 3: never show a large idle figure for a mate whose LIVE state is
      # working. A long-lived jcode session does not rewrite its session JSON per
      # turn, so idle_seconds can read hours while the agent is demonstrably
      # building - the exact false-wedge signal we fight. When status_display is
      # working the mate is provably active, so the idle figure is meaningless
      # noise: show "working" in its place rather than "idle 7h". Off the working
      # path the terse idle figure stands (or "idle unknown" when no signal read).
      | .idle_display = (
          if .status_display == "working" then "working"
          elif $idle == null then "idle unknown"
          else ("idle " + $idle) end)
      # Overwrite the display columns the boards paint so no diagnostic leaks:
      # headline = status word, trailing meta = "<ctx> · <idle>".
      | .doing = .status_display
      | .freshness = (.context_display + " · " + .idle_display)
      # Bullet reflects real activity: a working child tree is running, a captain
      # decision waits, everything else idles.
      | .bullet = (
          if .status_display == "working" then "running"
          elif .status_display == "waiting on you" then "waiting"
          else "idle" end)))')

  # --- gaps array ------------------------------------------------------------
  local gaps_json beat_age=$DESK_BEAT_AGE
  gaps_json=$(printf '%s' "$DESK_GAPS" | desk_plain \
    | jq -R -s '[ split("\n")[] | select(length > 0) ]')

  # --- emit fm-desk.v1 -------------------------------------------------------
  # generated_at is a machine-readable build stamp for the persisted cache (WP-1):
  # distinct from .now (the captain-facing "as of" string), it lets a consumer
  # judge cache staleness. FM_DESK_NOW pins it in tests for a stable document.
  local beat_json="null"
  [ -n "$beat_age" ] && beat_json="$beat_age"
  local usage_json="null"
  [ -n "$DESK_USAGE" ] && usage_json="$DESK_USAGE"
  local accounts_json="null"
  [ -n "$DESK_ACCOUNTS" ] && accounts_json="$DESK_ACCOUNTS"
  local token_cost_json="null"
  [ -n "$DESK_TOKEN_COST" ] && token_cost_json="$DESK_TOKEN_COST"
  local generated_at="${FM_DESK_NOW:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
  jq -n \
    --arg schema "fm-desk.v1" \
    --arg now "$now" \
    --arg generated_at "$generated_at" \
    --argjson away "$away" \
    --argjson beat "$beat_json" \
    --argjson usage "$usage_json" \
    --argjson accounts "$accounts_json" \
    --argjson token_cost "$token_cost_json" \
    --arg summary "$summary" \
    --argjson decisions "${decisions:-0}" \
    --argjson urgent "${urgent:-0}" \
    --argjson running "${running:-0}" \
    --argjson broken "${broken:-0}" \
    --argjson queued "${queued:-0}" \
    --argjson gaps "$gaps_json" \
    --argjson call "$s_call" \
    --argjson under "$s_under" \
    --argjson charted "$s_charted" \
    --argjson landed "$s_landed" \
    --argjson merge "$merge_section" \
    --argjson merge_count "$merge_count" \
    --argjson second "$s_second" \
    --argjson inflight "${inflight:-0}" \
    --argjson landed_count "${landed_count:-0}" \
    --argjson second_count "${second_count:-0}" \
    '{
      schema: $schema,
      now: $now,
      generated_at: $generated_at,
      away: ($away == 1),
      health: { beat_age_seconds: $beat },
      header: { summary: $summary,
                usage: $usage,
                accounts: $accounts,
                token_cost: $token_cost,
                counts: { decisions: $decisions, urgent: $urgent,
                          running: $running, blocked: $broken, queued: $queued } },
      gaps: $gaps,
      sections: {
        captains_call: ($call + { merge_count: $merge_count, full_total: $decisions }),
        under_way: ($under + { full_total: $inflight }),
        charted: ($charted + { full_total: $queued }),
        landed: ($landed + { full_total: $landed_count }),
        merge: ($merge + { full_total: $merge_count }),
        secondmates: ($second + { full_total: $second_count })
      }
    }'
}

# --- concern 3c: the persisted model cache (tier 1) --------------------------
# desk_persist_model: build the fm-desk.v1 document ONCE and write it to the
# cache file ATOMICALLY (temp in the same dir + rename), so a concurrent reader
# (the app) never sees a half-written model. This is the ONE writer of the cache;
# it exists so an interactive consumer loads a full model in milliseconds instead
# of paying the tens-of-seconds projection cost on its interactive path (build
# plan tier 1). The watcher bounds one detached refresh with DESK_REGEN_TIMEOUT
# (bin/fm-watch.sh owns that bound's rationale, sized against this function's
# measured cost) - re-check that bound if this function gets slower.
#
# Default path is $STATE/desk-model.json (gitignored runtime state); override
# with FM_DESK_MODEL_OUT. The write is best-effort: a build or write failure
# returns nonzero and leaves any prior good cache untouched, so a bad render can
# never replace a good model with a truncated one. Requires jq (the model is
# JSON); with no jq it records nothing and returns nonzero.
#   $1  optional pre-built model JSON (skips a second desk_project build); when
#       omitted, this builds it. A board that already built the model for its own
#       render passes it here so the projection runs exactly once.
desk_persist_model() {
  command -v jq >/dev/null 2>&1 || return 1
  local out model tmp
  out="${FM_DESK_MODEL_OUT:-$STATE/desk-model.json}"
  if [ "$#" -ge 1 ] && [ -n "$1" ]; then
    model=$1
  else
    model=$(desk_project) || return 1
  fi
  [ -n "$model" ] && printf '%s' "$model" | jq -e . >/dev/null 2>&1 || return 1
  local dir
  dir=$(dirname "$out")
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp="$dir/.$(basename "$out").tmp.$$"
  if ! printf '%s\n' "$model" > "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  if ! mv -f "$tmp" "$out" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  return 0
}
