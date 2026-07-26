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
# The second clone stands in for another copy of the same repo sharing the same
# treehouse pool - another firstmate home's clone, or the captain's own checkout.
#
# The home's own clone lives at $home/projects/<name>, the shape the registry
# defines and the shape fm-spawn now requires; the foreign clone deliberately
# sits outside that directory, because "a clone this home does not own" is
# exactly what the containment assertion has to reject.
make_case() {
  local name=$1 id=$2 case_dir home proj own_wt foreign foreign_wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/home/projects/project"
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
  IFS='|' read -r _ HOME_DIR PROJ_DIR OWN_WT FOREIGN_DIR FOREIGN_WT FAKEBIN_DIR <<EOF
$1
EOF
}

# run_spawn <id> <pane> [<project-arg>] - the project argument defaults to the
# home's own clone; the bypass tests pass their own to stand in for a caller that
# names a clone this home does not own.
run_spawn() {
  local id=$1 pane=$2 project=${3:-$PROJ_DIR}
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$pane" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$project" 2>&1
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

# The bypass: the clone comparison above is RELATIVE - it only proves the
# worktree and the project agree. Name a clone this home does not own AS the
# project and treehouse allocates a slot of that same clone, so both sides match
# and the comparison is satisfied while the crew works in a foreign object store.
# This is the shape that let real fleet branches land in another clone's store
# even after the clone comparison shipped, so it gets a test that tries the
# bypass directly rather than trusting the comparison to imply it.
test_foreign_clone_as_the_project_is_refused() {
  local rec id out status
  id="foreign-project-z3"
  rec=$(make_case bypass "$id")
  read_case "$rec"

  # Pane path and project are the SAME foreign clone: self-consistent, so the
  # clone-identity comparison alone would pass this launch.
  out=$(run_spawn "$id" "$FOREIGN_WT" "$FOREIGN_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a foreign clone as its project: $out"
  assert_contains "$out" "not one of this home's project clones" \
    "refusal did not explain that the project is not one of this home's clones"
  # The refusal names the PHYSICALLY resolved projects dir (/private/... on
  # macOS), so match the fixture's directory suffix rather than the raw path.
  assert_contains "$out" "/home/projects" "refusal did not name this home's projects directory"
  assert_contains "$out" "/foreign-clone" "refusal did not name the clone it refused"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused foreign-clone project still recorded task metadata"
  pass "a clone this home does not own is refused as a project"
}

# Same bypass reached by path traversal instead of an absolute path: the
# "projects/" prefix is rewritten against this home's projects dir, so a caller
# can try to climb back out of it. The check resolves physically before comparing,
# so the climb does not survive.
test_traversal_out_of_projects_is_refused() {
  local rec id out status
  id="traversal-z4"
  rec=$(make_case traversal "$id")
  read_case "$rec"

  out=$(run_spawn "$id" "$FOREIGN_WT" "projects/../../foreign-clone")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a path that climbed out of the projects dir: $out"
  assert_contains "$out" "not one of this home's project clones" \
    "refusal did not explain that the traversed path leaves this home's clones"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused traversal path still recorded task metadata"
  pass "a path that climbs out of the projects dir is refused"
}

# A nested path INSIDE the projects dir is still not a project clone: only a
# direct child is, so a subdirectory of a clone cannot stand in for it.
test_subdirectory_of_a_clone_is_refused() {
  local rec id out status sub
  id="subdir-z5"
  rec=$(make_case subdir "$id")
  read_case "$rec"
  sub="$PROJ_DIR/nested"
  mkdir -p "$sub"

  out=$(run_spawn "$id" "$OWN_WT" "$sub")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a subdirectory of a clone as its project: $out"
  assert_contains "$out" "not one of this home's project clones" \
    "refusal did not explain that a nested path is not a project clone"
  pass "a subdirectory inside a clone is refused as a project"
}

test_foreign_clone_worktree_is_refused
test_own_clone_worktree_is_accepted
test_foreign_clone_as_the_project_is_refused
test_traversal_out_of_projects_is_refused
test_subdirectory_of_a_clone_is_refused

echo "# all fm-spawn-foreign-clone tests passed"
