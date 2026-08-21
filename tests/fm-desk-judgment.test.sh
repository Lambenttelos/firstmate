#!/usr/bin/env bash
# Behavior tests for the desk judgment-layer hook (sections 1, 2, 11, 12).
#
# The union/enrichment contract under test:
#   - Sections 1 and 2 are MERGE/UNION: the script owns WHICH items appear, the
#     judgment file only ENRICHES matched items by task id, an unmatched script
#     item shows a no-analysis marker, and a judgment-only id renders in a
#     labeled "firstmate also flags" sub-block. No duplicate cards.
#   - Sections 11 and 12 are SOLE-SOURCE from the judgment file, degrading to the
#     exact byte output of today's gap note when absent/stale/malformed.
#   - A visible generated-at stamp and a 900s max-age govern freshness.
# The absence path is a byte-identical regression lock against tests/fixtures.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DESK="$ROOT/bin/fm-desk-refresh.sh"
FIXTURES="$ROOT/tests/fixtures"
TMP_ROOT=$(fm_test_tmproot fm-desk-judgment)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

FAKE_EPOCH=1785225600

# The same populated projection the base desk test uses: two open decisions,
# three in-flight rows (one blocked to drive section 2).
POPULATED=$(cat <<'JSON'
{
  "decisions_open": [
    {"id":"decide-alpha","summary":"pick a data store","owner":"scout"},
    {"id":"decide-pay-rename","summary":"confirm the pricing rename","owner":"scout"}
  ],
  "in_flight": [
    {"id":"ship-one","kind":"ship","state":"working","doing":"editing the parser"},
    {"id":"ship-two","kind":"ship","state":"working","doing":{"weird":"object"}},
    {"id":"ship-stuck","kind":"ship","state":"blocked","doing":"waiting on a credential"}
  ],
  "gates": [],
  "landed": [ {"id":"ship-old","what":"landed the migration"} ],
  "recorded_prs": [ {"id":"pr-one","url":"https://github.com/acme/repo/pull/9"} ],
  "secondmates": [
    {"id":"decision-desk","state":"working","doing":"ruling on a schema question"},
    {"id":"mirror-desk","state":"no_active_work","doing":"No active child work"}
  ]
}
JSON
)

# make_snapshot <dir>: a fake fm-bearings-snapshot.sh printing $FAKE_JSON.
make_snapshot() {  # <dir>
  local f="$1/fake-snapshot.sh"
  cat > "$f" <<'SH'
#!/usr/bin/env bash
printf '%s' "$FAKE_JSON"
exit 0
SH
  chmod +x "$f"
  printf '%s\n' "$f"
}

# run_desk <home> <out> <judgment-path> [feed-path]: render with the fake
# snapshot, a minimal tasks-axi stub, a judgment path via FM_DESK_JUDGMENT, and
# an OPTIONAL durable transcript feed via FM_DESK_TRANSCRIPT. Pass a nonexistent
# judgment path for the absent case. When no feed path is given, the feed is
# pointed at a nonexistent file so the durable-feed source is absent and the
# existing golden regressions still hold.
run_desk() {  # <home> <out> <judgment-path> [feed-path]
  local home="$1" out="$2" fakebin jpath fpath
  jpath="${3:-$home/no-such-judgment.json}"
  [ -n "$jpath" ] || jpath="$home/no-such-judgment.json"
  fpath="${4:-$home/no-such-feed.jsonl}"
  [ -n "$fpath" ] || fpath="$home/no-such-feed.jsonl"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"show "*) exit 0 ;;
esac
case "$args" in
  *"--state done"*"--limit 1"*) exit 0 ;;
