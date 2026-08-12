#!/usr/bin/env bash
# Tests for the decision-desk value ledger (bin/fm-decision-desk-ledger.sh).
#
# The ledger is a cheap tracking affordance: firstmate appends a row at the
# secondmate-routing step, updates its status when the ruling returns, and reads
# a tally on demand. This suite drives the script through FM_DATA_OVERRIDE so it
# never touches a real home.
#
# Covers:
#   (a) route appends one row with status routed and an empty overturned cell
#   (b) resolve updates the last matching row's status in place
#   (c) overturn marks the last matching row overturned=yes
#   (d) tally counts routed/ruled/insufficient-source/escalated and overturned
#   (e) a re-used subject updates its most recent row, not an older one
#   (f) resolve of a missing subject is a reported no-op (rc 3), not corruption
#   (g) an invalid status is refused (rc 2) without writing
#   (h) a pipe in a field is refused so the Markdown table stays parseable
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BIN="$ROOT/bin/fm-decision-desk-ledger.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-desk-tests)

# Run the ledger tool against a fresh data dir. Args: data_dir cmd...
run() {
  local data=$1
  shift
  FM_DATA_OVERRIDE="$data" bash "$BIN" "$@"
}

# Count data rows (skip title, prose, header, separator).
row_count() {
  grep -E '^\| ' "$1" 2>/dev/null | grep -vE '^\| --- |^\| when \(UTC\)' | grep -c . || echo 0
}

test_route_appends_routed_row() {
  local data="$TMP_ROOT/a"
  mkdir -p "$data"
  run "$data" route task-a "does foo override bar?" || fail "route failed"
  local file="$data/decision-desk-ledger.md"
  [ -f "$file" ] || fail "ledger not created"
  [ "$(row_count "$file")" = 1 ] || fail "expected exactly 1 row"
  local row
  row=$(grep -E '^\| ' "$file" | grep -vE '^\| --- |^\| when \(UTC\)')
  case "$row" in
    *"| task-a | does foo override bar? | routed | |") : ;;
    *) fail "route row wrong: $row" ;;
  esac
  pass "route appends one row with status routed and empty overturned"
}

test_resolve_updates_status() {
  local data="$TMP_ROOT/b"
  mkdir -p "$data"
  run "$data" route task-b "q?"
  run "$data" resolve task-b ruled || fail "resolve failed"
  grep -qE '\| task-b \|.*\| ruled \|' "$data/decision-desk-ledger.md" \
    || fail "status not updated to ruled"
  [ "$(row_count "$data/decision-desk-ledger.md")" = 1 ] || fail "resolve changed row count"
  pass "resolve updates the last matching row status in place"
}

test_overturn_marks_yes() {
  local data="$TMP_ROOT/c"
  mkdir -p "$data"
  run "$data" route task-c "q?"
  run "$data" resolve task-c ruled
  run "$data" overturn task-c || fail "overturn failed"
  grep -qE '\| task-c \|.*\| ruled \| yes \|' "$data/decision-desk-ledger.md" \
    || fail "overturned cell not set to yes"
  pass "overturn marks the last matching row overturned=yes"
}

test_tally_counts() {
  local data="$TMP_ROOT/d"
  mkdir -p "$data"
  run "$data" route t1 "q1"
  run "$data" route t2 "q2"
  run "$data" route t3 "q3"
  run "$data" route t4 "q4"          # stays routed
  run "$data" resolve t1 ruled
  run "$data" resolve t2 insufficient-source
  run "$data" resolve t3 escalated
  run "$data" overturn t1
  local out
  out=$(run "$data" tally)
  printf '%s\n' "$out" | grep -q '4 requests total' || fail "total wrong: $out"
  printf '%s\n' "$out" | grep -q 'routed (awaiting ruling): 1' || fail "routed wrong: $out"
  printf '%s\n' "$out" | grep -q 'ruled: 1' || fail "ruled wrong: $out"
  printf '%s\n' "$out" | grep -q 'insufficient-source: 1' || fail "insufficient wrong: $out"
  printf '%s\n' "$out" | grep -q 'escalated: 1' || fail "escalated wrong: $out"
  printf '%s\n' "$out" | grep -q 'overturned: 1' || fail "overturned wrong: $out"
  pass "tally counts each status and overturned annotations"
}

test_reused_subject_updates_latest() {
  local data="$TMP_ROOT/e"
  mkdir -p "$data"
  run "$data" route dup "first"
  run "$data" route dup "second"
  run "$data" resolve dup ruled
  local file="$data/decision-desk-ledger.md"
  # The first row must still be routed, the second ruled.
  grep -qE '\| dup \| first \| routed \|' "$file" || fail "first row disturbed"
  grep -qE '\| dup \| second \| ruled \|' "$file" || fail "latest row not resolved"
  pass "a re-used subject updates its most recent row"
}

test_resolve_missing_is_noop() {
  local data="$TMP_ROOT/f"
  mkdir -p "$data"
  run "$data" route present "q"
  local rc=0
  run "$data" resolve absent ruled >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 3 ] || fail "expected rc 3 for missing subject, got $rc"
  # The existing row is untouched.
  grep -qE '\| present \|.*\| routed \|' "$data/decision-desk-ledger.md" \
    || fail "resolve of missing subject corrupted the ledger"
  pass "resolve of a missing subject is a reported no-op"
}

test_invalid_status_refused() {
  local data="$TMP_ROOT/g"
  mkdir -p "$data"
  run "$data" route task-g "q"
  local rc=0
  run "$data" resolve task-g bogus >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "expected rc 2 for bad status, got $rc"
  grep -qE '\| task-g \|.*\| routed \|' "$data/decision-desk-ledger.md" \
    || fail "invalid status wrote to the ledger"
  pass "an invalid status is refused without writing"
}

test_pipe_field_refused() {
  local data="$TMP_ROOT/h"
  mkdir -p "$data"
  local rc=0
  run "$data" route "a|b" "q" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "expected rc 2 for a pipe in subject, got $rc"
  pass "a pipe in a field is refused so the table stays parseable"
}

test_route_appends_routed_row
test_resolve_updates_status
test_overturn_marks_yes
test_tally_counts
test_reused_subject_updates_latest
test_resolve_missing_is_noop
test_invalid_status_refused
test_pipe_field_refused
