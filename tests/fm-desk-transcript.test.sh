#!/usr/bin/env bash
# Tests for the durable desk transcript feed producer (bin/fm-desk-transcript.sh).
#
# The feed is the SEPARATE, durable, captain-private rolling source for the
# desk's two catch-up panels (sections 11 and 12). This script is its only
# writer. This suite drives it through FM_DESK_TRANSCRIPT so it never touches a
# real home.
#
# Covers:
#   (a) turn/question append produce well-formed jsonl (one object per line)
#   (b) the feed is bounded at FM_DESK_TRANSCRIPT_MAX; the OLDEST lines trim
#   (c) the trim is atomic (a concurrent reader never sees a partial file)
#   (d) a malformed pre-existing line is tolerated (the producer never fails on
#       what it did not write; the reader owns line-level tolerance)
#   (e) the FM_DESK_TRANSCRIPT override selects the feed path
#   (f) turn --unread flags the unread field; who is validated
#   (g) list prints the last N lines; path prints the feed path
#   (h) arbitrary text with quotes/newlines/pipes is encoded safely (no torn JSON)
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

BIN="$ROOT/bin/fm-desk-transcript.sh"
TMP_ROOT=$(fm_test_tmproot fm-desk-transcript-tests)

# Run the producer against an explicit feed path. Args: feed cmd...
run() {
  local feed=$1
  shift
  FM_DESK_TRANSCRIPT="$feed" bash "$BIN" "$@"
}

# Every non-empty line must be a valid JSON object.
assert_all_json() {
  local feed=$1 msg=$2 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s' "$line" | jq -e 'type == "object"' >/dev/null 2>&1 \
      || fail "$msg (not a JSON object: $line)"
  done < "$feed"
}

test_turn_and_question_append_valid_json() {
  local feed="$TMP_ROOT/a.jsonl"
  run "$feed" turn captain "hello there" || fail "turn append failed"
  run "$feed" turn firstmate "on it" --unread || fail "unread turn append failed"
  run "$feed" question "which store?" "postgres" || fail "question append failed"
  run "$feed" question "no answer yet" || fail "answerless question append failed"
  [ "$(grep -c . "$feed")" = 4 ] || fail "expected 4 lines, got $(grep -c . "$feed")"
  assert_all_json "$feed" "append produces valid jsonl"
  # Field checks.
  jq -e 'select(.kind=="turn" and .who=="captain" and .text=="hello there" and .unread==false)' \
    < <(sed -n '1p' "$feed") >/dev/null || fail "turn 1 fields wrong"
  jq -e 'select(.kind=="turn" and .who=="firstmate" and .unread==true)' \
    < <(sed -n '2p' "$feed") >/dev/null || fail "unread turn not flagged"
  jq -e 'select(.kind=="question" and .q=="which store?" and .a=="postgres")' \
    < <(sed -n '3p' "$feed") >/dev/null || fail "question fields wrong"
  jq -e 'select(.kind=="question" and .a=="")' \
    < <(sed -n '4p' "$feed") >/dev/null || fail "answerless question a not empty"
  pass "turn and question append produce well-formed jsonl with correct fields"
}

test_bounded_oldest_trimmed() {
  local feed="$TMP_ROOT/b.jsonl" i
  for i in $(seq 1 12); do
    FM_DESK_TRANSCRIPT="$feed" FM_DESK_TRANSCRIPT_MAX=5 bash "$BIN" turn captain "msg $i" \
      || fail "append $i failed"
  done
  [ "$(grep -c . "$feed")" = 5 ] || fail "feed not capped at 5, got $(grep -c . "$feed")"
  # The oldest (msg 1..7) are gone; msg 8..12 remain.
  grep -q '"text":"msg 1"' "$feed" && fail "oldest line was not trimmed"
  grep -q '"text":"msg 8"' "$feed" || fail "newest window missing msg 8"
  grep -q '"text":"msg 12"' "$feed" || fail "newest line missing"
  assert_all_json "$feed" "trim keeps valid jsonl"
  pass "the feed is bounded at N and the oldest lines are trimmed"
}