esac
case "$args" in
  *"--state held"*)
    printf '  held-money-thing,queued,ship,hyfin,1,"rotate a pricing key",captain\n'
    exit 0 ;;
  *"--state queued"*)
    printf '  ship-hyfin-a,queued,ship,hyfin,1,"add a pricing column"\n'
    exit 0 ;;
  *"--state in_flight"*) exit 0 ;;
  *"--blocked"*) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  local today
  today=$(date -d "@$FAKE_EPOCH" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
  mkdir -p "$home/data"
  printf '# ledger\ndone-a\t%s\tship\thyfin\tabc123\n' "$today" > "$home/data/completions.tsv"
  PATH="$fakebin:$PATH" \
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_DESK_SNAPSHOT_BIN="$SNAP" \
  FAKE_JSON="$POPULATED" \
  FM_DESK_CI_BUDGET=0 \
  FM_DESK_NOW_EPOCH="$FAKE_EPOCH" \
  FM_DESK_JUDGMENT="$jpath" \
  FM_DESK_TRANSCRIPT="$fpath" \
  FM_DESK_OUT="$out" FM_DESK_NOW='2026-07-28 09:00' \
    bash "$DESK" >/dev/null 2>&1
}

# extract <out> <section-id> : the exact bytes of one section, start heading
# through its closing </section>. Used for the byte-identical regression lock.
extract() {  # <file> <section-id>
  awk -v id="$2" '
    $0 ~ ("id=\"" id "\"") { p = 1 }
    p { print }
    p && /<\/section>/ { exit }
  ' "$1"
}

# write_judgment <path> <written_at> <body-json-object-without-schema/written_at>
# Builds a schema-1 judgment file. The body is merged so callers pass just the
# section arrays they want.
write_judgment() {  # <path> <written_at> <body>
  local path="$1" wa="$2" body="$3"
  printf '%s' "$body" | jq --argjson wa "$wa" '. + {schema: 1, written_at: $wa}' > "$path"
}

# ============================================================================
# 1. ABSENT judgment -> the four sections are byte-identical to the golden
#    fixtures captured from the pre-hook script (hard regression lock).
# ============================================================================
HOME_ABS="$TMP_ROOT/absent"; mkdir -p "$HOME_ABS"
SNAP=$(make_snapshot "$HOME_ABS")
OUT_ABS="$HOME_ABS/desk.html"
run_desk "$HOME_ABS" "$OUT_ABS" ""

for pair in "sec-decisions:desk-s1-absent.golden" "sec-blockers:desk-s2-absent.golden" \
            "sec-questions:desk-s11-absent.golden" "sec-conversation:desk-s12-absent.golden"; do
  secid="${pair%%:*}"; golden="${pair##*:}"
  extract "$OUT_ABS" "$secid" > "$HOME_ABS/$secid.actual"
  if diff -u "$FIXTURES/$golden" "$HOME_ABS/$secid.actual" >/dev/null 2>&1; then
    pass "absent: $secid byte-identical to golden (regression lock)"
  else
    diff -u "$FIXTURES/$golden" "$HOME_ABS/$secid.actual" || true
    fail "absent: $secid drifted from golden $golden"
  fi
done
# The absent page still emits the terminal needs-decision hook line on stdout and
# shows the "no fresh firstmate analysis" stamp.
assert_grep 'No fresh firstmate analysis' "$OUT_ABS" 'absent: the no-analysis generated stamp is shown'
assert_grep 'About the two catch-up panels' "$OUT_ABS" 'absent: the transcript hook note is still shown'

# ============================================================================
# 2. FRESH VALID union: enrich matched decision + blocker by id, render 11/12.
# ============================================================================
HOME_FRESH="$TMP_ROOT/fresh"; mkdir -p "$HOME_FRESH"
SNAP=$(make_snapshot "$HOME_FRESH")
OUT_FRESH="$HOME_FRESH/desk.html"
JBODY=$(cat <<'JSON'
{
  "decisions": [
    {"id":"decide-alpha","ask":"Which data store do we standardize on?","options":["Postgres","SQLite"],"recommendation":"Postgres for the write volume","unblocks":"the ingest rewrite"}
  ],
  "blockers": [
    {"id":"ship-stuck","diagnosis":"the deploy token expired overnight","needs":"a fresh deploy token from you"}
  ],
  "questions": [
    {"q":"Should the nightly job email on success?","a":"No, only on failure"},
    {"q":"Do we keep the legacy export path?","a":""}
  ],
  "transcript": [
    {"who":"captain","text":"kick off the pricing rename","unread":false},
    {"who":"firstmate","text":"pricing rename is queued and running now","unread":true}
  ]
}
JSON
)
write_judgment "$HOME_FRESH/judgment.json" "$FAKE_EPOCH" "$JBODY"
run_desk "$HOME_FRESH" "$OUT_FRESH" "$HOME_FRESH/judgment.json"

