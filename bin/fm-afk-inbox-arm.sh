#!/usr/bin/env bash
# fm-afk-inbox-arm.sh - resilient arm wrapper for the away-mode PULL-delivery
# reader (bin/fm-afk-inbox.sh), the fm-watch-arm.sh analog for that reader.
#
# WHY THIS EXISTS. On a paneless away home the reader IS the delivery channel:
# firstmate arms it as its own harness-tracked background task, and on a
# wake-on-completion harness (claude, grok) the reader PROCESS EXITING is what
# surfaces its stdout and wakes firstmate into a turn that reads the digests.
# That couples two things that pull in opposite directions - to WAKE firstmate
# the reader must exit, but to stay ARMED it must not - so every reader exit
# leaves a window in which nothing is listening until firstmate re-arms.
#
# Two separate failure shapes made that window a real gap:
#   1. The bare reader idle-exits on its --timeout (default 3600s) with nothing
#      pending, forcing a re-arm every hour even on a completely quiet home.
#      Each of those hourly exits was a chance for the channel to be left
#      unarmed, and observed reality was a reader that kept dying silently
#      between re-arms (evidence 2026-07-30: reader ended 22:33, nine escalations
#      unread until 09:55, ~11.5 hours blind). This wrapper runs the reader
#      RESIDENT (--timeout 0), so it never idle-exits: it exits only on a real
#      delivery, a genuine do-not-re-arm condition, or an operational failure.
#      The set of re-arm points collapses from "every hour" to "every actual
#      delivery", which is the smallest it can be on a completion-wake harness.
#   2. The reader PROCESS itself dying mid-quiet-wait (killed, OOM, a crash) with
#      no verdict on its stdout. The bare reader had nothing to relaunch it until
#      the next firstmate turn. This wrapper self-relaunches it with bounded
#      backoff, absorbing a transient crash WITHOUT spending a firstmate turn,
#      and surfaces a durable degraded `check` wake only after
#      FM_AFK_INBOX_ARM_FAILURE_THRESHOLD consecutive rapid crashes - the same
#      "heal quietly, escalate loudly" shape bin/fm-present-daemon.sh uses for
#      the watcher.
#
# WHAT IT NEVER DOES. It never classifies, decides on, or swallows an
# escalation. A reader run that delivered records, or that hit an operational
# failure, or that says do-not-re-arm, is a genuine outcome firstmate must SEE:
# the wrapper prints that reader's exact stdout and EXITS with the reader's own
# status, so the harness completion notification wakes firstmate with the digests
# and the reader's re-arm verdict intact. The wrapper only loops internally on a
# reader that died WITHOUT a verdict line, which is a crash, never a delivery.
#
# This is not a substitute for the two outer safety nets, which stay in place:
# the session-start reader-liveness sweep (bin/fm-afk-reader-check.sh via
# bin/fm-bootstrap.sh) re-arms a dead channel on the next turn, and the daemon's
# paneless undelivered-escalation alarm (bin/fm-supervise-daemon.sh) wakes a
# human when records age past max-defer with a stale reader beacon.
#
# ARM IT the same way bin/fm-watch-arm.sh is armed: as the harness's OWN tracked
# background task (e.g. run_in_background), a standalone task, never bundled onto
# another command and never fired-and-forgotten with a shell `&` - that
# backgrounded child is reaped when the call returns, leaving nothing listening.
# When this wrapper's tracked task is killed (a re-arm, a turnover), its trap
# tears the reader child down with it, so no orphan reader survives to consume
# escalations to a stdout nobody reads.
#
# SINGLETON PER HOME. On arm this wrapper guarantees exactly one live reader for
# this home, reusing the shared portable mutex (bin/fm-mutex-lib.sh, via
# bin/fm-wake-lib.sh) rather than inventing a second locking scheme, the same
# primitive bin/fm-watch-arm.sh / bin/fm-watch.sh use for the watcher singleton.
# It holds this home's state/.afk-inbox-arm.lock for its whole armed lifetime.
# Before it claims that lock it RETIRES any pre-existing reader for this home, so
# a stale reader from a dead session cannot survive and keep draining the outbox
# to a stdout nobody reads (evidence 2026-08-06: three stale fm-afk-inbox.sh
# readers acknowledged the outbox while the captain got no wakes). Retiring is
# unconditional on arm, exactly like bin/fm-watch-arm.sh --restart: the fresh arm
# always wins and becomes the sole reader, whether the predecessor was live or
# stale. Two things get retired, both home-scoped, zombie/dead-pid safe (a
# Z/defunct holder counts as dead, per fm_pid_alive) and gated on a captured
# process-identity match (fm_pid_identity), so a reused pid or another home's
# reader is NEVER signalled:
#   1. A predecessor WRAPPER recorded as this home's arm-lock holder. Signalling
#      it fires its own trap, which tears down its reader child and releases the
#      lock; a wrapper killed hard (SIGKILL, its trap never ran) leaves a dead-pid
#      stale lock the mutex reclaims on the fresh claim.
#   2. An orphan READER recorded in state/.afk-inbox-reader.pid by a wrapper that
#      died WITHOUT running its trap, so no live wrapper is left to tear it down.
#      This wrapper writes that record on every reader launch and clears it on
#      exit, and it is retired directly once the fresh arm owns the lock.
# All of that state lives in this home's own state/ directory, so the retire can
# never reach a reader belonging to another firstmate home. Only the arm-lock
# holder is signalled as a wrapper and only the sidecar pid is signalled as a
# reader, both under an identity match, so nothing else on the host is touched.
#
# Usage: fm-afk-inbox-arm.sh
#   Runs in the foreground (it IS the tracked background task). Blocks until the
#   resident reader produces a genuine outcome, then prints that outcome and
#   exits with the reader's status. Relaunches the reader internally on a crash.
#
#   Reader knobs pass through unchanged: FM_AFK_INBOX_POLL,
#   FM_AFK_INBOX_LOCK_TIMEOUT_MAX. The reader timeout is FORCED to 0 (resident);
#   FM_AFK_INBOX_TIMEOUT is deliberately not honored here, because a finite
#   timeout would reintroduce the hourly idle-exit toil this wrapper removes.
#
#   Wrapper knobs:
#     FM_AFK_INBOX_ARM_RAPID_SECONDS      a reader cycle shorter than this counts
#                                         as a rapid (crash-loop) failure (default 5)
#     FM_AFK_INBOX_ARM_FAILURE_THRESHOLD  consecutive rapid crashes before a
#                                         degraded check wake is surfaced (default 5)
#     FM_AFK_INBOX_ARM_BACKOFF_BASE       backoff step per rapid failure (default 2)
#     FM_AFK_INBOX_ARM_BACKOFF_MAX        backoff ceiling in seconds (default 60)
#     FM_STATE_OVERRIDE                   alternate state dir (testing)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# The durable wake queue (for the degraded escalation) and the pid helpers.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# The outbox library owns away-mode presence and the recorded delivery mode, so
# the wrapper can stop cleanly the moment away mode ends or switches to a pane
# instead of relaunching a reader that would only exit again.
# shellcheck source=bin/fm-afk-outbox-lib.sh
. "$SCRIPT_DIR/fm-afk-outbox-lib.sh"

