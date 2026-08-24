#!/usr/bin/env bash
# tests/fm-watch-drift.test.sh - the watcher's heartbeat model/effort drift watch
# for live jcode lanes (jcode_drift_sweep in bin/fm-watch.sh, task
# spawn-model-verify-enforce, incident 2026-08-23, data/learnings.md "MODEL
# DRIFT INCIDENT"). The jcode session store is the only truth for what a session
# runs, and a silently-lost /model|/effort or a later in-session switch must
# surface.
#
# Contract pinned here:
#   1. A live jcode task whose store profile disagrees with the meta profile
#      (last-write-wins: the CONFIRMED stamps fm-spawn appends after a verified
#      apply) wakes once with `check: model-drift <id> wanted=<m>/<e>
#      actual=<m>/<e>`.
#   2. Idempotency: the same drift signature does not re-wake on the next sweep.
#   3. Re-arm: the marker clears when the store comes back to the recorded
#      profile, so a fresh drift wakes again.
#   4. Fail closed: a non-jcode harness, a supervise=off pane, an unrequested
#      (default) axis, an unresolvable session id, or an unreadable store never
#      wakes and never guesses.
#   5. A meta without a recorded session_id falls back to the newest store
#      session matching the meta worktree (fm_resolve_crew_session_id).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
assert_present "$WATCH" "bin/fm-watch.sh is missing"

TMP_ROOT=$(fm_test_tmproot fm-watch-drift)
mkdir -p "$TMP_ROOT"

# setup_case: a hermetic home with one jcode task meta and a fake jcode session
# store the real resolver + store reader run against. Echoes "<state> <sessions>".
setup_case() {  # <name> <store-model|-> <store-effort|-> [session_id:worktree|none] [extra-meta-line]
  local name=$1 smodel=$2 seffort=$3 sid=${4:-session_a} extra=${5:-}
  local dir state sessions
  dir="$TMP_ROOT/$name"; state="$dir/state"; sessions="$dir/sessions"
  mkdir -p "$state" "$sessions"
  local model_meta effort_meta sid_line
  model_meta="model=deepseek-v4-flash"
  effort_meta="effort=high"
  if [ "$sid" = none ]; then
    sid_line=""
  else
    sid_line="session_id=$sid"
  fi
  {
    echo "window=test:p1"
    echo "worktree=$dir/work"
    echo "harness=jcode"
    echo "kind=ship"
    echo "$model_meta"
    echo "$effort_meta"
    [ -z "$sid_line" ] || echo "$sid_line"
    [ -z "$extra" ] || echo "$extra"
  } > "$state/job.meta"
  mkdir -p "$dir/work"
  if [ "$smodel" != - ]; then
    local mval efield
    mval=$smodel
    if [ "$seffort" = - ]; then
      # A "-" effort means the store omits the reasoning_effort field entirely.
      cat > "$sessions/session_a.json" <<EOF
{"id":"session_a","model":"$mval","working_dir":"$dir/work","created_at":"2026-08-23T00:00:00Z"}
EOF
    else
      [ "$seffort" = null ] && efield=null || efield="\"$seffort\""
      cat > "$sessions/session_a.json" <<EOF
{"id":"session_a","model":"$mval","reasoning_effort":$efield,"working_dir":"$dir/work","created_at":"2026-08-23T00:00:00Z"}
EOF
    fi
  fi
  printf '%s %s\n' "$state" "$sessions"
}

# run_sweep: source the watcher (guard returns before lock/loop) and call the
# drift sweep. wake() exits 0 after printing its reason; a quiet sweep returns
# and we echo NOWAKE.
run_sweep() {  # <state> <sessions>
  local state=$1 sessions=$2
  # shellcheck disable=SC2016  # WATCH/SESS expand in the inner bash -c, not here.
  OUT=$(env FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$state/config" FM_HOME="$state" \
    JCODE_SESSIONS_DIR="$sessions" \
    FM_WAKE_QUEUE="$state/.wake-queue" FM_WAKE_QUEUE_LOCK="$state/.wake-queue.lock" \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_POLL=1 \
    WATCH="$WATCH" \
    bash -c '
      . "$WATCH" >/dev/null 2>&1
      jcode_drift_sweep
      echo NOWAKE
    ' 2>&1)
  printf '%s' "$OUT"
}

wake_seen() {  # <out>
  case "$1" in
    *"check: model-drift job"*) return 0 ;;
  esac
  return 1
}

queued_wake() {  # <state> [<substring>]
  local state=$1 needle=${2:-model-drift}
  grep -q "$needle" "$state/.wake-queue" 2>/dev/null
}

test_drift_wakes_once_and_rearms() {
  # A live jcode lane whose store shows a different profile wakes firstmate
  # once; the same signature is quiet on the next sweep; a store that heals to
  # the recorded profile clears the marker silently.
  state_and_sessions=$(setup_case drift claude-opus-4-8 max)
  state=${state_and_sessions%% *}
  sessions=${state_and_sessions#* }
  out=$(run_sweep "$state" "$sessions")
  wake_seen "$out" || fail "a store/meta mismatch must wake with check: model-drift; out: $out"
  case "$out" in
    *"check: model-drift job wanted=deepseek-v4-flash/high actual=claude-opus-4-8/max"*) : ;;
    *) fail "the drift wake must carry the wanted and actual profiles; out: $out" ;;
  esac
  queued_wake "$state" || fail "the drift wake must be enqueued in the wake queue"
  [ -e "$state/.drift-surfaced-job" ] \
    || fail "the drift marker must be written so the wake does not re-fire"
  # Same drift on the next sweep: absorbed, no second wake.
  out=$(run_sweep "$state" "$sessions")
  [ "$out" = NOWAKE ] || fail "the same drift signature must not re-wake; out: $out"
  # Store heals to the recorded profile: silent, marker cleared.
  cat > "$sessions/session_a.json" <<EOF
{"id":"session_a","model":"deepseek-v4-flash","reasoning_effort":"high","working_dir":"$TMP_ROOT/drift/work","created_at":"2026-08-23T00:00:00Z"}
EOF
  out=$(run_sweep "$state" "$sessions")
  [ "$out" = NOWAKE ] || fail "a healed store must stay quiet; out: $out"
  [ ! -e "$state/.drift-surfaced-job" ] || fail "the marker must clear when the store matches"
  pass "a drifted jcode lane wakes once with the wanted/actual profile and re-arms on heal"
}

