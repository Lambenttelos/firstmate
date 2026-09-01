#!/usr/bin/env bash
# Behavior tests for bin/fm-desk-tui.sh, the captain's-desk terminal renderer.
#
# Every assertion drives the executable interface (the painted frame on stdout
# and the CLI contract), never the script's source bytes. A synthetic fleet
# projection is injected through FM_DESK_SNAPSHOT_BIN and a synthetic merge queue
# through FM_DESK_MERGEQ_BIN - the SAME seams the lib test uses - so the paint is
# exercised without a live fleet. Output is captured through a
# pipe (so [ -t 1 ] is false) with TERM=dumb, making it deterministic plain text.
#
# Covers: --once and --help and usage-error contracts; every section header with
# its content; ids/branches/URLs carried verbatim; the empty-state and
# absent-source gap handling (no crash, no confident-empty); the away-mode
# explicit gap; and the NEVER-WAKES invariant (no status/wake side effects, no
# writes under state/).
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TUI="$ROOT/bin/fm-desk-tui.sh"
TMP_ROOT=$(fm_test_tmproot fm-desk-tui)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state"

# A populated synthetic projection covering every section the desk renders.
SNAP_BIN="$TMP_ROOT/snap.sh"
cat > "$SNAP_BIN" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{
  "schema": "fm-bearings.v1",
  "home": "test/home",
  "generated": "2026-01-01T00:00:00Z",
  "in_flight": [
    { "id": "ship-alpha", "kind": "ship", "state": "working", "doing": "editing the payment path" },
    { "id": "ship-beta", "kind": "ship", "state": "blocked", "doing": "waiting on a decision" }
  ],
  "secondmates": [
    { "id": "research-secondmate", "state": "idle", "doing": "nothing queued", "freshness": "fresh" }
  ],
  "decisions_open": [
    { "id": "decide-refund-contract", "key": "decide-refund-contract", "verb": "captain-hold", "summary": "keep the refund throw or convert it to a skip", "owner": "ship-alpha" },
    { "id": "decide-version-semantics", "key": "decide-version-semantics", "verb": "captain-hold", "summary": "monotonic counter or raw version", "owner": "ship-beta" }
  ],
  "landed": [
    { "id": "ticket-fixed-index", "what": "add a compound index on Order", "artifact": "-" }
  ],
  "gates": [
    { "id": "queued-cleanup", "title": "remove the dead code path", "blocked_by": "-", "reason": "waiting on capacity" }
  ]
}
JSON
SH
chmod +x "$SNAP_BIN"

# A synthetic merge queue: two finished-but-unmerged branches with compare links.
MQ_BIN="$TMP_ROOT/mq.sh"
cat > "$MQ_BIN" <<'SH'
#!/usr/bin/env bash
printf 'branch-one\t/repos/x\tfm/branch-one\tabc123\tdev\thttps://example.test/compare/one\n'
printf 'branch-two\t/repos/y\tfm/branch-two\tdef456\tmain\thttps://example.test/compare/two\n'
SH
chmod +x "$MQ_BIN"

# Deterministic Claude-account seams so the board never shells out to a real
# cswap / jcode / ~/.jcode/auth.json on the test box. CSWAP_OK lists three
# accounts (one active, one disabled via the JSON flag) for the ROSTER; the jcode
# auth points at a different account, so both store markers are exercised. The
# USAGE numbers come from the jcode-usage stub (matched by email), not cswap.
CSWAP_OK="$TMP_ROOT/cswap.sh"
cat > "$CSWAP_OK" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{ "schemaVersion": 1, "activeAccountNumber": 3, "accounts": [
  { "number": 1, "email": "a@crew.test", "active": false },
  { "number": 2, "email": "b@example.net", "active": false, "disabled": true },
  { "number": 3, "email": "c@gmail.com", "active": true } ] }
JSON
SH
chmod +x "$CSWAP_OK"
JCODE_AUTH="$TMP_ROOT/jcode-auth.json"
cat > "$JCODE_AUTH" <<'JSON'
{ "active_anthropic_account": "fox",
  "anthropic_accounts": [ { "label": "fox", "email": "a@crew.test" },
                          { "label": "panda", "email": "c@gmail.com" } ] }
JSON
# jcode usage: per-account numbers keyed by the alias in provider_name, resolved
# to email through auth.json. Account 1 (fox) 5h 100% / 7d 78%; account 3 (panda)
# 5h 20% / 7d 4%. These are what the account tokens below assert.
JU_OK="$TMP_ROOT/jcode-usage.sh"
cat > "$JU_OK" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{ "providers": [
  { "provider_name": "Anthropic - fox (a***p) ✦",
    "limits": [ { "name": "5-hour window", "usage_percent": 100.0, "resets_at": "2026-01-01T05:00:00+00:00" },
                { "name": "7-day window", "usage_percent": 78.0, "resets_at": "2026-01-01T21:00:00+00:00" } ],
    "extra_info": [ ["Last used", "just now"] ], "error": null },
  { "provider_name": "Anthropic - panda (c***m)",
    "limits": [ { "name": "5-hour window", "usage_percent": 20.0, "resets_at": "2026-01-01T05:00:00+00:00" },
                { "name": "7-day window", "usage_percent": 4.0, "resets_at": "2026-01-07T21:00:00+00:00" } ],
    "extra_info": [ ["Last used", "5m ago"] ], "error": null } ] }
JSON
SH
chmod +x "$JU_OK"
export FM_DESK_CSWAP_BIN="$CSWAP_OK" FM_DESK_JCODE_AUTH="$JCODE_AUTH" \
  FM_DESK_JCODE_USAGE_BIN="$JU_OK" FM_DESK_JCODE_USAGE_CACHE="$TMP_ROOT/ju-tui-cache.json"

# Default token-cost seam: a report binary that emits a VALID but empty coster
# blob (no billed activity), plus a per-test cache path under TMP. WHY: the
# token-cost panel shells out to the coster through a desk-owned disk cache;
# without this seam a paint would run the REAL coster (a full jcode session-store
# scan) and write the real state dir, breaking the NEVER-WAKES "no writes under
# state/" contract this suite asserts. An empty-but-valid report deterministically
# yields the honest "no billed activity yet" panel - never a read-failure gap that
# would trip the collapsed-tail assertions - and the TMP cache keeps its one owned
# write off the seeded state dirs. The rollup half is absent (a nonexistent bin),
# so per-ticket cost reads "not available", exercising the optional-rollup path.
TOKEN_COST_EMPTY="$TMP_ROOT/token-cost-empty.sh"
cat > "$TOKEN_COST_EMPTY" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"price_source":"test","price_cached_at":"2026-01-01T00:00:00Z",
 "totals":{"cost_if_api":null,"cost_if_api_billed":null,"cost_if_api_covered":null,
   "sessions":0,"token_input":0,"token_cache_read":0,"token_cache_write":0,"unknown_model_tokens":0},
 "rows":[]}
JSON
SH
chmod +x "$TOKEN_COST_EMPTY"
export FM_DESK_TOKEN_REPORT_BIN="$TOKEN_COST_EMPTY" \
  FM_DESK_TICKET_ROLLUP_BIN="$TMP_ROOT/token-cost-rollup-absent.sh" \
  FM_DESK_TOKEN_COST_CACHE="$TMP_ROOT/token-cost-absent.json"

