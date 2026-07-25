#!/usr/bin/env bash
# tests/fm-hourly-passes.test.sh - behavior tests for the two session-lifetime
# hourly passes: the session review (bin/fm-session-review.sh), the cleanup
# sweep (bin/fm-cleanup-sweep.sh), their shared arming/cadence contract
# (bin/fm-hourly-lib.sh), and the watcher wiring that runs them.
#
# Coverage:
#   - a clean home is SILENT: both passes print nothing worth waking for
#   - the review reports only things that have not moved: an aging open
#     decision, a silent worker, queued work with nothing running, a batch of
#     unmerged branches
#   - suppression: a finding surfaces once and stays silent while unchanged, a
#     new finding surfaces, and an emptied finding set re-arms silently
#   - the cleanup sweep RECLAIMS only bookkeeping (watcher temp residue, dead
#     suppression markers with nothing in flight) and REPORTS without removing
#     anything that could hold unlanded work
#   - suppression markers survive while work IS in flight
#   - fm-session-start.sh arms both passes when it holds the lock and skips
#     arming on the read-only path
#   - the real watcher runs a due pass, wakes once with a "check: session-*"
#     record, and exits - no second supervision cycle, no background process
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REVIEW="$ROOT/bin/fm-session-review.sh"
CLEANUP="$ROOT/bin/fm-cleanup-sweep.sh"
WATCH="$ROOT/bin/fm-watch.sh"
SESSION_START="$ROOT/bin/fm-session-start.sh"
TMP_ROOT=$(fm_test_tmproot fm-hourly-passes-tests)
fm_git_identity fmtest fmtest@example.invalid

# new_home <name>: a bare FM_HOME with state/, data/, projects/.
new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/projects"
  printf '%s' "$home"
}

run_review() {  # <home> [extra env...]
  local home=$1
  shift
  env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$@" "$REVIEW"
}

run_cleanup() {  # <home> [extra env...]
  local home=$1
  shift
  env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$@" "$CLEANUP"
}

# backdate <path> <seconds>: age a file or directory by <seconds>.
backdate() {
  local path=$1 secs=$2 stamp
  stamp=$(date -r $(( $(date +%s) - secs )) '+%Y%m%d%H%M.%S' 2>/dev/null) \
    || stamp=$(date -d "@$(( $(date +%s) - secs ))" '+%Y%m%d%H%M.%S')
  touch -t "$stamp" "$path"
}

# --- review: silence on a healthy home ---------------------------------------
t_review_silent_when_clean() {
  local home out
  home=$(new_home review-clean)
  out=$(run_review "$home")
  [ -z "$out" ] || fail "review must be silent on a clean home, got: $out"
  assert_present "$home/state/.hourly-review.latest" "review must still write its report file"
  assert_grep "no findings" "$home/state/.hourly-review.latest" "clean report must say so in the file, not on stdout"
  pass "review is silent on a clean home but still records a report"
}

# --- review: an open decision nobody has answered -----------------------------
t_review_aging_decision() {
  local home out
  home=$(new_home review-decision)
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "kind=ship"
  printf 'working: started\nneeds-decision: pick the delivery mode\n' > "$home/state/alpha.status"
  backdate "$home/state/alpha.status" 7200

  out=$(run_review "$home")
  assert_contains "$out" "alpha waiting on a decision" "an aging open decision must surface"
  assert_grep "pick the delivery mode" "$home/state/.hourly-review.latest" "the report must carry the decision text"

  # Unchanged an hour later: silent.
  out=$(run_review "$home")
  [ -z "$out" ] || fail "an unchanged finding must not surface again, got: $out"

  # Answered: silent, and the marker is cleared so a later decision surfaces.
  printf 'resolved: delivery mode chosen\n' >> "$home/state/alpha.status"
  out=$(run_review "$home")
  [ -z "$out" ] || fail "an answered decision must not surface, got: $out"
  assert_absent "$home/state/.hourly-review-surfaced" "an empty finding set must re-arm the marker"
  pass "review surfaces an aging decision once, then stays silent until it changes"
}

