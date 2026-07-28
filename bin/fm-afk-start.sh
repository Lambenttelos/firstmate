#!/usr/bin/env bash
# Enter away mode and run the sub-supervisor daemon in a harness-tracked
# foreground process when one is not already alive.
#
# Usage: fm-afk-start.sh
#   Sets state/.afk unless FM_AFK_STATE_PREPARED=1, checks
#   state/.supervise-daemon.lock, and:
#     - prints "afk: daemon already running pid=<pid>" then exits 0 when that
#       lock is held by a live daemon (a REFRESH: no stale-artifact clear);
#     - otherwise clears any prior away session's stale escalation artifacts
#       (fm_afk_clear_stale_artifacts) for a direct, non-prepared start - naming
#       on stderr, never aborting on, any it cannot clear - then execs
#       bin/fm-supervise-daemon.sh in the foreground. A prepared start was
#       already cleared transactionally by bin/fm-afk-launch.sh.
#
# This file is sourceable: its BASH_SOURCE guard keeps main from running, while
# exposing the daemon-lock helpers and fm_afk_clear_stale_artifacts. Sourcing it
# enables nounset and errexit; callers that need different shell options must
# restore them explicitly.
#
# This is the COMMON daemon entry for every backend. HOW it becomes a tracked
# background process differs by harness/backend and is owned elsewhere:
#   - Harnesses with a native in-pane tracked-background tool (e.g. claude, grok)
#     run this directly via that tool, so the daemon inherits the captain pane's
#     env and auto-discovers it.
#   - Harnesses with NO native background mechanism (e.g. pi) run this THROUGH
#     bin/fm-afk-launch.sh, which creates a non-visible tracked terminal per
#     backend (herdr tab/workspace, tmux detached session) and passes the
#     captain pane in as FM_SUPERVISOR_TARGET so injection targets it, not the
#     daemon's own new pane.
# Do not wrap this in `nohup ... &`: Codex/herdr can reap fire-and-forget shell
# children after the tool call returns, while a tracked background terminal stays
# attached and has a real lifecycle.
set -eu

FM_AFK_START_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_AFK_START_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_AFK_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_AFK_LOCK="$FM_AFK_STATE/.supervise-daemon.lock"
FM_AFK_DAEMON="$FM_AFK_START_DIR/fm-supervise-daemon.sh"

# shellcheck source=bin/fm-wake-lib.sh
. "$FM_AFK_START_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-afk-daemon-lib.sh
. "$FM_AFK_START_DIR/fm-afk-daemon-lib.sh"
# Paneless-delivery artifact names (bin/fm-afk-outbox-lib.sh owns the outbox
# record and acknowledgement contract itself).
# shellcheck source=bin/fm-afk-outbox-lib.sh
. "$FM_AFK_START_DIR/fm-afk-outbox-lib.sh"

fm_afk_start_usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# fm_afk_clear_stale_artifacts: on a FRESH away-session entry (the daemon is not
# already running), drop the previous away session's leftover escalation-delivery
# artifacts so they cannot surface as stale escalations under the new session.
# These are session-scoped by timing: a fresh entry owns a new supervision
# session and the new daemon has not produced anything yet, so anything present
# here belongs to a PRIOR session. This never drops a genuinely-pending
# escalation - the delivery buffer is a transient cache, and any condition still
# true (a crew still blocked, a check still firing) is re-derived and re-escalated
# fresh by the daemon's heartbeat catch-all scan and the durable
# state/.wake-queue replay (see docs/herdr-backend.md "Away-mode stale-artifact
# lifecycle" and bin/fm-supervise-daemon.sh's escalate_add/inject_wedge_alarm).
# NOT called on a refresh (daemon already alive), so the current session's own
# buffered escalations are preserved.
#
# fm_afk_session_artifact_names lists every one of those DURABLE artifacts, one
# name per line, covering both delivery modes: the pane path's escalation buffer
# and wedge marker, and the paneless path's outbox, acknowledgement, sequence
# counter, and recorded delivery mode. Clearing here and the launcher's
# transactional backup and rollback both iterate this one list, so the two sets
# cannot drift apart.
#
# The paneless path also leaves process-scoped scratch - its portable lock and
# the mktemp siblings used for atomic acknowledgement and delivery-mode renames.
# Those are cleared by fm_afk_clear_stale_artifacts too (through the outbox
# library's own owning list), but deliberately stay out of the durable list: a
# lock directory cannot be backed up and restored, and restoring one from a
# rolled-back start would hand the new session another session's lock.
fm_afk_session_artifact_names() {
  printf '%s\n' \
    .subsuper-escalations \
    .subsuper-escalations.since \
    .subsuper-inject-wedged
  fm_afk_outbox_artifact_names
}

# The one wording every away-mode entry point uses after fm_afk_clear_stale_artifacts
# fails. Away mode must still come up: refusing to enter costs the captain ALL
# supervision over a rare filesystem condition, which is the exact outcome the
# pull-delivery path exists to prevent, while a lock whose owner is dead is
# already stolen by bin/fm-wake-lib.sh and a genuinely unusable one surfaces at
# runtime through the paneless append-failure alarm. Both bin/fm-afk-start.sh's
# direct start and both bin/fm-afk-launch.sh entry points render THIS text, so an
# operator reading either sees the same fact and the two paths cannot drift into
# disagreeing about whether away mode may come up.
fm_afk_stale_artifact_continue_message() {
  printf 'continuing into daemon startup despite the stale away-mode artifact(s) named above'
}

