#!/usr/bin/env bash
# Behavior tests for the captain's-desk renderer.
#
# The regression these guard: an unreadable or unusual data source must never
# render as a confident empty section ("Nothing is running") - it must render as
# a VISIBLE GAP. Two independent failure modes caused the confident-empty bug:
#   1. desk_json swallowed a jq failure (one object/array-valued field makes
#      @tsv reject the WHOLE stream) via `2>/dev/null || printf ''`, so a
#      populated section rendered empty with no gap.
#   2. The desk resolved FM_HOME but never exported it, so a child source could
#      resolve a different (empty) home than the ticket band, which cd's into
#      FM_HOME. The tests assert the resolved home reaches the child.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DESK="$ROOT/bin/fm-desk-refresh.sh"
TMP_ROOT=$(fm_test_tmproot fm-desk)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A populated projection: two open decisions, three in-flight rows (one with an
# OBJECT-valued .doing to exercise the scalarize hardening, one blocked to drive
# section 2), one landed row, one recorded PR, two second mates (one idle).
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
  "landed": [
    {"id":"ship-old","what":"landed the migration"}
  ],
  "recorded_prs": [
    {"id":"pr-one","url":"https://github.com/acme/repo/pull/9"}
  ],
  "secondmates": [
    {"id":"decision-desk","state":"working","doing":"ruling on a schema question"},
    {"id":"mirror-desk","state":"no_active_work","doing":"No active child work"},
    {"id":"empty-desk","state":"no_active_work","doing":"No active child work"}
  ]
}
JSON
)

# make_snapshot <dir> writes a fake fm-bearings-snapshot.sh that records the
# FM_HOME it was invoked with to <dir>/seen-home, then behaves per FAKE_MODE:
#   json     print $FAKE_JSON verbatim (default)
#   broken   print valid JSON whose .in_flight is a NUMBER, so a section's jq
#            query fails even though `jq -e .` accepts the document
#   empty    print nothing and exit 0
#   fail     exit 1
make_snapshot() {  # <dir>
  local f="$1/fake-snapshot.sh"
  cat > "$f" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_HOME:-UNSET}" > "$SEEN_HOME"
printf '%s\n' "${FM_BEARINGS_SKIP_AFK_GUARD:-0}" > "${SEEN_SKIP:-/dev/null}"
# Simulate the real fm-bearings-snapshot.sh away-return guard: while away mode is
# active (FAKE_AFK=1) an ordinary read is refused with exit 3, unless the
# read-only bypass FM_BEARINGS_SKIP_AFK_GUARD=1 is set.
if [ "${FAKE_AFK:-0}" = 1 ] && [ "${FM_BEARINGS_SKIP_AFK_GUARD:-0}" != 1 ]; then
  exit 3
fi
case "${FAKE_MODE:-json}" in
  json)   printf '%s' "$FAKE_JSON" ;;
  broken) printf '{"decisions_open":[],"in_flight":42,"gates":[],"landed":[]}' ;;
  empty)  : ;;
  fail)   exit 1 ;;
esac
exit 0
SH
  chmod +x "$f"
  printf '%s\n' "$f"
}

# run_desk <home> <out> : render the desk with the fake snapshot and a minimal
# tasks-axi/gh stub set, echoing nothing (assertions read <out>).
run_desk() {  # <home> <out>
  local home="$1" out="$2" fakebin
  fakebin=$(fm_fakebin "$home")
  # tasks-axi stub: the ticket-band probe must exit 0. It also answers the desk's
  # backlog reads for sections 8 (captain-held) and 9 (four ranked queue lists),
  # emitting tasks-axi's two-space-indented, comma-separated row shape. show --full
  # returns nothing so cards fall back to the id-derived title.
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
# Args carry the query; branch on the flags the desk uses.
args="$*"
case "$args" in
  *"show "*) exit 0 ;;  # full-record read: fall back to snapshot/id
esac
case "$args" in
  *"--state done"*"--limit 1"*) exit 0 ;;  # the collect_tickets probe
