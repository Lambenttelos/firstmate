#!/usr/bin/env bash
# Behavior tests for the secondmate context-window read (fm-secondmate-context-lib.sh)
# and its reporter (fm-secondmate-context.sh). The claude read is evidence-backed
# in docs/secondmate-context-handoff.md; every other harness must fail closed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-secondmate-context-lib.sh
. "$ROOT/bin/fm-secondmate-context-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-context-tests)
mkdir -p "$TMP_ROOT"

# Build a fake claude config dir with a transcript for <home>. Extra args are
# appended verbatim as additional JSONL lines.
write_transcript() {  # <config-dir> <home> <file-basename> <input> <cc> <cr> [extra-line...]
  local config=$1 home=$2 base=$3 input=$4 cc=$5 cr=$6; shift 6
  local dir extra
  dir="$config/projects/$(printf '%s' "$home" | tr '/.' '--')"
  mkdir -p "$dir"
  {
    printf '{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}\n' "$input" "$cc" "$cr"
    for extra in "$@"; do printf '%s\n' "$extra"; done
  } > "$dir/$base.jsonl"
  printf '%s' "$dir/$base.jsonl"
}

write_meta() {  # <state> <id> <home> <harness> [kind]
  local state=$1 id=$2 home=$3 harness=$4 kind=${5:-secondmate}
  mkdir -p "$state"
  cat > "$state/$id.meta" <<EOF
window=test:fm-$id
worktree=$home
harness=$harness
kind=$kind
home=$home
EOF
}

test_threshold_default_and_config() {
  local config="$TMP_ROOT/cfg1"
  mkdir -p "$config"
  [ "$(fm_sm_context_threshold "$config")" = 200000 ] || fail "absent config should default to 200000"
  printf '150000\n' > "$config/secondmate-context-threshold"
  [ "$(fm_sm_context_threshold "$config")" = 150000 ] || fail "configured threshold should be honored"
  printf '# comment\n\n  250000  \n' > "$config/secondmate-context-threshold"
  [ "$(fm_sm_context_threshold "$config")" = 250000 ] || fail "comment/blank/whitespace should be skipped/trimmed"
  printf 'garbage\n' > "$config/secondmate-context-threshold"
  [ "$(fm_sm_context_threshold "$config")" = 200000 ] || fail "non-integer threshold should fall back to default"
  printf '0\n' > "$config/secondmate-context-threshold"
  [ "$(fm_sm_context_threshold "$config")" = 200000 ] || fail "non-positive threshold should fall back to default"
  pass "threshold reads config, trims/skips noise, and fails safe on bad values"
}

test_munge_matches_claude() {
  [ "$(fm_sm_munge_path /Users/x/.treehouse/a-b/3/f)" = "-Users-x--treehouse-a-b-3-f" ] \
    || fail "munge must replace / and . with - (verified against real claude dir)"
  pass "path munging matches claude's project-folder rule"
}

test_claude_read_sums_last_mainthread_usage() {
  local config="$TMP_ROOT/cfg-read" home="$TMP_ROOT/home-read" out
  local sidechain='{"type":"assistant","isSidechain":true,"message":{"usage":{"input_tokens":999999,"cache_creation_input_tokens":999999,"cache_read_input_tokens":999999}}}'
  local trailing='{"type":"mode"}'
  write_transcript "$config" "$home" session 10 20 170000 "$sidechain" "$trailing" >/dev/null
  out=$(CLAUDE_CONFIG_DIR="$config" fm_sm_context_tokens "$home" claude)
  [ "$out" = 170030 ] || fail "should sum input+cache_creation+cache_read of last main-thread turn, got: $out"
  pass "claude read sums the last main-thread usage and ignores sidechain and trailing lines"
}

test_newest_transcript_wins() {
  local config="$TMP_ROOT/cfg-newest" home="$TMP_ROOT/home-newest" f1 f2 out
  f1=$(write_transcript "$config" "$home" old 1 1 1)
  f2=$(write_transcript "$config" "$home" new 5 5 90)
  touch -t 202601010000 "$f1"
  touch -t 202607200000 "$f2"
  out=$(CLAUDE_CONFIG_DIR="$config" fm_sm_context_tokens "$home" claude)
  [ "$out" = 100 ] || fail "newest-mtime transcript should be read, got: $out"
  pass "the active (newest-mtime) transcript is the one read"
}

