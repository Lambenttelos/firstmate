#!/usr/bin/env bash
# Durable merge-queue format owner. Sourced by bin/fm-teardown.sh (record) and
# bin/fm-merge-queue.sh (list/remove/sweep). NEVER executed directly.
#
# The merge queue is the safety guard for release-on-pushed teardown: when a
# finished worker's branch is fully pushed to origin but not yet merged, teardown
# releases its disposable worktree (freeing the memory-bound slot) and records the
# branch here so it can never be silently forgotten. Firstmate surfaces the batched
# set as one list of compare links, and entries clear once the branch's content is
# confirmed in its base branch.
#
# Storage: data/merge-queue.tsv, one entry per line, tab-separated:
#   <id>\t<project-path>\t<branch>\t<head>\t<base>\t<compare-url>
# where <project-path> is the local clone firstmate runs git against, <head> is the
# branch tip commit at release time, <base> is the intended merge target branch, and
# <compare-url> is the captain-facing compare link. Comment lines start with '#'.
#
# One entry per task id; recording an id again replaces its line. All writes are
# atomic (tmp + mv). Field values may not contain a tab or newline.

FM_MERGE_QUEUE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Serialize the read-modify-write in record/remove so two concurrent teardowns
# cannot lose an entry. The lock primitives live in bin/fm-wake-lib.sh (one owner
# for portable locking); it is sourced lazily so this leaf lib stays cheap for
# read-only callers. A lock that cannot be taken within the bounded wait is not a
# reason to drop a record: the write itself is atomic (tmp + mv), so proceed.
fm_merge_queue_lock_path() {
  printf '%s\n' "$1/.merge-queue.lock"
}

fm_merge_queue_lock() {
  local data_dir=$1 lock attempt=0
  command -v fm_lock_try_acquire >/dev/null 2>&1 || {
    # shellcheck source=bin/fm-wake-lib.sh
    . "$FM_MERGE_QUEUE_LIB_DIR/fm-wake-lib.sh"
  }
  lock=$(fm_merge_queue_lock_path "$data_dir")
  while [ "$attempt" -lt 100 ]; do
    if fm_lock_try_acquire "$lock"; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 0.1
  done
  return 1
}

fm_merge_queue_unlock() {
  local data_dir=$1
  fm_lock_release "$(fm_merge_queue_lock_path "$data_dir")" 2>/dev/null || true
}

# Print every entry line whose first tab-separated field is NOT <id>. Literal
# field comparison, never a regex, so an id containing '.' cannot match another.
fm_merge_queue_drop_id() {
  local file=$1 id=$2
  awk -F'\t' -v id="$id" '$1 != id' "$file"
}

# Absolute path to the merge-queue file for a data dir.
fm_merge_queue_file() {
  local data_dir=$1
  printf '%s\n' "$data_dir/merge-queue.tsv"
}

# True when a value is a safe single-line field (no tab, no newline, non-empty).
fm_merge_queue_field_safe() {
  local v=$1
  [ -n "$v" ] || return 1
  case "$v" in
    *"	"*) return 1 ;;
  esac
  [ "$(printf '%s' "$v" | wc -l | tr -d ' ')" = 0 ] || return 1
  return 0
}