# Section 1: the matched decision is enriched by id (ask/options/recommendation).
assert_grep 'Which data store do we standardize on' "$OUT_FRESH" 'fresh: matched decision ask is rendered'
assert_grep 'Postgres for the write volume' "$OUT_FRESH" 'fresh: matched decision recommendation is rendered'
assert_grep 'the ingest rewrite' "$OUT_FRESH" 'fresh: matched decision unblocks is rendered'
# The unmatched script decision (decide-pay-rename) shows the no-analysis marker.
assert_grep 'No firstmate analysis for this item' "$OUT_FRESH" 'fresh: an unmatched script item shows the no-analysis marker'
# Section 2: the matched blocker enrichment.
assert_grep 'the deploy token expired overnight' "$OUT_FRESH" 'fresh: matched blocker diagnosis is rendered'
assert_grep 'a fresh deploy token from you' "$OUT_FRESH" 'fresh: matched blocker needs is rendered'
# The script still owns which items appear: the blocked in-flight card is present.
assert_grep 'Ship stuck' "$OUT_FRESH" 'fresh: the script-owned blocker card still appears'
# Sections 11 and 12 render from judgment; no gap note.
assert_grep 'Should the nightly job email on success' "$OUT_FRESH" 'fresh: a recent question renders'
assert_grep 'only on failure' "$OUT_FRESH" 'fresh: a question answer renders'
assert_grep 'Not answered yet' "$OUT_FRESH" 'fresh: an unanswered question is marked'
assert_grep 'pricing rename is queued and running now' "$OUT_FRESH" 'fresh: a transcript turn renders'
assert_grep '#eb760f' "$OUT_FRESH" 'fresh: an unread transcript turn carries the orange rail'
assert_no_grep 'no local transcript source' "$OUT_FRESH" 'fresh: no 11/12 gap note when judgment supplied them'
assert_no_grep 'About the two catch-up panels' "$OUT_FRESH" 'fresh: the transcript hook note is suppressed'
# The visible generated-at stamp is present and states freshness.
assert_grep 'Firstmate analysis for sections 1, 2, 11, and 12 was written' "$OUT_FRESH" 'fresh: a visible generated-at stamp is shown'
# Transcript order: newest FIRST (firstmate turn appears before the captain turn).
fm_pos_a=$(grep -n 'pricing rename is queued' "$OUT_FRESH" | head -1 | cut -d: -f1)
fm_pos_b=$(grep -n 'kick off the pricing rename' "$OUT_FRESH" | head -1 | cut -d: -f1)
if [ -n "$fm_pos_a" ] && [ -n "$fm_pos_b" ] && [ "$fm_pos_a" -lt "$fm_pos_b" ]; then
  pass 'fresh: transcript renders newest-first'
else
  fail "fresh: transcript order wrong (firstmate at $fm_pos_a, captain at $fm_pos_b)"
fi
# No duplicate decision cards IN SECTION 1: decide-alpha appears exactly once as
# a card title there. The Captain's Call panel earlier on the page is a separate
# summary panel that legitimately repeats the title, so this count is scoped to
# section 1's own markup rather than the whole page.
n_alpha=$(awk 'BEGIN{ins=0;n=0} /id="sec-decisions"/{ins=1} ins && /Decide alpha/{n++} ins && /<\/section>/{print n; exit}' "$OUT_FRESH")
if [ "$n_alpha" -eq 1 ]; then
  pass 'fresh: matched decision renders exactly one card in section 1 (no duplication)'
else
  fail "fresh: expected 1 Decide alpha card in section 1, got $n_alpha"
fi
# The summary panel itself carries the decision once, never twice.
n_panel_alpha=$(awk 'BEGIN{ins=0;n=0} /id="sec-captains-call"/{ins=1} ins && /Decide alpha/{n++} ins && /<\/section>/{print n; exit}' "$OUT_FRESH")
if [ "$n_panel_alpha" -eq 1 ]; then
  pass 'fresh: captains-call panel lists the decision exactly once'
else
  fail "fresh: expected 1 Decide alpha row in the captains-call panel, got $n_panel_alpha"
fi