# run_tui: paint one frame with the populated sources, captured through a pipe
# (so stdout is not a tty) with TERM=dumb - deterministic plain text.
run_tui() {  # [extra env cmd...] TUI
  TERM=dumb FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" \
    FM_DESK_MERGEQ_BIN="$MQ_BIN" FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
    "$@" "$TUI"
}

# --- CLI contract -----------------------------------------------------------
help_out=$("$TUI" --help)
assert_contains "$help_out" "the captain's desk in a terminal" "--help prints usage"
assert_contains "$help_out" "NEVER WAKES" "--help documents the never-wakes contract"
pass "--help prints the header usage"

code=0
TERM=dumb FM_HOME="$HOME_DIR" "$TUI" --bogus >/dev/null 2>&1 || code=$?
expect_code 64 "$code" "usage error"
pass "unknown argument exits 64"

# --- full render (--once, default) ------------------------------------------
frame=$(run_tui) || fail "populated paint must exit 0"

# Every section header is present.
assert_contains "$frame" "Captain's Call" "captain's call section present"
assert_contains "$frame" "Under Way" "under-way section present"
assert_contains "$frame" "Charted / Queued next" "charted section present"
assert_contains "$frame" "Recently Landed" "landed section present"
assert_contains "$frame" "Ready to merge" "merge section present"
assert_contains "$frame" "Second mates" "second-mates section present"
# Fleet health is chrome-free when fine: with no watcher beat the synthetic home
# is "monitoring unknown", so a single dim line appears but NO "Fleet health"
# header/rule (the 5-line block was cut). See the health assertions below.
assert_not_contains "$frame" "Fleet health" "healthy/quiet health shows no section header"

# Content from each source is rendered. Captain's Call is counts-only: its TOTAL
# folds into the header (2 decisions here) and no decision text/id is painted, so
# assert the header count and the pointer rather than a decision row.
assert_contains "$frame" "Captain's Call (2)" "Captain's Call header carries the decision total"
assert_not_contains "$frame" "decide-refund-contract" "counts-only: no decision id painted on the TUI"
assert_not_contains "$frame" "keep the refund throw" "counts-only: no decision summary painted on the TUI"
assert_contains "$frame" "Open the full desk to read them." "counts-only Captain's Call points at the full desk"
assert_contains "$frame" "ship-alpha" "in-flight id rendered"
assert_contains "$frame" "ship-beta" "blocked in-flight id rendered"
assert_contains "$frame" "queued-cleanup" "queued gate id rendered"
assert_contains "$frame" "waiting on capacity" "gate reason rendered"
assert_contains "$frame" "ticket-fixed-index" "landed id rendered"
assert_contains "$frame" "research-secondmate" "second-mate id rendered"

# The Claude accounts block: all three accounts, the honesty caption, and both
# per-store markers, painted by the shared header off the model.
assert_contains "$frame" "a running session may differ" "accounts caption states the honesty caveat"
assert_contains "$frame" "1 fox a@crew.test" "account 1 line painted with its jcode animal alias"
assert_contains "$frame" "2 b@example.net" "account 2 line painted"
assert_contains "$frame" "3 panda c@gmail.com" "account 3 line painted with its jcode animal alias"
assert_contains "$frame" "<- cc" "the Claude Code store marker is painted"
assert_contains "$frame" "jcode" "the jcode store marker is painted"
assert_contains "$frame" "(disabled)" "the disabled marker (from the JSON flag) is painted"
# CHANGE 2 on this board (TERM=dumb, so NO colour): each window token still reads
# its state via the baked ascii glyph - account 1 5h 100% is spent (x), 7d 78% is
# tight (?); account 3 5h 20% has headroom (+).
assert_contains "$frame" "5h 100%x" "account 1 5h token carries the spent 'x' glyph without colour"
assert_contains "$frame" "7d 78%?" "account 1 7d token carries the tight '?' glyph without colour"
assert_contains "$frame" "5h 20%+" "account 3 5h token carries the headroom '+' glyph without colour"
# Both windows paint their own terse reset on the physical line: 5h resets_at 05:00
# from now 00:00 = 5h, 7d resets_at 21:00 = 21h. The 5h reset is no longer dropped.
assert_contains "$frame" "5h 100%x (5h)" "account 1 line paints the 5h reset beside its 5h token"
assert_contains "$frame" "7d 78%? (21h)" "account 1 line still paints the 7d reset beside its 7d token"
# LEGIBILITY at the 80-column fallback this paint resolves to (the captain's SSH
# pane): the widest account line survives WHOLE through clip_frame - both windows,
# both resets, and the trailing store marker - rather than being cut mid-content.
# The on-line "used <x>" text is what was traded away to pay for the 5h reset, so
# it must not come back and spend the room again.
assert_contains "$frame" "3 panda c@gmail.com  5h 20%+ (5h) · 7d 4%+ (6d)  <- cc" \
  "the account line is painted whole at the 80-column fallback"
assert_not_contains "$frame" "used 5m ago" "the account line spends no width on the last-used text"
assert_not_contains "$frame" "used just now" "the account line spends no width on the last-used text"
pass "populated paint shows every section with its content"

# The merge id is carried verbatim; the branch (id + "fm/" prefix) and the ~95-char
# compare URL are CUT from the TUI as redundant/unusable terminal text - the HTML
# board keeps both. This is the accepted TUI/HTML divergence.
assert_contains "$frame" "branch-one" "merge-queue id rendered verbatim"
assert_not_contains "$frame" "fm/branch-one" "merge branch is not shown (redundant with the id)"
assert_not_contains "$frame" "https://example.test/compare/one" "merge compare URL is cut from the TUI"
pass "merge rows show one id and drop the redundant branch/URL"

# Explicit --once matches the default behavior.
frame_once=$(run_tui env FM_DESK_NOW="2026-01-01 00:00:00 UTC" ) || fail "--once via env wrapper must exit 0"
assert_contains "$frame_once" "Captain's Call" "--once paints the same board"
frame_flag=$(TERM=dumb FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" \
  FM_DESK_MERGEQ_BIN="$MQ_BIN" FM_DESK_NOW="2026-01-01 00:00:00 UTC" "$TUI" --once)
assert_contains "$frame_flag" "ship-alpha" "explicit --once flag paints the board"
pass "--once is the default and the explicit flag paints the same board"

# The "Not in this fork" notice was cut entirely: it listed things that do not
# exist and cost a row on a board fighting for space (the HTML board keeps it).
assert_not_contains "$frame" "Not in this fork" "the unavailable-sources notice is cut from the TUI"
pass "the unavailable-sources notice is dropped"

# Status bullets: with a pipe + TERM=dumb the colored circle degrades to a
# DISTINCT ASCII char per class, so status survives a colorless render. The
# blocked in-flight row leads with 'x', a running row with '>', a landed row with
# '+'. (Captain's Call is counts-only now, so it paints no decision bullet.)
# Never color-alone.
assert_contains "$frame" "x waiting on a decision" "blocked degrades to a distinct 'x' bullet"
assert_contains "$frame" "> editing the payment path" "running degrades to a distinct '>' bullet"
assert_contains "$frame" "+ add a compound index" "landed degrades to a distinct '+' bullet"
pass "status bullets degrade to a distinct ASCII char per class (no color-alone)"

# Plain-text fallback: with a pipe + TERM=dumb, no ANSI escape byte leaks.
case "$frame" in
  *$'\033'*) fail "non-tty plain-text fallback must not emit ANSI escapes" ;;
  *) : ;;
