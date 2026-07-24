#!/usr/bin/env bash
# Clear a lane to run no-mistakes, and tell it how to drive its own run.
#
# no-mistakes serializes pipeline runs per repo+branch, NOT per repo. Nothing a
# lane invokes can reach a run on another branch:
#
#   axi run     internal/cli/axi_drive.go activeRunID -> GetActiveRun(repo, BRANCH),
#               and it attaches only when the run's head SHA also matches, so a
#               different branch always starts a fresh run
#   axi respond internal/cli/axi_drive.go runAxiRespond -> same branch-scoped lookup;
#               from another branch it answers "no active run to respond to"
#   axi abort   internal/cli/axi_drive.go runAxiAbort -> same branch-scoped lookup
#   daemon      internal/daemon/manager.go startRun locks repoID+"/"+branch and
#               cancelActiveRuns skips runs whose branch differs, so two branches
#               of one repo validate concurrently by design
#
# The ONE repo-wide surface is display: internal/cli/axi_query.go resolveRun
# falls back to the repo's newest active run when the invoking branch has no run
# row of its own. That fallback is why a bare `axi status` in a lane whose branch
# has never been validated shows ANOTHER lane's run - the observation behind
# data/learnings.md anchor `no-mistakes-wrong-repo-attach`, which read as an
# attach but was the display fallback. Verified against no-mistakes v1.34.0 (the
# installed line) and HEAD; the resolution code is identical in both.
#
# So this guard does not refuse an unrelated in-flight run - refusing it queued
# every finished lane behind one run per repo for no safety gain. It instead:
#
#   - names the unrelated run so a lane never mistakes it for its own, and
#   - tells every lane to drive its run by explicit id (`--run <id>`), which
#     bypasses resolveRun entirely and makes the display fallback harmless.
#
# What it still refuses is what is genuinely unsafe: a detached HEAD (no branch
# to validate) and a worktree belonging to another copy of the repo. The latter
# is the real defect behind the 2026-07-23 incident - bin/fm-spawn.sh asserts
# clone identity at launch, and --project re-asserts it here so a checkout that
# moved after launch is still caught before it validates into the wrong copy.
#
# A run on the CURRENT branch is a legitimate resume - the documented way to
# re-validate after adding fix commits - and is always allowed.
#
# Usage:
#   fm-nm-preflight.sh [--project <clone-path>]
#
# Runs against the current directory's git worktree.
# --project <clone-path> additionally requires that worktree to belong to the
# same clone as <clone-path>, compared by shared git directory.
#
# Exit contract:
#   0  clear to run; prints one `ok:` line naming the branch and owning clone,
#      a `note:` line with the drive-by-id instruction, and - when the repo has
#      an unrelated run in flight - a `warning:` line naming it.
#   1  refused; the reason is on stderr and no-mistakes must not be invoked.
#   2  usage error.
#
# Not being able to reach no-mistakes is not a refusal: with no pipeline there is
# nothing to validate against.
set -u