test_drift_rearms_on_new_signature() {
  # After a wake and a marker, a DIFFERENT wrong store value is a new drift
  # signature and wakes again.
  state_and_sessions=$(setup_case resign claude-opus-4-8 max)
  state=${state_and_sessions%% *}
  sessions=${state_and_sessions#* }
  out=$(run_sweep "$state" "$sessions")
  wake_seen "$out" || fail "first drift must wake; out: $out"
  cat > "$sessions/session_a.json" <<EOF
{"id":"session_a","model":"deepseek-v4-flash","reasoning_effort":"xhigh","working_dir":"$TMP_ROOT/resign/work","created_at":"2026-08-23T00:00:00Z"}
EOF
  out=$(run_sweep "$state" "$sessions")
  case "$out" in
    *"check: model-drift job wanted=deepseek-v4-flash/high actual=deepseek-v4-flash/xhigh"*) : ;;
    *) fail "a changed wrong store value must wake again with the new signature; out: $out" ;;
  esac
  pass "a changed drift signature (new actual) re-wakes firstmate"
}

test_non_jcode_and_hands_off_skipped() {
  # A claude lane and a supervise=off jcode lane are never drift-checked, even
  # with a store that disagrees: no wake, no marker.
  for extra in "supervise=off" "harness=claude"; do
    if [ "$extra" = "harness=claude" ]; then
      state_and_sessions=$(setup_case nonjcode claude-opus-4-8 max session_a "$extra")
    else
      state_and_sessions=$(setup_case handsf claude-opus-4-8 max session_a "$extra")
    fi
    state=${state_and_sessions%% *}
    sessions=${state_and_sessions#* }
    out=$(run_sweep "$state" "$sessions")
    [ "$out" = NOWAKE ] || fail "a non-drift-checked lane must stay quiet ($extra); out: $out"
  done
  pass "non-jcode harnesses and supervise=off panes are never drift-checked"
}

test_unrequested_axis_not_enforced() {
  # A meta whose only requested axis verifies must not block on the other axis:
  # with model=default, only the effort axis is enforced.
  state_and_sessions=$(setup_case defaultaxis claude-opus-4-8 max session_a "effort=low")
  state=${state_and_sessions%% *}
  sessions=${state_and_sessions#* }
  sed -i 's/^model=deepseek-v4-flash$/model=default/' "$state/job.meta"
  sed -i 's/^effort=high$/effort=low/' "$state/job.meta"
  out=$(run_sweep "$state" "$sessions")
  case "$out" in
    *"check: model-drift job wanted=-/low actual=claude-opus-4-8/max"*) : ;;
    *) fail "only the requested effort axis may be enforced; out: $out" ;;
  esac
  pass "an unrequested axis is never enforced; only requested axes drift-check"
}

test_default_profile_skipped() {
  # model=default effort=default: nothing requested, nothing checked.
  state_and_sessions=$(setup_case defaultprof claude-opus-4-8 max session_a "effort=default")
  state=${state_and_sessions%% *}
  sessions=${state_and_sessions#* }
  sed -i 's/^model=deepseek-v4-flash$/model=default/' "$state/job.meta"
  sed -i 's/^effort=high$/effort=default/' "$state/job.meta"
  out=$(run_sweep "$state" "$sessions")
  [ "$out" = NOWAKE ] || fail "a fully-default meta must never drift-check; out: $out"
  pass "a default profile meta is skipped entirely"
}

test_unreadable_store_fails_closed() {
  # No store file at all: the session cannot be read, so no wake and no guess.
  state_and_sessions=$(setup_case nostore - - session_a)
  state=${state_and_sessions%% *}
  sessions=${state_and_sessions#* }
  rm -f "$sessions"/session_*.json
  out=$(run_sweep "$state" "$sessions")
  [ "$out" = NOWAKE ] || fail "an unreadable store must stay quiet, never wake; out: $out"
  pass "an unresolvable or unreadable store is skipped, never woken"
}

test_meta_without_session_id_resolves_newest() {
  # No session_id in the meta: the sweep falls back to the newest store session
  # matching the meta worktree and still detects the drift.
  state_and_sessions=$(setup_case resolve claude-opus-4-8 max none)
  state=${state_and_sessions%% *}
  sessions=${state_and_sessions#* }
  out=$(run_sweep "$state" "$sessions")
  wake_seen "$out" || fail "the worktree fallback must resolve the session and wake; out: $out"
  pass "a meta without a session_id falls back to the worktree resolver and still wakes"
}

test_drift_wakes_once_and_rearms
test_drift_rearms_on_new_signature
test_non_jcode_and_hands_off_skipped
test_unrequested_axis_not_enforced
test_default_profile_skipped
test_unreadable_store_fails_closed
test_meta_without_session_id_resolves_newest