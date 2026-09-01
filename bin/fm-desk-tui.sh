#!/usr/bin/env bash
# fm-desk-tui.sh - the captain's desk in a terminal: paint THIS home's current
# fleet state in the captain's own vocabulary to stdout, either as ONE static
# frame (--once) or self-refreshing on an interval (--loop).
#
# This board reads the SAME normalized view model (schema fm-desk.v1) from the
# shared data layer (bin/fm-desk-lib.sh) as the compiled desk app (the desk/
# crate), so every board renders the same fleet truth in the same words. They
# share the model and split only the paint: this board emits ANSI + box rules,
# the compiled app paints its own frame. Neither re-derives which fields a
# section shows, how an absent source degrades to a gap, or which internal words
# get rewritten - the lib owns all of that (the one-owner rule in
# firstmate-coding-guidelines).
#
# Usage:
#   fm-desk-tui.sh              paint one frame (--once) to stdout
#   fm-desk-tui.sh --once       the same, explicitly
#   fm-desk-tui.sh --loop [secs]  self-refresh: repaint the whole desk on an
#                               interval in an alternate screen buffer until a
#                               signal (Ctrl-C) restores the terminal. Interval
#                               is [secs] if given, else FM_DESK_TUI_INTERVAL,
#                               else 5. On a non-terminal stdout --loop degrades
#                               to a single --once paint (nothing to refresh).
#   fm-desk-tui.sh --help
#
# The loop is READ-ONLY and NEVER WAKES exactly like --once: each tick just
# re-runs the same read-only desk_project + paint the --once path uses. It builds
# the whole frame into a buffer and emits it in ONE write per tick to minimize
# flicker, hides the cursor while running, and traps INT/TERM/EXIT to restore the
# terminal (leave the alternate screen, show the cursor, reset colors) so the pane
# is left clean on Ctrl-C or any exit. A tick whose sources fail degrades to the
# previous good frame (or a clearly-marked banner), never a blank screen. A resize
# is handled simply: the next tick re-reads `tput cols`.
#
# Exit status:
#   0  a frame was painted (possibly with noted gaps)
#   64 usage error
#
# READ-ONLY / NEVER WAKES. This board only READS its sources, but for two owned
# throttle caches: the lib's desk_jcode_usage_cached writes only
# state/desk-jcode-usage.json and desk_token_cost_cached writes only
# state/desk-token-cost.json. It appends no status line and calls no wake/send
# path. Painting a board is not captain-facing progress (AGENTS.md section 8), so
# it reports nothing and interrupts nobody. The never-wakes property - no status
# append, no wake queue, no state/ write beyond those two caches - is tested
# (tests/fm-desk-tui.test.sh).
#
# LANGUAGE. This is a captain-private LOCAL artifact, so task ids are shown
# VERBATIM. Unlike the HTML board, the TUI does NOT paint the merge section's
# ~95-char compare URL (unusable terminal text) or its branch (redundant with the
# id) - an accepted TUI/HTML divergence; any URL that survives as free text (a
# landed artifact link) still passes through verbatim. The view model's free-text
# strings are already desk_text-translated by the lib; this board passes them
# through (it does NOT HTML-escape - that is the HTML board's job) and strips only
# control characters for terminal safety.
#
# COLOR / WIDTH. ANSI color comes from tput and is emitted only when stdout is a
# terminal that reports colors; TERM=dumb, a pipe, or a redirect all yield plain
# deterministic text (so piping/logging this is harmless). Width comes from
# `tput cols` with an 80 fallback, floored at 40 so a narrow pane still lays out.
#
# NON-TTY FALLBACK. When stdout is not a terminal ([ -t 1 ]) the board runs in
# --once plain-text mode with no color and no cursor control, so redirecting or
# piping it never emits control codes into a file.
#
# Test seams (shared with the HTML board, via the lib): FM_DESK_SNAPSHOT_BIN
# overrides the fleet projection, FM_DESK_MERGEQ_BIN overrides the merge queue,
# FM_DESK_NOW injects the timestamp, FM_DESK_TIMEOUT bounds each source, and
# FM_DESK_MAX bounds each unbounded list. FM_DESK_TUI_COLS overrides the width
# and FM_DESK_TUI_ROWS the pane height (so a test can pin layout without a real
# terminal); by default this board budgets its PHYSICAL painted lines to that
# height and clips each painted line to that width (see resolve_cap, which hands
# the budget to the lib's desk_fit, and clip_frame, the one width owner).
# FM_DESK_CAP pins a fixed per-section row cap instead, bypassing the
# line budget (a test or the operator). FM_DESK_TUI_INTERVAL sets
# the --loop repaint interval in seconds (default 5; an explicit `--loop [secs]`
# argument wins over it). FM_DESK_TUI_FORCE_LOOP=1 forces --loop to run its real
# refresh loop even when stdout is not a terminal (so a test can drive the loop
# through a pipe); without it, --loop on a non-tty degrades to a single paint.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# Export the resolved home so every child source reads the SAME home this board
# resolved, rather than each defaulting to its own script-relative code root.
export FM_HOME