test_non_claude_and_missing_fail_closed() {
  local config="$TMP_ROOT/cfg-fc" home="$TMP_ROOT/home-fc"
  write_transcript "$config" "$home" session 10 20 170000 >/dev/null
  [ -z "$(CLAUDE_CONFIG_DIR="$config" fm_sm_context_tokens "$home" codex)" ] || fail "codex must read empty (fail closed)"
  [ -z "$(CLAUDE_CONFIG_DIR="$config" fm_sm_context_tokens "$home" opencode)" ] || fail "opencode must read empty"
  [ -z "$(CLAUDE_CONFIG_DIR="$config" fm_sm_context_tokens "$home" pi)" ] || fail "pi must read empty"
  [ -z "$(CLAUDE_CONFIG_DIR="$config" fm_sm_context_tokens "$home" grok)" ] || fail "grok must read empty"
  [ -z "$(CLAUDE_CONFIG_DIR="$config" fm_sm_context_tokens "/no/such/home" claude)" ] || fail "missing transcript must read empty"
  [ -z "$(fm_sm_context_tokens "" claude)" ] || fail "empty cwd must read empty"
  pass "unsupported harness, missing transcript, and empty cwd all fail closed"
}

test_no_jq_fails_closed() {
  local config="$TMP_ROOT/cfg-jq" home="$TMP_ROOT/home-jq" nojqbin tool out
  write_transcript "$config" "$home" session 10 20 170000 >/dev/null
  # A PATH holding only the read's non-jq tools, so `command -v jq` fails.
  nojqbin="$TMP_ROOT/nojqbin"
  mkdir -p "$nojqbin"
  for tool in bash grep tr; do ln -sf "$(command -v "$tool")" "$nojqbin/$tool"; done
  PATH="$nojqbin" command -v jq >/dev/null 2>&1 && fail "test PATH must not resolve jq"
  out=$(PATH="$nojqbin" CLAUDE_CONFIG_DIR="$config" bash -c '. "'"$ROOT"'/bin/fm-secondmate-context-lib.sh"; fm_sm_context_tokens "'"$home"'" claude')
  [ -z "$out" ] || fail "without jq the read must fail closed (empty), got: $out"
  pass "an absent jq fails the read closed instead of guessing"
}

test_reporter_over_under_unknown() {
  local config="$TMP_ROOT/cfg-rep" home="$TMP_ROOT/home-rep" fmhome out
  fmhome="$TMP_ROOT/fmhome-rep"
  mkdir -p "$fmhome/config"
  write_meta "$fmhome/state" sm-x "$home" claude
  write_transcript "$config" "$home" session 10 20 170000 >/dev/null

  printf '100000\n' > "$fmhome/config/secondmate-context-threshold"
  out=$(CLAUDE_CONFIG_DIR="$config" FM_HOME="$fmhome" "$ROOT/bin/fm-secondmate-context.sh" sm-x)
  assert_contains "$out" "context_tokens=170030" "reporter should print the token count"
  assert_contains "$out" "over_threshold=yes" "170030 over 100000 should report yes"

  printf '200000\n' > "$fmhome/config/secondmate-context-threshold"
  out=$(CLAUDE_CONFIG_DIR="$config" FM_HOME="$fmhome" "$ROOT/bin/fm-secondmate-context.sh" sm-x)
  assert_contains "$out" "over_threshold=no" "170030 under 200000 should report no"

  # codex meta -> unknown read -> unknown verdict, still exit 0.
  write_meta "$fmhome/state" sm-c "$home" codex
  out=$(CLAUDE_CONFIG_DIR="$config" FM_HOME="$fmhome" "$ROOT/bin/fm-secondmate-context.sh" sm-c)
  assert_contains "$out" "context_tokens=unknown" "codex read should be unknown"
  assert_contains "$out" "over_threshold=unknown" "unknown read verdict should be unknown"
  pass "reporter classifies over/under/unknown against the configured threshold"
}

test_reporter_refuses_non_secondmate() {
  local fmhome="$TMP_ROOT/fmhome-refuse" status
  write_meta "$fmhome/state" ship1 "$TMP_ROOT/whatever" claude ship
  FM_HOME="$fmhome" "$ROOT/bin/fm-secondmate-context.sh" ship1 >/dev/null 2>&1
  status=$?
  expect_code 2 "$status" "a non-secondmate task must be refused"
  FM_HOME="$fmhome" "$ROOT/bin/fm-secondmate-context.sh" nope >/dev/null 2>&1
  status=$?
  expect_code 2 "$status" "an unknown id must be refused"
  pass "reporter refuses non-secondmate and unknown ids"
}

test_threshold_default_and_config
test_munge_matches_claude
test_claude_read_sums_last_mainthread_usage
test_newest_transcript_wins
test_non_claude_and_missing_fail_closed
test_no_jq_fails_closed
test_reporter_over_under_unknown
test_reporter_refuses_non_secondmate

echo "# all fm-secondmate-context tests passed"
