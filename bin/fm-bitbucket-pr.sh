#!/usr/bin/env bash
# Open a Bitbucket Cloud pull request from the command line: the Bitbucket
# counterpart to `gh-axi pr create` for the GitHub direct-PR path. Firstmate can
# push a validated fm/<id> branch to a Bitbucket product repository over SSH but
# has no forge CLI that opens a Bitbucket pull request object, so this command
# fills that gap by calling the REST 2.0 API through bin/fm-bitbucket-lib.sh.
#
# It requires curl, jq, and the NO_MISTAKES_BITBUCKET_EMAIL /
# NO_MISTAKES_BITBUCKET_API_TOKEN credentials (the same credentials the
# no-mistakes binary reads for its own Bitbucket integration). On success it
# prints the canonical PR URL, in the exact shape bin/fm-pr-lib.sh validates, so
# the caller can hand it straight to bin/fm-pr-check.sh to arm the merge watch.
#
# The workspace and repository default to the origin remote of the current git
# worktree when it is a bitbucket.org clone, so a worker on a task branch does
# not have to restate them. The destination branch is required (never guessed),
# and the title defaults to the source branch name when not given.
#
# Usage:
#   fm-bitbucket-pr.sh open --source <branch> --dest <branch> \
#     [--workspace <ws>] [--repo <repo>] [--title <title>] [--description <text>] [-C <dir>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-bitbucket-lib.sh
. "$SCRIPT_DIR/fm-bitbucket-lib.sh"

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

if [ "$#" -lt 1 ]; then
  usage >&2
  exit 2
fi

SUBCOMMAND=$1
shift
if [ "$SUBCOMMAND" != open ]; then
  echo "error: unknown subcommand: $SUBCOMMAND (only 'open' is supported)" >&2
  exit 2
fi

SOURCE=
DEST=
WORKSPACE=
REPO=
TITLE=
DESCRIPTION=
DIR=.

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) SOURCE=${2-}; shift 2 ;;
    --dest|--destination) DEST=${2-}; shift 2 ;;
    --workspace) WORKSPACE=${2-}; shift 2 ;;
    --repo|--repository) REPO=${2-}; shift 2 ;;
    --title) TITLE=${2-}; shift 2 ;;
    --description) DESCRIPTION=${2-}; shift 2 ;;
    -C) DIR=${2-}; shift 2 ;;
    --) shift; break ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$SOURCE" ] || [ -z "$DEST" ]; then
  echo "error: --source and --dest are both required" >&2
  exit 2
fi

# Resolve workspace/repository from the git clone's origin when not given
# explicitly. fm_pr_bitbucket_origin_slug returns non-zero when origin is not a
# bitbucket.org clone, in which case the caller must pass them.
if [ -z "$WORKSPACE" ] || [ -z "$REPO" ]; then
  if SLUG=$(fm_pr_bitbucket_origin_slug "$DIR"); then
    [ -n "$WORKSPACE" ] || WORKSPACE=${SLUG%%/*}
    [ -n "$REPO" ] || REPO=${SLUG#*/}
  fi
fi

if [ -z "$WORKSPACE" ] || [ -z "$REPO" ]; then
  echo "error: could not resolve the Bitbucket workspace/repository; pass --workspace and --repo" >&2
  exit 1
fi
fm_pr_bitbucket_slug_valid "$WORKSPACE" || { echo "error: invalid Bitbucket workspace: $WORKSPACE" >&2; exit 1; }
fm_pr_bitbucket_slug_valid "$REPO" || { echo "error: invalid Bitbucket repository: $REPO" >&2; exit 1; }

[ -n "$TITLE" ] || TITLE=$SOURCE

fm_bitbucket_ready || exit 1
fm_bitbucket_open_pr "$WORKSPACE" "$REPO" "$SOURCE" "$DEST" "$TITLE" "$DESCRIPTION"