esac
case "$args" in
  *"--state held"*)
    # id,state,kind,repo,priority,title,hold_kind
    printf '  held-money-thing,queued,ship,hyfin,1,"rotate a pricing key",captain\n'
    printf '  held-other,queued,task,firstmate,2,"tooling note",captain\n'
    exit 0 ;;
  *"--state queued"*)
    # id,state,kind,repo,priority,title
    printf '  ship-hyfin-a,queued,ship,hyfin,1,"add a pricing column"\n'
    printf '  scout-hyfin-b,queued,scout,hyfin-server,2,"investigate a charge bug"\n'
    printf '  tool-fm-c,queued,ship,firstmate,1,"speed up the watcher"\n'
    printf '  ship-hyfin-d,queued,ship,hyfin,3,"tweak a label"\n'
    exit 0 ;;
  *"--state in_flight"*) exit 0 ;;
  *"--blocked"*) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  # A completion ledger for the progress windows (5, 6) and stats (10). Dates are
  # relative to the injected epoch's calendar day so the windows are deterministic.
  local today yesterday
  today=$(date -d "@${FAKE_EPOCH:-1785225600}" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
  yesterday=$(date -d "@$(( ${FAKE_EPOCH:-1785225600} - 86400 ))" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
  if [ "${FAKE_NO_COMPLETIONS:-0}" != 1 ]; then
    mkdir -p "$home/data"
    {
      printf '# ledger\n'
      printf 'done-a\t%s\tship\thyfin\tabc123\n' "$today"
      printf 'done-b\t%s\tship\tfirstmate\tdef456\n' "$today"
      printf 'done-c\t%s\tscout\thyfin-server\t\n' "$yesterday"
    } > "$home/data/completions.tsv"
  fi
  # The second-mate registry the per-secondmate panel parses for home + scope,
  # and a real second-mate home with its own two-item open backlog so the panel's
  # queue-depth read has a file to count. FAKE_NO_SECONDMATE_REG=1 omits the
  # registry entirely (registry-absent path); FAKE_SM_REG_UNREADABLE=1 writes it
  # unreadable (registry-unreadable gap path).
  if [ "${FAKE_NO_SECONDMATE_REG:-0}" != 1 ]; then
    mkdir -p "$home/data"
    local ddhome mmhome mthome
    ddhome="$home/sm-decision-desk"
    mmhome="$home/sm-mirror-desk"
    mthome="$home/sm-empty-desk"
    mkdir -p "$ddhome/data" "$mmhome/data" "$mthome/data"
    # decision-desk: two open items + one done, so the open count is exactly 2.
    {
      printf '## Queued\n'
      printf -- '- [ ] q-one - first open item (repo: alpha)\n'
      printf -- '- [ ] q-two - second open item (repo: beta)\n'
      printf '## Done\n'
      printf -- '- [x] d-one - already landed (repo: alpha)\n'
    } > "$ddhome/data/backlog.md"
    # mirror-desk: no backlog file, so its queue depth reads as a gap ("-").
    # empty-desk: a readable backlog with zero open items, so its queue depth is
    # a confident "0" (a read file with no open work), not a gap.
    {
      printf '## Done\n'
      printf -- '- [x] d-only - already landed (repo: alpha)\n'
    } > "$mthome/data/backlog.md"
    {
      printf -- '- decision-desk - rules on schema questions (home: %s; scope: schema rulings; projects: hyfin; added 2026-07-01)\n' "$ddhome"
      printf -- '- mirror-desk - audits the mirror (home: %s; scope: mirror audits; projects: hyfin; added 2026-07-02)\n' "$mmhome"
      printf -- '- empty-desk - drains a quiet queue (home: %s; scope: quiet queue; projects: hyfin; added 2026-07-03)\n' "$mthome"
    } > "$home/data/secondmates.md"
    if [ "${FAKE_SM_REG_UNREADABLE:-0}" = 1 ]; then
      chmod 000 "$home/data/secondmates.md"
    fi
  fi
  PATH="$fakebin:$PATH" \
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_DESK_SNAPSHOT_BIN="$SNAP" SEEN_HOME="$home/seen-home" \
  SEEN_SKIP="$home/seen-skip" \
  FM_DESK_CI_BUDGET=0 \
  FM_DESK_NOW_EPOCH="${FAKE_EPOCH:-1785225600}" \
  FM_DESK_OUT="$out" FM_DESK_NOW='2026-07-28 09:00' \
    bash "$DESK"
}

# --- populated: real data renders, and the object-valued field does not blank
#     the section ---------------------------------------------------------------
HOME1="$TMP_ROOT/home1"; mkdir -p "$HOME1"
SNAP=$(make_snapshot "$HOME1")
OUT1="$HOME1/desk.html"
FAKE_MODE=json FAKE_JSON="$POPULATED" run_desk "$HOME1" "$OUT1"

# Record ids are rendered as human titles: "decide-alpha" -> "Decide alpha".
assert_grep 'Decide alpha' "$OUT1" 'populated: first open decision reaches the page'
assert_grep 'Decide pay rename' "$OUT1" 'populated: second open decision reaches the page'
assert_grep 'Ship one' "$OUT1" 'populated: an in-flight row reaches the page'
assert_grep 'Ship two' "$OUT1" 'populated: the object-valued row still renders (scalarize)'
assert_no_grep 'No slots are occupied' "$OUT1" 'populated: slots section is not confident-empty'
assert_no_grep 'Nothing is waiting on you' "$OUT1" 'populated: decisions section is not confident-empty'

# The sticky KPI strip and its jump links to sections 11 and 12 exist.
assert_grep 'sticky top-0' "$OUT1" 'sticky strip: the pinned KPI strip is present'
assert_grep 'href="#sec-questions"' "$OUT1" 'sticky strip: jump link to section 11'
assert_grep 'href="#sec-conversation"' "$OUT1" 'sticky strip: jump link to section 12'

# All twelve spec sections render in order.
for n in \
  '1. Decisions needed' '2. Blockers and failures' '3. Ready to merge' \
  '4. Slots and host' '5. Progress - last 3 hours' '6. Progress - last 12 hours' \
  '7. Most important upcoming progress' '8. Captain-held tickets' \
  '9. Next queue tickets' '10. Stats' '11. Recent questions' '12. Recent conversation'; do
  assert_grep "$n" "$OUT1" "section present: $n"
done

# Section 2 draws the blocked in-flight row and a fleet-health line.
assert_grep 'Ship stuck' "$OUT1" 'blockers: the blocked in-flight row reaches section 2'
assert_grep 'Monitoring' "$OUT1" 'blockers: a fleet-health line is shown'

# Section 4 lists crew only now (second mates have their own panel).
assert_grep 'Ship one' "$OUT1" 'slots: an in-flight crew row reaches section 4'

# The dedicated per-secondmate panel lists BOTH second mates, marks the idle one
# idle, and carries the registry-derived scope + this-home queue depth.
assert_grep 'id="sec-secondmates"' "$OUT1" 'secondmates: the dedicated panel renders'
assert_grep 'Decision desk' "$OUT1" 'secondmates: a working second mate is listed'
assert_grep 'Mirror desk' "$OUT1" 'secondmates: an idle second mate is listed'
assert_grep 'second mate' "$OUT1" 'secondmates: second mates are labeled'
# Idle is marked idle (state no_active_work -> "idle").
assert_grep 'idle' "$OUT1" 'secondmates: an idle second mate is marked idle'
# Scope one-liner parsed out of the fixture registry reaches the panel.
assert_grep 'schema rulings' "$OUT1" 'secondmates: registry scope reaches the panel'
assert_grep 'mirror audits' "$OUT1" 'secondmates: second registry scope reaches the panel'
# Queue depth: the fixture decision-desk home has a two-item open backlog.
assert_grep '<td class="text-sm align-top">2</td>' "$OUT1" 'secondmates: queue depth from the home backlog reaches the panel'
# A readable backlog with zero open items is a confident "0", not a gap "-".
assert_grep '<td class="text-sm align-top">0</td>' "$OUT1" 'secondmates: a readable empty backlog renders a confident 0'
# The panel must not fold back into the slots section.
assert_no_grep 'No second mates are standing' "$OUT1" 'secondmates: panel is not confident-empty when populated'

# Sections 5 and 6 render throughput from the completion ledger.
assert_grep '5. Progress - last 3 hours' "$OUT1" 'progress: 3h heading present'
assert_grep 'landed.' "$OUT1" 'progress: a landed count is shown'

# Section 8 shows the captain-held list, money item flagged.
assert_grep 'Held money thing' "$OUT1" 'captain-held: a captain hold is listed'

# Section 9 renders the four ranked cards.
assert_grep 'Top product ship' "$OUT1" 'queue: product-ship card present'
assert_grep 'Top product scout' "$OUT1" 'queue: product-scout card present'
assert_grep 'Top tooling' "$OUT1" 'queue: tooling card present'
assert_grep 'Quick and cheap wins' "$OUT1" 'queue: quick-wins card present'

# Sections 11 and 12 render as marked gaps naming the missing transcript source.
assert_grep 'no local transcript source' "$OUT1" '11/12: the transcript gap note is shown'

# NEVER WAKES holds: the builder must not reference any wake/steer/status-write path.
assert_no_grep 'fm_wake_append' "$OUT1" 'never wakes: no wake call leaked into output'

# Both open decisions must appear (acceptance: captain holds reach the page).
n_dec=$(grep -c 'your call' "$OUT1")
if [ "$n_dec" -eq 2 ]; then
  pass 'populated: both open decisions rendered'
else
  fail "populated: expected 2 decision cards, got $n_dec"
fi

# The desk's resolved home must reach the child snapshot.
seen=$(cat "$HOME1/seen-home" 2>/dev/null || printf '')
if [ "$seen" = "$HOME1" ]; then
  pass 'home export: child snapshot saw the desk FM_HOME'
else
  fail "home export: child saw '$seen', expected '$HOME1'"
fi

# --- broken projection: a failing section query renders a VISIBLE GAP, not a
#     confident empty ------------------------------------------------------------
HOME2="$TMP_ROOT/home2"; mkdir -p "$HOME2"
SNAP=$(make_snapshot "$HOME2")
OUT2="$HOME2/desk.html"
FAKE_MODE=broken run_desk "$HOME2" "$OUT2"

assert_no_grep 'No slots are occupied' "$OUT2" 'broken: slots section must not claim empty'
assert_grep 'could not be read' "$OUT2" 'broken: a visible section gap is shown instead'

# --- absent projection: the global gap banner shows and no dependent section
#     confidently claims empty -----------------------------------------------------
HOME3="$TMP_ROOT/home3"; mkdir -p "$HOME3"
SNAP=$(make_snapshot "$HOME3")
OUT3="$HOME3/desk.html"
FAKE_MODE=fail run_desk "$HOME3" "$OUT3"

assert_grep 'Some of this page is missing' "$OUT3" 'absent: the global gap banner is shown'
assert_no_grep 'No slots are occupied' "$OUT3" 'absent: slots section must not claim empty'
assert_no_grep 'Nothing is waiting on you' "$OUT3" 'absent: decisions section must not claim empty'

# Even with the projection gone, the twelve section headings still render (each
# degrades to a gap independently) and the sticky strip is still present.
assert_grep 'sticky top-0' "$OUT3" 'absent: the sticky strip still renders'
for n in '1. Decisions needed' '4. Slots and host' '9. Next queue tickets' '12. Recent conversation'; do
  assert_grep "$n" "$OUT3" "absent: section heading still present: $n"
done

# The count band is always present, even with the projection gone.
assert_grep 'Ticket count' "$OUT3" 'absent: the required count band is still rendered'

# --- away mode: the read-only desk still renders a FULL fleet, because it passes
#     the read-only away-guard bypass to the snapshot ---------------------------
# Regression: the desk previously rendered an empty "could not be read"/"missing"
# page whenever state/.afk was set, because the bearings away-return guard refused
# the read. The desk is strictly read-only (it displays away status), so it opts
# out of ONLY that refusal.
HOME4="$TMP_ROOT/home4"; mkdir -p "$HOME4"
SNAP=$(make_snapshot "$HOME4")
OUT4="$HOME4/desk.html"
FAKE_MODE=json FAKE_JSON="$POPULATED" FAKE_AFK=1 run_desk "$HOME4" "$OUT4"

assert_grep 'Ship one' "$OUT4" 'away: an in-flight row still reaches the page'
assert_grep 'Decide alpha' "$OUT4" 'away: an open decision still reaches the page'
assert_grep 'Decision desk' "$OUT4" 'away: a second-mate slot still reaches the page'
assert_no_grep 'could not be read' "$OUT4" 'away: no fleet-state gap banner while away'
assert_no_grep 'Some of this page is missing' "$OUT4" 'away: no global gap banner while away'
assert_no_grep 'No slots are occupied' "$OUT4" 'away: slots section is not confident-empty'

# The desk must have passed the read-only bypass to the snapshot.
seen_skip=$(cat "$HOME4/seen-skip" 2>/dev/null || printf '')
if [ "$seen_skip" = "1" ]; then
  pass 'away: desk passed FM_BEARINGS_SKIP_AFK_GUARD=1 to the snapshot'
else
  fail "away: desk did not pass the read-only bypass, snapshot saw '$seen_skip'"
fi

# --- non-away render is byte-unchanged whether or not the bypass would matter --
# The bypass only skips the guard; with away mode off, the output must match a
# render that never set FAKE_AFK at all.
HOME5="$TMP_ROOT/home5"; mkdir -p "$HOME5"
SNAP=$(make_snapshot "$HOME5")
OUT5A="$HOME5/desk-a.html"; OUT5B="$HOME5/desk-b.html"
FAKE_MODE=json FAKE_JSON="$POPULATED" run_desk "$HOME5" "$OUT5A"
FAKE_MODE=json FAKE_JSON="$POPULATED" FAKE_AFK=0 run_desk "$HOME5" "$OUT5B"
if diff -q "$OUT5A" "$OUT5B" >/dev/null 2>&1; then
  pass 'non-away: desk render is byte-unchanged with the bypass in play'
else
  fail 'non-away: desk render differs when the bypass path is exercised'
fi

# --- per-secondmate panel: registry UNREADABLE renders a GAP, not a confident
#     empty, and the rows still render from the snapshot -------------------------
HOME6="$TMP_ROOT/home6"; mkdir -p "$HOME6"
SNAP=$(make_snapshot "$HOME6")
OUT6="$HOME6/desk.html"
FAKE_MODE=json FAKE_JSON="$POPULATED" FAKE_SM_REG_UNREADABLE=1 run_desk "$HOME6" "$OUT6"

assert_grep 'id="sec-secondmates"' "$OUT6" 'sm-unreadable: the panel still renders'
assert_grep 'Decision desk' "$OUT6" 'sm-unreadable: snapshot rows still reach the panel'
assert_grep 'registry could not be read' "$OUT6" 'sm-unreadable: a visible registry gap is shown, not a confident empty'
assert_no_grep 'No second mates are standing' "$OUT6" 'sm-unreadable: panel is not confident-empty'

# --- per-secondmate panel: registry ABSENT still renders rows from the snapshot,
#     with scope shown as "-" and no confident-empty claim ----------------------
HOME7="$TMP_ROOT/home7"; mkdir -p "$HOME7"
SNAP=$(make_snapshot "$HOME7")
OUT7="$HOME7/desk.html"
FAKE_MODE=json FAKE_JSON="$POPULATED" FAKE_NO_SECONDMATE_REG=1 run_desk "$HOME7" "$OUT7"

assert_grep 'Decision desk' "$OUT7" 'sm-absent: snapshot rows still reach the panel'
assert_no_grep 'No second mates are standing' "$OUT7" 'sm-absent: panel is not confident-empty'
# An absent registry is not an unreadable registry: no unreadable-gap line.
assert_no_grep 'registry could not be read' "$OUT7" 'sm-absent: absence is not reported as an unreadable registry'

# --- per-secondmate panel: NO second mates in the snapshot is a confident empty,
#     not a gap ---------------------------------------------------------------
NO_SM=$(printf '%s' "$POPULATED" | jq -c '.secondmates = []')
HOME8="$TMP_ROOT/home8"; mkdir -p "$HOME8"
SNAP=$(make_snapshot "$HOME8")
OUT8="$HOME8/desk.html"
FAKE_MODE=json FAKE_JSON="$NO_SM" run_desk "$HOME8" "$OUT8"
assert_grep 'No second mates are standing' "$OUT8" 'sm-empty: an empty second-mate list is a confident empty'

# --- read-only invariant: building the desk must not mutate the fixture second-
#     mate registry or the second mate's own backlog (byte-unchanged) -----------
HOME9="$TMP_ROOT/home9"; mkdir -p "$HOME9"
SNAP=$(make_snapshot "$HOME9")
OUT9="$HOME9/desk.html"
FAKE_MODE=json FAKE_JSON="$POPULATED" run_desk "$HOME9" "$OUT9"
reg_before=$(md5sum "$HOME9/data/secondmates.md" | awk '{print $1}')
bl_before=$(md5sum "$HOME9/sm-decision-desk/data/backlog.md" | awk '{print $1}')
FAKE_MODE=json FAKE_JSON="$POPULATED" run_desk "$HOME9" "$OUT9"
reg_after=$(md5sum "$HOME9/data/secondmates.md" | awk '{print $1}')
bl_after=$(md5sum "$HOME9/sm-decision-desk/data/backlog.md" | awk '{print $1}')
if [ "$reg_before" = "$reg_after" ] && [ "$bl_before" = "$bl_after" ]; then
  pass 'read-only: the registry and second-mate backlog are byte-unchanged after a build'
else
  fail 'read-only: the desk mutated the registry or a second-mate backlog'
fi

echo "all fm-desk-refresh tests passed"
