#!/usr/bin/env bash
# fm-afk-reader-check.sh - report an away-mode inbox reader that is not running
# while escalations are waiting for it.
#
# WHY THIS EXISTS. A paneless away home has TWO processes that must both be live:
# the sub-supervisor daemon (bin/fm-supervise-daemon.sh), which classifies wakes
# and appends escalation digests to the durable outbox, and the inbox reader
# (bin/fm-afk-inbox.sh), which firstmate arms as its own harness-tracked
# background task so the harness's task-completion notification delivers those
# digests into an actual firstmate turn.
#
# The reader dying is self-concealing. Reviving it requires a firstmate turn, and
# the only thing that starts a firstmate turn while the captain is away IS the
# reader's delivery, so a dead reader can never announce itself through the channel
# it owns. Evidence 2026-07-30: the reader ended at 22:33, nine escalations
# accumulated unread until 09:55, and the fleet coasted roughly 9.5 hours.
#
# The daemon side of that gap is already covered: its paneless
# undelivered-escalation alarm writes state/.subsuper-inject-wedged and fires the
# active-alert channel when the oldest unacknowledged record passes max-defer AND
# the reader's beacon is absent or stale (bin/fm-supervise-daemon.sh housekeeping
# section 1c, pinned by tests/fm-daemon.test.sh). That alarm wakes a HUMAN. This
# check is the other half: it gives the next firstmate turn a machine-readable
# instruction to re-arm the reader, so session start heals the channel the same way
# it revives a dead daemon.
#
# It is a DETECTOR, never a fixer. It deliberately does not start a reader itself:
# the reader acknowledges every record it prints, so a reader started outside the
# harness would consume the captain's escalations to a stdout nobody reads and mark
# them delivered. Arming it must stay firstmate's own action.
#
# It reports only when every one of these holds, because any weaker condition
# reports a healthy home:
#   - away mode is active (state/.afk present),
#   - the daemon recorded PANELESS delivery for this away session (a pane home
#     needs no reader at all),
#   - the reader's liveness beacon is absent or staler than the shared window
#     (bin/fm-afk-outbox-lib.sh's fm_afk_inbox_beacon_stale_secs), and
#   - at least one unacknowledged record is actually waiting.
# An outbox that cannot be READ reports nothing: a failed read is never an empty
# one, and it is equally never proof that a reader is missing.
#
# Usage: fm-afk-reader-check.sh
# Output: one AFK_READER: line when the reader must be re-armed, nothing otherwise.
# Exit status: always 0 - this is a detector, and its silence is the healthy case.
#
# Environment:
#   FM_HOME                        the firstmate home to check
#   FM_AFK_INBOX_BEACON_STALE_SECS staleness window override (shared with the daemon)
#   FM_STATE_OVERRIDE              alternate state dir (testing)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-afk-outbox-lib.sh
. "$SCRIPT_DIR/fm-afk-outbox-lib.sh"

# Seconds since <file> was last touched; a huge number when it does not exist, so
# an absent beacon reads as the strongest form of "nothing is listening".
file_age() {  # <file>
  local f=$1 mtime now
  [ -e "$f" ] || { printf '999999'; return; }
  now=$(date +%s)
  mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "$now")
  printf '%s' $(( now - mtime ))
}

main() {
  local pending count age

  [ -e "$STATE/.afk" ] || return 0
  [ "$(fm_afk_delivery_mode_recorded "$STATE")" = paneless ] || return 0

  age=$(file_age "$(fm_afk_inbox_beacon_file "$STATE")")
  [ "$age" -ge "$(fm_afk_inbox_beacon_stale_secs)" ] || return 0

  count=0
  if ! pending=$(fm_afk_outbox_pending_count "$STATE" 2>/dev/null); then
    return 0
  fi
  case "$pending" in
    ''|*[!0-9]*) return 0 ;;
    *) count=$pending ;;
  esac
  [ "$count" -gt 0 ] || return 0

  printf 'AFK_READER: away-mode escalation reader is not running (no sign of life for %ss) and %s escalation record(s) are waiting; arm bin/fm-afk-inbox.sh as a tracked background task to deliver them\n' \
    "$age" "$count"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
