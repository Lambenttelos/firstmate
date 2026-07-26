#!/usr/bin/env bash
# Behavior tests for bin/fm-treehouse-pin.sh.
#
# Treehouse keys its worktree pool by the ORIGIN URL, not by the clone, so every
# clone of one remote on the machine shares a single pool and `treehouse get` can
# hand a spawn a slot belonging to a different clone's object store - the
# captain's own checkout of the same repo, or another firstmate home's clone. The
# pin gives each home's clone its own pool by pointing treehouse's `root` at that
# home. See docs/treehouse-pools.md for the measured pool-key derivation.
#
# What these tests pin: the pin is applied where it is safe and refused where it
# is not. It never touches a clone outside this home's projects directory (the
# captain's checkout is exactly that shape), never overwrites a treehouse.toml
# the project itself tracks, keeps its own file out of git's view, preserves
# unrelated keys, and is silent once converged so a settled fleet stays quiet.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PIN="$ROOT/bin/fm-treehouse-pin.sh"
TMP_ROOT=$(fm_test_tmproot fm-treehouse-pin)

# make_home <name> builds a home with one project clone at
# $home/projects/demo carrying an origin remote, plus a same-shaped clone OUTSIDE
# the home standing in for the captain's own checkout of the same repo.
make_home() {
  local name=$1 case_dir home clone outside
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  clone="$home/projects/demo"
  outside="$case_dir/captain-checkout"
  mkdir -p "$home/projects"
  fm_git_init_commit "$clone"
  git -C "$clone" remote add origin "git@example.com:demo/demo.git"
  fm_git_init_commit "$outside"
  git -C "$outside" remote add origin "git@example.com:demo/demo.git"
  printf '%s\n' "$case_dir|$home|$clone|$outside"
}

read_home() {
  IFS='|' read -r _ HOME_DIR CLONE OUTSIDE <<EOF
$1
EOF
}

run_pin() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    "$PIN" "$@" 2>&1
}

home_real() { (cd "$HOME_DIR" && pwd -P); }

test_pin_points_the_pool_at_this_home() {
  local rec out status
  rec=$(make_home basic); read_home "$rec"

  out=$(run_pin "$CLONE"); status=$?
  expect_code 0 "$status" "pin should succeed on this home's own clone: $out"
  assert_contains "$out" "pinned" "pin did not report that it changed the clone"
  assert_grep "root = \"$(home_real)\"" "$CLONE/treehouse.toml" \
    "treehouse.toml did not point the pool root at this home"
  pass "the pin points the clone's worktree pool at this home"
}

# The pin must be invisible to git: it is firstmate's local operating config, not
# a change to the project. A dirty clone would otherwise show up in every status
# read and could ride along in a commit.
test_pin_is_invisible_to_git() {
  local rec status_out
  rec=$(make_home invisible); read_home "$rec"
  run_pin "$CLONE" >/dev/null

  assert_grep "/treehouse.toml" "$CLONE/.git/info/exclude" \
    "the pin was not added to the clone's info/exclude"
  status_out=$(git -C "$CLONE" status --porcelain)
  [ -z "$status_out" ] || fail "the pin left the clone dirty: $status_out"
  pass "the pin leaves the clone clean and stays out of git's view"
}

# A settled fleet re-runs this on every sync, so a converged clone must produce
# no output at all; otherwise session start grows a permanent noise line.
test_pin_is_idempotent_and_silent_once_converged() {
  local rec first second
  rec=$(make_home idempotent); read_home "$rec"

  first=$(run_pin "$CLONE")
  assert_contains "$first" "pinned" "first pin did not report a change"
  second=$(run_pin "$CLONE")
  [ -z "$second" ] || fail "a converged clone still reported a change: $second"
  pass "re-pinning a converged clone changes nothing and says nothing"
}

# The pin owns only the `root` key. Anything else in an untracked treehouse.toml
# is the operator's and must survive.
test_pin_preserves_other_keys_and_replaces_a_stale_root() {
  local rec
  rec=$(make_home preserve); read_home "$rec"
  printf 'max_trees = 4\nroot = "/somewhere/stale"\n' > "$CLONE/treehouse.toml"

  run_pin "$CLONE" >/dev/null
  assert_grep "max_trees = 4" "$CLONE/treehouse.toml" "the pin dropped an unrelated key"
  assert_grep "root = \"$(home_real)\"" "$CLONE/treehouse.toml" "the pin did not replace the stale root"
  assert_no_grep "/somewhere/stale" "$CLONE/treehouse.toml" "the stale root survived the pin"
  pass "the pin replaces a stale root and preserves unrelated keys"
}

