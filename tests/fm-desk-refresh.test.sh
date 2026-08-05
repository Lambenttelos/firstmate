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

# A populated projection: two open decisions, two in-flight rows (one with an
# OBJECT-valued .doing to exercise the scalarize hardening), one landed row.
POPULATED=$(cat <<'JSON'
{
  "decisions_open": [
    {"id":"decide-alpha","summary":"pick a data store","owner":"scout"},
    {"id":"decide-beta","summary":"confirm the rename","owner":"scout"}
  ],
  "in_flight": [
    {"id":"ship-one","state":"working","doing":"editing the parser"},
    {"id":"ship-two","state":"working","doing":{"weird":"object"}}
  ],
  "gates": [],
  "landed": [
    {"id":"ship-old","what":"landed the migration"}
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
  # tasks-axi: the ticket-band probe must exit 0; show/list return nothing so the
  # desk falls back to the snapshot's own field values.
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  PATH="$fakebin:$PATH" \
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_DESK_SNAPSHOT_BIN="$SNAP" SEEN_HOME="$home/seen-home" \
  SEEN_SKIP="$home/seen-skip" \
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
assert_grep 'Decide beta' "$OUT1" 'populated: second open decision reaches the page'
assert_grep 'Ship one' "$OUT1" 'populated: an in-flight row reaches the page'
assert_grep 'Ship two' "$OUT1" 'populated: the object-valued row still renders (scalarize)'
assert_grep 'Ship old' "$OUT1" 'populated: a landed row reaches the page'
assert_no_grep 'Nothing is running' "$OUT1" 'populated: running section is not confident-empty'
assert_no_grep 'Nothing is waiting on you' "$OUT1" 'populated: decisions section is not confident-empty'

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

assert_no_grep 'Nothing is running' "$OUT2" 'broken: running section must not claim empty'
assert_grep 'could not be read' "$OUT2" 'broken: a visible section gap is shown instead'

# --- absent projection: the global gap banner shows and no dependent section
#     confidently claims empty -----------------------------------------------------
HOME3="$TMP_ROOT/home3"; mkdir -p "$HOME3"
SNAP=$(make_snapshot "$HOME3")
OUT3="$HOME3/desk.html"
FAKE_MODE=fail run_desk "$HOME3" "$OUT3"

assert_grep 'Some of this page is missing' "$OUT3" 'absent: the global gap banner is shown'
assert_no_grep 'Nothing is running' "$OUT3" 'absent: running section must not claim empty'
assert_no_grep 'Nothing is waiting on you' "$OUT3" 'absent: decisions section must not claim empty'

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
assert_grep 'Ship old' "$OUT4" 'away: a landed row still reaches the page'
assert_no_grep 'could not be read' "$OUT4" 'away: no fleet-state gap banner while away'
assert_no_grep 'Some of this page is missing' "$OUT4" 'away: no global gap banner while away'
assert_no_grep 'Nothing is running' "$OUT4" 'away: running section is not confident-empty'

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

echo "all fm-desk-refresh tests passed"