esac
pass "non-tty stdout falls back to deterministic plain text (no ANSI)"

# --- colored status circle on a real terminal + single-width glyph ----------
# Color (and the U+25CF circle) is emitted ONLY for a real tty reporting >=8
# colors, so drive the paint through a pseudo-terminal with `script`. The glyph
# is asserted single-width so it cannot silently break the line budget: U+25CF is
# 0xE2 0x97 0x8F, a 3-byte single-column char. This is skipped where `script` is
# unavailable rather than passing vacuously.
CIRCLE=$(printf '\xe2\x97\x8f')
if command -v script >/dev/null 2>&1; then
  color_out=""
  # BSD and GNU `script` differ in argument order; try GNU form then BSD.
  color_out=$(TERM=xterm-256color FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" \
    FM_DESK_MERGEQ_BIN="$MQ_BIN" FM_DESK_NOW="2026-01-01 00:00:00 UTC" FM_DESK_TUI_COLS=200 \
    script -qec "$TUI --once" /dev/null 2>/dev/null) \
    || color_out=$(TERM=xterm-256color FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" \
    FM_DESK_MERGEQ_BIN="$MQ_BIN" FM_DESK_NOW="2026-01-01 00:00:00 UTC" FM_DESK_TUI_COLS=200 \
    script -q /dev/null "$TUI" --once 2>/dev/null) || color_out=""
  if [ -n "$color_out" ] && printf '%s' "$color_out" | grep -q "Captain's desk"; then
    case "$color_out" in
      *$'\033'*) : ;;
      *) fail "a real terminal must emit ANSI color" ;;
    esac
    case "$color_out" in
      *"$CIRCLE"*) : ;;
      *) fail "a real terminal must lead rows with the U+25CF status circle" ;;
    esac
    # The glyph is single-width: wc -L reports its display columns as 1.
    glyph_w=$(printf '%s' "$CIRCLE" | wc -L | tr -d ' ')
    [ "$glyph_w" = 1 ] || fail "the status glyph must be single-width (measured $glyph_w)"
    pass "a real terminal leads rows with a single-width colored status circle"
  else
    echo "skip: script produced no usable pty capture"
  fi
else
  echo "skip: script not available for a pty color render"
fi

# --- section-rule width -----------------------------------------------------
# A rule is a full line of COLS dashes, so the width of the widest dash run is an
# observable proxy for the resolved COLS. dashes builds a run of a given length.
dashes() { printf '%*s' "$1" '' | tr ' ' '-'; }

