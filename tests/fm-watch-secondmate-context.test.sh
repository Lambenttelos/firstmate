#!/usr/bin/env bash
# tests/fm-watch-secondmate-context.test.sh - the watcher's slow-poll secondmate
# context monitor (secondmate_context_sweep in bin/fm-watch.sh) across its two
# modes: the default escalate-only WAKE and the opt-in AUTOMATIC handoff.
#
# Contract pinned here (the seven invariants of the auto-handoff brief):
#   1. Fail closed on an unknown context: no wake, no launch, no marker.
#   2. AUTO DISABLED (default, config/secondmate-auto-handoff absent): a crossing
#      wakes the primary once with `check: secondmate-context <id>` and sets the
#      marker - today's behavior, unchanged.
#   3. AUTO ENABLED + IDLE: a crossing launches the detached handoff wrapper
#      (proven via a stub), sets the marker, and does NOT wake the primary to
#      start it. The FYI is the wrapper's job (fm-secondmate-auto-handoff.test.sh).
#   4. AUTO ENABLED + BUSY: never fire mid-turn - no launch, no wake, and the
#      marker is left UNSET so the crossing re-evaluates next poll.
#   5. Idempotency: a set marker suppresses a second launch/wake.
#   6. Re-arm: the marker clears once the count drops back under threshold.
#
# The sweep launches the wrapper as "$SCRIPT_DIR/fm-secondmate-auto-handoff.sh".
# Reassigning SCRIPT_DIR to a stub bin AFTER sourcing (the only sweep use of
# SCRIPT_DIR) makes the launch deterministic and side-effect-free: the stub just
# records that it ran, so no live backend or real handoff is needed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
assert_present "$WATCH" "bin/fm-watch.sh is missing"

TMP_ROOT=$(fm_test_tmproot fm-watch-secondmate-context)
mkdir -p "$TMP_ROOT"

# A stub wrapper that records each invocation's id, so a launch is observable.
STUB_BIN="$TMP_ROOT/stubbin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/fm-secondmate-auto-handoff.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$TMP_ROOT/launched"
EOF
chmod +x "$STUB_BIN/fm-secondmate-auto-handoff.sh"

# setup_case: a hermetic home with one secondmate meta (window=test:fm-sm,
# tmux backend so window_is_busy uses the pane-tail regex) and a claude
# transcript giving fm_sm_context_tokens a controllable count. Echoes
# "<state> <config> <home>".
setup_case() {  # <name> <tokens|-> [auto:0|1]
  local name=$1 tokens=$2 auto=${3:-0} dir state config home tdir
  dir="$TMP_ROOT/$name"
  state="$dir/state"; config="$dir/config"; home="$dir/home"
  mkdir -p "$state" "$config" "$home/data"
  cat > "$state/sm.meta" <<EOF
window=test:fm-sm
worktree=$home
harness=claude
kind=secondmate
home=$home
EOF
  [ "$auto" = 1 ] && : > "$config/secondmate-auto-handoff"
  if [ "$tokens" != - ]; then
    tdir="$config/projects/$(printf '%s' "$home" | tr '/.' '--')"
    mkdir -p "$tdir"
    printf '{"type":"assistant","message":{"usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' "$tokens" > "$tdir/s.jsonl"
  fi
  printf '%s %s %s\n' "$state" "$config" "$home"
}

