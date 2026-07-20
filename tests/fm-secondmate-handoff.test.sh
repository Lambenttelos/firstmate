#!/usr/bin/env bash
# Behavior tests for the secondmate context-handoff orchestrator
# (fm-secondmate-handoff.sh): fail-closed refusals, the threshold gate, the
# dry-run action sequence, and capture idempotency. The steering/exit/respawn
# side effects are exercised through FM_SM_HANDOFF_DRY_RUN so no live backend or
# real agent is needed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-handoff-tests)
mkdir -p "$TMP_ROOT"

# Fresh FM_HOME + claude config per case, wired so fm_sm_context_tokens reads a
# controllable token count for the secondmate.
setup_home() {  # <name> <tokens|-> [kind] [with_window] [with_homedir]
  local name=$1 tokens=$2 kind=${3:-secondmate} with_window=${4:-1} with_homedir=${5:-1}
  local fmhome="$TMP_ROOT/$name" home="$TMP_ROOT/$name-home" config="$TMP_ROOT/$name-cfg"
  mkdir -p "$fmhome/config" "$fmhome/state"
  [ "$with_homedir" = 1 ] && mkdir -p "$home/data"
  {
    [ "$with_window" = 1 ] && printf 'window=test:fm-%s\n' sm
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

# run_handoff sets STATUS and OUT in the parent shell (no command-substitution
# subshell, which would strip the assignments).
run_handoff() {  # <fmhome> <config> <args...>
  local fmhome=$1 config=$2; shift 2
  FM_HOME="$fmhome" CLAUDE_CONFIG_DIR="$config" FM_SM_HANDOFF_DRY_RUN=1 \
    "$ROOT/bin/fm-secondmate-handoff.sh" "$@" > "$TMP_ROOT/out" 2>&1
  STATUS=$?
  OUT=$(cat "$TMP_ROOT/out")
}

test_refuse_missing_and_non_secondmate() {
  local fmhome home config out
  IFS=$'\t' read -r fmhome home config < <(setup_home refuse-ship 210000 ship)
  run_handoff "$fmhome" "$config" sm; out=$OUT; expect_code 1 "$STATUS" "non-secondmate must refuse"
  assert_contains "$out" "is not a secondmate" "non-secondmate refusal message"

  out=$(FM_HOME="$fmhome" FM_SM_HANDOFF_DRY_RUN=1 "$ROOT/bin/fm-secondmate-handoff.sh" nope 2>&1)
  expect_code 1 "$?" "unknown id must refuse"
  assert_contains "$out" "no metadata" "unknown id refusal message"

  expect_code 2 "$(FM_HOME="$fmhome" "$ROOT/bin/fm-secondmate-handoff.sh" >/dev/null 2>&1; echo $?)" "no id is a usage error"
  pass "refuses missing metadata, non-secondmate tasks, and missing id"
}

test_refuse_no_window_or_home() {
  local fmhome home config out
  IFS=$'\t' read -r fmhome home config < <(setup_home refuse-nowin 210000 secondmate 0 1)
  run_handoff "$fmhome" "$config" sm; out=$OUT; expect_code 1 "$STATUS" "no window must refuse"
  assert_contains "$out" "no window recorded" "no-window refusal is a recovery case, not a handoff"

  IFS=$'\t' read -r fmhome home config < <(setup_home refuse-nohome 210000 secondmate 1 0)
  run_handoff "$fmhome" "$config" sm; out=$OUT; expect_code 1 "$STATUS" "missing home dir must refuse"
  assert_contains "$out" "home for 'sm' is missing" "missing-home refusal message"
  pass "refuses when the window or home is missing"
}

test_threshold_gate() {
  local fmhome home config out
  # Under threshold, non-force: no-op success.
  IFS=$'\t' read -r fmhome home config < <(setup_home gate-under 50000)
  run_handoff "$fmhome" "$config" sm; out=$OUT; expect_code 0 "$STATUS" "under-threshold is a clean no-op"
  assert_contains "$out" "no handoff needed" "under-threshold no-op message"
  assert_not_contains "$out" "DRY-RUN" "under-threshold must not start the sequence"

  # Unknown read, non-force: fail closed.
  IFS=$'\t' read -r fmhome home config < <(setup_home gate-unknown -)
  run_handoff "$fmhome" "$config" sm; out=$OUT; expect_code 1 "$STATUS" "unknown context must refuse without --force"
  assert_contains "$out" "unreadable" "unknown-context refusal message"
  pass "threshold gate no-ops under threshold and fails closed on an unreadable read"
}

test_dry_run_full_sequence_over_threshold() {
  local fmhome home config out
  IFS=$'\t' read -r fmhome home config < <(setup_home seq-over 260000)
  run_handoff "$fmhome" "$config" sm; out=$OUT; expect_code 0 "$STATUS" "over-threshold dry-run should complete"
  assert_contains "$out" ">= threshold" "should announce the crossing"
  assert_contains "$out" "fm-send.sh" "should steer the secondmate to write the doc"
  assert_contains "$out" "handoff-latest.md" "should target the durable in-home doc, not temp"
  assert_contains "$out" "exit agent" "should exit the old agent"
  assert_contains "$out" "fm-spawn.sh sm --secondmate" "should respawn a fresh secondmate"
  assert_contains "$out" "handoff complete" "should report completion"
  pass "over-threshold dry-run runs the full steer/exit/respawn sequence"
}

test_force_bypasses_threshold() {
  local fmhome home config out
  # Force with an unreadable context still proceeds.
  IFS=$'\t' read -r fmhome home config < <(setup_home force-unknown -)
  run_handoff "$fmhome" "$config" sm --force; out=$OUT; expect_code 0 "$STATUS" "--force proceeds despite unknown read"
  assert_contains "$out" "forced" "forced handoff should announce itself"
  assert_contains "$out" "fm-spawn.sh sm --secondmate" "forced handoff still respawns"
  pass "--force bypasses the threshold and unknown-read gate"
}

test_capture_idempotent() {
  local fmhome home config out
  IFS=$'\t' read -r fmhome home config < <(setup_home idem 260000)
  # A completed capture from a prior run: doc + done marker, no pending request.
  printf 'continuation\n' > "$home/data/handoff-latest.md"
  : > "$home/data/.handoff-done"
  run_handoff "$fmhome" "$config" sm --force; out=$OUT; expect_code 0 "$STATUS" "idempotent resume should succeed"
  assert_contains "$out" "already captured" "a completed capture must not be repeated"
  assert_not_contains "$out" "write" "must not rewrite the instruction file when capture is complete"
  pass "a completed capture is detected and not repeated (idempotent resume)"
}

test_refuse_missing_and_non_secondmate
test_refuse_no_window_or_home
test_threshold_gate
test_dry_run_full_sequence_over_threshold
test_force_bypasses_threshold
test_capture_idempotent

echo "# all fm-secondmate-handoff tests passed"