# The FM_DESK_TUI_COLS override pins the rule width exactly: 50 present, 51 absent.
width50=$(TERM=dumb FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" \
  FM_DESK_MERGEQ_BIN="$MQ_BIN" FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  FM_DESK_TUI_COLS=50 "$TUI" --once)
assert_contains "$width50" "$(dashes 50)" "FM_DESK_TUI_COLS pins the rule to 50 columns"
assert_not_contains "$width50" "$(dashes 51)" "rule width does not exceed the pinned 50 columns"

# A width below the 40 floor is raised to 40, never narrower.
widthfloor=$(TERM=dumb FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" \
  FM_DESK_MERGEQ_BIN="$MQ_BIN" FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  FM_DESK_TUI_COLS=10 "$TUI" --once)
assert_contains "$widthfloor" "$(dashes 40)" "a sub-floor width is raised to the 40-column floor"
assert_not_contains "$widthfloor" "$(dashes 41)" "the floor is exactly 40 columns, not wider"

# With no override and a non-tty pipe (tput is skipped) the width is the 80
# fallback - deterministic and independent of both the terminal and the override.
assert_contains "$frame" "$(dashes 80)" "non-tty width falls back to 80 columns"
assert_not_contains "$frame" "$(dashes 81)" "the non-tty fallback is exactly 80 columns"
pass "section-rule width honors FM_DESK_TUI_COLS, the 40 floor, and the 80 fallback"

# --- empty-state handling ---------------------------------------------------
EMPTY_SNAP="$TMP_ROOT/empty.sh"
cat > "$EMPTY_SNAP" <<'SH'
#!/usr/bin/env bash
echo '{"schema":"fm-bearings.v1","in_flight":[],"secondmates":[],"decisions_open":[],"landed":[],"gates":[]}'
SH
chmod +x "$EMPTY_SNAP"
EMPTY_MQ="$TMP_ROOT/emptymq.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$EMPTY_MQ"; chmod +x "$EMPTY_MQ"
empty_frame=$(TERM=dumb FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$EMPTY_SNAP" \
  FM_DESK_MERGEQ_BIN="$EMPTY_MQ" FM_DESK_NOW="2026-01-01 00:00:00 UTC" "$TUI" --once) \
  || fail "empty paint must exit 0"
# The captain's-call and merge sections always render (they carry the two things
# he acts on); an empty routine section (Under Way) folds away entirely on the
# height-constrained TUI, its state already told by the top summary.
assert_contains "$empty_frame" "Nothing needs your action" "empty decisions is an explicit empty line"
assert_contains "$empty_frame" "No finished branches waiting to merge" "empty merge queue is an explicit empty line"
assert_not_contains "$empty_frame" "No work is under way" "an empty routine section folds away on the TUI"
assert_not_contains "$empty_frame" "Under Way" "the folded section's header is gone too"
pass "empty sources: acted-on sections stay, empty routine sections fold"

# --- header counts, counts-only Captain's Call, and the dropped +N-more row ---
# A busy fleet: 12 decisions (2 urgent), 26 gates, at a pinned cap of 4.
BUSY_SNAP="$TMP_ROOT/busy.sh"
cat > "$BUSY_SNAP" <<'SH'
#!/usr/bin/env bash
jq -n '{
  schema: "fm-bearings.v1",
  in_flight: [], secondmates: [], landed: [],
  decisions_open: ([ range(0;10) | { id: ("hold-\(.)"), verb: "captain-hold", summary: ("routine decision \(.)") } ]
    + [ { id: "URGENTONE", verb: "needs-decision", summary: "ANSWER THIS URGENT QUESTION" },
        { id: "URGENTTWO", verb: "needs-decision", summary: "AND THIS URGENT ONE" } ]),
  gates: [ range(0;26) | { id: ("gate-\(.)"), title: ("queued item \(.)"), blocked_by: "-", reason: "-" } ]
}'
SH
chmod +x "$BUSY_SNAP"
busy_frame=$(TERM=dumb FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$BUSY_SNAP" \
  FM_DESK_MERGEQ_BIN="$EMPTY_MQ" FM_DESK_CAP=4 FM_DESK_TUI_COLS=200 \
  FM_DESK_NOW="2026-01-01 00:00:00 UTC" "$TUI" --once) || fail "busy paint must exit 0"
# Captain's Call is COUNTS ONLY: the TOTAL folds into the header as " (12)" and
# NO decision question or id is painted - not even the urgent ones. The captain
# reads the size off the header he already scans; the questions live on the full
# desk, which the section still points at, so the count is navigation not a dead
# end. (This is the captain's answer on the open design question.)
assert_contains "$busy_frame" "Captain's Call (12)" "the section header carries the TOTAL decision count"
assert_not_contains "$busy_frame" "ANSWER THIS URGENT QUESTION" "counts-only: no decision question is painted on the TUI"
assert_not_contains "$busy_frame" "URGENTONE" "counts-only: no decision id is painted on the TUI"
assert_not_contains "$busy_frame" "routine decision" "counts-only: no routine decision text is painted on the TUI"
# The counts-only section still points at where the real questions live.
assert_contains "$busy_frame" "Open the full desk to read them." "counts-only Captain's Call points at the full desk"
# Charted still lists rows and carries its TRUE TOTAL in the header - the honest
# 26 gates, not the DESK_MAX-bounded working set of 20 - so the header agrees
# with the "26 stacked behind" summary below. The old trailing "+N more" collapse
# row is GONE from every section now that the header carries the count.
assert_contains "$busy_frame" "Charted / Queued next (26)" "a still-listing section carries its TRUE total in the header"
assert_not_contains "$busy_frame" "+8 more" "the +N-more collapse row is dropped (count now lives in the header)"
assert_not_contains "$busy_frame" "+16 more" "the gate +N-more collapse row is dropped too"
assert_not_contains "$busy_frame" "open the full desk" "the +N-more hint line is not painted on the TUI"
# A collapsed tail must never read like a failed source.
assert_not_contains "$busy_frame" "could not be read" "a collapsed tail is not a read-failure gap"
# The top summary still answers the glance question with counts.
assert_contains "$busy_frame" "12 things need your word" "the summary counts open decisions"
assert_contains "$busy_frame" "2 urgent" "the summary flags the urgent subset"
assert_contains "$busy_frame" "26 stacked behind" "the summary counts the queued backlog"
pass "header carries counts; Captain's Call is counts-only; the +N-more row is dropped"

# --- unreadable projection --> gap, not crash ------------------------------
BAD_SNAP="$TMP_ROOT/bad.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BAD_SNAP"; chmod +x "$BAD_SNAP"
bad_frame=$(TERM=dumb FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$BAD_SNAP" \
  FM_DESK_MERGEQ_BIN="$MQ_BIN" FM_DESK_NOW="2026-01-01 00:00:00 UTC" "$TUI" --once)
code=$?
expect_code 0 "$code" "unreadable projection still paints (exit 0)"
assert_contains "$bad_frame" "Some of this board is missing" "unreadable projection shows a gap banner"
assert_contains "$bad_frame" "Current fleet state could not be read" "unreadable projection notes the specific gap"
pass "unreadable projection degrades to a visible gap, not a crash"

# --- away mode --> explicit "unavailable while away" line, not confident-empty
AWAY_HOME="$TMP_ROOT/awayhome"
mkdir -p "$AWAY_HOME/state"
: > "$AWAY_HOME/state/.afk"
AWAY_SNAP="$TMP_ROOT/awaysnap.sh"
cat > "$AWAY_SNAP" <<'SH'
#!/usr/bin/env bash
[ -e "$FM_HOME/state/.afk" ] && { echo "away mode is still active" >&2; exit 3; }
echo '{"schema":"fm-bearings.v1","in_flight":[],"secondmates":[],"decisions_open":[],"landed":[],"gates":[]}'
SH
chmod +x "$AWAY_SNAP"
away_frame=$(TERM=dumb FM_HOME="$AWAY_HOME" FM_DESK_SNAPSHOT_BIN="$AWAY_SNAP" \
  FM_DESK_MERGEQ_BIN="$EMPTY_MQ" FM_DESK_NOW="2026-01-01 00:00:00 UTC" "$TUI" --once)
code=$?
expect_code 0 "$code" "away-mode paint still exits 0"
assert_contains "$away_frame" "away mode is active" "fleet sections attribute the gap to away mode"
assert_contains "$away_frame" "You are marked away" "header/health notes away status"
assert_not_contains "$away_frame" "No work is under way" "away mode is not a confident-empty section"
assert_not_contains "$away_frame" "Current fleet state could not be read" "away mode is not a bare read-failure gap"
pass "away mode renders an explicit unavailable-while-away line"

# --- NEVER WAKES: no status/wake side effects, no writes under state/ --------
WAKE_HOME="$TMP_ROOT/wakehome"
mkdir -p "$WAKE_HOME/state"
# Seed a status file and prove neither it nor anything under state/ is touched.
printf 'working: seed\n' > "$WAKE_HOME/state/ship-alpha.status"
status_before=$(cat "$WAKE_HOME/state/ship-alpha.status")
before_listing=$(find "$WAKE_HOME/state" -mindepth 1 | sort)
TERM=dumb FM_HOME="$WAKE_HOME" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" \
  FM_DESK_MERGEQ_BIN="$MQ_BIN" FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  "$TUI" --once >/dev/null 2>&1 || fail "wake-check paint must exit 0"
status_after=$(cat "$WAKE_HOME/state/ship-alpha.status")
[ "$status_before" = "$status_after" ] || fail "paint must not append to a status file"
after_listing=$(find "$WAKE_HOME/state" -mindepth 1 | sort)
[ "$before_listing" = "$after_listing" ] || fail "paint must not create any file under state/ (no wake queue, no marker)"
assert_absent "$WAKE_HOME/state/.wake-queue" "paint must not create a wake queue"
pass "paint never wakes: no status append, no state/ writes"

# --- --loop: self-refresh in an alternate screen buffer ---------------------
# The loop is driven as a real backgrounded process (the fm-watch-desk.test.sh
# pattern): start it, wait for the first frame, let it tick, then signal it and
# wait. It is forced to run its real refresh loop through a pipe with
# FM_DESK_TUI_FORCE_LOOP=1 and a real TERM, so the alt-screen/cursor control
# sequences are observable in the captured stream without a live terminal.
LOOP_HOME="$TMP_ROOT/loophome"
mkdir -p "$LOOP_HOME/state"
# Seed a status file so the never-wakes assertion has something to guard.
printf 'working: seed\n' > "$LOOP_HOME/state/ship-alpha.status"
loop_before_listing=$(find "$LOOP_HOME/state" -mindepth 1 | sort)

LOOP_OUT="$TMP_ROOT/loop.out"
TERM=xterm FM_HOME="$LOOP_HOME" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" \
  FM_DESK_MERGEQ_BIN="$MQ_BIN" FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  FM_DESK_TUI_FORCE_LOOP=1 FM_DESK_TUI_INTERVAL=1 FM_DESK_TUI_COLS=60 \
  "$TUI" --loop > "$LOOP_OUT" 2>&1 &
LOOP_PID=$!

# Wait for the first frame to land (proves the loop paints).
i=0
while [ "$i" -lt 80 ]; do
  grep -q "Captain's Call" "$LOOP_OUT" 2>/dev/null && break
  sleep 0.1; i=$((i + 1))
done
grep -q "Captain's Call" "$LOOP_OUT" 2>/dev/null \
  || { kill "$LOOP_PID" 2>/dev/null; fail "--loop did not paint a first frame"; }

# Let it tick across several 1s intervals, then stop it.
sleep 4
kill -TERM "$LOOP_PID" 2>/dev/null
wait "$LOOP_PID" 2>/dev/null || true

# It repainted MORE THAN ONCE over the intervals (the loop actually fires).
frames=$(grep -c "Captain's desk" "$LOOP_OUT" 2>/dev/null || echo 0)
[ "$frames" -ge 2 ] || fail "--loop must repaint more than once; saw $frames frames"

# It is THROTTLED to ~the interval, not a busy-spin: over ~5s at a 1s interval an
# honest loop paints a handful of frames, never dozens. Bound it generously.
[ "$frames" -le 12 ] || fail "--loop is not throttled: $frames frames over ~5s at a 1s interval (busy-spin)"
pass "--loop repaints on the interval and is throttled (saw $frames frames)"

# It NEVER wrote under state/ across the whole run (the ported never-wakes property).
loop_after_listing=$(find "$LOOP_HOME/state" -mindepth 1 | sort)
[ "$loop_before_listing" = "$loop_after_listing" ] \
  || fail "--loop must not create any file under state/ across the run"
status_after=$(cat "$LOOP_HOME/state/ship-alpha.status")
[ "$status_after" = "working: seed" ] || fail "--loop must not append to a status file"
assert_absent "$LOOP_HOME/state/.wake-queue" "--loop must not create a wake queue"
pass "--loop never wakes across the whole run: no status append, no state/ writes"

# A signal restores the terminal: the alternate-screen-off (rmcup) and
# show-cursor sequences are emitted on exit. Compare against what tput itself
# produces for this TERM so the assertion is not a hardcoded escape string.
rmcup_seq=$(TERM=xterm tput rmcup 2>/dev/null || printf '')
cnorm_seq=$(TERM=xterm tput cnorm 2>/dev/null || printf '')
loop_stream=$(cat "$LOOP_OUT")
if [ -n "$rmcup_seq" ]; then
  case "$loop_stream" in
    *"$rmcup_seq"*) : ;;
    *) fail "--loop must emit the leave-alternate-screen (rmcup) sequence on exit" ;;
  esac
fi
if [ -n "$cnorm_seq" ]; then
  case "$loop_stream" in
    *"$cnorm_seq"*) : ;;
    *) fail "--loop must emit the show-cursor sequence on exit" ;;
  esac