# --- review: a worker that has gone quiet -------------------------------------
t_review_silent_worker() {
  local home out
  home=$(new_home review-stall)
  fm_write_meta "$home/state/beta.meta" "window=firstmate:fm-beta" "kind=ship"
  printf 'working: implementing\n' > "$home/state/beta.status"
  backdate "$home/state/beta.status" 10800

  out=$(run_review "$home")
  assert_contains "$out" "beta silent for" "a worker with no status event for hours must surface"

  # A fresh event clears it.
  printf 'working: still going\n' >> "$home/state/beta.status"
  out=$(run_review "$home")
  [ -z "$out" ] || fail "a worker that reported again must not surface, got: $out"
  pass "review surfaces a long-silent worker and drops it once it reports"
}

# --- review: queued work with nothing running ---------------------------------
t_review_idle_capacity() {
  local home out
  home=$(new_home review-idle)
  cat > "$home/data/backlog.md" <<'MD'
## In flight

## Queued

- one - first queued item
- two - second queued item

## Done
MD
  out=$(run_review "$home")
  assert_contains "$out" "nothing under way with 2 queued" "queued work with no worker must surface"

  fm_write_meta "$home/state/gamma.meta" "window=firstmate:fm-gamma" "kind=ship"
  out=$(run_review "$home")
  [ -z "$out" ] || fail "with work under way the idle-capacity finding must clear, got: $out"
  pass "review surfaces queued work with nothing running"
}

# --- review: a batch of finished-but-unmerged branches ------------------------
t_review_merge_batch() {
  local home out i
  home=$(new_home review-merge)
  : > "$home/data/merge-queue.tsv"
  for i in 1 2 3; do
    printf 'task%s\tproj\tfm/branch%s\tdeadbeef\tmain\thttps://example.test/compare/%s\n' \
      "$i" "$i" "$i" >> "$home/data/merge-queue.tsv"
  done
  out=$(run_review "$home")
  assert_contains "$out" "finished branches waiting to merge" "an accumulated merge batch must surface"
  pass "review surfaces an accumulated batch of unmerged branches"
}

# --- cleanup: silent reclaim of bookkeeping -----------------------------------
t_cleanup_reclaims_quietly() {
  local home out
  home=$(new_home cleanup-reclaim)
  : > "$home/state/.fm-check-output.abc123"
  backdate "$home/state/.fm-check-output.abc123" 7200
  : > "$home/state/.seen-gone_status"
  backdate "$home/state/.seen-gone_status" 200000

  out=$(run_cleanup "$home" FM_CLEANUP_TMP_ROOT="$TMP_ROOT/no-such-tmp")
  [ -z "$out" ] || fail "reclaiming bookkeeping is not captain-facing, expected silence, got: $out"
  assert_absent "$home/state/.fm-check-output.abc123" "stale watcher temp residue must be reclaimed"
  assert_absent "$home/state/.seen-gone_status" "a dead suppression marker must be reclaimed with nothing in flight"
  assert_grep "removed stale watcher temp file" "$home/state/.hourly-cleanup.log" "reclaim actions must be logged"
  pass "cleanup reclaims bookkeeping silently and logs what it did"
}

# --- cleanup: markers survive while work is in flight -------------------------
t_cleanup_keeps_markers_in_flight() {
  local home out
  home=$(new_home cleanup-inflight)
  fm_write_meta "$home/state/delta.meta" "window=firstmate:fm-delta" "kind=ship"
  : > "$home/state/.hash-firstmate_fm-delta"
  backdate "$home/state/.hash-firstmate_fm-delta" 200000

  out=$(run_cleanup "$home" FM_CLEANUP_TMP_ROOT="$TMP_ROOT/no-such-tmp")
  [ -z "$out" ] || fail "expected silence, got: $out"
  assert_present "$home/state/.hash-firstmate_fm-delta" "suppression markers must survive while work is in flight"
  pass "cleanup leaves suppression markers alone while work is under way"
}

