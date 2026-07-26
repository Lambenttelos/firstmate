#!/usr/bin/env bash
# End-to-end test for the treehouse pool pin, driving the REAL treehouse binary
# against real git repos.
#
# The unit tests in fm-treehouse-pin.test.sh pin what the pin script writes. This
# one pins the behaviour that actually matters and that no mock can establish:
# that two clones of one remote really do share a pool and really can hand each
# other's worktrees out, and that the pin really does separate them.
#
# The reproduction is deterministic rather than incidental. Treehouse hands out a
# FREE slot, and a slot belongs forever to the clone that created it, so:
#   1. the captain's checkout acquires a slot, creating it in the shared pool;
#   2. it returns the slot, leaving it free but still bound to that clone;
#   3. the fleet clone acquires next and is handed that same, now-free slot -
#      a real, isolated worktree of the captain's object store.
# That is the incident shape. After the pin, step 3 draws from the fleet clone's
# own pool instead and can only yield a worktree of the fleet clone.
#
# HOME is redirected into the temp root for every treehouse call, because the
# default pool root is $HOME and this test must never create or disturb a pool in
# the real home directory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PIN="$ROOT/bin/fm-treehouse-pin.sh"

if ! command -v treehouse >/dev/null 2>&1; then
  echo "# skip - treehouse is not installed; the pool pin cannot be exercised end to end"
  exit 0
fi

TMP_ROOT=$(fm_test_tmproot fm-treehouse-pin-e2e)
FAKE_HOME="$TMP_ROOT/fake-home"
ORIGIN="$TMP_ROOT/origin.git"
HOME_DIR="$TMP_ROOT/home"
FLEET="$HOME_DIR/projects/demo"
CAPTAIN="$TMP_ROOT/captain-checkout/demo"

mkdir -p "$FAKE_HOME" "$HOME_DIR/projects" "$TMP_ROOT/captain-checkout"

git init --quiet --bare "$ORIGIN"
fm_git_init_commit "$FLEET"
git -C "$FLEET" remote add origin "$ORIGIN"
git -C "$FLEET" branch -M main
git -C "$FLEET" push --quiet origin main
git clone --quiet "$ORIGIN" "$CAPTAIN"

# th <clone> <treehouse args...> - run treehouse from <clone> with HOME pointed
# at the temp root, so an unpinned clone's default pool lands there too.
th() {
  local clone=$1
  shift
  ( cd "$clone" && HOME="$FAKE_HOME" treehouse "$@" 2>/dev/null )
}

# git-common-dir is the object store every worktree of one clone shares, so two
# checkouts agree here if and only if they belong to the same clone. git answers
# it relative to its -C directory for an ordinary checkout (a bare ".git"), so
# resolve it physically before comparing, exactly as bin/fm-spawn.sh does.
common_dir_of() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir) || return 1
  case "$common" in
    /*) ;;
    *) common="$dir/$common" ;;
  esac
  (cd "$common" && pwd -P)
}

fleet_git=$(common_dir_of "$FLEET")
captain_git=$(common_dir_of "$CAPTAIN")
[ "$fleet_git" != "$captain_git" ] || fail "fixture is wrong: both clones share one git directory"

# --- 1. reproduce: unpinned, the fleet clone is handed the captain's worktree --

captain_wt=$(th "$CAPTAIN" get --lease --lease-holder captain)
[ -n "$captain_wt" ] || fail "the captain's checkout could not acquire a worktree"
[ "$(common_dir_of "$captain_wt")" = "$captain_git" ] || \
  fail "fixture is wrong: the captain's slot does not belong to the captain's clone"

th "$CAPTAIN" return --force "$captain_wt" >/dev/null

fleet_wt=$(th "$FLEET" get --lease --lease-holder fleet)
[ -n "$fleet_wt" ] || fail "the fleet clone could not acquire a worktree"

if [ "$(common_dir_of "$fleet_wt")" = "$captain_git" ]; then
  pass "reproduced: unpinned, the fleet clone is handed a worktree of the captain's clone"
else
  # If treehouse ever starts tracking slot ownership, this stops reproducing.
  # Say so loudly rather than passing silently on a test that no longer tests.
  fail "the shared-pool handout did not reproduce; treehouse may have changed its slot allocation, so re-measure docs/treehouse-pools.md before trusting the pin"
fi

th "$FLEET" return --force "$fleet_wt" >/dev/null

# --- 2. fix: pinned, the fleet clone can only get its own worktree ------------

pin_out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
  "$PIN" "$FLEET" 2>&1) || fail "pinning the fleet clone failed: $pin_out"

pinned_wt=$(th "$FLEET" get --lease --lease-holder fleet-pinned)
[ -n "$pinned_wt" ] || fail "the pinned fleet clone could not acquire a worktree"

[ "$(common_dir_of "$pinned_wt")" = "$fleet_git" ] || \
  fail "the pinned fleet clone was still handed a worktree of $(common_dir_of "$pinned_wt")"
pass "pinned, the fleet clone acquires a worktree of the fleet clone"

# Treehouse echoes whichever spelling of the root it was configured with, so
# resolve both sides physically before comparing prefixes (/var vs /private/var).
real_of() { (cd "$1" && pwd -P); }

case "$(real_of "$pinned_wt")" in
  "$(real_of "$HOME_DIR")"/.treehouse/*) : ;;
  *) fail "the pinned worktree is not in this home's own pool: $pinned_wt" ;;
esac
pass "the pinned worktree comes from this home's own pool"

# The captain's checkout must be entirely unaffected: it never gets a config
# written into it, and it still draws from the default pool.
assert_absent "$CAPTAIN/treehouse.toml" "the pin wrote a config into the captain's own checkout"

captain_again=$(th "$CAPTAIN" get --lease --lease-holder captain2)
[ "$(common_dir_of "$captain_again")" = "$captain_git" ] || \
  fail "the captain's checkout was handed a worktree of another clone after the pin"
case "$(real_of "$captain_again")" in
  "$(real_of "$FAKE_HOME")"/.treehouse/*) : ;;
  *) fail "the captain's checkout stopped using the default pool: $captain_again" ;;
esac
pass "the captain's own checkout keeps its default pool, untouched by the pin"

th "$FLEET" return --force "$pinned_wt" >/dev/null
th "$CAPTAIN" return --force "$captain_again" >/dev/null

echo "# all fm-treehouse-pin-e2e tests passed"
