#!/usr/bin/env bash
# tests/fm-work-report-counts.test.sh - the work-report throughput counter
# (bin/fm-work-report-counts.sh).
#
# Covers the two error-prone git counts the work-report skill mechanizes and the
# contract that makes them reproducible: TOTAL COMMITS is first-parent and
# commit-date-filtered, TICKET LANDINGS counts distinct fm/ lanes across ALL
# commits (so a batch-merge's inner lanes are unrolled) while excluding the
# fm/batch-merge-* wrappers themselves, both numbers share the resolved
# since/until bounds echoed back in the JSON, and named-window resolution plus
# argument validation fail closed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-work-report-counts.sh"
TMP=$(fm_test_tmproot fm-work-report)
REPO="$TMP/repo"

fm_git_init_commit "$REPO"
git -C "$REPO" branch -M main
GIT() { git -C "$REPO" -c user.name=t -c user.email=t@t.invalid "$@"; }

# Commit-date drives the window filter; set both author and committer dates.
commit_at() {
  local date=$1 subject=$2
  GIT_AUTHOR_DATE="$date" GIT_COMMITTER_DATE="$date" \
    GIT commit -q --allow-empty -m "$subject"
}

# Out-of-window (before since).
commit_at "2026-06-30T12:00:00" "old work fm/old-lane"
# In-window first-parent commits.
commit_at "2026-07-02T09:00:00" "Merge fm/real-lane-a"
commit_at "2026-07-03T09:00:00" "Merge fm/batch-merge-01"
# A merge subject with an inner batched lane, reachable but as a non-first-parent
# body commit: emulate by a normal commit whose subject names another lane.
commit_at "2026-07-03T10:00:00" "Merged fm/real-lane-b into dev"
# Duplicate lane name must dedupe.
commit_at "2026-07-04T09:00:00" "Merge fm/real-lane-a"
# Out-of-window (after the exclusive until midnight; real commits never sit
# exactly on the boundary instant, which git would otherwise treat as inclusive).
commit_at "2026-07-05T09:00:00" "Merge fm/future-lane"

OUT=$("$SCRIPT" --repo "$REPO" --ref main --since 2026-07-01 --until 2026-07-05)
code=$?
expect_code 0 "$code" "explicit range exits 0"

# 4 in-window first-parent commits (07-02..07-04 inclusive; 07-05 is the exclusive until).
assert_contains "$OUT" '"total_commits":4' "total_commits counts in-window first-parent commits only"
# Distinct fm/ lanes: real-lane-a (deduped), real-lane-b = 2; batch-merge excluded; future/old out of window.
assert_contains "$OUT" '"ticket_landings":2' "ticket_landings dedupes and excludes fm/batch-merge wrappers"
assert_contains "$OUT" '"since":"2026-07-01"' "since echoed for caller reuse"
assert_contains "$OUT" '"until":"2026-07-05"' "until echoed for caller reuse"
assert_contains "$OUT" '"repo":"repo"' "repo basename reported"

# Named window resolves to concrete bounds without hardcoding dates.
WOUT=$("$SCRIPT" --repo "$REPO" --ref main --window last-month)
expect_code 0 "$?" "named window exits 0"
assert_contains "$WOUT" '"since":' "named window resolves a since bound"
assert_contains "$WOUT" '"until":' "named window resolves an until bound"

# Argument validation fails closed.
set +e
"$SCRIPT" --repo "$REPO" --ref main --window this-week --since 2026-07-01 >/dev/null 2>&1
expect_code 2 "$?" "window + since is rejected"
"$SCRIPT" --ref main --window this-week >/dev/null 2>&1
expect_code 2 "$?" "missing --repo is rejected"
"$SCRIPT" --repo "$REPO" --ref main >/dev/null 2>&1
expect_code 2 "$?" "no window and no range is rejected"
"$SCRIPT" --repo "$REPO" --ref main --window bogus >/dev/null 2>&1
expect_code 2 "$?" "unknown window is rejected"
"$SCRIPT" --repo "$REPO" --ref no-such-ref --since 2026-07-01 --until 2026-07-05 >/dev/null 2>&1
expect_code 2 "$?" "missing ref is rejected"
set -e

pass "fm-work-report-counts: counts, window resolution, and validation"
