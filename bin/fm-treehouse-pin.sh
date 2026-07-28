#!/usr/bin/env bash
# fm-treehouse-pin.sh - pin one project clone's treehouse worktree pool to this
# firstmate home, so a spawn can never be handed a worktree of another clone.
#
# WHY THIS EXISTS
# Treehouse names its pool directory "<repo-basename>-<sha256(origin-url)[0:6]>"
# under "<root>/.treehouse/", and the default root is $HOME. The pool key is the
# ORIGIN URL, so it is remote-scoped, not clone-scoped: every clone of one remote
# on the machine shares a single pool, and `treehouse get` hands out whichever
# slot is free regardless of which clone created it. Two clones of one remote -
# this home's projects/<name> and the captain's own checkout of the same repo, or
# a secondmate home's clone of it - therefore draw from the same pool. A slot
# created from the captain's checkout is a real, isolated worktree of the
# CAPTAIN'S object store: a crewmate handed that slot commits where the home that
# dispatched it cannot see the branch, and every repo-scoped tool it runs
# (no-mistakes among them) resolves the wrong repo.
# See docs/treehouse-pools.md for the measured evidence behind each of those
# statements, including the pool-key derivation and the migration behaviour.
#
# WHAT IT DOES
# Writes a treehouse.toml at the clone's repo root setting `root` to this home's
# physical path, so the clone's pool becomes "$FM_HOME/.treehouse/..." instead of
# "$HOME/.treehouse/...". Each firstmate home holds at most one clone per remote,
# so a home-scoped root is a per-clone pool, and the captain's own checkouts keep
# using the default $HOME pool untouched.
#
# Writing into a project clone is a project write, permitted here only because
# this script runs from the guarded project-initialization and fleet-sync paths
# AGENTS.md section 1 names as exceptions. It stays inside those bounds:
#   - it refuses any clone that is not a direct child of this home's projects dir,
#     so it can never touch the captain's own checkout;
#   - it refuses a repo whose treehouse.toml is TRACKED, rather than modifying a
#     file the project itself owns;
#   - it preserves every other key already in an untracked treehouse.toml;
#   - it adds treehouse.toml to .git/info/exclude, so the pin is invisible to
#     git status, never rides along in a commit, and never blocks a dirty check.
# It changes no tracked file, no branch, and no commit.
#
# Already-open worktrees in the old pool keep working: `treehouse return --force
# <absolute-path>` locates the pool that actually contains the path and releases
# the slot there, so teardown of a task allocated before the pin still succeeds
# (measured; see docs/treehouse-pools.md "Migration").
#
# Usage: fm-treehouse-pin.sh <clone-dir>
# Prints "pinned <clone-dir>" when it changed something and nothing when the
# clone is already converged, so callers can stay quiet on a no-op. Exits
# non-zero with an explanation on stderr when the pin cannot be applied safely.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

CLONE=${1:?usage: fm-treehouse-pin.sh <clone-dir>}

# Physical paths throughout: a symlinked prefix (macOS /tmp -> /private/tmp, or a
# home reached through a symlink) would otherwise make the containment check below
# compare two spellings of the same directory and refuse a legitimate clone.
clone_real=$(cd "$CLONE" 2>/dev/null && pwd -P) || {
  echo "error: no such clone directory: $CLONE" >&2
  exit 1
}
projects_real=$(cd "$PROJECTS" 2>/dev/null && pwd -P) || {
  echo "error: this home has no projects directory at $PROJECTS" >&2
  exit 1
}
home_real=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || {
  echo "error: cannot resolve firstmate home $FM_HOME" >&2
  exit 1
}

# Containment is the safety boundary: only a direct child of this home's projects
# directory may be pinned. This is what keeps the script off the captain's own
# checkouts, off another home's clones, and off arbitrary paths a caller passes.
if [ "$(dirname "$clone_real")" != "$projects_real" ]; then
  echo "error: refusing to pin $clone_real: not a project clone of this home ($projects_real)" >&2
  exit 1
fi

if ! git -C "$clone_real" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: refusing to pin $clone_real: not a git work tree" >&2
  exit 1
fi

# A clone with no origin has no pool key, so treehouse never pools it and there is
# nothing to pin. Not an error - local-only projects are a supported shape.
git -C "$clone_real" remote get-url origin >/dev/null 2>&1 || exit 0

TOML="$clone_real/treehouse.toml"

# A treehouse.toml the project itself tracks belongs to the project, not to
# firstmate. Refuse rather than overwrite it; the captain can decide what the
# project's own pool policy should be.
if git -C "$clone_real" ls-files --error-unmatch treehouse.toml >/dev/null 2>&1; then
  echo "error: refusing to pin $clone_real: treehouse.toml is tracked by the project" >&2
  exit 1
fi

# TOML basic strings take backslash escapes, so escape backslash before quote.
escaped=${home_real//\\/\\\\}
escaped=${escaped//\"/\\\"}
want_root="root = \"$escaped\""

changed=no

# Preserve every key the file already carries except `root`, which this script
# owns. A hand-added max_trees, for example, survives re-pinning.
# `root` is written FIRST: treehouse's config is flat, so a top-level key placed
# after a table header such as [pool] would belong to that table and be ignored,
# making the pin silently ineffective. Writing it ahead of every preserved line
# also fixes a pre-existing root that sat under a table header.
new_toml=$(
  printf '%s\n' "$want_root"
  if [ -f "$TOML" ]; then
    grep -v '^[[:space:]]*root[[:space:]]*=' "$TOML" || true
  fi
)

if [ ! -f "$TOML" ] || [ "$(cat "$TOML")" != "$new_toml" ]; then
  tmp="$TOML.fm-tmp.$$"
  printf '%s\n' "$new_toml" > "$tmp"
  mv -f "$tmp" "$TOML"
  changed=yes
fi

# Keep the pin out of git's view: never dirty, never committed, never a teardown
# blocker. info/exclude is per-clone and untracked, so this adds nothing to the
# project's own ignore rules.
EXCLUDE=$(git -C "$clone_real" rev-parse --git-path info/exclude 2>/dev/null || true)
if [ -n "$EXCLUDE" ]; then
  case "$EXCLUDE" in
    /*) ;;
    *) EXCLUDE="$clone_real/$EXCLUDE" ;;
  esac
  mkdir -p "$(dirname "$EXCLUDE")"
  if ! grep -qxF '/treehouse.toml' "$EXCLUDE" 2>/dev/null; then
    printf '/treehouse.toml\n' >> "$EXCLUDE"
    changed=yes
  fi
fi

if [ "$changed" = yes ]; then
  echo "pinned $clone_real"
fi
exit 0