PROJECT=""

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)
      [ "$#" -gt 1 ] || { echo "error: --project requires a value" >&2; exit 2; }
      PROJECT=$2
      shift 2
      ;;
    --project=*)
      PROJECT=${1#--project=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

command -v git >/dev/null 2>&1 || { echo "error: git not found; cannot establish the invoking worktree" >&2; exit 1; }

WT_TOP=$(git rev-parse --show-toplevel 2>/dev/null) || WT_TOP=
[ -n "$WT_TOP" ] || { echo "error: not inside a git worktree; run this from the task worktree" >&2; exit 1; }

# Physical path of a checkout's shared git directory: the object store every
# worktree of one clone shares, and therefore the identity of the clone itself.
# `rev-parse --git-common-dir` may answer relative to its -C directory, and
# older git has no --path-format=absolute, so resolve it here.
git_common_dir_real() {  # <dir>
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  case "$common" in
    /*) ;;
    *) common="$dir/$common" ;;
  esac
  (cd "$common" 2>/dev/null && pwd -P) || return 1
}

OWNING_CLONE=$(git_common_dir_real "$WT_TOP" || true)
[ -n "$OWNING_CLONE" ] || { echo "error: cannot establish which clone '$WT_TOP' belongs to; refusing rather than validating into an unknown copy" >&2; exit 1; }

if [ -n "$PROJECT" ]; then
  EXPECTED_CLONE=$(git_common_dir_real "$PROJECT" || true)
  if [ -z "$EXPECTED_CLONE" ]; then
    echo "error: --project '$PROJECT' is not a git checkout; cannot confirm this worktree belongs to the intended copy" >&2
    exit 1
  fi
  if [ "$OWNING_CLONE" != "$EXPECTED_CLONE" ]; then
    echo "error: this worktree belongs to a different copy of the repo (worktree '$WT_TOP' belongs to '$OWNING_CLONE'; expected '$EXPECTED_CLONE'); refusing so the pipeline cannot validate into another copy" >&2
    exit 1
  fi
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || BRANCH=
if [ -z "$BRANCH" ] || [ "$BRANCH" = HEAD ]; then
  echo "error: HEAD is detached in '$WT_TOP'; check out the task branch before validating" >&2
  exit 1
fi

# The instruction that replaces the old refusal. `axi status` and `axi logs`
# resolve repo-wide when this branch has no run row of its own, so a lane that
# reads them bare can be handed another lane's run. Passing the run id skips
# that resolution (internal/cli/axi_query.go resolveRun returns early on an
# explicit id), which is what makes concurrent lanes safe to read as well as to
# start. `axi run` prints the id it started.
# shellcheck disable=SC2016  # backticks are literal command quoting in the message, not expansions
DRIVE_BY_ID_NOTE='note: drive YOUR run by its id. `no-mistakes axi run` reports the run it started; from then on use `no-mistakes axi status --run <id>` and `no-mistakes axi logs --run <id> --step <step>`. A bare `axi status` resolves repo-wide whenever this branch has no run of its own and will show a run that belongs to another lane.'

allow() {  # <detail>
  echo "ok: $BRANCH in $OWNING_CLONE ($1)"
  echo "$DRIVE_BY_ID_NOTE"
  exit 0
}

NM=${FM_NM_BIN:-no-mistakes}
command -v "$NM" >/dev/null 2>&1 || allow "no-mistakes not installed; nothing to validate against"

STATUS_OUT=$("$NM" axi status 2>&1) || STATUS_OUT=""
[ -n "$STATUS_OUT" ] || allow "no existing run"

# TOON key/value lines, first occurrence wins. Values may be bare or quoted.
toon_value() {  # <key>
  printf '%s\n' "$STATUS_OUT" | awk -v key="$1" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (index(line, key ":") == 1) {
        v = substr(line, length(key) + 2)
        sub(/^[[:space:]]+/, "", v)
        sub(/[[:space:]]+$/, "", v)
        gsub(/^"|"$/, "", v)
        print v
        exit
      }
    }
  '
}

RUN_BRANCH=$(toon_value branch)
[ -n "$RUN_BRANCH" ] || allow "no existing run"

[ "$RUN_BRANCH" != "$BRANCH" ] || allow "existing run is this branch's own"

RUN_ID=$(toon_value id)
RUN_STATUS=$(toon_value status)

# The run belongs to another branch, so it is not this lane's to start from,
# answer, or abort - and it cannot be reached from here anyway. Say so out loud,
# because it IS what a bare `axi status` here will keep showing until this branch
# has a run of its own. Warning, not refusal: the run's existence blocks nothing.
case "$RUN_STATUS" in
  completed|failed|cancelled|canceled|aborted)
    allow "last run ${RUN_ID:-unknown} on $RUN_BRANCH already $RUN_STATUS"
    ;;
esac

cat >&2 <<EOF
warning: this repo has an unrelated run in flight; it is not yours.
  this branch:   $BRANCH
  unrelated run: ${RUN_ID:-unknown} on $RUN_BRANCH (${RUN_STATUS:-unknown state})
  repo copy:     $OWNING_CLONE
Never respond to or abort that run - its findings belong to the lane that started it.
It does not block you: no-mistakes serializes per repo+branch, so your branch validates alongside it.
EOF
allow "unrelated run ${RUN_ID:-unknown} on $RUN_BRANCH is ${RUN_STATUS:-in an unknown state} and is not yours"