READER="$SCRIPT_DIR/fm-afk-inbox.sh"

# The home-scoped singleton lock, held for the whole armed lifetime, and the
# home-local record of the reader child so a wrapper that was SIGKILLed (its trap
# never ran) still leaves a trail for the next arm to retire its orphan reader.
ARM_LOCK="$STATE/.afk-inbox-arm.lock"
READER_RECORD_PID="$STATE/.afk-inbox-reader.pid"
READER_RECORD_ID="$STATE/.afk-inbox-reader.id"
LOCK_HELD=0
# How long to wait for a signalled predecessor or orphan to actually exit before
# escalating TERM to KILL, in 0.1s steps (mirrors bin/fm-watch-arm.sh --restart).
RETIRE_WAIT_STEPS=${FM_AFK_INBOX_ARM_RETIRE_WAIT_STEPS:-50}
case "$RETIRE_WAIT_STEPS" in ''|*[!0-9]*|0) RETIRE_WAIT_STEPS=50 ;; esac

RAPID_SECONDS=${FM_AFK_INBOX_ARM_RAPID_SECONDS:-5}
FAILURE_THRESHOLD=${FM_AFK_INBOX_ARM_FAILURE_THRESHOLD:-5}
BACKOFF_BASE=${FM_AFK_INBOX_ARM_BACKOFF_BASE:-2}
BACKOFF_MAX=${FM_AFK_INBOX_ARM_BACKOFF_MAX:-60}