# run_sweep: source the watcher (guard returns before lock/loop), stub the
# per-window busy read and the recorded-window list to the single test window,
# point SCRIPT_DIR at the stub bin, then call the sweep. wake() exits 0 after
# printing its reason; a non-waking path returns and we echo NOWAKE.
# <busy> = 1 forces window_is_busy true (mid-turn), else idle.
run_sweep() {  # <state> <config> <home> <busy:0|1> [expect_launch:0|1]
  local state=$1 config=$2 home=$3 busy=$4 expect=${5:-0}
  rm -f "$TMP_ROOT/launched"
  # shellcheck disable=SC2016  # WATCH/STUB_BIN/BUSYFLAG expand in the inner bash -c, not here.
  OUT=$(env FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$config" FM_HOME="$home" \
    CLAUDE_CONFIG_DIR="$config" \
    FM_WAKE_QUEUE="$state/.wake-queue" FM_WAKE_QUEUE_LOCK="$state/.wake-queue.lock" \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_POLL=1 \
    STUB_BIN="$STUB_BIN" BUSYFLAG="$busy" WATCH="$WATCH" \
    bash -c '
      . "$WATCH" >/dev/null 2>&1
      SCRIPT_DIR="$STUB_BIN"
      recorded_windows() { printf "%s\n" "test:fm-sm"; }
      window_is_busy() { [ "$BUSYFLAG" = 1 ]; }
      secondmate_context_sweep
      echo NOWAKE
    ' 2>&1)
  # The auto-launch is detached (disowned); when a launch is EXPECTED, poll
  # briefly for its sentinel. When none is expected, a short settle catches a
  # wrongful launch without paying the full poll on every no-launch case.
  local i=0 cap=50
  [ "$expect" = 1 ] || cap=3
  while [ ! -f "$TMP_ROOT/launched" ] && [ "$i" -lt "$cap" ]; do
    sleep 0.1; i=$((i + 1))
  done
}

queue_count() {  # <state>
  local state=$1 q; q="$state/.wake-queue"
  [ -f "$q" ] || { printf '0'; return; }
  grep -c 'secondmate-context' "$q" 2>/dev/null || printf '0'
}
marker() { printf '%s/.sm-context-surfaced-test_fm-sm' "$1"; }
launched_count() { [ -f "$TMP_ROOT/launched" ] && wc -l < "$TMP_ROOT/launched" | tr -d ' ' || printf '0'; }

test_fail_closed_unknown() {
  local state config home
  read -r state config home <<<"$(setup_case failclosed - 1)"
  run_sweep "$state" "$config" "$home" 0
  assert_contains "$OUT" "NOWAKE" "an unknown context must not wake"
  [ "$(launched_count)" -eq 0 ] || fail "an unknown context must launch no handoff"
  [ -e "$(marker "$state")" ] && fail "an unknown context must set no marker (fail closed)"
  pass "unknown context: no wake, no launch, no marker (fail closed)"
}

test_auto_disabled_wakes() {
  local state config home
  read -r state config home <<<"$(setup_case disabled 260000 0)"
  run_sweep "$state" "$config" "$home" 0
  assert_contains "$OUT" "check: secondmate-context sm" "auto-disabled must wake the primary"
  [ "$(queue_count "$state")" -eq 1 ] || fail "auto-disabled crossing must enqueue one wake"
  [ "$(launched_count)" -eq 0 ] || fail "auto-disabled must NOT auto-launch a handoff"
  [ -e "$(marker "$state")" ] || fail "auto-disabled crossing must set the marker"
  pass "auto disabled (default): a crossing wakes once and does not auto-launch"
}

test_auto_enabled_idle_launches() {
  local state config home
  read -r state config home <<<"$(setup_case autoidle 260000 1)"
  run_sweep "$state" "$config" "$home" 0 1
  assert_contains "$OUT" "NOWAKE" "auto-enabled must NOT wake the primary to start the handoff"
  case "$OUT" in *"check: secondmate-context"*) fail "auto-enabled must not enqueue the escalate wake reason" ;; esac
  [ "$(launched_count)" -eq 1 ] || fail "auto-enabled + idle must launch the handoff exactly once"
  [ "$(head -1 "$TMP_ROOT/launched")" = sm ] || fail "the launch must name the secondmate id"
  [ -e "$(marker "$state")" ] || fail "auto-enabled launch must set the marker"
  pass "auto enabled + idle: launches the detached handoff once, no primary wake, marker set"
}

test_auto_enabled_busy_defers() {
  local state config home
  read -r state config home <<<"$(setup_case autobusy 260000 1)"
  run_sweep "$state" "$config" "$home" 1
  assert_contains "$OUT" "NOWAKE" "a busy secondmate must not wake"
  [ "$(launched_count)" -eq 0 ] || fail "a busy secondmate must NOT be handed off (never mid-turn)"
  [ -e "$(marker "$state")" ] && fail "deferring a busy secondmate must leave the marker UNSET so it re-evaluates"
  pass "auto enabled + busy: deferred (no launch, no wake, marker unset so it re-evaluates)"
}

test_idempotent_marker() {
  local state config home
  read -r state config home <<<"$(setup_case idem 260000 1)"
  run_sweep "$state" "$config" "$home" 0 1
  [ "$(launched_count)" -eq 1 ] || fail "first crossing should launch once"
  # Second poll, still over threshold, marker present: no second launch.
  run_sweep "$state" "$config" "$home" 0
  [ "$(launched_count)" -eq 0 ] || fail "a still-over-threshold second poll must not re-launch (marker dedupes)"
  pass "a set marker suppresses a second auto-launch (idempotent)"
}

test_rearm_after_drop() {
  local state config home tdir
  read -r state config home <<<"$(setup_case rearm 260000 1)"
  run_sweep "$state" "$config" "$home" 0 1
  [ -e "$(marker "$state")" ] || fail "first crossing should set the marker"
  # Fresh post-handoff agent drops under threshold: the marker must clear.
  tdir="$config/projects/$(printf '%s' "$home" | tr '/.' '--')"
  printf '{"type":"assistant","message":{"usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' > "$tdir/s.jsonl"
  run_sweep "$state" "$config" "$home" 0
  [ -e "$(marker "$state")" ] && fail "dropping under threshold must clear the marker (re-arm)"
  pass "the marker clears once the count drops back under threshold (re-arm)"
}

test_fail_closed_unknown
test_auto_disabled_wakes
test_auto_enabled_idle_launches
test_auto_enabled_busy_defers
test_idempotent_marker
test_rearm_after_drop

echo "# all fm-watch-secondmate-context tests passed"
