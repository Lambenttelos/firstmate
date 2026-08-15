#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# GitHub PR URLs are parsed by bin/fm-pr-lib.sh and the derived owner/repository
# and PR number are passed to gh-axi as separate arguments. Bitbucket Cloud PR
# URLs are also accepted: they merge by workspace/repository through the REST 2.0
# API in bin/fm-bitbucket-lib.sh (which requires curl, jq, and the
# NO_MISTAKES_BITBUCKET_* credentials). A GitLab merge request URL is still
# refused here until its merge path lands.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. For a Bitbucket
# PR those same flags translate to a Bitbucket merge strategy (squash,
# merge_commit, fast_forward) and any other extra argument is refused; for a
# GitHub PR they are forwarded to gh-axi, and extra args must not include --repo
# or -R because the repository comes only from the URL.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra merge args>]
#
# Orphan mode merges a PR whose task metadata state/<id>.meta is already gone
# (the worker was torn down), for example a branch drained from the durable
# merge queue by the merge-desk secondmate. It runs the same guarded machinery -
# the URL is parsed and validated by bin/fm-pr-lib.sh, the merge method still
# defaults to --squash, --repo/-R overrides are still refused, and any conflict
# or red required check still makes the provider refuse loudly - but it takes no
# task id, requires no meta, and records merge evidence to the append-only log
# data/orphan-merges.log instead of a task's pr= line. The explicit repository
# argument must equal the project path the URL already carries (owner/repository
# on GitHub, workspace/repository on Bitbucket, the full namespace on GitLab); it
# exists so the caller states the repository it believes it is merging and the
# merge refuses on any mismatch.
#
# Orphan mode accepts every provider the task-based path merges: a GitHub PR
# merges through gh-axi, and a Bitbucket Cloud PR merges through the REST 2.0 API
# in bin/fm-bitbucket-lib.sh (curl, jq, and the NO_MISTAKES_BITBUCKET_*
# credentials). A GitLab merge request URL is accepted and parsed but refused
# with a provider-specific "GitLab orphan merge not yet supported" message and
# exit code 3, mirroring the task path where GitLab merge is not yet implemented;
# no orphan evidence is recorded because no merge happened.
# Usage: fm-pr-merge.sh --orphan <project-path> <pr-url> [-- <extra merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

# Translate the caller's extra merge arguments into a single Bitbucket merge
# strategy, printed on stdout. Extra gh-axi flags do not apply to a Bitbucket
# merge, so only an explicit merge method (mapped to a Bitbucket strategy) is
# accepted and any other extra argument is refused loudly rather than silently
# ignored. The default is squash, matching the GitHub default. Used by both the
# task-based path and the orphan path so the mapping lives in one place.
bitbucket_strategy_from_args() {
  local strategy=squash
  bb_translate_method() {
    case "$1" in
      --squash|--method=squash) strategy=squash ;;
      --merge|--method=merge) strategy=merge_commit ;;
      --rebase|--method=rebase|--method=fast_forward) strategy=fast_forward ;;
      *) return 1 ;;
    esac
  }
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --method ]; then
      shift
      bb_translate_method "--method=${1:-}" || {
        echo "error: unsupported Bitbucket merge method: ${1:-}" >&2
        return 1
      }
    elif ! bb_translate_method "$1"; then
      echo "error: unsupported Bitbucket merge argument: $1" >&2
      return 1
    fi
    shift
  done
  printf '%s\n' "$strategy"
}