# A misconfigured knob must refuse loudly rather than silently degrade the loop
# into a spin or a permanent stall, exactly as bin/fm-present-daemon.sh does.
require_positive_int() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*|0)
      echo "afk-inbox-arm: FAILED - $1 must be a positive integer" >&2
      exit 2
      ;;
  esac
}
require_positive_int FM_AFK_INBOX_ARM_RAPID_SECONDS "$RAPID_SECONDS"
require_positive_int FM_AFK_INBOX_ARM_FAILURE_THRESHOLD "$FAILURE_THRESHOLD"
require_positive_int FM_AFK_INBOX_ARM_BACKOFF_BASE "$BACKOFF_BASE"
require_positive_int FM_AFK_INBOX_ARM_BACKOFF_MAX "$BACKOFF_MAX"

[ -x "$READER" ] || { echo "afk-inbox-arm: FAILED - missing $READER" >&2; exit 1; }

RUNNING=1
READER_PID=
SLEEP_PID=
READER_OUT=

cleanup_reader() {
  [ -n "$READER_PID" ] || return 0
  if fm_pid_alive "$READER_PID"; then
    kill -TERM "$READER_PID" 2>/dev/null || true
    wait "$READER_PID" 2>/dev/null || true
  fi
  READER_PID=
}

remove_reader_out() {
  [ -n "$READER_OUT" ] || return 0
  rm -f "$READER_OUT" 2>/dev/null || true
  READER_OUT=
}

# Record this home's live reader child so a wrapper that is later SIGKILLed
# (trap never runs) still leaves the next arm a home-local trail to retire the
# orphan. The identity pins it to THIS process, so a reused pid is a mismatch.
record_reader() {  # <pid>
  local pid=$1
  printf '%s\n' "$pid" > "$READER_RECORD_PID" 2>/dev/null || true
  fm_pid_identity "$pid" > "$READER_RECORD_ID" 2>/dev/null || true
}

clear_reader_record() {
  rm -f "$READER_RECORD_PID" "$READER_RECORD_ID" 2>/dev/null || true
}

# Signal a recorded pid down home-scoped and identity-verified: TERM, wait for
# it to exit, then KILL if it will not. NEVER acts on a pid whose captured
# identity no longer matches (a reused pid) or that is already dead/zombie, so
# this can only ever reach the exact process this home recorded. The identity is
# re-checked immediately before every kill to close the reuse race.
retire_recorded_pid() {  # <pid> <expected-identity>
  local pid=$1 want=$2 i=0
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  fm_pid_alive "$pid" || return 0
  [ -n "$want" ] || return 0
  [ "$(fm_pid_identity "$pid" 2>/dev/null)" = "$want" ] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$i" -lt "$RETIRE_WAIT_STEPS" ] && fm_pid_alive "$pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  if fm_pid_alive "$pid" && [ "$(fm_pid_identity "$pid" 2>/dev/null)" = "$want" ]; then
    kill -KILL "$pid" 2>/dev/null || true
    i=0
    while [ "$i" -lt "$RETIRE_WAIT_STEPS" ] && fm_pid_alive "$pid"; do
      sleep 0.1
      i=$((i + 1))
    done
  fi
}

# Retire a reader ORPHANED by a wrapper that died without running its trap. The
# predecessor wrapper itself is retired by the singleton lock (its own trap tears
# its reader down); this covers only the reader left with no live parent. The
# record is home-local, so this can never signal another home's reader, and the
# identity match makes a reused pid or an already-recycled record a no-op.
retire_orphan_reader() {
  local pid identity
  [ -f "$READER_RECORD_PID" ] || return 0
  pid=$(cat "$READER_RECORD_PID" 2>/dev/null || true)
  identity=$(cat "$READER_RECORD_ID" 2>/dev/null || true)
  retire_recorded_pid "$pid" "$identity"
  clear_reader_record
}

