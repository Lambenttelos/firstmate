#!/usr/bin/env bash
# Tests for the durable merge queue (bin/fm-merge-queue-lib.sh, bin/fm-merge-queue.sh).
#
# The queue records ship branches that were released by teardown while pushed to
# origin but not yet merged, so a released-but-unmerged branch is never forgotten.
#
# Covers:
#   - record then list surfaces the entry as a compare link
#   - recording the same id twice replaces (not duplicates) the entry
#   - unsafe fields (embedded tab) are refused without writing
#   - remove drops one entry; count reflects the queue size
#   - sweep clears a branch merged into its base (content-in-base) and keeps an
#     unmerged one
#   - the merged check uses content-in-base, not a PR lookup, so it works for a
#     Bitbucket-style repo with no PR automation
#   - compare-url builds github and bitbucket links and falls back for unknown hosts
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=bin/fm-merge-queue-lib.sh disable=SC1091
. "$ROOT/bin/fm-merge-queue-lib.sh"
CLI="$ROOT/bin/fm-merge-queue.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-queue-tests)

run_cli() {
  local data=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$data" "$CLI" "$@"
}

test_record_and_list() {
  local data="$TMP_ROOT/rl/data"
  mkdir -p "$data"
  fm_merge_queue_record "$data" task-a /proj fm/a deadbeef main \
    'https://github.com/o/r/compare/main...fm/a' || fail "record failed"
  out=$(run_cli "$data" list)
  printf '%s\n' "$out" | grep -F 'task-a' >/dev/null || fail "list missing id: $out"
  printf '%s\n' "$out" | grep -F 'compare/main...fm/a' >/dev/null || fail "list missing url: $out"
  pass "record then list surfaces the entry as a compare link"
}

test_record_replaces_same_id() {
  local data="$TMP_ROOT/replace/data"
  mkdir -p "$data"
  fm_merge_queue_record "$data" task-b /proj fm/b c1 main url1
  fm_merge_queue_record "$data" task-b /proj fm/b c2 main url2
  local n
  n=$(run_cli "$data" count)
  [ "$n" = 1 ] || fail "expected 1 entry after re-record, got $n"
  run_cli "$data" list --raw | grep -F 'c2' >/dev/null || fail "re-record did not update head"
  run_cli "$data" list --raw | grep -F 'c1' >/dev/null && fail "old entry survived re-record"
  pass "recording the same id twice replaces the entry"
}

test_unsafe_field_refused() {
  local data="$TMP_ROOT/unsafe/data"
  mkdir -p "$data"
  local bad
  bad=$(printf 'fm/%s\tx' bad)
  if fm_merge_queue_record "$data" task-c /proj "$bad" c1 main url 2>/dev/null; then
    fail "record accepted a tab-bearing field"
  fi
  [ ! -f "$data/merge-queue.tsv" ] || {
    grep -q task-c "$data/merge-queue.tsv" && fail "unsafe record was written"
  }
  pass "unsafe field with an embedded tab is refused without writing"
}

test_remove_and_count() {
  local data="$TMP_ROOT/rm/data"
  mkdir -p "$data"
  fm_merge_queue_record "$data" task-d /proj fm/d c1 main url
  fm_merge_queue_record "$data" task-e /proj fm/e c2 main url
  [ "$(run_cli "$data" count)" = 2 ] || fail "expected 2 before remove"
  run_cli "$data" remove task-d >/dev/null
  [ "$(run_cli "$data" count)" = 1 ] || fail "expected 1 after remove"
  run_cli "$data" list --raw | grep -F task-e >/dev/null || fail "wrong entry removed"
  pass "remove drops one entry; count reflects the queue size"
}

# Build a bare origin + clone with a task branch pushed. Echoes "<origin> <clone>".
make_repo_with_pushed_branch() {
  local dir=$1 branch=$2
  git init -q --bare "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir/origin.git" "$dir/seed" 2>/dev/null
  git -C "$dir/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m baseline
  git -C "$dir/seed" push -q origin main
  rm -rf "$dir/seed"
  git clone -q "$dir/origin.git" "$dir/clone"
  git -C "$dir/clone" checkout -q -b "$branch"
  printf '%s\n' feature > "$dir/clone/feature.txt"
  git -C "$dir/clone" add -- feature.txt
  git -C "$dir/clone" -c user.email=t@t -c user.name=t commit -q -m "work on $branch"
  git -C "$dir/clone" push -q origin "$branch"
}