fi
pass "a signal restores the terminal (rmcup + show-cursor emitted on exit)"

# --- --loop: a failing source mid-loop is non-fatal, shows a gap ------------
# A snapshot that exits non-zero on EVERY tick must not crash or blank the loop:
# it degrades to a visible gap banner and keeps ticking.
BADLOOP_HOME="$TMP_ROOT/badloophome"
mkdir -p "$BADLOOP_HOME/state"
BADLOOP_OUT="$TMP_ROOT/badloop.out"
TERM=xterm FM_HOME="$BADLOOP_HOME" FM_DESK_SNAPSHOT_BIN="$BAD_SNAP" \
  FM_DESK_MERGEQ_BIN="$MQ_BIN" FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  FM_DESK_TUI_FORCE_LOOP=1 FM_DESK_TUI_INTERVAL=1 FM_DESK_TUI_COLS=60 \
  "$TUI" --loop > "$BADLOOP_OUT" 2>&1 &
BADLOOP_PID=$!
i=0
while [ "$i" -lt 80 ]; do
  grep -q "Some of this board is missing" "$BADLOOP_OUT" 2>/dev/null && break
  sleep 0.1; i=$((i + 1))
done
# The loop must still be alive despite the failing source (non-fatal).
kill -0 "$BADLOOP_PID" 2>/dev/null || fail "a failing source must not kill the --loop process"
# Let it tick across several 1s intervals, then stop it. Match the good-loop
# settle above (sleep 4, not 2): a failing-snapshot paint is itself ~1s, so a
# tighter window makes the >=2-frame count flaky on a busy machine while proving
# nothing more about loop liveness.
sleep 4
kill -TERM "$BADLOOP_PID" 2>/dev/null
wait "$BADLOOP_PID" 2>/dev/null || true
assert_contains "$(cat "$BADLOOP_OUT")" "Some of this board is missing" \
  "a failing source mid-loop shows a gap banner, not a blank screen"
assert_contains "$(cat "$BADLOOP_OUT")" "Current fleet state could not be read" \
  "the failing-source gap names the specific read failure"
badloop_frames=$(grep -c "Captain's desk" "$BADLOOP_OUT" 2>/dev/null || echo 0)
[ "$badloop_frames" -ge 2 ] || fail "the loop must keep ticking through a failing source; saw $badloop_frames frames"
pass "a failing source mid-loop is non-fatal: the loop survives and shows a gap"

# --- --loop: non-tty without the force seam degrades to a single paint -------
# Piped (not a tty) and without FM_DESK_TUI_FORCE_LOOP, --loop paints once and
# exits cleanly rather than spinning forever, so piping/logging it is harmless.
once_via_loop=$(TERM=dumb FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" \
  FM_DESK_MERGEQ_BIN="$MQ_BIN" FM_DESK_NOW="2026-01-01 00:00:00 UTC" "$TUI" --loop) \
  || fail "--loop on a non-tty must exit 0"
assert_contains "$once_via_loop" "Captain's Call" "--loop on a non-tty paints a single frame"
loop1_frames=$(printf '%s' "$once_via_loop" | grep -c "Captain's desk")
[ "$loop1_frames" -eq 1 ] || fail "--loop on a non-tty must paint exactly one frame; saw $loop1_frames"
case "$once_via_loop" in
  *$'\033'*) fail "--loop on a non-tty must not emit control sequences" ;;
  *) : ;;
esac
pass "--loop on a non-tty degrades to a single plain-text paint"

# --- --loop: a bad interval is a usage error --------------------------------
code=0
TERM=dumb FM_HOME="$HOME_DIR" "$TUI" --loop notanumber >/dev/null 2>&1 || code=$?
expect_code 64 "$code" "bad --loop interval"
pass "--loop with a non-numeric interval exits 64"