# ============================================================================
# 3. JUDGMENT-ONLY item -> a decision/blocker id with no script match appears in
#    the "firstmate also flags" sub-block, ADDING to the script rows.
# ============================================================================
HOME_ONLY="$TMP_ROOT/only"; mkdir -p "$HOME_ONLY"
SNAP=$(make_snapshot "$HOME_ONLY")
OUT_ONLY="$HOME_ONLY/desk.html"
JBODY_ONLY=$(cat <<'JSON'
{
  "decisions": [
    {"id":"ghost-decision","ask":"Approve the vendor swap?","recommendation":"yes, cheaper and faster"}
  ],
  "blockers": [
    {"id":"ghost-blocker","diagnosis":"CI runner pool is exhausted","needs":"a bigger runner quota"}
  ]
}
JSON
)
write_judgment "$HOME_ONLY/judgment.json" "$FAKE_EPOCH" "$JBODY_ONLY"
run_desk "$HOME_ONLY" "$OUT_ONLY" "$HOME_ONLY/judgment.json"
assert_grep 'Firstmate also flags' "$OUT_ONLY" 'judgment-only: the also-flags sub-block header is shown'
assert_grep 'Approve the vendor swap' "$OUT_ONLY" 'judgment-only: a judgment-only decision is added'
assert_grep 'CI runner pool is exhausted' "$OUT_ONLY" 'judgment-only: a judgment-only blocker is added'
# ADD, never suppress: the script-owned items still appear alongside.
assert_grep 'Decide alpha' "$OUT_ONLY" 'judgment-only: the script decision still appears'
assert_grep 'Ship stuck' "$OUT_ONLY" 'judgment-only: the script blocker still appears'

# ============================================================================
# 4. STALE judgment -> older than 900s degrades to the exact absent output.
# ============================================================================
HOME_STALE="$TMP_ROOT/stale"; mkdir -p "$HOME_STALE"
SNAP=$(make_snapshot "$HOME_STALE")
OUT_STALE="$HOME_STALE/desk.html"
write_judgment "$HOME_STALE/judgment.json" "$(( FAKE_EPOCH - 901 ))" "$JBODY"
run_desk "$HOME_STALE" "$OUT_STALE" "$HOME_STALE/judgment.json"
for pair in "sec-decisions:desk-s1-absent.golden" "sec-blockers:desk-s2-absent.golden" \
            "sec-questions:desk-s11-absent.golden" "sec-conversation:desk-s12-absent.golden"; do
  secid="${pair%%:*}"; golden="${pair##*:}"
  extract "$OUT_STALE" "$secid" > "$HOME_STALE/$secid.actual"
  if diff -u "$FIXTURES/$golden" "$HOME_STALE/$secid.actual" >/dev/null 2>&1; then
    pass "stale: $secid degrades to the exact absent output"
  else
    diff -u "$FIXTURES/$golden" "$HOME_STALE/$secid.actual" || true
    fail "stale: $secid did not degrade cleanly"
  fi
done
# A stale-but-present file must not show the "fresh analysis written" stamp.
assert_grep 'No fresh firstmate analysis' "$OUT_STALE" 'stale: the no-analysis stamp is shown for a stale file'

# Freshness boundary: exactly 900s old is still FRESH (inclusive bound).
HOME_EDGE="$TMP_ROOT/edge"; mkdir -p "$HOME_EDGE"
SNAP=$(make_snapshot "$HOME_EDGE")
OUT_EDGE="$HOME_EDGE/desk.html"
write_judgment "$HOME_EDGE/judgment.json" "$(( FAKE_EPOCH - 900 ))" "$JBODY"
run_desk "$HOME_EDGE" "$OUT_EDGE" "$HOME_EDGE/judgment.json"
assert_grep 'Which data store do we standardize on' "$OUT_EDGE" 'edge: a judgment exactly 900s old is still fresh'

