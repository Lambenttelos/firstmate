#!/usr/bin/env bash
# tests/fm-afk-inbox-arm-singleton.test.sh - the per-home SINGLETON guarantee of
# the away-mode reader arm wrapper (bin/fm-afk-inbox-arm.sh).
#
# The wrapper is what firstmate arms as its tracked background task, and on a
# paneless away home the reader it holds IS the delivery channel. A re-arm from a
# fresh session must leave exactly ONE live reader for this home: a stale reader
# or wrapper from a dead session that keeps running acknowledges the outbox to a
# stdout nobody reads, silently swallowing the captain's escalations (evidence
# 2026-08-06: three stale fm-afk-inbox.sh readers acked the outbox while the
# captain got no wakes). This suite asserts the guard the wrapper adds:
#   - arming with a pre-existing LIVE wrapper retires it and leaves exactly one;
#   - arming with NO pre-existing reader just arms one;
#   - a DEAD/stale arm-lock record is reclaimed, not treated as a live holder;
#   - the retire is home-scoped and can NEVER signal another home's wrapper.
#
# The wrapper resolves its reader as a sibling of its own script path, so every
# case that must exercise the resident loop runs a COPY of the wrapper placed
# next to a controllable reader stand-in (the same technique the crash-loop case
# in tests/fm-afk-inbox-arm.test.sh uses).
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-afk-inbox-arm-singleton-tests)

enter_away() {  # <state>
  date +%s > "$1/.afk"
}

