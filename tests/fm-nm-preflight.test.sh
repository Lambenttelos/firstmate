#!/usr/bin/env bash
# Regression test for bin/fm-nm-preflight.sh.
#
# no-mistakes serializes runs per repo+branch, never per repo, so a run in
# flight on ANOTHER branch cannot be attached to, answered, or aborted from
# here: `axi run`, `axi respond`, and `axi abort` all resolve through a
# branch-scoped active-run lookup. Only `axi status` and `axi logs` fall back
# repo-wide, and only for display. These tests pin that an unrelated in-flight
# run is ALLOWED and loudly annotated, that every allow carries the drive-by-id
# instruction that makes the display fallback harmless, and that the two real
# refusals - a detached HEAD and a worktree from another copy of the repo -
# still stand.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PREFLIGHT="$ROOT/bin/fm-nm-preflight.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-preflight)

# make_nm <dir> <branch> <status> [id] installs a fake `no-mistakes` whose
# `axi status` prints the TOON block the real binary prints for that run. An
# empty <branch> stands in for a repo with no run at all.
make_nm() {
  local dir=$1 branch=$2 status=$3 id=${4:-01TESTRUNTESTRUNTESTRUN} fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
set -u
[ "\${1:-}" = axi ] || exit 0
[ "\${2:-}" = status ] || exit 0
if [ -z "$branch" ]; then
  exit 0
fi
cat <<'TOON'
run:
  id: "$id"
  branch: $branch
  status: $status
  head: 0d70dc68
outcome: $status
TOON
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

# make_repo <name> <branch> builds a clone with a worktree checked out on
# <branch>, and echoes "<clone>|<worktree>".
make_repo() {
  local name=$1 branch=$2 case_dir clone wt
  case_dir="$TMP_ROOT/$name"
  clone="$case_dir/clone"
  wt="$case_dir/wt"
  fm_git_worktree "$clone" "$wt" "$branch"
  printf '%s|%s\n' "$clone" "$wt"
}

run_preflight() {  # <worktree> <fakebin> [args...]
  local wt=$1 fakebin=$2
  shift 2
  (cd "$wt" && PATH="$fakebin:$PATH" "$PREFLIGHT" "$@" 2>&1)
}

# A run in flight on an unrelated branch does not block this lane: nothing this
# lane can invoke resolves to it. The allow must still name it, so the lane
# knows the run a bare `axi status` shows is not its own.
test_inflight_run_on_other_branch_is_allowed_and_named() {
  local clone wt fakebin out status
  IFS='|' read -r clone wt <<<"$(make_repo inflight fm/mine)"
  fakebin=$(make_nm "$TMP_ROOT/inflight" fm/theirs running 01KY7N2XXAG28JB6H838K5XJSS)

  out=$(run_preflight "$wt" "$fakebin")
  status=$?
  expect_code 0 "$status" "preflight refused a lane merely because another branch had a run in flight: $out"
  assert_contains "$out" "ok:" "allow did not print the ok line"
  assert_contains "$out" "fm/mine" "allow did not name the branch being validated"
  assert_contains "$out" "fm/theirs" "allow did not name the branch of the unrelated run"
  assert_contains "$out" "01KY7N2XXAG28JB6H838K5XJSS" "allow did not name the unrelated run id"
  assert_contains "$out" "not yours" "allow did not warn that the unrelated run belongs to another lane"
  : "$clone"
  pass "an in-flight run on another branch is allowed and named as another lane's"
}

# A parked or unrecognized state on another branch is the same case: parked or
# not, a branch-scoped lookup from here cannot reach it.
test_unknown_state_on_other_branch_is_allowed() {
  local clone wt fakebin out status
  IFS='|' read -r clone wt <<<"$(make_repo unknown-state fm/mine)"
  fakebin=$(make_nm "$TMP_ROOT/unknown-state" fm/theirs awaiting_approval)

  out=$(run_preflight "$wt" "$fakebin")
  status=$?
  expect_code 0 "$status" "preflight refused a lane because another branch's run was parked: $out"
  assert_contains "$out" "awaiting_approval" "allow did not report the unrelated run's state"
  assert_contains "$out" "not yours" "allow did not warn that the parked run belongs to another lane"
  : "$clone"
  pass "a parked run on another branch is allowed and flagged as another lane's"
}

# The display fallback is what made the old guard necessary: with no run row for
# this branch, `axi status` answers with whatever run the repo has. Driving by
# explicit run id bypasses that resolution entirely, so every allow must carry
# the instruction - not just the ones that saw another lane's run.
test_every_allow_carries_the_drive_by_id_instruction() {
  local clone wt fakebin out status
  IFS='|' read -r clone wt <<<"$(make_repo driveby fm/mine)"

  for fakebin in \
    "$(make_nm "$TMP_ROOT/driveby-other" fm/theirs running)" \
    "$(make_nm "$TMP_ROOT/driveby-own" fm/mine running)" \
    "$(make_nm "$TMP_ROOT/driveby-none" "" "")"; do
    out=$(run_preflight "$wt" "$fakebin")
    status=$?
    expect_code 0 "$status" "preflight refused an allowed shape: $out"
    assert_contains "$out" "--run" "allow did not instruct the lane to drive its run by id"
  done
  : "$clone"
  pass "every allow tells the lane to drive its own run by explicit id"
}

# Legitimate resume: re-running on the branch that owns the run is the
# documented way to re-validate after adding fix commits, and must stay allowed.
test_run_on_same_branch_is_allowed() {
  local clone wt fakebin out status
  IFS='|' read -r clone wt <<<"$(make_repo same-branch fm/mine)"
  fakebin=$(make_nm "$TMP_ROOT/same-branch" fm/mine running)

  out=$(run_preflight "$wt" "$fakebin")
  status=$?
  expect_code 0 "$status" "preflight refused a resume of this branch's own run: $out"
  assert_contains "$out" "ok:" "allow did not print the ok line"
  : "$clone"
  pass "an in-flight run on the invoking branch is still allowed to resume"
}

# Every repo keeps its last run around; a finished one on another branch is the
# ordinary steady state and must not block anybody.
test_finished_run_on_other_branch_is_allowed() {
  local clone wt fakebin out status state
  IFS='|' read -r clone wt <<<"$(make_repo finished fm/mine)"
  for state in completed failed cancelled; do
    fakebin=$(make_nm "$TMP_ROOT/finished-$state" fm/theirs "$state")
    out=$(run_preflight "$wt" "$fakebin")
    status=$?
    expect_code 0 "$status" "preflight refused a $state run on another branch: $out"
    assert_contains "$out" "$state" "allow line did not report the finished run's state"
  done
  : "$clone"
  pass "a completed, failed, or cancelled run on another branch does not block a new one"
}

# No run at all is trivially clear.
test_no_existing_run_is_allowed() {
  local clone wt fakebin out status
  IFS='|' read -r clone wt <<<"$(make_repo norun fm/mine)"
  fakebin=$(make_nm "$TMP_ROOT/norun" "" "")

  out=$(run_preflight "$wt" "$fakebin")
  status=$?
  expect_code 0 "$status" "preflight refused a repo with no existing run: $out"
  assert_contains "$out" "no existing run" "allow line did not explain there was no run"
  : "$clone"
  pass "a repo with no existing run is clear to validate"
}

# --project is the crew-side re-assertion of the launch-time clone check: a
# worktree that belongs to another copy of the repo is refused before the
# pipeline can resolve into it.
test_foreign_clone_worktree_is_refused() {
  local clone wt other_clone other_wt fakebin out status
  IFS='|' read -r clone wt <<<"$(make_repo foreign fm/mine)"
  IFS='|' read -r other_clone other_wt <<<"$(make_repo foreign-other fm/other)"
  fakebin=$(make_nm "$TMP_ROOT/foreign" "" "")

  out=$(run_preflight "$wt" "$fakebin" --project "$other_clone")
  status=$?
  [ "$status" -eq 1 ] || fail "preflight allowed a worktree of a different copy of the repo (exit $status): $out"
  assert_contains "$out" "different copy" "refusal did not explain the worktree belongs to another copy"
  : "$other_wt"
  pass "a worktree belonging to another copy of the repo is refused"

  out=$(run_preflight "$wt" "$fakebin" --project "$clone")
  status=$?
  expect_code 0 "$status" "preflight refused a worktree of its own project clone: $out"
  pass "a worktree of the expected project clone passes the same check"
}

# The guard exists to stop an attach; with no pipeline reachable there is
# nothing to attach to, so a missing binary is not a refusal.
test_missing_no_mistakes_is_not_a_refusal() {
  local clone wt fakebin out status
  IFS='|' read -r clone wt <<<"$(make_repo nonm fm/mine)"
  fakebin=$(fm_fakebin "$TMP_ROOT/nonm-empty")

  out=$(cd "$wt" && PATH="$fakebin:$PATH" FM_NM_BIN=fm-nm-absent-on-purpose "$PREFLIGHT" 2>&1)
  status=$?
  expect_code 0 "$status" "preflight refused merely because no-mistakes was unavailable: $out"
  assert_contains "$out" "ok:" "allow did not print the ok line"
  : "$clone"
  pass "an unreachable no-mistakes is not treated as a refusal"
}

# A detached HEAD has no branch for no-mistakes to validate, so the guard must
# stop before the branch comparison it cannot make.
test_detached_head_is_refused() {
  local clone wt fakebin out status
  IFS='|' read -r clone wt <<<"$(make_repo detached fm/mine)"
  git -C "$wt" checkout --quiet --detach
  fakebin=$(make_nm "$TMP_ROOT/detached" "" "")

  out=$(run_preflight "$wt" "$fakebin")
  status=$?
  [ "$status" -eq 1 ] || fail "preflight allowed a detached HEAD (exit $status): $out"
  assert_contains "$out" "detached" "refusal did not explain the detached HEAD"
  : "$clone"
  pass "a detached HEAD is refused before any run comparison"
}

test_inflight_run_on_other_branch_is_allowed_and_named
test_unknown_state_on_other_branch_is_allowed
test_every_allow_carries_the_drive_by_id_instruction
test_run_on_same_branch_is_allowed
test_finished_run_on_other_branch_is_allowed
test_no_existing_run_is_allowed
test_foreign_clone_worktree_is_refused
test_missing_no_mistakes_is_not_a_refusal
test_detached_head_is_refused

echo "# all fm-nm-preflight tests passed"