# --- line-budget fit: the board fits its pane's PHYSICAL lines (the fix) -----
# The old cap model budgeted ROWS and assumed one line per row, but many rows
# paint a second detail line and long rows wrap, so a full board overflowed a
# 49-row pane (measured 53 lines) - and the floor was inverted, so a shorter
# pane kept the same 3-row cap and overflowed WORSE. This fixture reproduces
# that live-fleet shape: multi-line merge/landed/charted rows (a second indented
# detail line each) and the two longest-on-the-board second-mate rows, which
# wrap to several physical lines at a realistic width. The assertion is the
# load-bearing one from the task: physical lines AFTER wrapping <= the pane
# height, at 49 rows and at a short and a tall pane.
FIT_SNAP="$TMP_ROOT/fit.sh"
cat > "$FIT_SNAP" <<'SH'
#!/usr/bin/env bash
jq -n '
  def longid($p;$i): ($p + "-decision-" + ([range(0;6)|"seg"]|join("-")) + "-\($i)");
  {
    schema:"fm-bearings.v1",
    in_flight:[ range(0;3) | {id:("ship-\(.)"), kind:"ship", state:"working",
                 doing:("editing a moderately long description of the work under way number \(.)")} ],
    secondmates:[
      {id:"builder-secondmate", state:"active_child_work",
       doing:"building the thing",
       freshness:"unknown"},
      {id:"research-secondmate", state:"captain_decision",
       doing:"waiting on you",
       freshness:"fresh"} ],
    decisions_open:[ range(0;20) | {id:(longid("dec";.)), verb:"captain-hold",
                 summary:("A fairly long plain-English decision question number \(.) that runs on for a while so it approaches or exceeds one line")} ],
    landed:[ range(0;8) | {id:("landed-\(.)"), what:("shipped a change with a fairly long description number \(.)"),
                 artifact:("data/landed-\(.)/report.md is a second indented detail line for this row")} ],
    gates:[ range(0;20) | {id:("gate-\(.)"), title:("queued item with a longish title number \(.)"),
                 blocked_by:(if . % 2 == 0 then "-" else "some-other-task-\(.)" end),
                 reason:("waiting on capacity or a dependency \(.)")} ]
  }'
SH
chmod +x "$FIT_SNAP"

FIT_MQ="$TMP_ROOT/fitmq.sh"
cat > "$FIT_MQ" <<'SH'
#!/usr/bin/env bash
for i in $(seq 0 14); do
  printf 'merge-%s\t/repos/x\tfm/a-branch-with-a-realistic-length-name-%s\tsha%s\tdev\thttps://bitbucket.org/org/repo/branch/fm/a-branch-with-a-realistic-length-name-%s?dest=dev\n' "$i" "$i" "$i" "$i"
done
SH
chmod +x "$FIT_MQ"

# phys_lines <file> <width>: count physical lines after hard-wrapping each
# logical line at <width> columns (an empty line still costs one row). This is
# the same wrap the terminal applies, so it is the honest overflow measure.
# Measures VISIBLE columns like vis_over (LC_ALL=C, SGR/charset escapes stripped,
# UTF-8 continuation bytes skipped) so the count is independent of the ambient
# locale and of the multibyte ellipsis a clipped line ends in and the U+25CF
# bullet - a byte count would inflate those into extra columns and phantom rows.
phys_lines() {  # <file> <width>
  LC_ALL=C awk -v w="$2" '
    BEGIN { for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i }
    function vcols(s,   n, i, o, c) {
      n = length(s); c = 0
      for (i = 1; i <= n; i++) {
        o = ord[substr(s, i, 1)]
        if (o >= 128 && o < 192) continue     # UTF-8 continuation byte, not a column
        c++
      }
      return c
    }
    { s = $0
      gsub(/\033\[[0-9;:?]*[A-Za-z]/, "", s)   # CSI/SGR
      gsub(/\033[()][0-9A-Za-z]/, "", s)        # charset select (ESC ( B etc.)
      gsub(/\033[=>]/, "", s)                    # keypad mode
      l = vcols(s); if (l == 0) c = 1; else c = int((l + w - 1) / w); t += c }
    END { print t + 0 }' "$1"
}

run_fit() {  # <rows> <cols> -> writes the frame to $TMP_ROOT/fit.out
  TERM=dumb FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$FIT_SNAP" \
    FM_DESK_MERGEQ_BIN="$FIT_MQ" FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
    FM_DESK_TUI_ROWS="$1" FM_DESK_TUI_COLS="$2" "$TUI" --once > "$TMP_ROOT/fit.out"
}

# The load-bearing case: a busy live-fleet-shaped board at a 49-row pane must
# not exceed 49 physical lines after wrapping at the pane width.
run_fit 49 80 || fail "fit paint (49x80) must exit 0"
fit49=$(phys_lines "$TMP_ROOT/fit.out" 80)
[ "$fit49" -le 49 ] || fail "board overflows a 49-row pane: $fit49 physical lines at width 80"
# It must actually USE most of the pane (not collapse to almost nothing), so the
# fit is a real fit, not a trivial one.
[ "$fit49" -ge 30 ] || fail "board underfills a 49-row pane: only $fit49 lines, wasting space"
pass "busy board fits a 49-row pane after wrapping ($fit49 <= 49 physical lines)"

# A narrow pane wraps the long second-mate rows to several physical lines; the
# fit must account for that width, not just the logical line count.
run_fit 49 52 || fail "fit paint (49x52) must exit 0"
fit49n=$(phys_lines "$TMP_ROOT/fit.out" 52)
[ "$fit49n" -le 49 ] || fail "board overflows a 49-row pane at width 52: $fit49n physical lines"
pass "busy board fits a 49-row pane at a narrow width ($fit49n <= 49 physical lines)"

# The width-40 floor is where slack is tightest: the always-rendered merge title
# "Ready to merge (finished, not yet landed)" is 41 cols and wraps to two lines
# there, so a header charged a flat one-line cost would under-count. The
# acceptance criterion is <= 49 physical lines at every width 40-160, so sweep
# the range (stepping past the wrapping-narrow band) and assert each width fits.
for wcol in 40 41 48 56 72 80 100 120 160; do
  run_fit 49 "$wcol" || fail "fit paint (49x$wcol) must exit 0"
  fitw=$(phys_lines "$TMP_ROOT/fit.out" "$wcol")
  [ "$fitw" -le 49 ] || fail "board overflows a 49-row pane at width $wcol: $fitw physical lines"
done
pass "busy board fits a 49-row pane at every swept width 40-160 (tightest is 40)"

# Short pane (30 rows): must fit AND show strictly fewer rows than the 49-row
# pane - the old floor was inverted (a shorter pane kept the same 3-row cap).
run_fit 30 80 || fail "fit paint (30x80) must exit 0"
fit30=$(phys_lines "$TMP_ROOT/fit.out" 80)
[ "$fit30" -le 30 ] || fail "board overflows a 30-row pane: $fit30 physical lines"
run_fit 30 80; rows30=$(grep -c '^  ' "$TMP_ROOT/fit.out")
run_fit 49 80; rows49=$(grep -c '^  ' "$TMP_ROOT/fit.out")
[ "$rows30" -lt "$rows49" ] || fail "a shorter pane must show FEWER content lines (30-row=$rows30 vs 49-row=$rows49) - floor inversion"
pass "short pane fits and shows fewer rows than a tall pane (no floor inversion: $rows30 < $rows49)"

# Tall pane (100 rows): fits its budget and shows MORE than the 49-row pane.
run_fit 100 80 || fail "fit paint (100x80) must exit 0"
fit100=$(phys_lines "$TMP_ROOT/fit.out" 80)
[ "$fit100" -le 100 ] || fail "board overflows a 100-row pane: $fit100 physical lines"
rows100=$(grep -c '^  ' "$TMP_ROOT/fit.out")
[ "$rows100" -gt "$rows49" ] || fail "a taller pane must show MORE content (100-row=$rows100 vs 49-row=$rows49)"
pass "tall pane fits its budget and shows more rows ($fit100 <= 100, $rows100 > $rows49)"

# A section dropped for want of budget drops its HEADER too (no bare 3-line
# collapse notice), while the two acted-on sections always render. At a very
# short pane the low-priority sections cannot fit, so at least one section
# header is absent, but Captain's Call and Ready to merge are always present.
run_fit 20 80 || fail "fit paint (20x80) must exit 0"
short=$(cat "$TMP_ROOT/fit.out")
fit20=$(phys_lines "$TMP_ROOT/fit.out" 80)
[ "$fit20" -le 20 ] || fail "board overflows a 20-row pane: $fit20 physical lines"
assert_contains "$short" "Captain's Call" "the acted-on decisions section always renders"
assert_contains "$short" "Ready to merge" "the acted-on merge section always renders"
# At least one lower-priority section header must be gone (dropped whole, not a
# bare collapse notice). Recently Landed is the lowest-value here.
if printf '%s' "$short" | grep -q "Recently Landed"; then
  fail "a section that could not fit must drop its header entirely, not show a bare collapse notice"
fi
pass "an unfittable section drops its whole header; acted-on sections always render"

# --- empty merge section under a line budget must not overflow (Finding 1) ----
# "Ready to merge" always renders, and when the queue is empty it paints its "No
# finished branches waiting to merge." line, so desk_fit must reserve that
# trailing line. Every row in this fixture is a single physical line, so the
# round-robin fill drains the budget to exactly zero at every pane height - the
# exact condition where an unreserved empty line paints budget+1 lines and
# scrolls the title off the pane. The invariant: physical lines <= the budget.
EMPTYMERGE_SNAP="$TMP_ROOT/emptymerge.sh"
cat > "$EMPTYMERGE_SNAP" <<'SH'
#!/usr/bin/env bash
jq -n '{
  schema: "fm-bearings.v1",
  in_flight: [ range(0;10) | { id: ("ship-\(.)"), kind: "ship", state: "working", doing: ("editing task \(.)") } ],
  secondmates: [], landed: [],
  decisions_open: [ range(0;3) | { id: ("hold-\(.)"), verb: "captain-hold", summary: ("decision \(.)") } ],
  gates: [ range(0;10) | { id: ("gate-\(.)"), title: ("queued \(.)"), blocked_by: "-", reason: "-" } ]
}'
SH
chmod +x "$EMPTYMERGE_SNAP"
for brow in 16 18 20 22 24; do
  TERM=dumb FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$EMPTYMERGE_SNAP" \
    FM_DESK_MERGEQ_BIN="$EMPTY_MQ" FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
    FM_DESK_TUI_ROWS="$brow" FM_DESK_TUI_COLS=80 "$TUI" --once > "$TMP_ROOT/emptymerge.out" \
    || fail "empty-merge fit paint (${brow}x80) must exit 0"
  emphys=$(phys_lines "$TMP_ROOT/emptymerge.out" 80)
  [ "$emphys" -le "$brow" ] || fail "an empty merge section overflows a ${brow}-row pane: $emphys physical lines"
