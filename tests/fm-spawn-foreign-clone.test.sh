#!/usr/bin/env bash
# Regression test for fm-spawn.sh's clone-identity assertion in
# validate_spawn_worktree (bin/fm-spawn.sh).
#
# A treehouse pool can be shared by TWO SEPARATE clones of the same repo - for
# example a main home's projects/<name> and a secondmate home's projects/<name>
# - with separate object stores. `treehouse get` then hands a slot back that is
# a perfectly real, perfectly isolated worktree of the WRONG clone. The
# pre-existing isolation check only proved the worktree was a real git
# worktree root distinct from the primary checkout, which such a slot satisfies,
# so the spawn recorded it and the crew worked in another home's clone. Its
# branch was invisible to the home that dispatched it, and every repo-scoped
# tool it ran (no-mistakes among them) resolved to that foreign clone.
#
# The assertion these tests pin: the allocated worktree's git-common-dir must
# resolve to the project clone's own git-common-dir, and a mismatch must refuse
# the launch loudly instead of recording a foreign-clone worktree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-foreign-clone)

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

# make_case <name> <id> builds a home, the home's own project clone with a real
# worktree, and a SEPARATE clone of the same shape with its own real worktree.
# The second clone stands in for another firstmate home's copy of the same repo
# sharing the same treehouse pool.
make_case() {
  local name=$1 id=$2 case_dir home proj own_wt foreign foreign_wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  own_wt="$case_dir/own-wt"
  foreign="$case_dir/foreign-clone"
  foreign_wt="$case_dir/foreign-wt"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$own_wt" "own-$name"
  fm_git_worktree "$foreign" "$foreign_wt" "foreign-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$own_wt|$foreign|$foreign_wt|$fakebin"
}

read_case() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR OWN_WT _ FOREIGN_WT FAKEBIN_DIR <<EOF
$1
EOF
}

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

# The incident shape: a real, isolated worktree that belongs to a DIFFERENT
# clone of the same repo. It passes every "is this a distinct real worktree"
# test, so only a clone-identity comparison can catch it.
test_foreign_clone_worktree_is_refused() {
  local rec id out status
  id="foreign-clone-z1"
  rec=$(make_case foreign "$id")
  read_case "$rec"

  out=$(run_spawn "$id" "$FOREIGN_WT")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a worktree belonging to a foreign clone: $out"
  assert_contains "$out" "different clone" "refusal did not explain that the worktree belongs to another clone"
  assert_contains "$out" "$FOREIGN_WT" "refusal did not name the foreign worktree"
  # Both owning clones are named by their shared git directory, which resolves
  # physically (/private/... on macOS), so match on the fixture directory names
  # rather than the pre-resolution paths.
  assert_contains "$out" "/foreign-clone/" "refusal did not name the clone the worktree actually belongs to"
  assert_contains "$out" "/project/" "refusal did not name the project clone it should have belonged to"
  [ -f "$HOME_DIR/state/$id.meta" ] && \
    assert_no_grep "worktree=$FOREIGN_WT" "$HOME_DIR/state/$id.meta" \
      "meta recorded the foreign-clone worktree despite the refusal"
  pass "a real worktree of a foreign clone is refused, not recorded"
}

# The legitimate case must keep working: a worktree of the project's OWN clone
# is still a normal, accepted spawn.
test_own_clone_worktree_is_accepted() {
  local rec id out status
  id="own-clone-z2"
  rec=$(make_case own "$id")
  read_case "$rec"

  out=$(run_spawn "$id" "$OWN_WT")
  status=$?
  expect_code 0 "$status" "spawn should accept a worktree of the project's own clone: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$OWN_WT" "$HOME_DIR/state/$id.meta" \
    "meta did not record the project's own worktree"
  pass "a worktree of the project's own clone is still accepted"
}

test_foreign_clone_worktree_is_refused
test_own_clone_worktree_is_accepted

echo "# all fm-spawn-foreign-clone tests passed"
