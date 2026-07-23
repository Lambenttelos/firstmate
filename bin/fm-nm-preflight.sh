#!/usr/bin/env bash
# Refuse a no-mistakes run that would validate someone else's branch.
#
# `no-mistakes axi run` triggers "a pipeline run for the current branch", but
# the run it acts on is resolved per REPO, not per branch: when the repo already
# has a run in flight, a second lane's `axi run` ATTACHES to it silently, on
# whatever branch that run belongs to. Observed live on 2026-07-23 from a
# firstmate worktree on `fm/fix-nm-repo-resolution-wrong-copy`:
#
#   $ no-mistakes axi status
#   run:
#     id: "01KY7JY2SA3P9ETYADZNDF07EA"
#     branch: fm/afk-paneless-delivery
#
# Nothing about the invoking branch reaches that resolution. In the incident
# this guard is built for, the attached run was parked at an approval gate, so
# the second lane's client was driving another lane's gate: its own branch was
# never validated, and the findings it was being asked to answer belonged to
# someone else. See data/learnings.md anchor `no-mistakes-wrong-repo-attach`.
#
# The check runs in the crewmate's own worktree, immediately before
# `/no-mistakes`, and refuses when the run no-mistakes would act on is on a
# different branch and is not already finished. A finished run on another branch
# is the ordinary steady state (every repo keeps its last run around) and is
# allowed. A run on the CURRENT branch is a legitimate resume - the documented
# way to re-validate after adding fix commits - and is always allowed.
#
# The companion defect, a task worktree that belongs to another home's clone of
# the same repo, is refused at launch by bin/fm-spawn.sh's clone-identity
# assertion. --project re-asserts it here, so a checkout that moved after launch
# is still caught before it validates into the wrong copy.
#
# Usage:
#   fm-nm-preflight.sh [--project <clone-path>]
#
# Runs against the current directory's git worktree.
# --project <clone-path> additionally requires that worktree to belong to the
# same clone as <clone-path>, compared by shared git directory.
#
# Exit contract:
#   0  clear to run; prints one `ok:` line naming the branch and owning clone.
#   1  refused; the reason is on stderr and no-mistakes must not be invoked.
#   2  usage error.
#
# Not being able to reach no-mistakes is not a refusal: with no pipeline there
# is no run to attach to. A reachable pipeline that reports an unrecognized run
# state IS a refusal, because an unknown state is exactly the in-flight case
# this guard exists to stop.
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

NM=${FM_NM_BIN:-no-mistakes}
command -v "$NM" >/dev/null 2>&1 || {
  echo "ok: $BRANCH in $OWNING_CLONE (no-mistakes not installed; nothing to attach to)"
  exit 0
}

STATUS_OUT=$("$NM" axi status 2>&1) || STATUS_OUT=""
if [ -z "$STATUS_OUT" ]; then
  echo "ok: $BRANCH in $OWNING_CLONE (no existing run)"
  exit 0
fi

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
if [ -z "$RUN_BRANCH" ]; then
  echo "ok: $BRANCH in $OWNING_CLONE (no existing run)"
  exit 0
fi

if [ "$RUN_BRANCH" = "$BRANCH" ]; then
  echo "ok: $BRANCH in $OWNING_CLONE (existing run is this branch's own)"
  exit 0
fi

RUN_ID=$(toon_value id)
RUN_STATUS=$(toon_value status)

# Only a finished run is safe to leave behind on another branch. Every other
# state - including one this guard has never seen - is treated as in flight,
# because attaching to an in-flight foreign run is the failure being prevented.
case "$RUN_STATUS" in
  completed|failed|cancelled|canceled|aborted)
    echo "ok: $BRANCH in $OWNING_CLONE (last run ${RUN_ID:-unknown} on $RUN_BRANCH already $RUN_STATUS)"
    exit 0
    ;;
esac

cat >&2 <<EOF
error: no-mistakes has a run in flight on another branch, and starting one here would attach to it instead of validating this branch.
  this branch:  $BRANCH
  in-flight run: ${RUN_ID:-unknown} on $RUN_BRANCH (${RUN_STATUS:-unknown state})
  repo copy:    $OWNING_CLONE
Do not run, respond to, or abort that run - its findings belong to the lane that started it. Report this and stop.
EOF
exit 1