test_sweep_clears_merged_keeps_unmerged() {
  local data="$TMP_ROOT/sweep/data" repo="$TMP_ROOT/sweep/repo"
  mkdir -p "$data" "$repo"
  make_repo_with_pushed_branch "$repo" fm/merged
  local head
  head=$(git -C "$repo/clone" rev-parse HEAD)
  # Land the branch content into origin/main (fast-forward merge).
  git -C "$repo/clone" push -q origin HEAD:main
  fm_merge_queue_record "$data" task-m "$repo/clone" fm/merged "$head" main url-m
  # A second, genuinely unmerged branch.
  make_repo_with_pushed_branch "$repo/u" fm/open
  local uhead
  uhead=$(git -C "$repo/u/clone" rev-parse HEAD)
  fm_merge_queue_record "$data" task-o "$repo/u/clone" fm/open "$uhead" main url-o
  run_cli "$data" sweep >/dev/null
  run_cli "$data" list --raw | grep -F task-m >/dev/null && fail "merged branch not swept"
  run_cli "$data" list --raw | grep -F task-o >/dev/null || fail "unmerged branch wrongly swept"
  pass "sweep clears a merged branch and keeps an unmerged one"
}

test_sweep_uses_content_not_pr_lookup() {
  # A squash-style landing: base gains a commit with the same net content but a
  # different commit id; the branch tip is NOT an ancestor of base. content-in-base
  # must still recognize it as merged, with no PR machinery involved.
  local data="$TMP_ROOT/squash/data" repo="$TMP_ROOT/squash/repo"
  mkdir -p "$data" "$repo"
  make_repo_with_pushed_branch "$repo" fm/squash
  local head
  head=$(git -C "$repo/clone" rev-parse HEAD)
  # Land equivalent content on main via a distinct commit.
  git clone -q "$repo/origin.git" "$repo/land"
  printf '%s\n' feature > "$repo/land/feature.txt"
  git -C "$repo/land" add -- feature.txt
  git -C "$repo/land" -c user.email=t@t -c user.name=t commit -q -m "squash feature"
  git -C "$repo/land" push -q origin HEAD:main
  fm_merge_queue_record "$data" task-s "$repo/clone" fm/squash "$head" main url-s
  run_cli "$data" sweep >/dev/null
  run_cli "$data" list --raw | grep -F task-s >/dev/null && fail "content-merged branch not swept"
  pass "sweep merged check uses content-in-base, not a PR lookup"
}

test_compare_url_hosts() {
  local u
  u=$(fm_merge_queue_compare_url 'git@github.com:yjuyjuy/firstmate.git' main fm/x)
  [ "$u" = 'https://github.com/yjuyjuy/firstmate/compare/main...fm/x' ] || fail "github ssh url wrong: $u"
  u=$(fm_merge_queue_compare_url 'https://github.com/o/r.git' main fm/x)
  [ "$u" = 'https://github.com/o/r/compare/main...fm/x' ] || fail "github https url wrong: $u"
  u=$(fm_merge_queue_compare_url 'git@bitbucket.org:team/hyfin.git' develop fm/y)
  [ "$u" = 'https://bitbucket.org/team/hyfin/branch/fm/y?dest=develop' ] || fail "bitbucket url wrong: $u"
  u=$(fm_merge_queue_compare_url 'git@example.com:o/r.git' main fm/z)
  case "$u" in *'fm/z'*'main'*) : ;; *) fail "unknown host fallback missing branch/base: $u" ;; esac
  pass "compare-url builds github and bitbucket links and falls back for unknown hosts"
}

test_record_and_list
test_record_replaces_same_id
test_unsafe_field_refused
test_remove_and_count
test_sweep_clears_merged_keeps_unmerged
test_sweep_uses_content_not_pr_lookup
test_compare_url_hosts
