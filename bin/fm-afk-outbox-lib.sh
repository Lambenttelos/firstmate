#!/usr/bin/env bash
# fm-afk-outbox-lib.sh - the single owner of away-mode PULL delivery: the durable
# outbox the sub-supervisor writes when it has no supervisor pane to type into,
# and the acknowledgement contract its reader (bin/fm-afk-inbox.sh) uses.
#
# Why this exists. bin/fm-supervise-daemon.sh delivers every escalation digest by
# typing it into firstmate's own pane. A primary firstmate that runs OUTSIDE any
# supported terminal backend - a Claude Code session launched from the desktop
# app, for example - has no such pane, so supervisor discovery falls through to
# its legacy "firstmate:0" GUESS, types into whatever unrelated pane answers to
# it, never gets an affirmatively-empty-composer confirmation, and buffers
# forever. Observed 2026-07-22: ~80 minutes of away-mode escalations undelivered
# behind repeated "inject deferred: supervisor composer not confirmed-empty"
# lines and one "away-mode escalation undelivered 1531s" ERROR. Nothing was lost
# (the durable wake queue survived), but away mode was silently useless.
#
# The pull path needs no pane: the daemon appends each flushed digest here, and
# firstmate arms bin/fm-afk-inbox.sh as its own harness-tracked background task,
# exactly the way bin/fm-watch-arm.sh is armed. The harness's own task-completion
# notification becomes the delivery mechanism.
#
# RECORD FORMAT (one line per flushed digest, append only):
#   <epoch>\t<seq>\t<kind>\t<digest>
# <seq> is a strictly increasing integer allocated from state/.afk-outbox.seq.
# <digest> is the exact single-line text the pane path would have typed, sentinel
# marker (FM_INJECT_MARK) included, with any tab, CR, or LF replaced by a space so
# one record stays one line.
#
# ACKNOWLEDGEMENT. state/.afk-outbox.ack holds the highest acknowledged <seq>.
# Only the READER writes it, and only after those records are already on its
# stdout. The writer never consumes a record. So a reader killed mid-wait or
# mid-print loses nothing: the next reader run delivers the same unacknowledged
# records. Delivery is exactly-once within a run and at-least-once across a
# killed run, which is the correct bias - a killed reader's stdout never reached
# firstmate.
#
# LOCKING. Every mutation and every pending read takes the repo's portable lock
# helper (bin/fm-wake-lib.sh) on state/.afk-outbox.lock, so the daemon may append
# while a reader waits. flock is absent on macOS and is never used.
#
# This library is sourced, never executed. It has no side effects at source time:
# bin/fm-wake-lib.sh creates its state directory when sourced, so the lock helpers
# are pulled in lazily on first use against an explicit state directory.

FM_AFK_OUTBOX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FM_AFK_OUTBOX_NAME=".afk-outbox"
FM_AFK_OUTBOX_ACK_NAME=".afk-outbox.ack"
FM_AFK_OUTBOX_SEQ_NAME=".afk-outbox.seq"
FM_AFK_OUTBOX_LOCK_NAME=".afk-outbox.lock"
FM_AFK_DELIVERY_MODE_NAME=".afk-delivery"

fm_afk_outbox_file() {  # <state>
  printf '%s/%s' "$1" "$FM_AFK_OUTBOX_NAME"
}

fm_afk_outbox_ack_file() {  # <state>
  printf '%s/%s' "$1" "$FM_AFK_OUTBOX_ACK_NAME"
}

fm_afk_outbox_seq_file() {  # <state>
  printf '%s/%s' "$1" "$FM_AFK_OUTBOX_SEQ_NAME"
}

fm_afk_outbox_lock_file() {  # <state>
  printf '%s/%s' "$1" "$FM_AFK_OUTBOX_LOCK_NAME"
}

fm_afk_delivery_mode_file() {  # <state>
  printf '%s/%s' "$1" "$FM_AFK_DELIVERY_MODE_NAME"
}

# Session-scoped away-mode delivery artifacts owned by this library, one name per
# line. bin/fm-afk-start.sh folds them into the single session-artifact list that
# fresh-entry clearing and the launcher's transactional rollback both iterate, so
# those two sets can never drift apart.
fm_afk_outbox_artifact_names() {
  printf '%s\n' \
    "$FM_AFK_OUTBOX_NAME" \
    "$FM_AFK_OUTBOX_ACK_NAME" \
    "$FM_AFK_OUTBOX_SEQ_NAME" \
    "$FM_AFK_DELIVERY_MODE_NAME"
}

# Collapse the field separators so one digest can never become two records. The
# daemon has already collapsed newlines before it reaches here; this is the
# record format's own guarantee, independent of that.
fm_afk_outbox_clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

