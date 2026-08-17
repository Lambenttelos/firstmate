#!/usr/bin/env bash
# Behavior tests for the automatic-handoff detached wrapper
# (fm-secondmate-auto-handoff.sh). The wrapper delegates the whole orderly
# sequence to fm-secondmate-handoff.sh (proven in fm-secondmate-handoff.test.sh)
# and owns only the after-the-fact PRIMARY notification and the double-launch
# lock. Driven through FM_SM_AUTO_HANDOFF_DRY_RUN=1 so the real handoff runs in
# its own dry-run (no live backend) and the notification is PRINTED rather than
# enqueued, so the exact FYI/escalation is asserted without a real wake queue.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-auto-handoff-tests)
mkdir -p "$TMP_ROOT"

# Reuse the handoff test's home wiring: a meta with window/home/harness/kind and
# a claude transcript giving fm_sm_context_tokens a controllable count.
setup_home() {  # <name> <tokens|-> [kind]
  local name=$1 tokens=$2 kind=${3:-secondmate}
  local fmhome="$TMP_ROOT/$name" home="$TMP_ROOT/$name-home" config="$TMP_ROOT/$name-cfg"
  mkdir -p "$fmhome/config" "$fmhome/state" "$home/data"
  {
    printf 'window=test:fm-sm\n'
    printf 'worktree=%s\nharness=claude\nkind=%s\nhome=%s\n' "$home" "$kind" "$home"
  } > "$fmhome/state/sm.meta"
  if [ "$tokens" != - ]; then
    local dir
    dir="$config/projects/$(printf '%s' "$home" | tr '/.' '--')"
    mkdir -p "$dir"
    printf '{"type":"assistant","message":{"usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' "$tokens" > "$dir/s.jsonl"
  fi
  printf '%s\t%s\t%s\n' "$fmhome" "$home" "$config"
}

run_wrapper() {  # <fmhome> <config> <args...>  -> sets STATUS, OUT
  local fmhome=$1 config=$2; shift 2
  FM_HOME="$fmhome" CLAUDE_CONFIG_DIR="$config" FM_SM_AUTO_HANDOFF_DRY_RUN=1 \
    "$ROOT/bin/fm-secondmate-auto-handoff.sh" "$@" > "$TMP_ROOT/out" 2>&1
  STATUS=$?
  OUT=$(cat "$TMP_ROOT/out")
}

test_usage_error_without_id() {
  local out
  out=$(FM_HOME="$TMP_ROOT" "$ROOT/bin/fm-secondmate-auto-handoff.sh" 2>&1; echo "code=$?")
  case "$out" in *"code=2"*) : ;; *) fail "missing id must be a usage error (code 2), got: $out" ;; esac
  pass "no id is a usage error"
}

test_success_emits_exactly_one_fyi() {
  local fmhome home config
  IFS=$'\t' read -r fmhome home config < <(setup_home ok 260000)
  run_wrapper "$fmhome" "$config" sm
  expect_code 0 "$STATUS" "over-threshold dry-run handoff should succeed"
  assert_contains "$OUT" "NOTIFY: secondmate-handoff-sm" "success must enqueue the FYI wake"
  assert_contains "$OUT" "check: secondmate-handoff sm" "FYI reason names the completed handoff"
  assert_not_contains "$OUT" "secondmate-handoff-failed" "success must NOT emit the failure escalation"
  # Exactly ONE FYI line.
  [ "$(printf '%s\n' "$OUT" | grep -c 'NOTIFY:')" -eq 1 ] \
    || fail "success must emit exactly one notification, got: $OUT"
  pass "a successful handoff emits exactly one primary FYI wake"
}

test_failure_emits_escalation() {
  local fmhome home config
  # A non-secondmate meta makes the underlying handoff refuse (exit 1), so the
  # wrapper must emit the failure escalation and exit non-zero.
  IFS=$'\t' read -r fmhome home config < <(setup_home fail 260000 ship)
  run_wrapper "$fmhome" "$config" sm
  expect_code 1 "$STATUS" "a refused handoff must make the wrapper exit non-zero"
  assert_contains "$OUT" "NOTIFY: secondmate-handoff-failed-sm" "failure must enqueue the escalation"
  assert_contains "$OUT" "run bin/fm-secondmate-handoff.sh sm by hand" "escalation tells the primary to run it by hand"
  pass "a failed handoff emits the escalation and exits non-zero (fail closed)"
}

test_double_launch_is_noop() {
  local fmhome home config lock
  IFS=$'\t' read -r fmhome home config < <(setup_home lock 260000)
  # Pre-create the per-id lock dir to simulate a handoff already in flight.
  lock="$fmhome/state/.sm-auto-handoff-sm.lock"
  mkdir -p "$lock"
  run_wrapper "$fmhome" "$config" sm
  expect_code 0 "$STATUS" "a concurrent launch must be a clean no-op"
  assert_contains "$OUT" "already in progress" "a concurrent launch is skipped"
  assert_not_contains "$OUT" "NOTIFY:" "a skipped launch must not notify"
  # The lock we planted must survive (the skipped run must not rmdir another's lock).
  [ -d "$lock" ] || fail "a skipped concurrent launch must not remove the in-flight lock"
  pass "a concurrent launch for the same id is a no-op that leaves the in-flight lock intact"
}

test_usage_error_without_id
test_success_emits_exactly_one_fyi
test_failure_emits_escalation
test_double_launch_is_noop

echo "# all fm-secondmate-auto-handoff tests passed"
