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
#   - task ids are matched literally, so a dotted id cannot clobber another entry
#   - an entry whose head object is gone clears only when origin provably no longer
#     carries the branch, and is kept on an inconclusive probe
#   - a rewrite that would truncate the queue is refused, keeping the file intact
#   - record and remove fail rather than proceed unlocked when the lock is held
#   - a branch-gone sweep clears with distinct wording, never worded as a merge
#   - compare-url builds github and bitbucket links and falls back for unknown hosts
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=bin/fm-merge-queue-lib.sh disable=SC1091
. "$ROOT/bin/fm-merge-queue-lib.sh"
CLI="$ROOT/bin/fm-merge-queue.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-queue-tests)

# Re-source the lib so a test that stubs one of its functions cannot leak that stub
# into later tests.
restore_lib() {
  # shellcheck source=bin/fm-merge-queue-lib.sh disable=SC1091
  . "$ROOT/bin/fm-merge-queue-lib.sh"
}

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

test_id_is_matched_literally() {
  # A task id may contain '.', which is a regex metacharacter: matching it as a
  # pattern would let 'a.b' delete an unrelated 'aXb' entry.
  local data="$TMP_ROOT/literal/data"
  mkdir -p "$data"
  fm_merge_queue_record "$data" aXb /proj fm/x c1 main url-x
  fm_merge_queue_record "$data" a.b /proj fm/dot c2 main url-dot
  [ "$(run_cli "$data" count)" = 2 ] || fail "re-record with a dotted id clobbered another entry"
  run_cli "$data" remove a.b >/dev/null
  run_cli "$data" list --raw | grep -F aXb >/dev/null || fail "remove of a dotted id took the wrong entry"
  [ "$(run_cli "$data" count)" = 1 ] || fail "expected 1 entry after removing the dotted id"
  pass "task ids are matched literally, so a dotted id cannot clobber another entry"
}

test_sweep_clears_when_head_gone_and_branch_deleted() {
  # After teardown the local branch is gone; a pruning fetch plus gc can drop the
  # last copy of the head object for a branch the forge deleted on merge. The entry
  # must clear rather than stick forever.
  local data="$TMP_ROOT/gone/data" repo="$TMP_ROOT/gone/repo"
  mkdir -p "$data" "$repo"
  make_repo_with_pushed_branch "$repo" fm/gone
  local head
  head=$(git -C "$repo/clone" rev-parse HEAD)
  git -C "$repo/origin.git" update-ref -d refs/heads/fm/gone
  fm_merge_queue_record "$data" task-g "$repo/clone" fm/gone 0000000000000000000000000000000000000000 main url-g
  run_cli "$data" sweep >/dev/null
  run_cli "$data" list --raw | grep -F task-g >/dev/null && fail "unresolvable head with deleted branch not swept"
  [ -n "$head" ] || fail "fixture head unset"
  pass "sweep clears an entry whose head is gone and whose branch no longer exists on origin"
}

test_sweep_keeps_when_head_gone_but_branch_alive() {
  # Same unresolvable head, but the branch still exists on origin: that is not
  # evidence of a merge, so the entry must be kept.
  local data="$TMP_ROOT/alive/data" repo="$TMP_ROOT/alive/repo"
  mkdir -p "$data" "$repo"
  make_repo_with_pushed_branch "$repo" fm/alive
  fm_merge_queue_record "$data" task-a2 "$repo/clone" fm/alive 0000000000000000000000000000000000000000 main url-a
  run_cli "$data" sweep >/dev/null
  run_cli "$data" list --raw | grep -F task-a2 >/dev/null || fail "entry cleared while its branch still exists on origin"
  pass "sweep keeps an entry whose head is gone while the branch still exists on origin"
}