test_trim_is_atomic_no_torn_read() {
  # Seed a feed already past a small cap, then append once. During the append+trim
  # the reader must always see a whole, valid file (the mv is atomic). We cannot
  # race a real reader deterministically, so we assert the invariant the atomicity
  # guarantees: after the trimming append the file parses fully and has exactly the
  # cap many valid lines, and no temp/partial file is left behind.
  local feed="$TMP_ROOT/c.jsonl" i
  for i in $(seq 1 6); do
    printf '{"ts":%s,"kind":"turn","who":"captain","text":"seed %s","unread":false}\n' "$i" "$i" >> "$feed"
  done
  FM_DESK_TRANSCRIPT="$feed" FM_DESK_TRANSCRIPT_MAX=4 bash "$BIN" turn firstmate "new one" \
    || fail "trimming append failed"
  [ "$(grep -c . "$feed")" = 4 ] || fail "post-trim line count wrong: $(grep -c . "$feed")"
  assert_all_json "$feed" "post-trim file is fully valid (no torn read)"
  # No leftover temp file in the feed directory.
  if ls "$TMP_ROOT"/.c.jsonl.tmp.* >/dev/null 2>&1; then
    fail "a temp file leaked - the trim was not a clean atomic mv"
  fi
  pass "the trim leaves a whole valid file and no leftover temp (atomic mv)"
}

test_malformed_preexisting_line_tolerated() {
  # The producer must never choke on a line it did not write. Seed garbage, then
  # append; the append must succeed and the new line must be valid.
  local feed="$TMP_ROOT/d.jsonl"
  printf 'this is not json\n' > "$feed"
  printf '{"ts":1,"kind":"turn"\n' >> "$feed"   # truncated JSON
  run "$feed" turn captain "still works" || fail "append over malformed lines failed"
  tail -n1 "$feed" | jq -e 'select(.text=="still works")' >/dev/null \
    || fail "the appended line is not valid after malformed predecessors"
  pass "a malformed pre-existing line is tolerated on append"
}

test_override_selects_path() {
  local feed="$TMP_ROOT/e-custom.jsonl"
  local shown
  shown=$(run "$feed" path)
  [ "$shown" = "$feed" ] || fail "path did not echo the override: $shown"
  run "$feed" turn captain "x" || fail "append failed"
  [ -f "$feed" ] || fail "override path was not written"
  pass "FM_DESK_TRANSCRIPT selects the feed path"
}

test_who_validated() {
  local feed="$TMP_ROOT/f.jsonl" rc=0
  run "$feed" turn nobody "x" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "expected rc 2 for a bad who, got $rc"
  [ ! -f "$feed" ] || fail "a rejected turn still wrote to the feed"
  pass "turn who must be captain or firstmate"
}

test_list_last_n_and_missing_feed() {
  local feed="$TMP_ROOT/g.jsonl" i out
  # list on a missing feed is a clean empty, not an error.
  out=$(run "$feed" list) || fail "list on missing feed errored"
  [ -z "$out" ] || fail "list on missing feed printed something"
  for i in $(seq 1 5); do run "$feed" turn captain "m$i"; done
  out=$(run "$feed" list 2)
  [ "$(printf '%s\n' "$out" | grep -c .)" = 2 ] || fail "list 2 did not return 2 lines"
  printf '%s\n' "$out" | tail -n1 | grep -q '"text":"m5"' || fail "list 2 did not return the newest lines"
  pass "list prints the last N lines and tolerates a missing feed"
}

test_hostile_text_encoded_safely() {
  # Quotes, a pipe, a tab, and a backslash must survive as JSON, one line each.
  local feed="$TMP_ROOT/h.jsonl"
  local hostile='he said "hi" | a\b	tab and | pipes'
  run "$feed" turn captain "$hostile" || fail "hostile-text append failed"
  [ "$(grep -c . "$feed")" = 1 ] || fail "hostile text produced more than one line"
  local decoded
  decoded=$(jq -r '.text' < "$feed")
  [ "$decoded" = "$hostile" ] || fail "hostile text did not round-trip: got [$decoded]"
  pass "arbitrary text with quotes, pipes, tabs is encoded as one safe JSON line"
}

test_turn_and_question_append_valid_json
test_bounded_oldest_trimmed
test_trim_is_atomic_no_torn_read
test_malformed_preexisting_line_tolerated
test_override_selects_path
test_who_validated
test_list_last_n_and_missing_feed
test_hostile_text_encoded_safely
echo "all fm-desk-transcript tests passed"