# Pull in the portable lock helpers on first use, scoped to the state directory
# the caller is operating on. Deferred rather than sourced at the top because
# bin/fm-wake-lib.sh creates its resolved state directory as a source-time side
# effect, and this library is sourced by the daemon's unit tests with no state
# override in force.
fm_afk_outbox_lock_lib() {  # <state>
  local state=$1
  if declare -F fm_lock_acquire_wait >/dev/null 2>&1; then
    return 0
  fi
  # shellcheck source=bin/fm-wake-lib.sh
  FM_STATE_OVERRIDE="$state" . "$FM_AFK_OUTBOX_LIB_DIR/fm-wake-lib.sh"
}

# Take the outbox lock with a BOUNDED wait. fm_lock_acquire_wait retries forever,
# which is right for a short-lived caller but wrong here: the daemon must never
# hang inside a delivery attempt when the state directory itself is unwritable
# (a read-only mount, a full disk). A bounded failure returns to the caller,
# which keeps the digest buffered and logs, so the next tick tries again.
_fm_afk_outbox_lock_acquire() {  # <lock-dir>
  local lock=$1 tries=${FM_AFK_OUTBOX_LOCK_TRIES:-100} i=0
  case "$tries" in
    ''|*[!0-9]*|0) tries=100 ;;
  esac
  while [ "$i" -lt "$tries" ]; do
    if fm_lock_try_acquire "$lock"; then
      return 0
    fi
    i=$((i + 1))
    sleep 0.05
  done
  return 1
}

_fm_afk_outbox_int() {  # <text> -> the integer, or 0
  local value=$1
  case "$value" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$value" ;;
  esac
}

# The acknowledged high-water mark. 0 means nothing has been acknowledged yet.
fm_afk_outbox_ack_seq() {  # <state>
  local state=$1
  _fm_afk_outbox_int "$(head -n 1 "$(fm_afk_outbox_ack_file "$state")" 2>/dev/null || true)"
}

# Highest sequence number present in the outbox itself, 0 when it is empty.
_fm_afk_outbox_last_seq() {  # <state>
  local file
  file=$(fm_afk_outbox_file "$1")
  [ -s "$file" ] || { printf '0'; return 0; }
  awk -F '\t' 'NF >= 4 && $2 ~ /^[0-9]+$/ && $2+0 > max { max = $2+0 } END { print max+0 }' \
    "$file" 2>/dev/null || printf '0'
}

# Allocate the next sequence number. It is the successor of every number this
# home has already used: the seq counter, the acknowledged high-water mark, and
# the highest record still in the outbox. Taking the maximum of all three means a
# deleted or truncated counter can never hand out a number an acknowledgement
# already covers, which would make the new record invisible to every reader.
_fm_afk_outbox_next_seq() {  # <state>  (call under the outbox lock)
  local state=$1 seq ack last next
  seq=$(_fm_afk_outbox_int "$(head -n 1 "$(fm_afk_outbox_seq_file "$state")" 2>/dev/null || true)")
  ack=$(fm_afk_outbox_ack_seq "$state")
  last=$(_fm_afk_outbox_last_seq "$state")
  next=$seq
  [ "$ack" -gt "$next" ] && next=$ack
  [ "$last" -gt "$next" ] && next=$last
  printf '%s' "$((next + 1))"
}

# Append one delivery record. Returns non-zero if the record could not be
# persisted, so the daemon keeps the digest buffered instead of losing it.
fm_afk_outbox_append() {  # <state> <kind> <digest>
  local state=$1 kind=$2 digest=$3 clean_kind clean_digest seq lock status=0
  mkdir -p "$state" || return 1
  clean_kind=$(printf '%s' "$kind" | fm_afk_outbox_clean_field)
  clean_digest=$(printf '%s' "$digest" | fm_afk_outbox_clean_field)
  [ -n "$clean_kind" ] || clean_kind=escalation
  [ -n "$clean_digest" ] || return 1
  fm_afk_outbox_lock_lib "$state" || return 1
  lock=$(fm_afk_outbox_lock_file "$state")
  _fm_afk_outbox_lock_acquire "$lock" || return 1
  seq=$(_fm_afk_outbox_next_seq "$state")
  printf '%s\n' "$seq" > "$(fm_afk_outbox_seq_file "$state")" || status=1
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$seq" "$clean_kind" "$clean_digest" \
      >> "$(fm_afk_outbox_file "$state")" || status=1
  fi
  fm_lock_release "$lock"
  return "$status"
}

# Raw unacknowledged records, oldest first. Read under the lock so a concurrent
# append is never observed half-written.
fm_afk_outbox_pending() {  # <state>
  local state=$1 lock ack file
  file=$(fm_afk_outbox_file "$state")
  [ -s "$file" ] || return 0
  fm_afk_outbox_lock_lib "$state" || return 1
  lock=$(fm_afk_outbox_lock_file "$state")
  _fm_afk_outbox_lock_acquire "$lock" || return 1
  ack=$(fm_afk_outbox_ack_seq "$state")
  awk -F '\t' -v ack="$ack" 'NF >= 4 && $2 ~ /^[0-9]+$/ && $2+0 > ack+0' "$file" 2>/dev/null || true
  fm_lock_release "$lock"
}