# The desk data layer: the ONE owner of reading fleet state, translating internal
# vocabulary, and shaping the fm-desk.v1 view model this board renders. This board
# owns only concern (c): terminal painting.
# shellcheck source=bin/fm-desk-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-desk-lib.sh"

# The header comment IS the help text: from the description line down to the last
# comment line before `set -u`.
usage() {
  sed -n '2,72p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- concern (c): terminal capabilities -------------------------------------
# Color is emitted only for a real terminal. A pipe, a redirect, or TERM=dumb all
# yield plain text so the output is deterministic and safe to log.
C_RESET="" C_BOLD="" C_DIM="" C_HEAD="" C_ID="" C_GAP="" C_WARN="" C_OK="" C_RUN=""
HAVE_COLOR=0
if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && command -v tput >/dev/null 2>&1 \
  && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ] 2>/dev/null; then
  HAVE_COLOR=1
  C_RESET=$(tput sgr0 2>/dev/null || printf '')
  C_BOLD=$(tput bold 2>/dev/null || printf '')
  C_DIM=$(tput dim 2>/dev/null || printf '')
  C_HEAD=$(tput setaf 4 2>/dev/null || printf '')   # blue section rules
  C_ID=$(tput setaf 6 2>/dev/null || printf '')      # cyan ids
  C_GAP=$(tput setaf 3 2>/dev/null || printf '')     # yellow gaps
  C_WARN=$(tput setaf 1 2>/dev/null || printf '')    # red blocked/failed
  C_OK=$(tput setaf 2 2>/dev/null || printf '')      # green done/landed
  C_RUN=$(tput setaf 6 2>/dev/null || printf '')     # cyan running
fi

# bullet: lead a row with a status glyph for the lib's bullet CLASS. With color a
# single-width colored circle (U+25CF, measured single-width) reads at a glance;
# WITHOUT color the shape itself must still convey status, so each class maps to a
# DISTINCT ASCII char (never color-alone). Vocabulary (one meaning everywhere):
#   blocked  red    x   needs attention (blocked/failed)
#   waiting  yellow ?   waiting on the captain
#   running  cyan   >   actively running
#   done     green  +   landed / ready to land
#   idle     dim    .   queued / idle
bullet() {  # <class>  ->  "<glyph> " ready to prefix a row
  local class=$1 col ch
  case "$class" in
    blocked) col=$C_WARN ch='x' ;;
    waiting) col=$C_GAP  ch='?' ;;
    running) col=$C_RUN  ch='>' ;;
    done)    col=$C_OK   ch='+' ;;
    *)       col=$C_DIM  ch='.' ;;
  esac
  if [ "$HAVE_COLOR" -eq 1 ]; then
    printf '%s\xe2\x97\x8f%s ' "$col" "$C_RESET"
  else
    printf '%s ' "$ch"
  fi
}

# class_color: the SGR colour for a usage CLASS, same vocabulary as bullet (so no
# second colour language). Empty when colour is off, so the token still reads by
# its baked ascii glyph alone.
class_color() {  # <class>  ->  a colour escape, or "" without colour
  [ "$HAVE_COLOR" -eq 1 ] || { printf ''; return; }
  case "$1" in
    blocked) printf '%s' "$C_WARN" ;;
    waiting) printf '%s' "$C_GAP" ;;
    done)    printf '%s' "$C_OK" ;;
    *)       printf '%s' "$C_DIM" ;;
  esac
}

# Terminal width: FM_DESK_TUI_COLS wins (so a test pins layout), then the real
# terminal's `tput cols`, then 80. Floored at 40 so a very narrow pane still lays
# out. desk_cols only validates and floors a candidate width; the raw candidate is
# resolved at top-level scope below, where the `[ -t 1 ]` check sees the real fd 1.
# Inside a COLS=$(desk_cols) command substitution fd 1 would be the capture pipe,
# so a tty check there is always false and the tput branch is dead code.
desk_cols() {
  local c=${1:-}
  case "$c" in ''|*[!0-9]*) c=80 ;; esac
  [ "$c" -lt 40 ] && c=40
  printf '%s' "$c"
}