# Retire a predecessor WRAPPER still holding this home's arm lock, exactly the
# way bin/fm-watch-arm.sh --restart stops the recorded watcher: read the holder
# pid straight from the lock, and signal it down only when it is this home's own
# arm wrapper (the fm-home field it wrote matches) AND its captured identity
# still matches (never a reused pid). Signalling it fires its trap, which tears
# down its reader child and releases the lock; a wrapper already gone leaves a
# dead-pid lock the mutex reclaims on the claim below. A holder that will not die
# is escalated TERM -> KILL. The lock lives in this home's state/, so this can
# never reach another home's wrapper.
retire_predecessor_wrapper() {
  local pid lock_home lock_identity i=0
  pid=$(cat "$ARM_LOCK/pid" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  lock_home=$(cat "$ARM_LOCK/fm-home" 2>/dev/null || true)
  lock_identity=$(cat "$ARM_LOCK/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$FM_HOME" ] || return 0
  fm_pid_alive "$pid" || return 0
  [ -n "$lock_identity" ] || return 0
  [ "$(fm_pid_identity "$pid" 2>/dev/null)" = "$lock_identity" ] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$i" -lt "$RETIRE_WAIT_STEPS" ] && fm_pid_alive "$pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  if fm_pid_alive "$pid" && [ "$(fm_pid_identity "$pid" 2>/dev/null)" = "$lock_identity" ]; then
    kill -KILL "$pid" 2>/dev/null || true
    i=0
    while [ "$i" -lt "$RETIRE_WAIT_STEPS" ] && fm_pid_alive "$pid"; do
      sleep 0.1
      i=$((i + 1))
    done
  fi
}

# Stamp this wrapper's ownership into the held lock so a later arm can recognise
# it as this home's arm wrapper and retire it, mirroring how bin/fm-watch.sh
# records fm-home and pid-identity in the watcher lock. Best-effort: the fields
# are only used to make the retire MORE selective, never less safe.
record_arm_lock_identity() {
  printf '%s\n' "$FM_HOME" > "$ARM_LOCK/fm-home" 2>/dev/null || true
  fm_pid_identity "${BASHPID:-$$}" > "$ARM_LOCK/pid-identity" 2>/dev/null || true
}

release_arm_lock() {
  [ "$LOCK_HELD" -eq 1 ] || return 0
  fm_lock_release "$ARM_LOCK"
  LOCK_HELD=0
}

# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_signal() {
  local rc=$1
  trap - HUP TERM INT
  RUNNING=0
  [ -n "$SLEEP_PID" ] && kill -TERM "$SLEEP_PID" 2>/dev/null
  cleanup_reader
  clear_reader_record
  remove_reader_out
  release_arm_lock
  exit "$rc"
}

trap 'handle_signal 129' HUP
trap 'handle_signal 143' TERM
trap 'handle_signal 130' INT

# Sleep in a killable child so a shutdown signal lands immediately instead of
# behind a foreground sleep - the same wedge bin/fm-watch.sh and
# bin/fm-present-daemon.sh fixed with a backgrounded sleep child.
interruptible_sleep() {  # <seconds>
  sleep "$1" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null || true
  SLEEP_PID=
}

away_mode_active() {
  [ -e "$STATE/.afk" ]
}

# The reader owns the whole re-arm-verdict contract: every genuine outcome ends
# in exactly one `afk-inbox:` line that ends in either "re-arm to keep listening"
# (a delivery or an operational failure whose records stay pending) or
# "- do not re-arm" (pane delivery, or away mode over). A run that produced NO
# such line did not reach any of its own exit points, so it was killed or
# crashed - the one case this wrapper absorbs internally.
reader_output_has_verdict() {  # <output-file>
  grep -q '^afk-inbox: ' "$1" 2>/dev/null
}

# Print the reader's exact stdout so firstmate sees the digests and the verdict,
# then hand back the reader's own status so a delivery is exit 0 and an
# operational failure stays loudly non-zero.
pass_through_and_exit() {  # <output-file> <reader-rc>
  local out=$1 rc=$2
  [ -s "$out" ] && cat "$out"
  remove_reader_out
  clear_reader_record
  release_arm_lock
  exit "$rc"
}