done
pass "an empty merge section never overflows the pane by one line under a budget"

# --- the WIDEST production-shaped account line fits the 80-column pane --------
# The captain reads this board over SSH, where the width falls back to 80 columns
# and clip_frame cuts the overflow with an ellipsis. This drives the widest line
# the accounts block can produce: his longest real alias+email with the alias
# WHOLE ("claude-panda"), BOTH windows spent, both resets at their widest
# single-unit form ("59m"/"23h"), the routine "(Nm old)" staleness token PRESENT,
# and BOTH stores pointing at the same account. It must reach the pane already
# safe - a "<- cc…" cut mid-word names no store, which the ruling forbids - so the
# lib drops whole decorations (marker first, then the label) until the row fits.
#
# The cache is written DIRECTLY, with a per-provider fetched_at 90 seconds behind
# the render time: the blob itself is fresh (no re-fetch, so the stub binary is
# never consulted) while the provider's own reading is past the 60s age floor,
# which is exactly the routine half of every TTL cycle that paints "(1m old)".
WIDE_CSWAP="$TMP_ROOT/cswap-wide.sh"
cat > "$WIDE_CSWAP" <<'SH'
#!/usr/bin/env bash
echo '{ "schemaVersion": 1, "activeAccountNumber": 3, "accounts": [
  { "number": 3, "email": "sample.person@gmail.com", "active": true } ] }'
SH
chmod +x "$WIDE_CSWAP"
WIDE_AUTH="$TMP_ROOT/jcode-auth-wide.json"
cat > "$WIDE_AUTH" <<'JSON'
{ "active_anthropic_account": "claude-panda",
  "anthropic_accounts": [ { "label": "claude-panda", "email": "sample.person@gmail.com" } ] }
JSON
WIDE_CACHE="$TMP_ROOT/ju-wide-cache.json"
wide_now=$(date -d "2026-01-01 00:00:00 UTC" +%s)
cat > "$WIDE_CACHE" <<JSON
{ "fetched_at": $wide_now, "providers": [
  { "provider_name": "Anthropic - claude-panda (r***e@gmail.com) \u2726",
    "fetched_at": $((wide_now - 90)),
    "limits": [ { "name": "5-hour window", "usage_percent": 100.0, "resets_at": "2026-01-01T00:59:00+00:00" },
                { "name": "7-day window", "usage_percent": 100.0, "resets_at": "2026-01-01T23:00:00+00:00" } ],
    "extra_info": [ ["Last used", "just now"] ], "error": null } ] }