# resolve_cols: (re)set the global COLS from FM_DESK_TUI_COLS, else the real
# terminal's `tput cols`, else the 80 fallback. Called once for --once and once
# per tick in --loop, so a resize (SIGWINCH) is picked up simply: the next tick's
# call re-reads `tput cols`, no immediate mid-tick redraw needed.
resolve_cols() {
  local raw="${FM_DESK_TUI_COLS:-}"
  if [ -z "$raw" ] && [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    raw=$(tput cols 2>/dev/null || printf '')
  fi
  COLS=$(desk_cols "$raw")
}
resolve_cols

# resolve_cap: derive the PHYSICAL-LINE budget for the whole board from the pane
# height and hand it to the lib's desk_fit (the one owner of per-row and
# per-chrome line cost). This board budgets PAINTED LINES, not rows: many rows
# paint a second detail line, so a row count systematically under-counts. Width
# no longer inflates the cost - clip_frame keeps every painted line to one
# physical row - so the budget is a plain line count.
# We leave the lib UNCAPPED (every ranked row present in the model) and let
# desk_fit trim to what fits the budget, dropping a whole section
# (header included) when nothing fits rather than paying 3 lines for a bare
# collapse notice. A shorter pane therefore shows FEWER rows, never the same 3
# (the old (rows-20)/8 floored at 3 inverted this). FM_DESK_CAP still wins (a test
# or the operator pins a row cap and bypasses the line budget); FM_DESK_TUI_ROWS,
# then `tput lines`, then 49 give the height.
resolve_cap() {
  # An explicit cap set before this script ran (a test, or the operator) wins: it
  # pins a row cap and bypasses the line budget entirely.
  if [ "${DESK_CAP_EXPLICIT:-}" = 1 ]; then export FM_DESK_CAP; unset FM_DESK_BUDGET; return 0; fi
  local rows="${FM_DESK_TUI_ROWS:-}"
  if [ -z "$rows" ] && [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    rows=$(tput lines 2>/dev/null || printf '')
  fi
  case "$rows" in ''|*[!0-9]*) rows=49 ;; esac
  [ "$rows" -lt 1 ] && rows=1
  # Uncapped rows into the model; desk_fit does the fitting against the budget.
  # Width is enforced by clip_frame at paint time, so desk_fit needs only the
  # height budget - one painted line is one physical row.
  unset FM_DESK_CAP
  export FM_DESK_BUDGET="$rows"
}
[ -n "${FM_DESK_CAP:-}" ] && DESK_CAP_EXPLICIT=1
resolve_cap

# desk_clean: strip control characters (except none - all removed) for terminal
# safety. The lib already translated the text; ids/branches/URLs are carried
# verbatim, and printable content stays intact. This only removes bytes that
# would move the cursor or reset the terminal.
desk_clean() {
  printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037\177'
}

# clip_frame: the ONE width owner every painted line passes through. No line may
# exceed COLS visible columns, so nothing wraps into a second physical row. Width
# is measured on VISIBLE columns: ANSI SGR escapes are zero-width, and each
# character (including the 3-byte U+25CF bullet) is one column. A line already
# within COLS is emitted verbatim - only rules span the full width, and they land
# exactly at COLS. An over-wide line keeps its leading columns (status glyph and
# headline, the part the captain acts on) and drops the trailing tail (id, meta),
# marking the cut with the existing "…" and a reset so color never bleeds. Byte
# semantics (LC_ALL=C) make the measure independent of the ambient locale: a
# UTF-8 continuation byte (0x80-0xBF) is not a new column, so multibyte glyphs
# count as one and cut on a character boundary.
clip_frame() {
  LC_ALL=C awk -v cols="$COLS" -v reset="$C_RESET" '
    BEGIN { for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i; ell = "\342\200\246" }
    function isletter(o) { return (o >= 65 && o <= 90) || (o >= 97 && o <= 122) }
    function vwidth(s,   n, i, c, o, inesc, w) {
      n = length(s); inesc = 0; w = 0
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1); o = ord[c]
        if (inesc) { if (isletter(o)) inesc = 0; continue }
        if (o == 27) { inesc = 1; continue }
        if (o >= 128 && o < 192) continue     # UTF-8 continuation byte
        w++
      }
      return w
    }
    function clip(s,   n, i, c, o, inesc, w, out, limit) {
      if (vwidth(s) <= cols) return s
      limit = cols - 1                         # reserve one column for the ellipsis
      n = length(s); inesc = 0; w = 0; out = ""
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1); o = ord[c]
        if (inesc) { out = out c; if (isletter(o)) inesc = 0; continue }
        if (o == 27) { inesc = 1; out = out c; continue }
        if (o >= 128 && o < 192) { out = out c; continue }  # part of the current char
        if (w >= limit) break                  # next char starts here: cut on the boundary
        w++; out = out c
      }
      return out ell reset
    }
    { print clip($0) }
  '
}

# _dv: read one jq expression out of the fm-desk.v1 view model in DESK_MODEL. The
# single accessor every paint_* function uses; -r so scalars come through as
# plain text and streamed rows read row by row.
_dv() { printf '%s' "$DESK_MODEL" | jq -r "$1" 2>/dev/null; }

