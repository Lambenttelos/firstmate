#!/usr/bin/env bash
# Spawn a pi-harness crewmate using the alternate opencode-go API token
# ($OPENCODE_API_KEY_JOE, the captain's "pi-joe" second-token workspace).
# Wraps bin/fm-spawn.sh with `--env OPENCODE_API_KEY=$TOKEN` so the launched pi
# agent (and any process it spawns) inherits the swapped workspace auth.
#
# Usage: fm-spawn-joe.sh <task-id> <project-dir> [--harness pi] [--model M] [--effort E] [...other fm-spawn flags]
#
# Firstmate's own process runs in a non-interactive shell that does NOT source
# ~/.zshenv, so the token exported there is invisible to firstmate by default.
# This wrapper resolves the token in priority order:
#   1. already-exported $OPENCODE_API_KEY_JOE in this process env
#   2. the `export OPENCODE_API_KEY_JOE="..."` line in ~/.zshenv
# and passes it through fm-spawn's --env wrap into the crewmate pane shell.
#
# Fails loudly if the token is missing: a silent empty token would launch pi
# against opencode-go with no auth, failing mid-run with a confusing 429/401
# instead of a clear setup error.
#
# See data/learnings.md `opencode-go-5h-rolling-limit` for the workspace-limit
# context and the claude/opus/low fallback when joe's 5h rolling window is
# saturated.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

resolve_token() {
  local tok="${OPENCODE_API_KEY_JOE:-}"
  if [ -n "$tok" ]; then
    printf '%s' "$tok"
    return 0
  fi
  local zshenv="${HOME}/.zshenv"
  if [ -f "$zshenv" ]; then
    # Extract `export OPENCODE_API_KEY_JOE="..."` (or unquoted) via awk; strip
    # surrounding single or double quotes. awk split on '=' is unsafe because
    # the value may itself contain '=', so match the prefix and substring.
    tok=$(awk '
      /^export[[:space:]]+OPENCODE_API_KEY_JOE=/ {
        sub(/^export[[:space:]]+OPENCODE_API_KEY_JOE=[\"\x27]?/, "")
        sub(/[\"\x27]?$/, "")
        print; exit
      }
    ' "$zshenv")
    if [ -n "$tok" ]; then
      printf '%s' "$tok"
      return 0
    fi
  fi
  return 1
}

TOKEN=$(resolve_token) || {
  echo "error: $(basename "$0"): OPENCODE_API_KEY_JOE not set and not found in ~/.zshenv" >&2
  echo "       set it with: export OPENCODE_API_KEY_JOE=<your-token>  (e.g. in ~/.zshenv)" >&2
  exit 1
}

exec "${FM_SPAWN_JOE_TARGET:-$SCRIPT_DIR/fm-spawn.sh}" "$@" --env "OPENCODE_API_KEY=$TOKEN"