# ============================================================================
# 5. schema != 1 -> ignored, degrades to absent output.
# ============================================================================
HOME_SCHEMA="$TMP_ROOT/schema"; mkdir -p "$HOME_SCHEMA"
SNAP=$(make_snapshot "$HOME_SCHEMA")
OUT_SCHEMA="$HOME_SCHEMA/desk.html"
printf '%s' "$JBODY" | jq --argjson wa "$FAKE_EPOCH" '. + {schema: 2, written_at: $wa}' > "$HOME_SCHEMA/judgment.json"
run_desk "$HOME_SCHEMA" "$OUT_SCHEMA" "$HOME_SCHEMA/judgment.json"
extract "$OUT_SCHEMA" sec-questions > "$HOME_SCHEMA/s11.actual"
if diff -u "$FIXTURES/desk-s11-absent.golden" "$HOME_SCHEMA/s11.actual" >/dev/null 2>&1; then
  pass 'schema!=1: section 11 degrades to the absent output'
else
  fail 'schema!=1: section 11 did not degrade'
fi
assert_no_grep 'Which data store do we standardize on' "$OUT_SCHEMA" 'schema!=1: enrichment is not applied'

# ============================================================================
# 6. MALFORMED JSON -> the page still renders (exit 0), degrades to absent.
# ============================================================================
HOME_BAD="$TMP_ROOT/bad"; mkdir -p "$HOME_BAD"
SNAP=$(make_snapshot "$HOME_BAD")
OUT_BAD="$HOME_BAD/desk.html"
printf '{ this is not valid json ' > "$HOME_BAD/judgment.json"
run_desk "$HOME_BAD" "$OUT_BAD" "$HOME_BAD/judgment.json"
assert_present "$OUT_BAD" 'malformed: the page still renders'
extract "$OUT_BAD" sec-conversation > "$HOME_BAD/s12.actual"
if diff -u "$FIXTURES/desk-s12-absent.golden" "$HOME_BAD/s12.actual" >/dev/null 2>&1; then
  pass 'malformed: section 12 degrades to the absent output'
else
  fail 'malformed: section 12 did not degrade'
fi

# ============================================================================
# 7. PER-SECTION empty array -> only that section degrades; others still splice.
# ============================================================================
HOME_PART="$TMP_ROOT/partial"; mkdir -p "$HOME_PART"
SNAP=$(make_snapshot "$HOME_PART")
OUT_PART="$HOME_PART/desk.html"
JBODY_PART=$(cat <<'JSON'
{
  "decisions": [
    {"id":"decide-alpha","ask":"Which data store?","recommendation":"Postgres"}
  ],
  "questions": [],
  "transcript": [
    {"who":"captain","text":"just this one line","unread":false}
  ]
}
JSON
)
write_judgment "$HOME_PART/judgment.json" "$FAKE_EPOCH" "$JBODY_PART"
run_desk "$HOME_PART" "$OUT_PART" "$HOME_PART/judgment.json"
# decisions present -> enriched; questions empty -> section 11 gap; transcript present.
assert_grep 'Which data store' "$OUT_PART" 'partial: present decisions array enriches section 1'
extract "$OUT_PART" sec-questions > "$HOME_PART/s11.actual"
if diff -u "$FIXTURES/desk-s11-absent.golden" "$HOME_PART/s11.actual" >/dev/null 2>&1; then
  pass 'partial: an empty questions array degrades section 11 only'
else
  fail 'partial: section 11 did not degrade with an empty array'
fi
assert_grep 'just this one line' "$OUT_PART" 'partial: a present transcript array still renders section 12'

# ============================================================================
# 8. HTML-escape + internal-vocab translation on judgment values.
# ============================================================================
HOME_ESC="$TMP_ROOT/esc"; mkdir -p "$HOME_ESC"
SNAP=$(make_snapshot "$HOME_ESC")
OUT_ESC="$HOME_ESC/desk.html"
JBODY_ESC=$(cat <<'JSON'
{
  "decisions": [
    {"id":"decide-alpha","ask":"the crewmate hit <script>alert(1)</script> & broke"}
  ]
}
JSON
)
write_judgment "$HOME_ESC/judgment.json" "$FAKE_EPOCH" "$JBODY_ESC"
run_desk "$HOME_ESC" "$OUT_ESC" "$HOME_ESC/judgment.json"
assert_no_grep '<script>alert(1)</script>' "$OUT_ESC" 'escape: raw HTML metacharacters do not reach the page'
assert_grep '&lt;script&gt;' "$OUT_ESC" 'escape: the metacharacters are HTML-escaped'
assert_grep 'worker hit' "$OUT_ESC" 'translate: internal vocabulary is rewritten to captain nouns'