# rule: a section header - a bold title over a horizontal rule spanning COLS.
# An optional COUNT folds the section's TOTAL item count into the title as
# " (N)", so the captain reads the size off a header he already scans and the
# collapsed-tail row below is unnecessary (that "+N more" row is not painted on
# this board). The count is passed only for a populated (ok) section; an empty,
# gap, or away section says its own thing and gets no silly "(0)". clip_frame
# still clips the longer title to COLS, so the width guarantee holds.
rule() {
  local title=$1 count=${2:-} line
  [ -n "$count" ] && title="$title ($count)"
  line=$(printf '%*s' "$COLS" '' | tr ' ' '-')
  printf '\n%s%s%s\n%s%s%s\n' "$C_BOLD$C_HEAD" "$title" "$C_RESET" \
    "$C_HEAD" "$line" "$C_RESET"
}

# lead_line: a row's headline - the plain-English question or outcome, bold, with
# the task id in a DIM TRAILING position (the captain reads the headline to act;
# the id matters only once he does). Falls back to the id alone when there is no
# headline. meta is composed+control-stripped by the caller so it may fold in an
# intentional ANSI state highlight rather than have it stripped as a control byte.
# bull is a bullet CLASS (from the lib): the row leads with a status glyph in
# place of the plain indent, so the glyph carries state and costs the same two
# leading columns the indent used to.
lead_line() {
  local head=$1 id=$2 meta=${3:-} bull=${4:-}
  local lead
  if [ -n "$bull" ]; then lead=$(bullet "$bull"); else lead='  '; fi
  local trail
  trail="$C_DIM$(desk_clean "$id")$C_RESET"
  [ -n "$meta" ] && trail="$trail  $C_DIM$meta$C_RESET"
  if [ -n "$head" ]; then
    printf '%s%s%s%s  %s\n' "$lead" "$C_BOLD" "$(desk_clean "$head")" "$C_RESET" "$trail"
  else
    printf '%s%s%s%s%s\n' "$lead" "$C_ID" "$(desk_clean "$id")" "$C_RESET" "${meta:+  $C_DIM$meta$C_RESET}"
  fi
}

# body_line: an indented plain content line (translated text, control-stripped).
body_line() {
  [ -n "$1" ] || return 0
  printf '      %s\n' "$(desk_clean "$1")"
}

# gap_line / empty_line: the explicit degraded markers, colored when possible.
gap_line() { printf '  %s%s%s\n' "$C_GAP" "$(desk_clean "$1")" "$C_RESET"; }
empty_line() { printf '  %s%s%s\n' "$C_DIM" "$(desk_clean "$1")" "$C_RESET"; }

# folded: on the height-constrained TUI an empty routine section is redundant
# with the top summary's counts, so it is skipped entirely (the HTML board, which
# has a scrollbar, still renders it). A gap/away status is NEVER folded - hiding
# a failed source would make it confusable with "nothing here".
folded() { [ "$(_dv ".sections.$1.status")" = "empty" ]; }