fm_afk_outbox_pending_count() {  # <state>
  local pending
  pending=$(fm_afk_outbox_pending "$1")
  [ -n "$pending" ] || { printf '0'; return 0; }
  printf '%s' "$(printf '%s\n' "$pending" | wc -l | tr -d ' ')"
}

# Portable epoch rendering. awk's strftime is a gawk extension that the macOS awk
# does not have, and `date -r` / `date -d @` differ by platform, so the platform
# is decided once here rather than probed per call - the same discipline
# bin/fm-watch.sh applies to stat.
if [ "$(uname)" = Darwin ]; then
  _fm_afk_outbox_stamp() { date -r "$1" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null; }
else
  _fm_afk_outbox_stamp() { date -d "@$1" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null; }
fi

# One human-readable line per raw record, for the reader's stdout and for the
# return catch-up gate's evidence. The digest keeps its sentinel marker verbatim,
# so a relayed line is still recognizable as an internal escalation.
fm_afk_outbox_format() {  # <raw-records-on-stdin>
  local epoch seq kind digest stamp
  while IFS="$(printf '\t')" read -r epoch seq kind digest; do
    [ -n "$digest" ] || continue
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    stamp=""
    case "$epoch" in
      ''|*[!0-9]*) ;;
      *) stamp=$(_fm_afk_outbox_stamp "$epoch") ;;
    esac
    printf '[%s] %s: %s\n' "${stamp:-$epoch}" "$kind" "$digest"
  done
}

# Formatted pending records WITHOUT acknowledging them. Used by the return
# catch-up gate, which reports leftovers as evidence rather than consuming them
# as a delivery.
fm_afk_outbox_pending_report() {  # <state>
  local pending
  pending=$(fm_afk_outbox_pending "$1") || return 1
  [ -n "$pending" ] || return 0
  printf '%s\n' "$pending" | fm_afk_outbox_format
}

# Record the acknowledged high-water mark atomically (write a sibling, rename over
# the ack file), so an interrupted acknowledgement leaves the previous mark intact
# and the records are simply delivered again.
fm_afk_outbox_ack() {  # <state> <seq>
  local state=$1 seq=$2 ack pending_file
  case "$seq" in
    ''|*[!0-9]*) return 1 ;;
  esac
  ack=$(fm_afk_outbox_ack_file "$state")
  pending_file=$(mktemp "$state/.afk-outbox.ack.pending.XXXXXX") || return 1
  printf '%s\n' "$seq" > "$pending_file" || { rm -f "$pending_file"; return 1; }
  mv "$pending_file" "$ack" || { rm -f "$pending_file"; return 1; }
}

# Deliver every unacknowledged record: print the formatted records on stdout
# FIRST, then acknowledge them. Returns 0 when at least one record was delivered,
# 1 when there was nothing pending, 2 when records were printed but could not be
# acknowledged (the caller reports that loudly; the records stay pending and are
# delivered again rather than lost).
#
# Deliberate ordering: print, then acknowledge. A reader killed between the two
# has not actually delivered anything to firstmate, so re-delivering is correct.
fm_afk_outbox_deliver() {  # <state>
  local state=$1 pending last
  pending=$(fm_afk_outbox_pending "$state") || return 1
  [ -n "$pending" ] || return 1
  printf '%s\n' "$pending" | fm_afk_outbox_format
  last=$(printf '%s\n' "$pending" | awk -F '\t' 'NF >= 4 && $2+0 > max { max = $2+0 } END { print max+0 }')
  fm_afk_outbox_ack "$state" "$last" || return 2
  return 0
}

# The daemon records which delivery mode it selected at startup so the reader and
# firstmate can tell a paneless away session from a pane one without re-deriving
# the daemon's own discovery.
fm_afk_delivery_mode_record() {  # <state> <mode>
  local state=$1 mode=$2 file pending_file
  case "$mode" in
    pane|paneless) ;;
    *) return 1 ;;
  esac
  mkdir -p "$state" || return 1
  file=$(fm_afk_delivery_mode_file "$state")
  pending_file=$(mktemp "$state/.afk-delivery.pending.XXXXXX") || return 1
  printf '%s\n' "$mode" > "$pending_file" || { rm -f "$pending_file"; return 1; }
  mv "$pending_file" "$file" || { rm -f "$pending_file"; return 1; }
}

# The recorded delivery mode, or an empty string when no daemon has recorded one
# in this away session yet.
fm_afk_delivery_mode_recorded() {  # <state>
  local mode
  mode=$(head -n 1 "$(fm_afk_delivery_mode_file "$1")" 2>/dev/null || true)
  case "$mode" in
    pane|paneless) printf '%s' "$mode" ;;
    *) printf '' ;;
  esac
}