# ============================================================================
# 9. DURABLE FEED: sections 11 and 12 render from the transcript feed, which is
#    the PRIMARY source (bin/fm-desk-transcript.sh). The feed stores turns
#    oldest-first; the panel shows them newest-first with the unread rail.
# ============================================================================
HOME_FEED="$TMP_ROOT/feed"; mkdir -p "$HOME_FEED"
SNAP=$(make_snapshot "$HOME_FEED")
OUT_FEED="$HOME_FEED/desk.html"
FEED_FILE="$HOME_FEED/desk-transcript.jsonl"
{
  printf '%s\n' '{"ts":1,"kind":"turn","who":"captain","text":"the FIRST turn","unread":false}'
  printf '%s\n' '{"ts":2,"kind":"turn","who":"firstmate","text":"the SECOND turn","unread":true}'
  printf '%s\n' '{"ts":3,"kind":"question","q":"which store for the feed?","a":"postgres for the feed"}'
} > "$FEED_FILE"
run_desk "$HOME_FEED" "$OUT_FEED" "" "$FEED_FILE"
assert_grep 'which store for the feed?' "$OUT_FEED" 'feed: a question from the feed renders in section 11'
assert_grep 'postgres for the feed' "$OUT_FEED" 'feed: the question answer renders'
assert_grep 'the FIRST turn' "$OUT_FEED" 'feed: a turn from the feed renders in section 12'
assert_grep 'the SECOND turn' "$OUT_FEED" 'feed: the second turn renders'
assert_grep '#eb760f' "$OUT_FEED" 'feed: an unread turn carries the orange rail'
assert_no_grep 'no local transcript source' "$OUT_FEED" 'feed: no 11/12 gap note when the feed supplied them'
assert_no_grep 'About the two catch-up panels' "$OUT_FEED" 'feed: the catch-up note is suppressed when the feed is present'
# Newest-first: the SECOND (newer) turn must appear on the page before the FIRST.
first_pos=$(grep -n 'the FIRST turn' "$OUT_FEED" | head -n1 | cut -d: -f1)
second_pos=$(grep -n 'the SECOND turn' "$OUT_FEED" | head -n1 | cut -d: -f1)
if [ -n "$first_pos" ] && [ -n "$second_pos" ] && [ "$second_pos" -lt "$first_pos" ]; then
  pass 'feed: section 12 renders newest-first'
else
  fail "feed: transcript order wrong (FIRST at $first_pos, SECOND at $second_pos)"
fi

# ============================================================================
# 10. PRECEDENCE: with BOTH a feed and a fresh judgment, the feed WINS and the
#     judgment turns are NOT rendered (no double-render).
# ============================================================================
HOME_PREC="$TMP_ROOT/prec"; mkdir -p "$HOME_PREC"
SNAP=$(make_snapshot "$HOME_PREC")
OUT_PREC="$HOME_PREC/desk.html"
FEED_PREC="$HOME_PREC/desk-transcript.jsonl"
printf '%s\n' '{"ts":1,"kind":"turn","who":"captain","text":"FEED turn wins","unread":false}' > "$FEED_PREC"
printf '%s\n' '{"ts":1,"kind":"question","q":"FEED question wins","a":"yes"}' >> "$FEED_PREC"
JBODY_PREC=$(cat <<'JSON'
{
  "questions": [ {"q":"JUDGMENT question loses","a":"no"} ],
  "transcript": [ {"who":"firstmate","text":"JUDGMENT turn loses","unread":false} ]
}
JSON
)
write_judgment "$HOME_PREC/judgment.json" "$FAKE_EPOCH" "$JBODY_PREC"
run_desk "$HOME_PREC" "$OUT_PREC" "$HOME_PREC/judgment.json" "$FEED_PREC"
assert_grep 'FEED turn wins' "$OUT_PREC" 'precedence: the feed transcript renders'
assert_grep 'FEED question wins' "$OUT_PREC" 'precedence: the feed question renders'
assert_no_grep 'JUDGMENT turn loses' "$OUT_PREC" 'precedence: the judgment transcript is NOT rendered (no double-render)'
assert_no_grep 'JUDGMENT question loses' "$OUT_PREC" 'precedence: the judgment question is NOT rendered (no double-render)'