main() {
  local started rc elapsed failures=0 backoff

  # Singleton per home. Retire any pre-existing reader for this home first, so a
  # stale reader from a dead session cannot survive this arm: signal the recorded
  # arm-lock holder (a predecessor wrapper), whose trap tears down its own reader
  # child and releases the lock. Retiring is unconditional, like
  # bin/fm-watch-arm.sh --restart - the fresh arm always wins.
  retire_predecessor_wrapper

  # Now claim this home's arm lock and hold it for the whole armed lifetime. A
  # predecessor that exited (its trap released the lock) or was killed hard (a
  # dead-pid stale lock the mutex reclaims) yields it here. A failure to acquire
  # now means a GENUINELY concurrent fresh peer beat us to the empty lock; stand
  # down with a do-not-re-arm line rather than starting a rival reader.
  if ! fm_lock_try_acquire "$ARM_LOCK"; then
    echo "afk-inbox-arm: another away-mode reader is already arming for this home (pid ${FM_LOCK_HELD_PID:-unknown}); not starting a second - do not re-arm"
    return 0
  fi
  LOCK_HELD=1
  record_arm_lock_identity
  # Sole owner now. A reader still recorded in the sidecar was orphaned by a
  # wrapper that died WITHOUT running its trap (a SIGKILL, an OOM), leaving no
  # live parent to tear it down; retire it before arming a fresh one.
  retire_orphan_reader

  # A run started with away mode already over, or in a home the daemon put into
  # pane delivery, has no pull channel to keep alive. Do not launch a reader just
  # to have it exit immediately; let the bare reader's own do-not-re-arm line be
  # the record when firstmate armed it deliberately, and simply stand down here.
  if ! away_mode_active; then
    echo "afk-inbox-arm: away mode is not active; nothing to keep armed - do not re-arm"
    return 0
  fi
  if [ "$(fm_afk_delivery_mode_recorded "$STATE")" = pane ]; then
    echo "afk-inbox-arm: away mode is delivering into the supervisor pane; no inbox reader needed - do not re-arm"
    return 0
  fi

  while [ "$RUNNING" -eq 1 ]; do
    READER_OUT=$(mktemp "$STATE/.afk-inbox-arm-output.XXXXXX") || {
      echo "afk-inbox-arm: FAILED - cannot create a reader output file under $STATE" >&2
      return 1
    }

    started=$(date +%s)
    # Resident: --timeout 0 blocks until a real delivery, a do-not-re-arm
    # condition, or an operational failure, and never idle-exits.
    "$READER" --timeout 0 > "$READER_OUT" 2>&1 &
    READER_PID=$!
    # Record the live reader so a wrapper SIGKILLed before its trap runs still
    # leaves the next arm a trail to retire this orphan.
    record_reader "$READER_PID"
    rc=0
    wait "$READER_PID" 2>/dev/null || rc=$?
    # A signal handled mid-wait already exited through the trap; guard anyway.
    [ "$RUNNING" -eq 1 ] || { remove_reader_out; return 0; }
    if fm_pid_alive "$READER_PID"; then
      cleanup_reader
    fi
    READER_PID=
    clear_reader_record
    elapsed=$(( $(date +%s) - started ))

    if reader_output_has_verdict "$READER_OUT"; then
      # A genuine reader outcome: a delivery, an operational failure, or a
      # do-not-re-arm condition. All three are firstmate's to see and act on.
      pass_through_and_exit "$READER_OUT" "$rc"
    fi

    # No verdict line: the reader did not reach any of its own exits, so it was
    # killed or crashed. Absorb it internally with bounded backoff rather than
    # spending a firstmate turn on every transient crash.
    remove_reader_out
    if ! away_mode_active; then
      echo "afk-inbox-arm: away mode ended while the reader was down; nothing to keep armed - do not re-arm"
      return 0
    fi
    if [ "$(fm_afk_delivery_mode_recorded "$STATE")" = pane ]; then
      echo "afk-inbox-arm: away mode switched to the supervisor pane while the reader was down; no inbox reader needed - do not re-arm"
      return 0
    fi

    if [ "$elapsed" -ge "$RAPID_SECONDS" ]; then
      # The reader ran a while before dying: not a tight crash loop, so relaunch
      # promptly and reset the rapid-failure count.
      failures=0
      continue
    fi

    failures=$((failures + 1))
    backoff=$((BACKOFF_BASE * failures))
    [ "$backoff" -gt "$BACKOFF_MAX" ] && backoff=$BACKOFF_MAX
    if [ "$failures" -ge "$FAILURE_THRESHOLD" ]; then
      # The reader cannot stay up. Surface it through the durable wake queue so
      # firstmate re-arms deliberately and looks at the home, then exit non-zero
      # so the harness completion also wakes firstmate right now. Records, if
      # any, stay pending in the outbox for the next reader.
      fm_wake_append check afk-inbox-arm \
        "away-mode escalation reader keeps crashing ($failures consecutive rapid failures on this paneless home); re-arm bin/fm-afk-inbox-arm.sh as a tracked background task and check the home" \
        || true
      echo "afk-inbox-arm: FAILED - the away-mode reader crashed $failures times in a row without delivering; records stay pending and nothing is listening; re-arm to keep listening" >&2
      return 1
    fi
    interruptible_sleep "$backoff"
  done
  return 0
}

main "$@"
# Every return path out of main() releases the singleton lock and clears the
# reader record here (the exit-via-exit paths pass_through_and_exit and
# handle_signal already released before exiting). This is the one drain point so
# a stand-down or crash-loop return never leaves the lock or an orphan record
# behind for the next arm.
rc=$?
if [ "$LOCK_HELD" -eq 1 ]; then
  clear_reader_record
  release_arm_lock
fi
exit "$rc"
