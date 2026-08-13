#!/usr/bin/env bash
# Regression tests for fm-spawn.sh's pre-spawn duplicate-dispatch guard
# (bin/fm-spawn.sh, immediately after the per-task spawn lock is acquired).
#
# The build-batch-doclint-pass double-build incident spawned workers onto work
# that had already landed. The close side of that incident was fixed by PR #85;
# this guard is the dispatch side. Before committing to a spawn, fm-spawn.sh now
# refuses loudly when either:
#   1. the task id already appears in data/completions.tsv (the append-only,
#      never-pruned completion ledger), read through fm_completions_lookup, or
#   2. the task's recorded PR (state/<id>.meta pr=) is already merged to origin.
# Both are warn-and-STOP (fail closed), overridable only with the explicit
# FM_SPAWN_ALLOW_DUPLICATE=1 escape hatch. A genuinely-new task id must never be
# refused. The merged-PR probe degrades gracefully offline: an unreachable forge
# leaves the state unknown, which never refuses.
#
# These tests cover the completions-hit refusal path (the required minimum), the
# override, and the no-false-positive path for a new task id. The unit-level
# fm_completions_lookup contract is pinned separately in fm-completions.test.sh.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-duplicate-dispatch)

# shellcheck source=bin/fm-completions-lib.sh disable=SC1091
. "$ROOT/bin/fm-completions-lib.sh"

# A fake tmux/treehouse so an accepted spawn reaches the launch path without a
# real backend; a refused spawn never uses it.
make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_case <name> <id> builds a home with its own project clone and a real
# isolated worktree, and a filled brief for <id>.
make_case() {
  local name=$1 id=$2 case_dir home proj own_wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/home/projects/project"
  own_wt="$case_dir/own-wt"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$own_wt" "own-$name"
  mkdir -p "$home/data/$id"
  printf '%s\n' "# Task" "Do the real work described here." > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$own_wt|$fakebin"
}

read_case() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR OWN_WT FAKEBIN_DIR <<EOF
$1
EOF
}

# run_spawn keeps FM_SPAWN_NO_GUARD unset so the duplicate-dispatch guard runs
# (it lives on the single-task path, unaffected by that batch flag), but stubs
# the watcher and resource check through PATH so the test never touches the real
# fleet. Extra environment is passed as trailing KEY=VAL words.
run_spawn() {
  local id=$1 pane=$2; shift 2
  env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$pane" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$@" \
    "$SPAWN" "$id" "$PROJ_DIR" 2>&1
}

# A task id already present in completions.tsv is refused loudly, with the prior
# completion line as evidence, and no task metadata is recorded.
test_completions_hit_is_refused() {
  local rec id out status
  id="dup-dispatch-z1"
  rec=$(make_case hit "$id")
  read_case "$rec"
  fm_completions_record "$HOME_DIR/data" "$id" 2026-08-06 ship project deadbeef1234 \
    || fail "seeding completions ledger failed"

  out=$(run_spawn "$id" "$OWN_WT")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a task id already in completions.tsv: $out"
  assert_contains "$out" "already reached completion" "refusal did not explain the completions hit"
  assert_contains "$out" "$id" "refusal did not name the offending task id"
  assert_contains "$out" "deadbeef1234" "refusal did not print the prior completion evidence"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused duplicate spawn still recorded task metadata"
  pass "a task id already in completions.tsv is refused with the prior completion evidence"
}

# The refusal is a warn-and-STOP guard, not a hard wall: FM_SPAWN_ALLOW_DUPLICATE=1
# overrides it and the spawn proceeds to launch.
test_override_allows_respawn() {
  local rec id out status
  id="dup-dispatch-z2"
  rec=$(make_case override "$id")
  read_case "$rec"
  fm_completions_record "$HOME_DIR/data" "$id" 2026-08-06 ship project deadbeef1234 \
    || fail "seeding completions ledger failed"

  out=$(run_spawn "$id" "$OWN_WT" FM_SPAWN_ALLOW_DUPLICATE=1)
  status=$?
  expect_code 0 "$status" "override should let a duplicate spawn proceed: $out"
  assert_contains "$out" "spawned $id" "override spawn did not report success"
  pass "FM_SPAWN_ALLOW_DUPLICATE=1 overrides the duplicate-dispatch refusal"
}

# A genuinely-new task id, absent from completions.tsv, must never be refused -
# the guard must not false-positive on the ordinary path.
test_new_task_id_not_refused() {
  local rec id out status
  id="dup-dispatch-z3"
  rec=$(make_case fresh "$id")
  read_case "$rec"
  # Seed the ledger with a DIFFERENT id so the file exists but does not match.
  fm_completions_record "$HOME_DIR/data" "some-other-task" 2026-08-06 ship project abc123 \
    || fail "seeding completions ledger failed"

  out=$(run_spawn "$id" "$OWN_WT")
  status=$?
  expect_code 0 "$status" "a new task id absent from completions.tsv must not be refused: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success for a new task id"
  assert_not_contains "$out" "already reached completion" "a new task id triggered a false completions refusal"
  pass "a genuinely-new task id is not refused by the duplicate-dispatch guard"
}

test_completions_hit_is_refused
test_override_allows_respawn
test_new_task_id_not_refused

echo "# all fm-spawn-duplicate-dispatch tests passed"