# Orphan mode: merge a PR with no task meta, recording evidence to the durable
# orphan-merge log rather than a task's pr= line. Gated strictly behind the
# explicit --orphan flag; the task-based path below is unchanged.
if [ "${1:-}" = "--orphan" ]; then
  if [ "$#" -lt 3 ]; then
    echo "error: invalid PR merge request" >&2
    exit 2
  fi
  REPO_ARG=$2
  RAW_URL=$3
  # Accept every provider bin/fm-pr-lib.sh parses; the merge dispatch below routes
  # each to its own implementation. An unparseable URL is still refused generically.
  if ! fm_pr_url_parse "$RAW_URL"; then
    echo "error: invalid PR merge request" >&2
    exit 2
  fi
  # The explicit repository argument must equal the URL's own project path
  # (owner/repository, workspace/repository, or the full GitLab namespace). This
  # check and the orphan-log recording apply to every provider.
  if [ "$REPO_ARG" != "$FM_PR_PATH" ]; then
    echo "error: repository argument does not match the PR URL" >&2
    exit 1
  fi
  URL=$FM_PR_URL
  PROVIDER=$FM_PR_PROVIDER
  PR_PATH=$FM_PR_PATH
  PR_OWNER=$FM_PR_OWNER
  PR_REPO=$FM_PR_REPO
  PR_WORKSPACE=$FM_PR_WORKSPACE
  PR_NUMBER=$FM_PR_NUMBER
  shift 3
  [ "${1:-}" = "--" ] && shift
  reject_repo_overrides "$@" || exit 1

  case "$PROVIDER" in
    github)
      merge_args=()
      if ! caller_has_merge_method "$@"; then
        merge_args=(--squash)
      fi
      gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
      ;;
    bitbucket)
      # Bitbucket merges through the REST API, not gh-axi, reusing the same merge
      # implementation and strategy mapping as the task-based path.
      # shellcheck source=bin/fm-bitbucket-lib.sh
      . "$SCRIPT_DIR/fm-bitbucket-lib.sh"
      BB_STRATEGY=$(bitbucket_strategy_from_args "$@") || exit 1
      fm_bitbucket_merge_pr "$PR_WORKSPACE" "$PR_REPO" "$PR_NUMBER" "$BB_STRATEGY" || exit 1
      ;;
    gitlab)
      # GitLab merge is not yet implemented anywhere, so the URL is accepted and
      # parsed but this fails with a provider-specific message rather than the
      # generic invalid-request error. No orphan evidence is recorded because no
      # merge happened.
      echo "error: GitLab orphan merge not yet supported" >&2
      exit 3
      ;;
    *)
      echo "error: invalid PR merge request" >&2
      exit 2
      ;;
  esac

  # Record merge evidence only after the provider merge confirms. There is no
  # task meta to write pr= into, so the append-only log is the durable evidence
  # sink, and it records every merged provider identically.
  mkdir -p "$DATA" || { echo "error: could not record orphan-merge evidence" >&2; exit 1; }
  printf '%s\torphan-merge\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PR_PATH" "$URL" \
    >> "$DATA/orphan-merges.log" \
    || { echo "error: could not record orphan-merge evidence" >&2; exit 1; }
  exit 0
fi

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitHub, Bitbucket, and GitLab PR/MR URLs. This path
# merges GitHub (by owner/repository through gh-axi) and Bitbucket Cloud (by
# workspace/repository through the REST API). A GitLab merge request is still
# refused here until its merge path lands, so the watcher can follow it but this
# command will not merge it.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || { [ "$FM_PR_PROVIDER" != github ] && [ "$FM_PR_PROVIDER" != bitbucket ]; }; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_WORKSPACE=$FM_PR_WORKSPACE
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

if [ "$PROVIDER" = bitbucket ]; then
  # Bitbucket merges through the REST API, not gh-axi, reusing the shared merge
  # implementation and strategy mapping. The default is a squash merge, matching
  # the GitHub default below.
  # shellcheck source=bin/fm-bitbucket-lib.sh
  . "$SCRIPT_DIR/fm-bitbucket-lib.sh"
  BB_STRATEGY=$(bitbucket_strategy_from_args "$@") || exit 1
  fm_bitbucket_merge_pr "$PR_WORKSPACE" "$PR_REPO" "$PR_NUMBER" "$BB_STRATEGY"
  exit $?
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