# --- cleanup: reports orphan copies, removes nothing ---------------------------
t_cleanup_reports_orphan_worktree() {
  local home clone wt out
  home=$(new_home cleanup-orphan)
  clone="$home/projects/alpha"
  git init -q -b main "$clone"
  git -C "$clone" commit -q --allow-empty -m init
  wt="$TMP_ROOT/cleanup-orphan-wt"
  git -C "$clone" worktree add -q -b fm/orphan "$wt" >/dev/null 2>&1
  backdate "$wt" 200000

  out=$(run_cleanup "$home" FM_CLEANUP_TMP_ROOT="$TMP_ROOT/no-such-tmp")
  assert_contains "$out" "outlived its task" "an orphan isolated copy must be reported"
  assert_contains "$out" "nothing was removed" "the headline must say nothing was removed"
  assert_present "$wt" "cleanup must never remove an isolated copy itself"
  assert_grep "bin/fm-teardown.sh" "$home/state/.hourly-cleanup.latest" "the report must point at the owner of the landed-work test"

  out=$(run_cleanup "$home" FM_CLEANUP_TMP_ROOT="$TMP_ROOT/no-such-tmp")
  [ -z "$out" ] || fail "an unchanged cleanup candidate must not surface again, got: $out"
  pass "cleanup reports an orphan copy once and never removes it"
}

# --- cleanup: reports a leftover per-task temp root ----------------------------
t_cleanup_reports_tasktmp() {
  local home tmproot out
  home=$(new_home cleanup-tasktmp)
  tmproot="$TMP_ROOT/cleanup-tasktmp-root"
  mkdir -p "$tmproot/fm-epsilon/gotmp"
  backdate "$tmproot/fm-epsilon" 200000

  out=$(run_cleanup "$home" FM_CLEANUP_TMP_ROOT="$tmproot")
  assert_contains "$out" "leftover build temp for epsilon" "a leftover per-task temp root must be reported"
  assert_present "$tmproot/fm-epsilon" "cleanup must not remove a per-task temp root itself"
  pass "cleanup reports a leftover per-task temp root without removing it"
}

# --- arming ---------------------------------------------------------------------
t_session_start_arms() {
  local home root out holder_pid
  home=$(new_home arm-home)
  root="$TMP_ROOT/arm-root"
  mkdir -p "$root"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init

  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$SESSION_START")
  assert_contains "$out" "HOURLY PASSES" "session start must report the hourly passes"
  assert_contains "$out" "armed:" "session start must arm the hourly passes when it holds the lock"
  assert_present "$home/state/.hourly-armed" "arming must write the durable armed marker"
  assert_present "$home/state/.last-hourly-review" "arming must stamp the review cadence"
  assert_present "$home/state/.last-hourly-cleanup" "arming must stamp the cleanup cadence"
  pass "session start arms both hourly passes"
}

t_session_start_read_only_does_not_arm() {
  local home root out holder_pid
  home=$(new_home arm-readonly)
  root="$TMP_ROOT/arm-readonly-root"
  mkdir -p "$root"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  # A live process that LOOKS like a harness (bin/fm-lock.sh only honors a
  # holder whose command name matches a known harness) makes this session
  # read-only.
  printf '#!/bin/sh\nsleep 300\n' > "$TMP_ROOT/claude"
  chmod +x "$TMP_ROOT/claude"
  # Detached from this suite's stdout: an inherited pipe would keep the suite's
  # own output open until the holder's sleep expired.
  "$TMP_ROOT/claude" >/dev/null 2>&1 &
  holder_pid=$!
  printf '%s\n' "$holder_pid" > "$home/state/.lock"

  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$SESSION_START")
  pkill -P "$holder_pid" 2>/dev/null || true
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  assert_contains "$out" "skipped (read-only session)" "a read-only session must not arm the hourly passes"
  assert_absent "$home/state/.hourly-armed" "a read-only session must not write the armed marker"
  pass "a read-only session leaves arming to the session holding the lock"
}

