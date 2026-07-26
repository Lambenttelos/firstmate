#!/usr/bin/env bash
# Tests for the one-pass session close (bin/fm-end-session.sh).
#
# Covers:
#   - a refusal is reported by task id with the line cleanup printed, exits 3,
#     and never retries with --force
#   - a refusing task is still recorded, and the session record is still appended
#   - a released task is counted and its id surfaced
#   - registered secondmates are left running, never torn down
#   - away time comes from state/.afk when a stretch is open, and is reported as
#     unrecorded when it is not
#   - the stats file is append-only across sessions
#   - report renders the most recent record, including model and effort
#   - report with no record yet fails loudly instead of printing an empty report
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLI="$ROOT/bin/fm-end-session.sh"
TMP_ROOT=$(fm_test_tmproot fm-end-session-tests)

# make_home <name> - create a home with state/ and data/ and echo its path.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data"
  printf '%s\n' "$home"
}

# fake_teardown <home> <refusing-id>... - install a cleanup stub that logs every
# invocation to <home>/teardown.log and refuses for the named task ids.
fake_teardown() {
  local home=$1 script="$1/fake-teardown.sh"
  shift
  printf '%s\n' "$@" > "$home/refuse-ids"
  cat > "$script" <<'SH'
#!/usr/bin/env bash
home=$(dirname "$0")
printf '%s\n' "$*" >> "$home/teardown.log"
if grep -qxF -- "$1" "$home/refuse-ids"; then
  echo "refusing: worktree holds unlanded work" >&2
  exit 1
fi
echo "cleaned up $1"
SH
  chmod +x "$script"
  printf '%s\n' "$script"
}

run_cli() {
  local home=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_END_SESSION_TEARDOWN="$home/fake-teardown.sh" "$CLI" "$@"
}

test_refusal_is_reported_and_never_forced() {
  local home; home=$(make_home refuse)
  fm_write_meta "$home/state/keeper.meta" 'kind=ship' 'window=fm:keeper'
  fm_write_meta "$home/state/clean.meta" 'kind=ship' 'window=fm:clean'
  fake_teardown "$home" keeper >/dev/null

  local out rc=0
  out=$(run_cli "$home" standdown --model claude-opus-5 --effort high 2>&1) || rc=$?
  expect_code 3 "$rc" "a refusal must exit 3"
  assert_contains "$out" 'keeper' 'the refusing worker must be named'
  assert_contains "$out" 'unlanded work' "the cleanup refusal's own words must be relayed"
  assert_contains "$out" 'workers stood down: 1' 'the clean worker must still be released'
  assert_no_grep '--force' "$home/teardown.log" 'cleanup must never be retried with --force'
  assert_grep 'refused=1' "$home/data/session-stats.log" 'the refusal must be recorded'
  assert_grep 'refused_ids=keeper' "$home/data/session-stats.log" 'the refusing id must be recorded'
  assert_grep 'released=1' "$home/data/session-stats.log" 'the released count must be recorded'
  pass "a refusal is named, relayed, recorded, and never forced"
}

test_all_clean_exits_zero() {
  local home; home=$(make_home clean)
  fm_write_meta "$home/state/a.meta" 'kind=ship'
  fm_write_meta "$home/state/b.meta" 'kind=scout'
  fake_teardown "$home" >/dev/null

  local out rc=0
  out=$(run_cli "$home" standdown 2>&1) || rc=$?
  expect_code 0 "$rc" "a fully clean stand-down must exit 0"
  assert_contains "$out" 'workers stood down: 2' 'both workers must be counted'
  assert_grep 'refused_ids=-' "$home/data/session-stats.log" 'no refusals must record as -'
  assert_grep 'model=unrecorded' "$home/data/session-stats.log" 'an unsupplied model must record as unrecorded'
  pass "a fully clean stand-down exits 0 and records no refusals"
}

test_secondmate_is_left_running() {
  local home; home=$(make_home secondmate)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home/sub"
  fake_teardown "$home" >/dev/null

  local out
  out=$(run_cli "$home" standdown)
  assert_contains "$out" 'secondmates left running: 1' 'the secondmate must be reported as still up'
  assert_absent "$home/teardown.log" 'a secondmate must never be torn down by session close'
  assert_grep 'secondmates_left=1' "$home/data/session-stats.log" 'the secondmate must be recorded'
  pass "registered secondmates are left running, never torn down"
}

test_away_time_from_open_flag() {
  local home; home=$(make_home away)
  fake_teardown "$home" >/dev/null
  printf '%s\n' 1000 > "$home/state/.afk"

  local out
  out=$(FM_END_SESSION_NOW=8200 run_cli "$home" standdown --model m --effort low)
  assert_contains "$out" 'away mode open at close: 2h 0m' 'the open away stretch must be measured'
  assert_grep 'away_seconds=7200' "$home/data/session-stats.log" 'away seconds must be recorded'
  assert_grep 'away_source=open-flag' "$home/data/session-stats.log" 'the away source must be recorded'
  pass "away time is measured from the open away flag"
}

test_away_time_unrecorded_without_flag() {
  local home; home=$(make_home noaway)
  fake_teardown "$home" >/dev/null

  local out
  out=$(run_cli "$home" standdown)
  assert_contains "$out" 'away mode: no open stretch' 'a closed stretch must not be invented'
  assert_grep 'away_source=unrecorded' "$home/data/session-stats.log" 'the away source must record as unrecorded'
  assert_grep 'away_seconds=0' "$home/data/session-stats.log" 'away seconds must record as 0'
  pass "away time is reported as unrecorded rather than estimated"
}

test_stats_file_is_append_only() {
  local home; home=$(make_home append)
  fake_teardown "$home" >/dev/null
  FM_END_SESSION_NOW=1000 run_cli "$home" standdown --model first --effort low >/dev/null
  FM_END_SESSION_NOW=2000 run_cli "$home" standdown --model second --effort high >/dev/null

  local count
  count=$(grep -c '^ended=' "$home/data/session-stats.log")
  [ "$count" = 2 ] || fail "expected 2 session records, got $count"
  assert_grep 'model=first' "$home/data/session-stats.log" 'the earlier session must survive the later one'
  pass "the stats file keeps history: a second close appends, never overwrites"
}

test_report_renders_last_record() {
  local home; home=$(make_home report)
  fm_write_meta "$home/state/x.meta" 'kind=ship'
  fake_teardown "$home" x >/dev/null
  printf '%s\n' 0 > "$home/state/.afk"
  FM_END_SESSION_NOW=5400 run_cli "$home" standdown --model claude-opus-5 --effort xhigh >/dev/null 2>&1 || true

  local out
  out=$(run_cli "$home" report)
  assert_contains "$out" 'model: claude-opus-5' 'the report must state the model'
  assert_contains "$out" 'effort: xhigh' 'the report must state the effort level'
  assert_contains "$out" 'time in away mode: 1h 30m' 'the report must state time in away mode'
  assert_contains "$out" 'workers still standing: 1 (x)' 'the report must name workers left standing'
  pass "report renders the most recent record with model, effort, and away time"
}

test_report_without_record_fails() {
  local home; home=$(make_home noreport)
  local rc=0
  run_cli "$home" report >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "report with no session record must fail"
  pass "report refuses rather than printing an empty session report"
}

test_refusal_is_reported_and_never_forced
test_all_clean_exits_zero
test_secondmate_is_left_running
test_away_time_from_open_flag
test_away_time_unrecorded_without_flag
test_stats_file_is_append_only
test_report_renders_last_record
test_report_without_record_fails
