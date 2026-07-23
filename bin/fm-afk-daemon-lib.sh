# shellcheck shell=bash
# Shared away-mode daemon liveness helpers.
# Usage: . bin/fm-afk-daemon-lib.sh
#
# One owner for the question "is an away-mode supervision daemon actually
# running for THIS home?". bin/fm-afk-start.sh (and through it
# bin/fm-afk-launch.sh) uses it to decide start-vs-refresh; every script that
# must tell the daemon-owned away mode apart from the daemon-free away mode - the
# turn-end guard, the watcher's triage gate, the pull-based guard banner, and the
# session-start digest - asks fm_afk_daemon_owns_supervision below rather than
# reading state/.afk directly.
#
# Home scoping comes from the lock path itself (state/.supervise-daemon.lock
# lives in one home's state dir) and, when present, the pid identity recorded
# beside it. Scripts come from the shared tracked code root, so a daemon path
# match is NOT home discrimination; strict mode only rejects a process that is
# not this repo's supervise daemon at all.
#
# Sources bin/fm-pid-lib.sh for fm_pid_alive and fm_pid_identity.

FM_AFK_DAEMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pid-lib.sh
. "$FM_AFK_DAEMON_LIB_DIR/fm-pid-lib.sh"

# fm_afk_daemon_lock_owner <lock-path>
# Print the owner directory backing the lock (the symlink target for a linked
# lock, the directory itself for a plain directory lock). Non-zero when no lock.
fm_afk_daemon_lock_owner() {
  local lock=$1 owner
  if [ -L "$lock" ]; then
    owner=$(readlink "$lock" 2>/dev/null) || return 1
    [ -n "$owner" ] || return 1
    case "$owner" in
      /*) printf '%s\n' "$owner" ;;
      *) printf '%s/%s\n' "$(dirname "$lock")" "$owner" ;;
    esac
    return 0
  fi
  [ -d "$lock" ] || return 1
  printf '%s\n' "$lock"
}

# fm_afk_daemon_lock_pid <lock-path>
# Print the pid recorded in the lock owner, empty when unreadable.
fm_afk_daemon_lock_pid() {
  local owner
  owner=$(fm_afk_daemon_lock_owner "$1") || return 1
  cat "$owner/pid" 2>/dev/null || true
}

# fm_afk_daemon_pid_matches <pid> <owner-dir> <daemon-path> [strict]
# True when the live pid really is that daemon. The recorded pid identity is
# authoritative when present. Without one, fall back to the process command:
# strict mode (1) accepts only the full bin/fm-supervise-daemon.sh path, while
# the default also accepts a bare fm-supervise-daemon.sh command, which is enough
# for the start/refresh decision that already runs inside the owning home.
fm_afk_daemon_pid_matches() {
  local pid=$1 owner=$2 daemon=$3 strict=${4:-0} identity current command
  identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  if [ -n "$identity" ]; then
    current=$(fm_pid_identity "$pid") || return 1
    [ "$current" = "$identity" ]
    return
  fi
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$daemon"*) return 0 ;;
  esac
  [ "$strict" = 1 ] && return 1
  case "$command" in
    *"fm-supervise-daemon.sh"*) return 0 ;;
  esac
  return 1
}

# fm_afk_daemon_alive <lock-path> <daemon-path> [strict]
# True exactly when this home's away-mode daemon lock is held by a live process
# that really is that daemon.
fm_afk_daemon_alive() {
  local lock=$1 daemon=$2 strict=${3:-0} owner pid
  owner=$(fm_afk_daemon_lock_owner "$lock") || return 1
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  fm_afk_daemon_pid_matches "$pid" "$owner" "$daemon" "$strict"
}

# fm_afk_daemon_owns_supervision <state-dir> <bin-dir>
# True exactly when away mode is on AND a live daemon for THIS home is actually
# running supervision. Away mode alone is only the away POSTURE: a home whose
# captain session runs outside any injectable supervisor pane deliberately runs
# away mode with no daemon, and its own watcher stays the real supervision
# mechanism. This home's own lock path is what keeps another home's daemon out;
# strict matching additionally rejects a non-daemon process holding that lock.
fm_afk_daemon_owns_supervision() {
  local state=$1 bindir=$2
  [ -e "$state/.afk" ] || return 1
  fm_afk_daemon_alive "$state/.supervise-daemon.lock" "$bindir/fm-supervise-daemon.sh" 1
}