# Build a private bin dir holding a COPY of the wrapper next to a reader
# stand-in, so SCRIPT_DIR resolution runs the real wrapper against a reader we
# control. <reader-body> is the bash body of the fake fm-afk-inbox.sh.
make_wrapper_copy() {  # <name> <reader-body> -> bindir
  local name=$1 body=$2 bindir
  bindir="$TMP_ROOT/$name/bin"
  mkdir -p "$bindir"
  ln -s "$ROOT/bin"/*.sh "$bindir/" 2>/dev/null || true
  rm -f "$bindir/fm-afk-inbox.sh" "$bindir/fm-afk-inbox-arm.sh"
  cp "$ROOT/bin/fm-afk-inbox-arm.sh" "$bindir/fm-afk-inbox-arm.sh"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$bindir/fm-afk-inbox.sh"
  chmod +x "$bindir/fm-afk-inbox.sh"
  printf '%s\n' "$bindir"
}

wait_pid_exit() {  # <pid> [tenths]
  local pid=$1 limit=${2:-200} i=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge "$limit" ]; then
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.1
    i=$((i + 1))
  done
  wait "$pid" 2>/dev/null
  return 0
}

# Wait until a pid is no longer alive, reaping it if it is our child. Returns 0
# once gone, 1 if it never exited within the bound. Deliberately ignores the
# exit STATUS (a wrapper stopped by SIGTERM exits 143, which is a success here).
wait_gone() {  # <pid> [tenths]
  local pid=$1 limit=${2:-200} i=0
  while kill -0 "$pid" 2>/dev/null; do
    [ "$i" -lt "$limit" ] || return 1
    sleep 0.1
    i=$((i + 1))
  done
  wait "$pid" 2>/dev/null || true
  return 0
}

# Wait until a reader stand-in has started, signalled by a reader-started.* marker
# it drops in the state dir. Re-globs every iteration (an unmatched glob passed as
# an argument would never re-expand inside the loop).
wait_for_reader_start() {  # <state> [tenths]
  local state=$1 limit=${2:-200} i=0
  while :; do
    set -- "$state"/reader-started.*
    [ -e "$1" ] && return 0
    [ "$i" -lt "$limit" ] || return 1
    sleep 0.1
    i=$((i + 1))
  done
}

# Count live processes whose recorded reader-record pid file names a running
# process. Used to assert exactly one reader survives.
reader_record_pid() {  # <state>
  cat "$1/.afk-inbox-reader.pid" 2>/dev/null || true
}

# A reader stand-in that never idle-exits and never prints a verdict, so the
# resident wrapper stays blocked on it exactly as it does on the real resident
# reader. It marks a file when it starts so the test can wait for it, and exits
# cleanly on TERM.
# shellcheck disable=SC2016 # This is a reader BODY; $vars must expand at run time, not here.
RESIDENT_READER_BODY='
touch "$FM_STATE_OVERRIDE/reader-started.$$"
trap "exit 0" TERM INT
while :; do sleep 0.2; done
'

# (1) Arming with a pre-existing LIVE wrapper retires it and leaves exactly one
# live reader. The old wrapper is holding a resident reader; the new arm must
# stop the old wrapper (its trap tears down its reader) and end up the sole
# holder of the arm lock with its own single reader.
test_arming_retires_a_live_predecessor_and_leaves_one() {
  local bindir state old_pid old_reader new_pid new_reader lock_pid
  bindir=$(make_wrapper_copy live-predecessor "$RESIDENT_READER_BODY")
  state="$TMP_ROOT/live-predecessor/state"
  mkdir -p "$state"
  enter_away "$state"

  # Arm the first wrapper; wait until its reader is genuinely running.
  FM_STATE_OVERRIDE="$state" FM_HOME="$state" "$bindir/fm-afk-inbox-arm.sh" \
    > "$state/old.out" 2>&1 &
  old_pid=$!
  wait_for_reader_start "$state" 100 \
    || fail "the first wrapper never started its reader: $(cat "$state/old.out" 2>/dev/null)"
  old_reader=$(reader_record_pid "$state")
  [ -n "$old_reader" ] || fail "the first wrapper recorded no reader pid"
  kill -0 "$old_reader" 2>/dev/null || fail "the first wrapper's reader is not running"
  lock_pid=$(cat "$state/.afk-inbox-arm.lock/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$old_pid" ] || fail "the arm lock does not name the first wrapper (got '$lock_pid', want $old_pid)"

  # Arm a second wrapper. It must retire the first (whose trap kills its reader)
  # and become the sole holder with its own reader.
  rm -f "$state"/reader-started.*
  FM_STATE_OVERRIDE="$state" FM_HOME="$state" "$bindir/fm-afk-inbox-arm.sh" \
    > "$state/new.out" 2>&1 &
  new_pid=$!
  wait_for_reader_start "$state" 200 \
    || fail "the second wrapper never started its reader: $(cat "$state/new.out" 2>/dev/null)"

  # The first wrapper must be gone, and so must its reader.
  wait_gone "$old_pid" 200 || fail "the first wrapper did not exit when the second armed"
  kill -0 "$old_reader" 2>/dev/null && fail "the retired wrapper's reader is still running"

  # Exactly one live reader remains, and it is the new wrapper's.
  new_reader=$(reader_record_pid "$state")
  [ -n "$new_reader" ] || fail "the second wrapper recorded no reader pid"
  [ "$new_reader" != "$old_reader" ] || fail "the second wrapper reused the retired reader pid record"
  kill -0 "$new_reader" 2>/dev/null || fail "the surviving reader is not running"
  lock_pid=$(cat "$state/.afk-inbox-arm.lock/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$new_pid" ] || fail "the arm lock does not name the surviving wrapper (got '$lock_pid', want $new_pid)"

  kill -TERM "$new_pid" 2>/dev/null || true
  wait_pid_exit "$new_pid" 200
  kill -0 "$new_reader" 2>/dev/null && fail "the surviving reader outlived its wrapper"
  pass "arming with a live predecessor retires it and leaves exactly one live reader"
}

# (2) Arming with NO pre-existing reader just arms one and holds the lock.
test_arming_with_no_predecessor_just_arms_one() {
  local bindir state pid reader lock_pid
  bindir=$(make_wrapper_copy no-predecessor "$RESIDENT_READER_BODY")
  state="$TMP_ROOT/no-predecessor/state"
  mkdir -p "$state"
  enter_away "$state"

  [ ! -e "$state/.afk-inbox-arm.lock" ] || fail "an arm lock existed before any wrapper armed"

  FM_STATE_OVERRIDE="$state" FM_HOME="$state" "$bindir/fm-afk-inbox-arm.sh" \
    > "$state/out" 2>&1 &
  pid=$!
  wait_for_reader_start "$state" 200 \
    || fail "the wrapper never started its reader: $(cat "$state/out" 2>/dev/null)"

  reader=$(reader_record_pid "$state")
  [ -n "$reader" ] || fail "the wrapper recorded no reader pid"
  kill -0 "$reader" 2>/dev/null || fail "the wrapper's reader is not running"
  lock_pid=$(cat "$state/.afk-inbox-arm.lock/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$pid" ] || fail "the arm lock does not name the wrapper (got '$lock_pid', want $pid)"

  kill -TERM "$pid" 2>/dev/null || true
  wait_pid_exit "$pid" 200
  # The lock is released on exit so the next arm is not blocked by a ghost.
  [ ! -e "$state/.afk-inbox-arm.lock" ] || fail "the arm lock survived the wrapper's clean exit"
  pass "arming with no predecessor arms exactly one reader and releases the lock on exit"
}

# (3) A DEAD/stale arm-lock record (a wrapper whose process is gone, e.g. a
# SIGKILL that skipped the trap) must be reclaimed, not mistaken for a live
# holder that blocks the arm. A stale ORPHAN reader record must also be retired.
test_a_dead_arm_lock_is_reclaimed_and_a_stale_orphan_reader_is_retired() {
  local bindir state stale_reader lock_owner pid reader
  bindir=$(make_wrapper_copy dead-lock "$RESIDENT_READER_BODY")
  state="$TMP_ROOT/dead-lock/state"
  mkdir -p "$state"
  enter_away "$state"

  # Forge a stale arm lock whose recorded holder pid is a never-used, dead pid.
  # The mutex must reclaim it rather than see a live holder.
  lock_owner="$state/.afk-inbox-arm.lock.owner.stale"
  mkdir -p "$lock_owner"
  printf '999999\n' > "$lock_owner/pid"
  printf '%s\n' "$state" > "$lock_owner/fm-home"
  ln -s "$lock_owner" "$state/.afk-inbox-arm.lock"

  # Forge a stale ORPHAN reader that IS still running (a real sleeper), recorded
  # in the sidecar with its true identity, as a wrapper killed hard would leave.
  sleep 120 &
  stale_reader=$!
  printf '%s\n' "$stale_reader" > "$state/.afk-inbox-reader.pid"
  FM_HOME="$state" bash -c '
    . "'"$ROOT"'/bin/fm-pid-lib.sh"
    fm_pid_identity "'"$stale_reader"'"
  ' > "$state/.afk-inbox-reader.id" 2>/dev/null || true

  FM_STATE_OVERRIDE="$state" FM_HOME="$state" "$bindir/fm-afk-inbox-arm.sh" \
    > "$state/out" 2>&1 &
  pid=$!
  wait_for_reader_start "$state" 200 \
    || fail "the wrapper did not arm past the stale lock: $(cat "$state/out" 2>/dev/null)"

  # The stale orphan reader must have been retired.
  wait_pid_exit "$stale_reader" 100
  kill -0 "$stale_reader" 2>/dev/null && fail "the stale orphan reader survived the fresh arm"

  # The fresh wrapper owns the lock and has its own reader.
  reader=$(reader_record_pid "$state")
  [ "$reader" != "$stale_reader" ] || fail "the sidecar still names the retired orphan reader"
  kill -0 "$reader" 2>/dev/null || fail "the fresh reader is not running"

  kill -TERM "$pid" 2>/dev/null || true
  wait_pid_exit "$pid" 200
  pass "a dead arm-lock record is reclaimed and a stale orphan reader is retired"
}

# (4) The retire is home-scoped: a wrapper arming in one home must NEVER touch a
# wrapper (or reader) belonging to another home, even though both use the same
# script and the same lock filename under their OWN state dirs. Forge another
# home's arm-lock naming a live process and confirm the fresh arm in THIS home
# leaves it untouched.
test_retire_never_signals_another_homes_reader() {
  local bindir state other_state other_reader other_lock_owner pid
  bindir=$(make_wrapper_copy home-scoped "$RESIDENT_READER_BODY")
  state="$TMP_ROOT/home-scoped/state"
  other_state="$TMP_ROOT/home-scoped/other-state"
  mkdir -p "$state" "$other_state"
  enter_away "$state"

  # Another home's live wrapper, represented by a real running process recorded
  # as that OTHER home's arm-lock holder with a matching identity.
  sleep 120 &
  other_reader=$!
  other_lock_owner="$other_state/.afk-inbox-arm.lock.owner.live"
  mkdir -p "$other_lock_owner"
  printf '%s\n' "$other_reader" > "$other_lock_owner/pid"
  printf '%s\n' "$other_state" > "$other_lock_owner/fm-home"
  bash -c '
    . "'"$ROOT"'/bin/fm-pid-lib.sh"
    fm_pid_identity "'"$other_reader"'"
  ' > "$other_lock_owner/pid-identity" 2>/dev/null || true
  ln -s "$other_lock_owner" "$other_state/.afk-inbox-arm.lock"

  FM_STATE_OVERRIDE="$state" FM_HOME="$state" "$bindir/fm-afk-inbox-arm.sh" \
    > "$state/out" 2>&1 &
  pid=$!
  wait_for_reader_start "$state" 200 \
    || fail "the wrapper never armed in its own home: $(cat "$state/out" 2>/dev/null)"

  # The other home's process must be completely untouched.
  kill -0 "$other_reader" 2>/dev/null || fail "the fresh arm signalled another home's wrapper"
  [ -L "$other_state/.afk-inbox-arm.lock" ] || fail "the fresh arm disturbed another home's arm lock"

  kill -TERM "$pid" 2>/dev/null || true
  wait_pid_exit "$pid" 200
  kill "$other_reader" 2>/dev/null || true
  wait "$other_reader" 2>/dev/null || true
  pass "the retire is home-scoped and never signals another home's wrapper or reader"
}

test_arming_retires_a_live_predecessor_and_leaves_one
test_arming_with_no_predecessor_just_arms_one
test_a_dead_arm_lock_is_reclaimed_and_a_stale_orphan_reader_is_retired
test_retire_never_signals_another_homes_reader