fm_merge_queue_id_safe() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Print the raw non-comment, non-blank entry lines (or nothing when absent).
fm_merge_queue_entries() {
  local data_dir=$1 file
  file=$(fm_merge_queue_file "$data_dir")
  [ -f "$file" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$file" || true
}

# Record (or replace) an entry. Args: data_dir id project branch head base url.
# Returns non-zero without writing on any unsafe field.
fm_merge_queue_record() {
  local data_dir=$1 id=$2 project=$3 branch=$4 head=$5 base=$6 url=$7 file tmp
  fm_merge_queue_id_safe "$id" || { echo "merge-queue: unsafe task id '$id'" >&2; return 1; }
  local f
  for f in "$project" "$branch" "$head" "$base" "$url"; do
    fm_merge_queue_field_safe "$f" || { echo "merge-queue: unsafe field for $id" >&2; return 1; }
  done
  mkdir -p "$data_dir" || return 1
  file=$(fm_merge_queue_file "$data_dir")
  local locked=0
  fm_merge_queue_lock "$data_dir" && locked=1
  tmp="$file.tmp.$$"
  {
    if [ -f "$file" ]; then
      fm_merge_queue_drop_id "$file" "$id" || true
    else
      printf '%s\n' \
        '# firstmate merge queue: pushed-but-unmerged branches whose worktree was released.' \
        '# Format: <id>\t<project-path>\t<branch>\t<head>\t<base>\t<compare-url>' \
        '# Owned by bin/fm-merge-queue-lib.sh; surface with bin/fm-merge-queue.sh list.'
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$project" "$branch" "$head" "$base" "$url"
  } > "$tmp" || {
    rm -f "$tmp"
    [ "$locked" -eq 1 ] && fm_merge_queue_unlock "$data_dir"
    return 1
  }
  mv "$tmp" "$file"
  local rc=$?
  [ "$locked" -eq 1 ] && fm_merge_queue_unlock "$data_dir"
  return "$rc"
}

# Remove the entry for a task id. Succeeds silently when absent.
fm_merge_queue_remove() {
  local data_dir=$1 id=$2 file tmp
  fm_merge_queue_id_safe "$id" || return 1
  file=$(fm_merge_queue_file "$data_dir")
  [ -f "$file" ] || return 0
  local locked=0
  fm_merge_queue_lock "$data_dir" && locked=1
  tmp="$file.tmp.$$"
  fm_merge_queue_drop_id "$file" "$id" > "$tmp" || true
  mv "$tmp" "$file"
  local rc=$?
  [ "$locked" -eq 1 ] && fm_merge_queue_unlock "$data_dir"
  return "$rc"
}

# True only when origin PROVABLY no longer carries <branch>. Used when the recorded
# head object is no longer in the clone (the local branch is gone after teardown, and
# a pruning fetch plus gc can drop the last remote-tracking copy of a merged branch):
# a branch the forge deleted after merging must clear rather than stick forever. Any
# inconclusive answer - a network or auth failure, an ls-remote error - returns
# non-zero so nothing clears on an unverifiable claim.
fm_merge_queue_branch_gone_from_origin() {
  local project=$1 branch=$2 rc=0
  [ -n "$branch" ] || return 1
  git -C "$project" ls-remote --exit-code --heads origin "refs/heads/$branch" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
}

# True when <branch>'s work (tip <head>) is confirmed merged into <base> on origin.
# Repo-agnostic and safe for Bitbucket repos with no PR automation: it checks
# content-in-base against the real base branch, never a PR-state lookup. Fetches the
# base fresh, then accepts either head reachable from origin/<base> (ordinary merge)
# or the branch introducing nothing origin/<base> lacks (squash/rebase merge). Any
# inconclusive result (no origin, fetch failure, conflict) returns non-zero so the
# entry is KEPT rather than cleared on an unverifiable claim.
fm_merge_queue_branch_merged() {
  local project=$1 branch=$2 head=$3 base=$4 ref base_tree merged_tree
  [ -n "$project" ] && [ -d "$project" ] || return 1
  [ -n "$base" ] || return 1
  git -C "$project" remote get-url origin >/dev/null 2>&1 || return 1
  if ! git -C "$project" cat-file -e "$head^{commit}" 2>/dev/null; then
    fm_merge_queue_branch_gone_from_origin "$project" "$branch"
    return
  fi
  git -C "$project" fetch --quiet origin "+refs/heads/$base:refs/remotes/origin/$base" >/dev/null 2>&1 || return 1
  ref="refs/remotes/origin/$base"
  git -C "$project" merge-base --is-ancestor "$head" "$ref" 2>/dev/null && return 0
  base_tree=$(git -C "$project" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$base_tree" ] || return 1
  merged_tree=$(git -C "$project" merge-tree --write-tree "$ref" "$head" 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$base_tree" ]
}

# Build a captain-facing compare URL from an origin remote URL, base, and branch.
# Handles github.com and bitbucket.org (SSH or HTTPS); falls back to a plain
# descriptive string when the host is unknown, so the value is always non-empty.
fm_merge_queue_compare_url() {
  local remote=$1 base=$2 branch=$3 hostpath host path owner repo
  hostpath=$remote
  case "$hostpath" in
    git@*:*) host=${hostpath#git@}; host=${host%%:*}; path=${hostpath#*:} ;;
    ssh://git@*) hostpath=${hostpath#ssh://git@}; host=${hostpath%%/*}; host=${host%%:*}; path=${hostpath#*/} ;;
    https://*) hostpath=${hostpath#https://}; hostpath=${hostpath#*@}; host=${hostpath%%/*}; path=${hostpath#*/} ;;
    http://*) hostpath=${hostpath#http://}; hostpath=${hostpath#*@}; host=${hostpath%%/*}; path=${hostpath#*/} ;;
    *) host=; path= ;;
  esac
  path=${path%.git}
  owner=${path%%/*}
  repo=${path#*/}
  if [ -n "$host" ] && [ -n "$owner" ] && [ -n "$repo" ] && [ "$owner" != "$path" ]; then
    case "$host" in
      github.com)
        printf '%s\n' "https://github.com/$owner/$repo/compare/$base...$branch"; return 0 ;;
      bitbucket.org)
        printf '%s\n' "https://bitbucket.org/$owner/$repo/branch/$branch?dest=$base"; return 0 ;;
    esac
  fi
  printf '%s\n' "branch $branch (base $base) in ${path:-$remote}"
}