t_unarmed_home_never_runs_a_pass() {
  local home out pid
  home=$(new_home unarmed)
  fm_write_meta "$home/state/zeta.meta" "window=firstmate:fm-zeta" "kind=ship"
  printf 'needs-decision: something old\n' > "$home/state/zeta.status"
  backdate "$home/state/zeta.status" 200000
  out="$TMP_ROOT/unarmed.out"

  FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  sleep 3
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_not_contains "$(cat "$out")" "check: session-" "an unarmed home must never run an hourly pass"
  pass "an unarmed home never runs an hourly pass"
}

# --- watcher wiring -------------------------------------------------------------
# The real watcher, one poll: a due, armed review pass wakes exactly once with a
# "check: session-review" record and the process EXITS. Nothing is backgrounded
# and no watcher is armed by the pass, so the single supervision cycle stays
# single.
t_watcher_runs_due_pass_and_exits() {
  local home out pid waited queue
  home=$(new_home watch-armed)
  fm_write_meta "$home/state/eta.meta" "window=firstmate:fm-eta" "kind=ship"
  printf 'needs-decision: which base branch\n' > "$home/state/eta.status"
  backdate "$home/state/eta.status" 200000
  touch "$home/state/.hourly-armed"
  : > "$home/state/.last-hourly-review"
  backdate "$home/state/.last-hourly-review" 7200
  : > "$home/state/.last-hourly-cleanup"
  out="$TMP_ROOT/watch-armed.out"

  FM_STATE_OVERRIDE="$home/state" FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_HOURLY_CLEANUP_INTERVAL=999999 \
    "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 30 ]; do
    sleep 1
    waited=$(( waited + 1 ))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "the watcher must EXIT after reporting an hourly-pass wake, it was still running"
  fi
  wait "$pid" 2>/dev/null || true

  assert_contains "$(cat "$out")" "check: session-review" "a due review pass must wake the watcher"
  queue=$(cat "$home/state/.wake-queue" 2>/dev/null || printf '')
  assert_contains "$queue" "session-review" "the wake must be recorded durably in the wake queue"
  pass "the watcher runs a due hourly pass, wakes once, and exits"
}

# --- structural: no second supervision cycle ------------------------------------
# A behavioral test proves the watcher exits; this proves the passes themselves
# cannot start a rival cycle - they never arm a watcher, never background a
# process, and never spawn a daemon.
t_passes_start_nothing() {
  local f
  for f in "$ROOT/bin/fm-session-review.sh" "$ROOT/bin/fm-cleanup-sweep.sh" "$ROOT/bin/fm-hourly-lib.sh"; do
    assert_no_grep "fm-watch-arm.sh" "$f" "$(basename "$f") must never arm a watcher"
    assert_no_grep "fm-supervise-daemon.sh" "$f" "$(basename "$f") must never start the supervision daemon"
    assert_no_grep "nohup" "$f" "$(basename "$f") must never background a process"
  done
  assert_no_grep "fm-teardown.sh\"" "$ROOT/bin/fm-cleanup-sweep.sh" "the cleanup pass must never run a teardown"
  pass "the hourly passes start no rival supervision cycle and run no teardown"
}

t_review_silent_when_clean
t_review_aging_decision
t_review_silent_worker
t_review_idle_capacity
t_review_merge_batch
t_cleanup_reclaims_quietly
t_cleanup_keeps_markers_in_flight
t_cleanup_reports_orphan_worktree
t_cleanup_reports_tasktmp
t_session_start_arms
t_session_start_read_only_does_not_arm
t_unarmed_home_never_runs_a_pass
t_watcher_runs_due_pass_and_exits
t_passes_start_nothing