# Every failure NAMES the artifact it could not clear on stderr in addition to
# returning non-zero, so no caller can turn a clearing problem into a silent stop.
#
# The outbox-owned artifacts are cleared by fm_afk_outbox_clear_session rather
# than by this loop, because they must be cleared under the outbox lock that
# guards appends and compaction; this loop owns only the pane path's artifacts,
# which no lock guards.
fm_afk_clear_stale_artifacts() {  # <state-dir>
  local state=$1 name outbox_names status=0
  outbox_names=$(fm_afk_outbox_artifact_names)
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "
$outbox_names
" in
      *"
$name
"*) continue ;;
    esac
    rm -f "$state/$name" 2>/dev/null && continue
    printf 'afk: could not clear stale away-mode artifact %s\n' "$state/$name" >&2
    status=1
  done < <(fm_afk_session_artifact_names)
  fm_afk_outbox_clear_session "$state" || status=1
  return "$status"
}

# Daemon-lock liveness lives in bin/fm-afk-daemon-lib.sh so the turn-end guard
# can ask the same question; these stay as this script's thin, lock-bound names,
# shared with bin/fm-afk-launch.sh, which sources this file.
daemon_lock_pid() {
  fm_afk_daemon_lock_pid "$FM_AFK_LOCK"
}

daemon_lock_held_by_live_daemon() {
  fm_afk_daemon_alive "$FM_AFK_LOCK" "$FM_AFK_DAEMON"
}

fm_afk_start_main() {
  case "${1:-}" in
    '' ) ;;
    -h|--help) fm_afk_start_usage; return 0 ;;
    * ) echo "usage: $(basename "${BASH_SOURCE[1]:-fm-afk-start.sh}")" >&2; return 2 ;;
  esac

  mkdir -p "$FM_AFK_STATE"
  if [ "${FM_AFK_STATE_PREPARED:-0}" = 1 ]; then
    [ -f "$FM_AFK_STATE/.afk" ] || { echo "afk: launcher-prepared state is missing" >&2; return 1; }
  else
    # Claim the bring-up window before away mode is visible, so nothing reads
    # this home as unsupervised while the daemon is still starting
    # (bin/fm-afk-daemon-lib.sh "DAEMON BRING-UP"). The daemon drops the claim
    # as it takes the lock.
    fm_afk_daemon_pending_mark "$FM_AFK_STATE" ||
      echo "afk: could not record the daemon-starting marker; this home may briefly look unsupervised" >&2
    if ! date '+%s' > "$FM_AFK_STATE/.afk"; then
      fm_afk_daemon_pending_clear "$FM_AFK_STATE" || true
      echo "afk: failed to write the away-mode flag" >&2
      return 1
    fi
  fi

  # Away-mode interlock: the present-mode daemon (bin/fm-present-daemon.sh) keeps
  # a watcher armed for an ACTIVE session. Away mode hands supervision to the
  # sub-supervisor daemon, which owns triage instead, so the two must never run
  # together. Stopping it here is the immediate handover; the present daemon also
  # re-checks state/.afk between its own cycles as a backstop. Inert and silent
  # when the feature is not opted in.
  FM_HOME="$FM_HOME" "$FM_AFK_START_DIR/fm-present-daemon.sh" stop >/dev/null 2>&1 || true

  local pid
  pid=$(daemon_lock_pid 2>/dev/null || true)
  if daemon_lock_held_by_live_daemon; then
    echo "afk: daemon already running pid=$pid"
    return 0
  fi

  # Reclaim the lock only from a live process this probe CONFIDENTLY reads as some
  # other program. Removing it whenever the owner pid is merely alive also fired on
  # an undetermined probe - an unreadable pid identity, or an empty ps command line
  # under fork pressure - which tore the lock away from a daemon that was in fact
  # running and started a second one beside it, two supervisors both believing they
  # own escalation delivery. An undetermined holder now keeps its lock, and the
  # daemon exec'd below refuses loudly against it instead
  # (bin/fm-afk-daemon-lib.sh, fm_afk_daemon_lock_held_by_foreign_live_process).
  if fm_afk_daemon_lock_held_by_foreign_live_process "$FM_AFK_LOCK" "$FM_AFK_DAEMON"; then
    fm_lock_remove_path "$FM_AFK_LOCK" 2>/dev/null || true
  fi

  # Fresh start: clear the previous away session's stale delivery artifacts
  # before the new daemon can surface them (fix for the leaked-artifact defect).
  #
  # Deliberately NOT fatal, and deliberately not a bare call under `set -e`: a
  # single artifact that will not delete - most likely a leftover outbox lock -
  # would otherwise abort right here, so `exec` below never runs and away mode
  # comes up with no sub-supervisor and no diagnostic at all. Coming up with a
  # supervisor and a stale artifact is strictly better than coming up with
  # neither, and the portable lock helper already recovers a stale lock through
  # its dead-pid steal. The clearing helpers name each artifact they could not
  # clear on stderr, so the problem is reported rather than swallowed.
  if [ "${FM_AFK_STATE_PREPARED:-0}" != 1 ]; then
    if ! fm_afk_clear_stale_artifacts "$FM_AFK_STATE"; then
      echo "afk: $(fm_afk_stale_artifact_continue_message)" >&2
    fi
  fi

  echo "afk: starting supervise daemon in foreground; keep this command as a tracked background session"
  exec "$FM_AFK_DAEMON"
}

# Run only when executed, not when sourced (bin/fm-afk-launch.sh and tests source
# fm_afk_clear_stale_artifacts and the thin daemon-lock wrappers).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_afk_start_main "$@"
fi