test_sweep_keeps_when_origin_unreachable() {
  # Inconclusive probe (origin URL points nowhere): never clear on an unverifiable
  # claim.
  local data="$TMP_ROOT/unreach/data" repo="$TMP_ROOT/unreach/repo"
  mkdir -p "$data" "$repo"
  make_repo_with_pushed_branch "$repo" fm/unreach
  git -C "$repo/clone" remote set-url origin "$repo/does-not-exist.git"
  fm_merge_queue_record "$data" task-u "$repo/clone" fm/unreach 0000000000000000000000000000000000000000 main url-u
  run_cli "$data" sweep >/dev/null
  run_cli "$data" list --raw | grep -F task-u >/dev/null || fail "entry cleared on an unreachable origin"
  pass "sweep keeps an entry when the origin probe is inconclusive"
}

test_remove_refuses_short_rewrite() {
  # A truncated rewrite would erase every other queued branch, the worst possible
  # failure for a guard whose whole purpose is that nothing is forgotten.
  local data="$TMP_ROOT/short/data"
  mkdir -p "$data"
  fm_merge_queue_record "$data" task-s1 /proj fm/s1 c1 main url-1
  fm_merge_queue_record "$data" task-s2 /proj fm/s2 c2 main url-2
  local before
  before=$(cat "$data/merge-queue.tsv")
  fm_merge_queue_drop_id() { printf ''; }
  if fm_merge_queue_remove "$data" task-s1 2>/dev/null; then
    restore_lib
    fail "remove accepted a truncating rewrite"
  fi
  restore_lib
  [ "$(cat "$data/merge-queue.tsv")" = "$before" ] || fail "queue was modified by a refused remove"
  pass "remove refuses a short rewrite and keeps the queue intact"
}

test_lock_timeout_fails_closed() {
  # An unlocked read-modify-write can lose an entry, so a lock that cannot be taken
  # must fail the record and the remove rather than proceed racy.
  local data="$TMP_ROOT/lock/data"
  mkdir -p "$data"
  fm_merge_queue_record "$data" task-l1 /proj fm/l1 c1 main url-l1
  fm_merge_queue_lock() { return 1; }
  if fm_merge_queue_record "$data" task-l2 /proj fm/l2 c2 main url-l2 2>/dev/null; then
    restore_lib
    fail "record proceeded without the lock"
  fi
  if fm_merge_queue_remove "$data" task-l1 2>/dev/null; then
    restore_lib
    fail "remove proceeded without the lock"
  fi
  restore_lib
  run_cli "$data" list --raw | grep -F task-l1 >/dev/null || fail "existing entry lost by a refused write"
  run_cli "$data" list --raw | grep -F task-l2 >/dev/null && fail "entry recorded despite a refused lock"
  pass "record and remove fail closed when the queue lock cannot be taken"
}

test_sweep_branch_gone_wording_is_distinct() {
  # Clearing because origin no longer carries the branch is NOT a verified merge and
  # must never read like one.
  local data="$TMP_ROOT/wording/data" repo="$TMP_ROOT/wording/repo" out
  mkdir -p "$data" "$repo"
  make_repo_with_pushed_branch "$repo" fm/word
  git -C "$repo/origin.git" update-ref -d refs/heads/fm/word
  fm_merge_queue_record "$data" task-w "$repo/clone" fm/word 0000000000000000000000000000000000000000 main url-w
  out=$(run_cli "$data" sweep)
  printf '%s\n' "$out" | grep -F 'merge unverified' >/dev/null || fail "branch-gone sweep missing distinct wording: $out"
  printf '%s\n' "$out" | grep -F 'merged into' >/dev/null && fail "branch-gone sweep claimed a merge: $out"
  pass "sweep reports a branch-gone clear distinctly from a verified merge"
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
test_id_is_matched_literally
test_sweep_clears_when_head_gone_and_branch_deleted
test_sweep_keeps_when_head_gone_but_branch_alive
test_sweep_keeps_when_origin_unreachable
test_remove_refuses_short_rewrite
test_lock_timeout_fails_closed
test_sweep_branch_gone_wording_is_distinct
test_compare_url_hosts
