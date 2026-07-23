#!/usr/bin/env bash
# fm-afk-inbox.sh - blocking reader for away-mode PULL delivery.
#
# The away-mode sub-supervisor normally types its escalation digests into
# firstmate's own pane. When firstmate runs outside every supported terminal
# backend there is no such pane, so bin/fm-supervise-daemon.sh selects paneless
# delivery and appends each flushed digest to the durable outbox instead
# (bin/fm-afk-outbox-lib.sh owns that record and acknowledgement contract).
#
# This script is the other half: firstmate arms it as the harness's OWN tracked
# background task, exactly the way bin/fm-watch-arm.sh is armed, and the harness's
# task-completion notification becomes the delivery mechanism. It blocks until an
# unacknowledged record exists, prints the pending digests on stdout, marks them
# acknowledged, and exits. Never fire it and forget with a shell `&`: that
# backgrounded child is reaped when the call returns, leaving nothing listening.
#
# It exits promptly, and always after delivering anything already pending, when:
#   - records were delivered (the normal case),
#   - the daemon recorded PANE delivery (a supervisor pane exists, so nothing
#     will ever arrive here),
#   - away mode ended (state/.afk is gone), or
#   - --timeout elapsed with nothing pending.
# Every one of those exits is 0 and prints exactly one status line naming which
# it was, so firstmate knows whether to re-arm. A genuine failure - an
# unwritable state directory, a delivery that could not be acknowledged - exits
# non-zero instead of pretending the channel is healthy.
#
# Concurrency: the outbox library takes the repo's portable lock (flock is absent
# on macOS) for every append and every pending read, so this reader is safe to
# run while the daemon is writing. Killing the reader mid-wait or mid-print loses
# nothing: records are acknowledged only after they are already on stdout, so the
# next run delivers the same unacknowledged records.
#
# Usage: fm-afk-inbox.sh [--timeout <secs>] [--poll <secs>] [--once]
#   --timeout <secs>  give up waiting after <secs> and exit 0 (default 3600, or
#                     FM_AFK_INBOX_TIMEOUT; 0 waits until away mode ends)
#   --poll <secs>     seconds between checks (default 1, or FM_AFK_INBOX_POLL)
#   --once            check once and exit without waiting
#   FM_STATE_OVERRIDE alternate state dir (testing)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-afk-outbox-lib.sh
. "$SCRIPT_DIR/fm-afk-outbox-lib.sh"

usage() {
  awk '/^# Usage:/ { show = 1 } show && /^#/ { sub(/^# ?/, ""); print; next } show { exit }' \
    "${BASH_SOURCE[0]}"
}

TIMEOUT=${FM_AFK_INBOX_TIMEOUT:-3600}
POLL=${FM_AFK_INBOX_POLL:-1}
ONCE=0

die() {
  printf 'fm-afk-inbox: %s\n' "$*" >&2
  exit 1
}

# Print and acknowledge everything pending. Returns 0 when something was
# delivered, 1 when the outbox was empty.
deliver() {
  local count rc
  count=$(fm_afk_outbox_pending_count "$STATE")
  [ "$count" -gt 0 ] || return 1
  printf 'afk-inbox: %s away-mode escalation(s)\n' "$count"
  fm_afk_outbox_deliver "$STATE"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) die "delivered records could not be acknowledged; they stay pending and will be delivered again" ;;
  esac
}

away_mode_active() {
  [ -e "$STATE/.afk" ]
}

main() {
  local waited=0 mode

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --timeout) [ "$#" -ge 2 ] || die "--timeout needs a value"; TIMEOUT=$2; shift 2 ;;
      --poll) [ "$#" -ge 2 ] || die "--poll needs a value"; POLL=$2; shift 2 ;;
      --once) ONCE=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) usage >&2; return 2 ;;
    esac
  done
  case "$TIMEOUT" in ''|*[!0-9]*) die "--timeout must be a whole number of seconds" ;; esac
  case "$POLL" in ''|*[!0-9]*|0) die "--poll must be a positive whole number of seconds" ;; esac

  mkdir -p "$STATE" || die "cannot create state directory $STATE"

  # Anything already pending is delivered before any early-exit condition is
  # consulted: a record that exists must reach firstmate even if the away session
  # has since ended or switched to pane delivery.
  if deliver; then
    printf 'afk-inbox: delivered; re-arm to keep listening while away mode is active\n'
    return 0
  fi

  # A recorded PANE delivery mode means the daemon has a real supervisor pane and
  # nothing will ever be written here, so waiting would be a lie. An ABSENT
  # marker is not treated as pane delivery: no daemon has recorded a mode yet, so
  # this waits, which is the direction that cannot drop an escalation.
  mode=$(fm_afk_delivery_mode_recorded "$STATE")
  if [ "$mode" = pane ]; then
    printf 'afk-inbox: away mode is delivering into the supervisor pane; no inbox reader needed\n'
    return 0
  fi

  if ! away_mode_active; then
    printf 'afk-inbox: away mode is not active; nothing to wait for\n'
    return 0
  fi

  if [ "$ONCE" -eq 1 ]; then
    printf 'afk-inbox: nothing pending\n'
    return 0
  fi

  while true; do
    sleep "$POLL"
    waited=$((waited + POLL))
    if deliver; then
      printf 'afk-inbox: delivered; re-arm to keep listening while away mode is active\n'
      return 0
    fi
    if ! away_mode_active; then
      printf 'afk-inbox: away mode ended; nothing pending\n'
      return 0
    fi
    if [ "$(fm_afk_delivery_mode_recorded "$STATE")" = pane ]; then
      printf 'afk-inbox: away mode switched to the supervisor pane; no inbox reader needed\n'
      return 0
    fi
    if [ "$TIMEOUT" -gt 0 ] && [ "$waited" -ge "$TIMEOUT" ]; then
      printf 'afk-inbox: idle after %ss with nothing pending; re-arm to keep listening\n' "$waited"
      return 0
    fi
  done
}

main "$@"