# Treehouse's config is flat, so a top-level key written after a table header
# would belong to that table and be ignored, leaving the pin silently ineffective.
# `root` must therefore lead the file, ahead of every preserved line.
test_pin_writes_root_ahead_of_a_table_header() {
  local rec root_line header_line
  rec=$(make_home tableheader); read_home "$rec"
  printf 'max_trees = 4\n[pool]\nroot = "/somewhere/stale"\n' > "$CLONE/treehouse.toml"

  run_pin "$CLONE" >/dev/null
  assert_grep "root = \"$(home_real)\"" "$CLONE/treehouse.toml" "the pin did not write this home's root"
  assert_no_grep "/somewhere/stale" "$CLONE/treehouse.toml" "the stale root under a table survived the pin"
  assert_grep "max_trees = 4" "$CLONE/treehouse.toml" "the pin dropped an unrelated key"
  assert_grep "[pool]" "$CLONE/treehouse.toml" "the pin dropped a preserved table header"
  root_line=$(grep -n '^root = ' "$CLONE/treehouse.toml" | head -1 | cut -d: -f1)
  header_line=$(grep -n '^\[pool\]' "$CLONE/treehouse.toml" | head -1 | cut -d: -f1)
  [ "$root_line" = 1 ] || fail "root is not the first line of the pinned treehouse.toml (line $root_line)"
  [ "$root_line" -lt "$header_line" ] || fail "root was written inside the [pool] table instead of at top level"
  pass "the pin writes root at top level ahead of an existing table header"
}

# The safety boundary. A clone outside this home's projects directory is not
# firstmate's to modify - the captain's own checkout of the same repo is exactly
# that shape, and writing into it would be a project write with no mandate.
test_pin_refuses_a_clone_outside_this_home() {
  local rec out status
  rec=$(make_home outside); read_home "$rec"

  out=$(run_pin "$OUTSIDE"); status=$?
  [ "$status" -eq 0 ] && fail "pin accepted a clone outside this home: $out"
  assert_contains "$out" "not a project clone of this home" \
    "refusal did not explain that the clone is not this home's"
  assert_absent "$OUTSIDE/treehouse.toml" "pin wrote into a clone outside this home"
  pass "a clone outside this home's projects directory is refused, not written"
}

# A treehouse.toml the project tracks belongs to the project. Refuse rather than
# overwrite a file the repo itself owns.
test_pin_refuses_a_tracked_treehouse_toml() {
  local rec out status before
  rec=$(make_home tracked); read_home "$rec"
  printf 'max_trees = 2\n' > "$CLONE/treehouse.toml"
  git -C "$CLONE" add treehouse.toml
  git -C "$CLONE" -c user.email=t@example.com -c user.name=t commit -qm "project owns its pool config"
  before=$(cat "$CLONE/treehouse.toml")

  out=$(run_pin "$CLONE"); status=$?
  [ "$status" -eq 0 ] && fail "pin overwrote a treehouse.toml the project tracks: $out"
  assert_contains "$out" "tracked by the project" \
    "refusal did not explain that the project tracks its own treehouse.toml"
  [ "$(cat "$CLONE/treehouse.toml")" = "$before" ] || fail "pin modified a tracked treehouse.toml"
  pass "a treehouse.toml the project tracks is refused, not overwritten"
}

# No origin means no pool key, so treehouse never pools the clone and there is
# nothing to pin. That is a supported project shape, not a failure.
test_pin_skips_a_clone_with_no_origin() {
  local rec out status
  rec=$(make_home noorigin); read_home "$rec"
  git -C "$CLONE" remote remove origin

  out=$(run_pin "$CLONE"); status=$?
  expect_code 0 "$status" "pin should skip a clone with no origin rather than fail: $out"
  [ -z "$out" ] || fail "pin was not silent on a clone with no origin: $out"
  assert_absent "$CLONE/treehouse.toml" "pin wrote a pool config for a clone with no origin"
  pass "a clone with no origin is skipped quietly"
}

test_pin_refuses_a_missing_directory() {
  local rec out status
  rec=$(make_home missing); read_home "$rec"

  out=$(run_pin "$HOME_DIR/projects/absent"); status=$?
  [ "$status" -eq 0 ] && fail "pin accepted a directory that does not exist: $out"
  assert_contains "$out" "no such clone directory" "refusal did not name the missing directory"
  pass "a missing clone directory is refused"
}

test_pin_points_the_pool_at_this_home
test_pin_is_invisible_to_git
test_pin_is_idempotent_and_silent_once_converged
test_pin_preserves_other_keys_and_replaces_a_stale_root
test_pin_writes_root_ahead_of_a_table_header
test_pin_refuses_a_clone_outside_this_home
test_pin_refuses_a_tracked_treehouse_toml
test_pin_skips_a_clone_with_no_origin
test_pin_refuses_a_missing_directory

echo "# all fm-treehouse-pin tests passed"