JSON
wide_frame=$(TERM=dumb FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" \
  FM_DESK_MERGEQ_BIN="$MQ_BIN" FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  FM_DESK_CSWAP_BIN="$WIDE_CSWAP" FM_DESK_JCODE_AUTH="$WIDE_AUTH" \
  FM_DESK_JCODE_USAGE_BIN="$TMP_ROOT/no-such-jcode" FM_DESK_JCODE_USAGE_CACHE="$WIDE_CACHE" \
  FM_DESK_TUI_COLS=80 "$TUI" --once) || fail "the wide-account paint must exit 0"
wide_line=$(printf '%s\n' "$wide_frame" | grep -F 'sample.person@gmail.com' | head -1)
[ -n "$wide_line" ] || fail "the widest account line must be painted at all"
# Everything the captain decides on survives WHOLE: both windows, both resets, and
# the staleness token. If clip_frame had cut the row this substring would be gone.
assert_contains "$wide_frame" \
  "3 sample.person@gmail.com  5h 100%x (59m) · 7d 100%x (23h) (1m old)" \
  "the widest account row reaches the 80-column pane with its numbers whole"
assert_not_contains "$wide_line" "…" "the widest account line carries no clip ellipsis"
assert_contains "$wide_line" "(1m old)" "the staleness token is never the thing dropped"
# What DID give way, in the documented worst-first order: the store marker, then
# the label - dropped outright, never abbreviated into a name jcode does not know.
assert_not_contains "$wide_line" "<- " "the store marker is dropped, not cut mid-word"
assert_not_contains "$wide_line" "claude-panda" "the label is dropped whole on a row that cannot hold it"
# Visible width, counted the way clip_frame counts it (a UTF-8 continuation byte
# continues the current column), so the ambient locale cannot change the answer.
vwidth() { local LC_ALL=C _s=$1 _b; _b=${_s//[$'\x80'-$'\xbf']/}; printf '%d' "${#_b}"; }
wide_w=$(vwidth "$wide_line")
[ "$wide_w" -le 80 ] || fail "the widest painted account row must fit 80 columns (got $wide_w): $wide_line"
# THIS BOARD'S chrome against the pane, reconciled with the single source of the
# budget rather than a number repeated here: the lib composes to DESK_ACCOUNT_COLS
# and this board prepends a 2-column status bullet, so ANY line within the budget
# reaches clip_frame already safe - not just the fixture above. The lib's own suite
# proves every composed line is within the budget; desk/src/render.rs proves the
# same relation for the static, nav and switch-overlay surfaces with their own
# (wider) chrome.
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
acct_cols=$(bash -c '. "$1"; printf "%s" "$DESK_ACCOUNT_COLS"' _ "$ROOT/bin/fm-desk-lib.sh")
case "$acct_cols" in ''|*[!0-9]*) fail "the lib must state DESK_ACCOUNT_COLS (got '$acct_cols')" ;; esac
[ $((acct_cols + 2)) -le 80 ] \
  || fail "the lib budget ($acct_cols) plus this board's 2-column bullet must fit the 80-column pane"
# The counterpart, from the populated paint above: a row that FITS keeps its
# marker AND its whole label. The suppression is a per-row width decision, never
# a blanket drop.
assert_contains "$frame" "3 panda c@gmail.com  5h 20%+ (5h) · 7d 4%+ (6d)  <- cc" \
  "a row that fits keeps its visible store marker"
assert_contains "$frame" "1 fox a@crew.test" "a row that fits keeps its whole jcode label"
pass "the widest account row is never clipped mid-content; a row that fits keeps its marker"

# --- hard width guarantee: no painted line exceeds COLS ----------------------
# The load-bearing property: at EVERY tested width, ZERO painted lines exceed
# COLS visible columns, measured with color OFF (plain bytes = columns for the
# ASCII fixture) and ON (a pty, ANSI stripped). This is asserted against the
# busy live-fleet-shaped fixture at the captain's real 62-col pane plus the 40
# floor, 80, and 120 - the widths that overran before the fix (decision rows at
# 142-151, second-mate rows at 151-152). vis_over counts lines wider than a
# width after stripping SGR (ESC [ ... letter) and charset-select (ESC ( X)
# escapes, then measuring VISIBLE COLUMNS: bytes minus UTF-8 continuation bytes
# (0x80-0xBF), so the 3-byte ellipsis and the 3-byte U+25CF bullet each count as
# one column, not three. A byte count would falsely flag a clipped 40-column
# line (39 chars + a 3-byte "…" = 42 bytes) as an overrun.
vis_over() {  # <file> <width> -> count of lines whose visible width exceeds <width>
  LC_ALL=C awk -v w="$2" '
    BEGIN { for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i }
    function vcols(s,   n, i, o, c) {
      n = length(s); c = 0
      for (i = 1; i <= n; i++) {
        o = ord[substr(s, i, 1)]
        if (o >= 128 && o < 192) continue     # UTF-8 continuation byte, not a column
        c++
      }
      return c
    }
    { s = $0
      gsub(/\033\[[0-9;:?]*[A-Za-z]/, "", s)   # CSI/SGR
      gsub(/\033[()][0-9A-Za-z]/, "", s)        # charset select (ESC ( B etc.)
      gsub(/\033[=>]/, "", s)                    # keypad mode
      if (vcols(s) > w) n++ }
    END { print n+0 }' "$1"
}

for wcol in 40 62 80 120; do
  # Color OFF: plain-text paint through a pipe (TERM=dumb).
  TERM=dumb FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$FIT_SNAP" \
    FM_DESK_MERGEQ_BIN="$FIT_MQ" FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
    FM_DESK_TUI_COLS="$wcol" "$TUI" --once > "$TMP_ROOT/w.plain"
  over=$(vis_over "$TMP_ROOT/w.plain" "$wcol")
  [ "$over" = 0 ] || fail "width $wcol: $over painted lines exceed COLS with color OFF"
done
pass "no painted line exceeds COLS at widths 40/62/80/120 (color OFF)"

# Color ON: the same assertion through a real pty, where the U+25CF bullet and
# SGR escapes are emitted. Skipped (not passed vacuously) where `script` is
# unavailable. Every line's VISIBLE width (SGR + charset escapes stripped) must
# still be <= COLS, proving width is measured on columns, not bytes.
if command -v script >/dev/null 2>&1; then
  color_over_total=0
  color_seen=0
  for wcol in 40 62 80 120; do
    cout=$(TERM=xterm-256color FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$FIT_SNAP" \
      FM_DESK_MERGEQ_BIN="$FIT_MQ" FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
      FM_DESK_TUI_COLS="$wcol" script -qec "$TUI --once" /dev/null 2>/dev/null) \
      || cout=$(TERM=xterm-256color FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$FIT_SNAP" \
      FM_DESK_MERGEQ_BIN="$FIT_MQ" FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
      FM_DESK_TUI_COLS="$wcol" script -q /dev/null "$TUI" --once 2>/dev/null) || cout=""
    if [ -n "$cout" ] && printf '%s' "$cout" | grep -q "Captain's desk"; then
      color_seen=1
      # The pty capture must actually carry color, or it is not exercising the
      # visible-width path (it would be a plain-text run in disguise).
      case "$cout" in *$'\033'*) : ;; *) fail "pty capture at width $wcol carried no ANSI" ;; esac
      printf '%s' "$cout" | sed 's/\r$//' > "$TMP_ROOT/w.color"
      over=$(vis_over "$TMP_ROOT/w.color" "$wcol")
      color_over_total=$((color_over_total + over))
      [ "$over" = 0 ] || fail "width $wcol: $over painted lines exceed COLS visible width with color ON"
    fi
  done
  if [ "$color_seen" = 1 ]; then
    pass "no painted line exceeds COLS visible width at widths 40/62/80/120 (color ON, $color_over_total overruns)"
  else
    echo "skip: script produced no usable pty capture for the color width guarantee"
  fi
else
  echo "skip: script not available for the color width guarantee"
fi

# An over-wide row is CLIPPED (marked with the ellipsis), not wrapped: at a narrow
# width the long second-mate row must end in the U+25CF-free "…" and still fit.
ELL=$(printf '\xe2\x80\xa6')
TERM=dumb FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$FIT_SNAP" \
  FM_DESK_MERGEQ_BIN="$FIT_MQ" FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  FM_DESK_TUI_COLS=62 "$TUI" --once > "$TMP_ROOT/w.clip"
assert_contains "$(cat "$TMP_ROOT/w.clip")" "$ELL" "an over-wide row is clipped with the ellipsis, not wrapped"
# And the clip preserves the head: a long captain-facing row still starts with
# its leading text so the captain can still read what it is. (The secondmates
# rows are now terse status words by design, so a long-line clip is exercised on
# the under-way work description that is legitimately long.)
grep -q "editing a moderately long description" "$TMP_ROOT/w.clip" \
  || fail "the clip must preserve the row headline (the part the captain acts on)"
pass "over-wide rows clip with the ellipsis and preserve the headline"

echo "# all fm-desk-tui tests passed"