# ============================================================================
# 11. FALLBACK: an EMPTY feed falls back to the judgment file for 11/12.
# ============================================================================
HOME_FB="$TMP_ROOT/fallback"; mkdir -p "$HOME_FB"
SNAP=$(make_snapshot "$HOME_FB")
OUT_FB="$HOME_FB/desk.html"
FEED_FB="$HOME_FB/desk-transcript.jsonl"
: > "$FEED_FB"   # present but empty
JBODY_FB=$(cat <<'JSON'
{
  "questions": [ {"q":"JUDGMENT fallback question","a":"ok"} ],
  "transcript": [ {"who":"captain","text":"JUDGMENT fallback turn","unread":false} ]
}
JSON
)
write_judgment "$HOME_FB/judgment.json" "$FAKE_EPOCH" "$JBODY_FB"
run_desk "$HOME_FB" "$OUT_FB" "$HOME_FB/judgment.json" "$FEED_FB"
assert_grep 'JUDGMENT fallback question' "$OUT_FB" 'fallback: empty feed falls back to the judgment question'
assert_grep 'JUDGMENT fallback turn' "$OUT_FB" 'fallback: empty feed falls back to the judgment transcript'

# ============================================================================
# 12. MALFORMED FEED: a present feed of only unparseable lines degrades sections
#     11 and 12 to the EXACT absent golden output, never an error.
# ============================================================================
HOME_FBAD="$TMP_ROOT/feed-bad"; mkdir -p "$HOME_FBAD"
SNAP=$(make_snapshot "$HOME_FBAD")
OUT_FBAD="$HOME_FBAD/desk.html"
FEED_FBAD="$HOME_FBAD/desk-transcript.jsonl"
{
  printf '%s\n' 'this is not json'
  printf '%s\n' '{"ts":1,"kind":"turn"'      # truncated
  printf '%s\n' '   '                         # whitespace only
} > "$FEED_FBAD"
run_desk "$HOME_FBAD" "$OUT_FBAD" "" "$FEED_FBAD"
assert_present "$OUT_FBAD" 'feed-malformed: the page still renders'
for pair in "sec-questions:desk-s11-absent.golden" "sec-conversation:desk-s12-absent.golden"; do
  secid="${pair%%:*}"; golden="${pair##*:}"
  extract "$OUT_FBAD" "$secid" > "$HOME_FBAD/$secid.actual"
  if diff -u "$FIXTURES/$golden" "$HOME_FBAD/$secid.actual" >/dev/null 2>&1; then
    pass "feed-malformed: $secid degrades to the exact absent golden"
  else
    diff -u "$FIXTURES/$golden" "$HOME_FBAD/$secid.actual" || true
    fail "feed-malformed: $secid did not degrade to the golden"
  fi
done

# ============================================================================
# 13. A GARBLED line among GOOD lines is skipped individually; the good turns
#     still render (line-level tolerance).
# ============================================================================
HOME_MIX="$TMP_ROOT/feed-mix"; mkdir -p "$HOME_MIX"
SNAP=$(make_snapshot "$HOME_MIX")
OUT_MIX="$HOME_MIX/desk.html"
FEED_MIX="$HOME_MIX/desk-transcript.jsonl"
{
  printf '%s\n' '{"ts":1,"kind":"turn","who":"captain","text":"good turn one","unread":false}'
  printf '%s\n' 'GARBAGE not json at all'
  printf '%s\n' '{"ts":3,"kind":"turn","who":"firstmate","text":"good turn two","unread":false}'
} > "$FEED_MIX"
run_desk "$HOME_MIX" "$OUT_MIX" "" "$FEED_MIX"
assert_grep 'good turn one' "$OUT_MIX" 'feed-mixed: the first good turn renders past a garbled line'
assert_grep 'good turn two' "$OUT_MIX" 'feed-mixed: the second good turn renders'
# The catch-up note is suppressed because a source (the feed) DID supply a panel.
assert_no_grep 'About the two catch-up panels' "$OUT_MIX" 'feed-mixed: the catch-up note is suppressed when the feed supplied section 12'

echo "all fm-desk-judgment tests passed"
