#!/usr/bin/env bash
# Regression test for fm-spawn.sh's duplicate-worktree assertion in
# assert_worktree_unclaimed (bin/fm-spawn.sh).
#
# Observed 2026-07-24: state/fix-charge-time-fee-config-reads.meta and
# state/prune-stale-lane-branches.meta both recorded
# worktree=/Users/cyuan/.treehouse/hyfin-847492/3/hyfin. Tearing down either task
# then inspects the SAME worktree, so one task's teardown verdict is really about
# the other task's work, and the two tasks' recorded state silently aliases.
#
# validate_spawn_worktree already proves the allocated slot is a genuine isolated
# worktree of the right clone, but not that no other task already claims it. The
# assertion these tests pin: a spawn that would record a worktree another task's
# meta already claims refuses loudly, names the other task, and records nothing;
# an unclaimed worktree still spawns normally.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-duplicate-worktree)

# make_fakebin <dir> builds a fake tmux whose `#{pane_current_path}` query
# always reports FM_FAKE_PANE_PATH, standing in for a pane that has already
# settled into whatever worktree `treehouse get` handed out.
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
# worktree of that clone (the shape validate_spawn_worktree accepts). A brief for
# <id> is staged so the spawn reaches the meta-write path.
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
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$own_wt|$fakebin"
}

read_case() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR OWN_WT FAKEBIN_DIR <<EOF
$1
EOF
}

# run_spawn <id> <pane> - the pane path stands in for the worktree treehouse
# handed out; the project is always the home's own clone.
run_spawn() {
  local id=$1 pane=$2
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$pane" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" 2>&1
}

# The incident shape: another task's meta already records this worktree. The
# second spawn must refuse, name the holder, and record no meta of its own.
test_already_claimed_worktree_is_refused() {
  local rec id other out status
  id="dup-b1"
  other="dup-a1"
  rec=$(make_case dup "$id")
  read_case "$rec"
  # Stage the other task's meta claiming the same worktree the new spawn draws.
  printf 'window=old\nworktree=%s\nproject=%s\n' "$OWN_WT" "$PROJ_DIR" \
    > "$HOME_DIR/state/$other.meta"

  out=$(run_spawn "$id" "$OWN_WT")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a worktree another task already claims: $out"
  assert_contains "$out" "already claimed by task '$other'" \
    "refusal did not name the task that already claims the worktree"
  assert_contains "$out" "$OWN_WT" "refusal did not name the contended worktree"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "a refused duplicate-worktree spawn still recorded task metadata"
  pass "a worktree another task already claims is refused, not recorded"
}

# The ordinary case: no other task claims the worktree, so the spawn records it
# and succeeds.
test_unclaimed_worktree_is_accepted() {
  local rec id out status
  id="dup-b2"
  rec=$(make_case solo "$id")
  read_case "$rec"

  out=$(run_spawn "$id" "$OWN_WT")
  status=$?
  expect_code 0 "$status" "spawn should accept an unclaimed worktree: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$OWN_WT" "$HOME_DIR/state/$id.meta" \
    "meta did not record the unclaimed worktree"
  pass "an unclaimed worktree is still accepted"
}

# A re-spawn of the SAME task reuses its own recorded worktree legitimately; the
# assertion must exclude the task's own meta, or recovery could never re-record.
test_own_meta_does_not_self_refuse() {
  local rec id out status
  id="dup-b3"
  rec=$(make_case self "$id")
  read_case "$rec"
  printf 'window=old\nworktree=%s\nproject=%s\n' "$OWN_WT" "$PROJ_DIR" \
    > "$HOME_DIR/state/$id.meta"

  out=$(run_spawn "$id" "$OWN_WT")
  status=$?
  expect_code 0 "$status" "spawn should not refuse a task's own recorded worktree: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success on self re-record"
  pass "a task's own meta does not trigger a duplicate-worktree refusal"
}

test_already_claimed_worktree_is_refused
test_unclaimed_worktree_is_accepted
test_own_meta_does_not_self_refuse

echo "# all fm-spawn-duplicate-worktree tests passed"