# hidden: desk_fit drops a section (header included) when no row fits the line
# budget, marking it render:false. A section explicitly marked render:false is
# skipped; when the field is absent (no line budget in play) nothing is hidden.
# gap/away sections are never given render:false by desk_fit, so a failed source
# still shows.
hidden() { [ "$(_dv "if (.sections.$1 | has(\"render\")) then .sections.$1.render else true end")" = "false" ]; }

# --- paint helpers (concern c only) -----------------------------------------
# Header: title + summary. The "as of <time>" stamp folds onto the title line
# (dim, trailing) rather than owning its own row - the board self-refreshes, so
# the stamp is a footnote, not a headline.
paint_header() {
  local now summary usage
  now=$(_dv '.now')
  summary=$(_dv '.header.summary')
  printf '%sCaptain'\''s desk%s  %sas of %s%s\n' \
    "$C_BOLD" "$C_RESET" "$C_DIM" "$(desk_clean "$now")" "$C_RESET"
  printf '%s\n' "$(desk_clean "$summary")"
  # ITEM 4: the captain's Claude usage, one dim line, only when the model carries
  # it. The line is a verbatim identifier/percent string (no translation), so it
  # is painted through desk_clean (control-strip + clip) alone.
  usage=$(_dv '.header.usage.line')
  [ -n "$usage" ] && [ "$usage" != null ] \
    && printf '%s%s%s\n' "$C_DIM" "$(desk_clean "$usage")" "$C_RESET"
  # The captain's Claude accounts: a dim caption then one line per account, each
  # pre-rendered by the MODEL so this board and the app paint identical text. The
  # caption states the honesty caveat (configured store, not the live token). Each
  # line leads with a usage-severity bullet (the lib's line_classes, same glyph
  # vocabulary as row bullets: green headroom, yellow tight, red spent) so which
  # account has room reads at a glance; without color the bullet degrades to a
  # distinct ascii shape, so state never rides on color alone. No "press w to
  # switch" hint here: this terminal board takes no keystrokes (the app owns w).
  local acct_caption acct_lines acct_classes
  acct_caption=$(_dv '.header.accounts.caption')
  acct_lines=$(_dv '.header.accounts.lines[]')
  if [ -n "$acct_lines" ] && [ "$acct_lines" != null ]; then
    [ -n "$acct_caption" ] && [ "$acct_caption" != null ] \
      && printf '%s%s%s\n' "$C_DIM" "$(desk_clean "$acct_caption")" "$C_RESET"
    # Read the classes into an aligned array so each line gets its own bullet.
    acct_classes=$(_dv '.header.accounts.line_classes[]')
    local -a class_arr=()
    if [ -n "$acct_classes" ] && [ "$acct_classes" != null ]; then
      while IFS= read -r c; do class_arr+=("$c"); done <<EOF
$acct_classes
EOF
    fi
    # Per-window tokens + classes (parallel to lines), so each of the 5h and 7d
    # tokens is coloured from its OWN class the model computed - never by parsing
    # the line. Colour wraps the token AFTER desk_clean (which strips ESC), and
    # the token already carries its ascii shape glyph so NO_COLOR still reads it.
    local -a f_tok=() f_cls=() s_tok=() s_cls=()
    _read_arr() { local -n _a=$1; local v=$2 x; _a=(); if [ -n "$v" ] && [ "$v" != null ]; then
      while IFS= read -r x; do _a+=("$x"); done <<EOF
$v
EOF
      fi; }
    _read_arr f_tok "$(_dv '.header.accounts.five_hour_tokens[]')"
    _read_arr f_cls "$(_dv '.header.accounts.five_hour_classes[]')"
    _read_arr s_tok "$(_dv '.header.accounts.seven_day_tokens[]')"
    _read_arr s_cls "$(_dv '.header.accounts.seven_day_classes[]')"
    local ai=0
    printf '%s\n' "$acct_lines" | while IFS= read -r acct_line; do
      [ -n "$acct_line" ] || continue
      local cls="${class_arr[$ai]:-idle}"
      local painted; painted=$(desk_clean "$acct_line")
      # Colour each window's exact token in place (only when that token is
      # non-empty, i.e. the window is measured). The token is a literal substring
      # of the line the lib baked, so a first-match replace is exact.
      local ft="${f_tok[$ai]:-}" fc="${f_cls[$ai]:-idle}"
      local st="${s_tok[$ai]:-}" sc="${s_cls[$ai]:-idle}"
      if [ -n "$ft" ] && [ "$HAVE_COLOR" -eq 1 ]; then
        painted="${painted/"$ft"/$(class_color "$fc")$ft$C_RESET}"
      fi
      if [ -n "$st" ] && [ "$HAVE_COLOR" -eq 1 ]; then
        painted="${painted/"$st"/$(class_color "$sc")$st$C_RESET}"
      fi
      printf '%s%s\n' "$(bullet "$cls")" "$painted"
      ai=$((ai + 1))
    done
  fi
}

paint_gaps() {
  local gaps
  gaps=$(_dv '.gaps[]')
  [ -n "$gaps" ] || return 0
  rule "Some of this board is missing"
  printf '%s\n' "$gaps" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    gap_line "$line"
  done
}

# Fleet health: chrome only when something is WRONG. When monitoring is alive and
# the captain is present (the near-always case) this paints NOTHING - a healthy
# fleet needs no five-line "everything is fine" block. It surfaces a single dim
# line only when monitoring may have lapsed or the captain is marked away.
paint_health() {
  local beat present line=""
  beat=$(_dv '.health.beat_age_seconds')
  if [ -z "$beat" ] || [ "$beat" = "null" ]; then
    line="Monitoring status is unknown; no recent check was recorded."
  elif [ "$beat" -gt 1800 ]; then
    line="Monitoring may have lapsed (last check about ${beat}s ago)."
  fi
  present=$(_dv '.away')
  [ "$present" = "true" ] && line="${line:+$line }You are marked away."
  [ -n "$line" ] || return 0
  printf '%s%s%s\n' "$C_GAP" "$(desk_clean "$(desk_text "$line")")" "$C_RESET"
}

# Captain's Call: how many decisions await the captain's word. On this board the
# section is COUNTS ONLY - the total sits in the header and NO question text or
# top slice is painted - but it still points at where the real questions live
# (the full desk keeps every decision card), so the count is navigation, not a
# dead end. That header total is the sum the later per-project breakdown must
# match. The HTML board keeps the full question cards (the accepted TUI/HTML
# divergence); only this terminal paint collapses to a count plus a pointer.
paint_captains_call() {
  local status merge_count count=""
  hidden captains_call && return 0
  status=$(_dv '.sections.captains_call.status')
  [ "$status" = "ok" ] && count=$(_dv '.sections.captains_call.full_total')
  rule "Captain's Call" "$count"
  merge_count=$(_dv '.sections.captains_call.merge_count')
  if [ "$status" = "gap" ] || [ "$status" = "away" ]; then
    gap_line "$(_dv '.sections.captains_call.gap')"
  elif [ "$status" = "empty" ]; then
    if [ "${merge_count:-0}" -gt 0 ]; then
      empty_line "No open decisions. Finished branches are waiting to merge (see below)."
    else
      empty_line "Nothing needs your action right now."
    fi
  else
    # Counts only: point at where the questions are readable in full.
    empty_line "Open the full desk to read them."
  fi
}

# Under Way: in-flight work, what it is doing first, state highlighted.
paint_underway() {
  local status count=""
  folded under_way && return 0
  hidden under_way && return 0
  status=$(_dv '.sections.under_way.status')
  [ "$status" = "ok" ] && count=$(_dv '.sections.under_way.full_total')
  rule "Under Way" "$count"
  if [ "$status" = "gap" ] || [ "$status" = "away" ]; then
    gap_line "$(_dv '.sections.under_way.gap')"
  elif [ "$status" = "empty" ]; then
    empty_line "No work is under way."
  else
    _dv '.sections.under_way.rows[:.sections.under_way.shown][] | .id, .kind, .doing, .bullet' \
      | while IFS= read -r id && IFS= read -r kind && IFS= read -r doing && IFS= read -r bull; do
      [ -n "$id" ] || continue
      # The bullet carries state (and degrades to a distinct char), so the state
      # WORD is cut; kind stays as dim trailing meta (the section does not imply it).
      lead_line "$doing" "$id" "$(desk_clean "$kind")" "$bull"
    done
  fi
}

# Charted / Queued next: gates, title first, why-blocked as a dim body line.
paint_charted() {
  local status count=""
  folded charted && return 0
  hidden charted && return 0
  status=$(_dv '.sections.charted.status')
  [ "$status" = "ok" ] && count=$(_dv '.sections.charted.full_total')
  rule "Charted / Queued next" "$count"
  if [ "$status" = "gap" ] || [ "$status" = "away" ]; then
    gap_line "$(_dv '.sections.charted.gap')"
  elif [ "$status" = "empty" ]; then
    empty_line "Nothing is charted or queued."
  else
    _dv '.sections.charted.rows[:.sections.charted.shown][] | .id, .title, .blocked_by, .reason, .bullet' \
      | while IFS= read -r id && IFS= read -r title && IFS= read -r blocked_by && IFS= read -r reason && IFS= read -r bull; do
      [ -n "$id" ] || continue
      lead_line "$title" "$id" "" "$bull"
      local why=""
      [ -n "$blocked_by" ] && [ "$blocked_by" != "-" ] && why="waits on $blocked_by"
      [ -n "$reason" ] && [ "$reason" != "-" ] && why="${why:+$why - }$reason"
      [ -n "$why" ] && body_line "$why"
    done
  fi
}

# Recently Landed: what landed first, artifact link as a dim body line.
paint_landed() {
  local status count=""
  folded landed && return 0
  hidden landed && return 0
  status=$(_dv '.sections.landed.status')
  [ "$status" = "ok" ] && count=$(_dv '.sections.landed.full_total')
  rule "Recently Landed" "$count"
  if [ "$status" = "gap" ] || [ "$status" = "away" ]; then
    gap_line "$(_dv '.sections.landed.gap')"
  elif [ "$status" = "empty" ]; then
    empty_line "Nothing landed recently."
  else
    _dv '.sections.landed.rows[:.sections.landed.shown][] | .id, .what, .artifact, .bullet' \
      | while IFS= read -r id && IFS= read -r what && IFS= read -r artifact && IFS= read -r bull; do
      [ -n "$id" ] || continue
      lead_line "$what" "$id" "" "$bull"
      [ -n "$artifact" ] && [ "$artifact" != "-" ] && body_line "$artifact"
    done
  fi
}

# Ready to merge: finished-but-unmerged branches. The id and branch are the same
# string with an "fm/" prefix, so only the id is shown; the compare URL is CUT
# (unusable ~95-char terminal text - the HTML board keeps it as a real link). The
# destination stays because it genuinely varies (dev vs main).
paint_merge() {
  local mcount count=""
  hidden merge && return 0
  mcount=$(_dv '.sections.merge.full_total')
  [ "${mcount:-0}" -gt 0 ] && count=$mcount
  rule "Ready to merge (finished, not yet landed)" "$count"
  if [ "${mcount:-0}" -eq 0 ]; then
    empty_line "No finished branches waiting to merge."
    return 0
  fi
  _dv '.sections.merge.rows[:.sections.merge.shown][] | .id, .dest, .bullet' \
    | while IFS= read -r id && IFS= read -r dest && IFS= read -r bull; do
    [ -n "$id" ] || continue
    lead_line "" "$id" "-> $(desk_clean "$dest")" "$bull"
  done
}

# Second mates: what each is doing first, state/freshness as dim trailing meta.
paint_secondmates() {
  local status count=""
  folded secondmates && return 0
  hidden secondmates && return 0
  status=$(_dv '.sections.secondmates.status')
  [ "$status" = "ok" ] && count=$(_dv '.sections.secondmates.full_total')
  rule "Second mates" "$count"
  if [ "$status" = "gap" ] || [ "$status" = "away" ]; then
    gap_line "$(_dv '.sections.secondmates.gap')"
  elif [ "$status" = "empty" ]; then
    empty_line "No second mates registered."
  else
    _dv '.sections.secondmates.rows[:.sections.secondmates.shown][] | .id, .doing, .freshness, .bullet' \
      | while IFS= read -r id && IFS= read -r doing && IFS= read -r freshness && IFS= read -r bull; do
      [ -n "$id" ] || continue
      # The bullet carries state; only freshness trails. The row truncates like
      # every other (the lib bounds .doing), so no more 168-char runaway lines.
      lead_line "$doing" "$id" "$(desk_clean "$freshness")" "$bull"
    done
  fi
}

# paint_frame: build the whole frame ONCE, then pass every painted line through
# the ONE width owner (clip_frame) so no physical line exceeds COLS and nothing
# wraps. paint_frame_body does the section painting; clip_frame enforces width on
# the whole frame in one place rather than a clip bolted onto each call site.
paint_frame() {
  paint_frame_body | clip_frame
}

# paint_frame_body: build the whole frame from the shared view model. When jq is
# missing the model cannot be built (it is JSON); fall back to a plain degraded
# frame straight from the read sources, so the pane is never blank.
paint_frame_body() {
  DESK_MODEL=$(desk_project)
  if [ -z "$DESK_MODEL" ]; then
    paint_frame_no_jq
    return 0
  fi
  # Fit the whole board to the pane's PHYSICAL-line budget, unless a row cap was
  # explicitly pinned (then the model already carries the collapse).
  if [ -z "${FM_DESK_CAP:-}" ] && [ -n "${FM_DESK_BUDGET:-}" ]; then
    local fitted
    fitted=$(desk_fit "$DESK_MODEL")
    [ -n "$fitted" ] && DESK_MODEL=$fitted
  fi
  paint_header
  paint_gaps
  paint_captains_call
  paint_underway
  paint_charted
  paint_landed
  paint_merge
  paint_secondmates
  paint_health
}

# The jq-absent fallback: paint straight from desk_read_sources state (no model),
# reproducing the degraded board. Only reached when jq is missing, so no section
# can read the projection.
paint_frame_no_jq() {
  desk_read_sources
  local summary
  if [ "$DESK_AWAY" -eq 1 ]; then summary="$DESK_SUMMARY_AWAY"; else summary="$DESK_SUMMARY_UNREAD"; fi
  printf '%sCaptain'\''s desk%s  %sas of %s%s\n' \
    "$C_BOLD" "$C_RESET" "$C_DIM" "$(desk_clean "$DESK_NOW")" "$C_RESET"
  printf '%s\n' "$(desk_clean "$(desk_text "$summary")")"
  if [ -n "$DESK_GAPS" ]; then
    rule "Some of this board is missing"
    printf '%s' "$DESK_GAPS" | while IFS= read -r line; do
      [ -n "$line" ] || continue
      gap_line "$(desk_text "$line")"
    done
  fi
  rule "Captain's Call"
  gap_line "$(desk_text "$(desk_section_sentence "$DESK_SENT_CAPTAINS")")"
  rule "Under Way"
  gap_line "$(desk_text "$(desk_section_sentence "$DESK_SENT_UNDER")")"
  rule "Charted / Queued next"
  gap_line "$(desk_text "$(desk_section_sentence "$DESK_SENT_CHARTED")")"
  rule "Recently Landed"
  gap_line "$(desk_text "$(desk_section_sentence "$DESK_SENT_LANDED")")"
  rule "Ready to merge (finished, not yet landed)"
  if [ -z "$DESK_MERGEQ" ]; then
    empty_line "No finished branches waiting to merge."
  else
    printf '%s\n' "$DESK_MERGEQ" | while IFS=$(printf '\t') read -r id _repo _branch _sha dest _url; do
      [ -n "$id" ] || continue
      lead_line "" "$id" "-> $(desk_clean "$dest")" "done"
    done
  fi
  rule "Second mates"
  gap_line "$(desk_text "$(desk_section_sentence "$DESK_SENT_SECOND")")"
  # Fleet health: a single line only when monitoring lapsed or the captain is away.
  local line=""
  if [ -z "$DESK_BEAT_AGE" ]; then
    line="Monitoring status is unknown; no recent check was recorded."
  elif [ "$DESK_BEAT_AGE" -gt 1800 ]; then
    line="Monitoring may have lapsed (last check about ${DESK_BEAT_AGE}s ago)."
  fi
  [ "$DESK_AWAY" -eq 1 ] && line="${line:+$line }You are marked away."
  [ -n "$line" ] && gap_line "$(desk_text "$line")"
}

# --- self-refresh loop (concern c only) -------------------------------------
# loop_restore: leave the alternate screen, show the cursor, and reset colors so
# the pane is clean on Ctrl-C or any exit. Idempotent: it may fire from both the
# INT/TERM trap and the EXIT trap, so it guards on a done flag.
LOOP_RESTORED=0
loop_restore() {
  [ "$LOOP_RESTORED" -eq 1 ] && return 0
  LOOP_RESTORED=1
  printf '%s%s%s' "$CURSOR_SHOW" "$C_RESET" "$TERM_ALT_OFF"
}

# desk_loop: repaint the WHOLE frame on an interval until a signal restores the
# terminal. READ-ONLY / NEVER WAKES - each tick only re-runs the read-only
# desk_project + paint. A tick whose frame comes back empty degrades to the
# PREVIOUS good frame, or a clearly-marked banner if there is no prior frame,
# never a blank screen.
desk_loop() {  # <interval>
  local interval=$1 frame last_frame=""
  # Terminal-control sequences for the loop, resolved from TERM via tput only when
  # the loop actually runs (so --once/--help/non-tty paths spawn none of them).
  # NOT gated on [ -t 1 ] because they are emitted ONLY inside desk_loop, never on
  # the --once path, so they cannot leak into a piped --once capture. Gating on
  # TERM alone lets a test drive the real loop through a pipe
  # (FM_DESK_TUI_FORCE_LOOP=1 with a real TERM) and still observe the restore
  # sequence. A dumb or absent TERM yields empty strings, so the loop is still
  # safe with no terminal database.
  TERM_ALT_ON="" TERM_ALT_OFF="" CURSOR_HIDE="" CURSOR_SHOW="" TERM_CLEAR=""
  if [ "${TERM:-dumb}" != dumb ] && command -v tput >/dev/null 2>&1; then
    TERM_ALT_ON=$(tput smcup 2>/dev/null || printf '')
    TERM_ALT_OFF=$(tput rmcup 2>/dev/null || printf '')
    CURSOR_HIDE=$(tput civis 2>/dev/null || printf '')
    CURSOR_SHOW=$(tput cnorm 2>/dev/null || printf '')
    TERM_CLEAR=$(tput clear 2>/dev/null || printf '')
  fi
  trap 'loop_restore; exit 0' INT TERM
  trap 'loop_restore' EXIT
  printf '%s%s' "$TERM_ALT_ON" "$CURSOR_HIDE"
  while :; do
    resolve_cols                 # re-read width each tick (picks up a resize)
    resolve_cap                  # re-derive the per-section cap from pane height
    frame=$(paint_frame)
    if [ -n "$frame" ]; then
      last_frame=$frame
    elif [ -n "$last_frame" ]; then
      frame=$last_frame          # degrade to the previous good frame
    else
      frame="Captain's desk: could not read fleet state this tick."
    fi
    printf '%s%s\n' "$TERM_CLEAR" "$frame"
    sleep "$interval"
  done
}

# --- entry point ------------------------------------------------------------
case "${1:-}" in
  ''|--once)
    # Build the whole frame in a buffer, then emit it in one write, so a partial
    # read never catches a half-painted screen.
    frame=$(paint_frame)
    printf '%s\n' "$frame"
    exit 0
    ;;
  --loop)
    # Interval: an explicit positive-integer argument wins, then
    # FM_DESK_TUI_INTERVAL, then 5. A bad value is a usage error.
    interval="${2:-${FM_DESK_TUI_INTERVAL:-5}}"
    case "$interval" in
      ''|*[!0-9]*|0) printf 'fm-desk-tui: --loop interval must be a positive integer: %s\n' "$interval" >&2; exit 64 ;;
    esac
    # On a non-terminal stdout there is nothing to refresh in place, so degrade to
    # a single paint - unless a test forces the real loop through a pipe.
    if [ ! -t 1 ] && [ "${FM_DESK_TUI_FORCE_LOOP:-0}" != 1 ]; then
      frame=$(paint_frame)
      printf '%s\n' "$frame"
      exit 0
    fi
    desk_loop "$interval"
    ;;
  -h|--help) usage; exit 0 ;;
  *) printf 'fm-desk-tui: unknown argument: %s\n' "$1" >&2; usage >&2; exit 64 ;;
esac
