#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh --unsupervised and the watcher's exclusion of a
# supervise=off pane.
#
# Two contracts are asserted:
#   1. Parser: --unsupervised is accepted for a crewmate/scout spawn (it reaches
#      the later missing-brief fast-fail, not a flag error) and is refused in
#      combination with --secondmate. These reach validation before any
#      tmux/treehouse side effect, so they need no mocks (same fast-fail pattern
#      as fm-spawn-env.test.sh).
#   2. Watcher: bin/fm-watch.sh returns early when sourced (before the singleton
#      lock and the blocking loop), so its functions load into this shell.
#      recorded_windows() is the single chokepoint feeding every supervision path
#      (the stale/wedge loop, the event/turn-end fast wake, and the context
#      sweep), so asserting it drops a supervise=off meta while keeping an
#      ordinary meta proves the hands-off-pane exclusion for all of them.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-unsupervised)
export FM_BACKEND=tmux

run_spawn() {
  FM_ROOT_OVERRIDE='' \
    FM_HOME='' \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
}

# --- parser -----------------------------------------------------------------

test_unsupervised_accepted_for_ship() {
  local out status
  # --unsupervised must not be a flag error: it should fall through to the later
  # missing-brief fast-fail, exactly like a plain ship spawn with no brief.
  out=$(run_spawn nope-unsup-a1 projects/none --unsupervised 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn with no brief should still fail"
  assert_not_contains "$out" "error: --unsupervised" "--unsupervised should be accepted for a ship spawn"
  pass "--unsupervised is accepted for a ship spawn"
}

test_unsupervised_refused_with_secondmate() {
  local out status
  out=$(run_spawn nope-unsup-a2 "$TMP_ROOT/some-home" --unsupervised --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "--unsupervised --secondmate should fail"
  assert_contains "$out" "error: --unsupervised cannot combine with --secondmate" \
    "--unsupervised --secondmate should print the contradiction error"
  pass "--unsupervised is refused with --secondmate"
}

# --- watcher exclusion ------------------------------------------------------

test_recorded_windows_drops_supervise_off() {
  local state out
  state="$TMP_ROOT/watch-state"
  mkdir -p "$state"
  # An ordinary supervised ship meta and a supervise=off (unsupervised) meta.
  fm_write_meta "$state/normal.meta" \
    "window=fm:sup-normal" \
    "worktree=$TMP_ROOT/wt-normal" \
    "project=$TMP_ROOT/proj" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  fm_write_meta "$state/griller.meta" \
    "window=fm:sup-griller" \
    "worktree=$TMP_ROOT/wt-griller" \
    "project=$TMP_ROOT/proj" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "supervise=off"

  # Source the watcher: it returns early (before the lock/loop) when sourced.
  # shellcheck source=bin/fm-watch.sh
  FM_STATE_OVERRIDE="$state" . "$WATCH"
  out=$(STATE="$state" recorded_windows)

  assert_contains "$out" "fm:sup-normal" "recorded_windows should list the supervised pane"
  assert_not_contains "$out" "fm:sup-griller" "recorded_windows must drop the supervise=off pane"
  pass "recorded_windows excludes a supervise=off pane from supervision"
}

test_unsupervised_accepted_for_ship
test_unsupervised_refused_with_secondmate
test_recorded_windows_drops_supervise_off
