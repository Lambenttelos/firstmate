#!/usr/bin/env bash
# Print this home's away-mode supervision-ownership state: owned, undetermined,
# or free.
#
# Thin CLI over fm_afk_daemon_supervision_state in bin/fm-afk-daemon-lib.sh, so a
# non-shell auto-arm adapter (the OpenCode plugin under .opencode/plugins/) can
# ask the SAME owner the shell guards ask instead of reimplementing the question
# and drifting from them. Away mode alone is only the away posture: a home in
# daemon-free away mode still arms and repairs its own watcher, so an adapter
# that gates on state/.afk would leave that home unsupervised.
#
# Home resolution matches the guards: FM_HOME, then FM_STATE_OVERRIDE.
# Exits 0 when a daemon owns supervision here (owned or undetermined, per the
# fail direction documented in bin/fm-afk-daemon-lib.sh) and 1 otherwise, so the
# state word on stdout and the exit status always agree.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-afk-daemon-lib.sh
. "$SCRIPT_DIR/fm-afk-daemon-lib.sh"

state=$(fm_afk_daemon_supervision_state "$STATE" "$SCRIPT_DIR")
printf '%s\n' "$state"
case "$state" in
  owned|undetermined) exit 0 ;;
esac
exit 1
