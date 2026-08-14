#!/usr/bin/env bash
# Detect the agent harness this process tree runs on.
# Usage: fm-harness.sh                  print own harness: claude|codex|opencode|pi|grok|jcode|unknown
#        fm-harness.sh crew             print the effective CREWMATE harness
#                                        (config/crew-harness; "default" resolves to own)
#        fm-harness.sh secondmate [<id>]   print the harness the PRIMARY uses to launch
#                                        SECONDMATE agents: per-id pin -> single-line
#                                        default -> config/crew-harness -> own. "default"
#                                        or absent defers to the crew resolution, so an
#                                        unset secondmate-harness behaves exactly as the
#                                        crew harness did before this knob existed.
#        fm-harness.sh secondmate-model [<id>]   print the optional MODEL token for that
#                                        secondmate, or empty when absent.
#        fm-harness.sh secondmate-effort [<id>]  print the optional EFFORT token for that
#                                        secondmate, or empty when absent.
# config/secondmate-harness format: each non-empty, non-comment line is either
#   1. a DEFAULT line "<harness> [<model>] [<effort>]" (no leading "<id>:"), or
#   2. a PER-ID line "<id>: <harness> [<model>] [<effort>]" pinning one secondmate id.
# All tokens are whitespace-separated. A bare "<harness>" default line (today's format)
# behaves exactly as before: harness only, no model/effort, and applies to every
# secondmate that has no per-id line. Resolution is LINE-LEVEL: when an <id>: line
# matches the requested secondmate id, that whole line is its pin; otherwise the
# single default line applies; otherwise the fallback chain (crew -> own) applies.
# A per-id line whose first token is "default" defers to the crew resolution just like
# a default line's "default" token. The first matching per-id line and the first
# default line are used. Model/effort come ONLY from this file - config/crew-harness
# stays a bare adapter name and is never parsed for a model.
# Detection layers: verified environment markers first, then process ancestry.
# Record each newly verified env marker here.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

detect_own() {
  # Layer 1: environment markers for verified harnesses.
  [ "${CLAUDECODE:-}" = "1" ] && { echo claude; return; }
  [ "${PI_CODING_AGENT:-}" = "true" ] && { echo pi; return; }
  # grok sets GROK_AGENT=1 for its child/tool processes (verified, grok 0.2.73).
  # It does NOT set CLAUDECODE despite being Claude-Code-compatible, so this marker
  # is unambiguous when firstmate runs natively on grok.
  [ "${GROK_AGENT:-}" = "1" ] && { echo grok; return; }
  # jcode (github.com/1jehuang/jcode) sets JCODE_ACTIVE_PROVIDER / JCODE_RUNTIME_PROVIDER
  # for its agent process and runs as comm "jcode" (verified 2026-07-30). It is a
  # Claude-Agent-SDK runtime but does not set CLAUDECODE, so this marker is the
  # unambiguous signal when firstmate runs natively on jcode.
  { [ -n "${JCODE_ACTIVE_PROVIDER:-}" ] || [ -n "${JCODE_RUNTIME_PROVIDER:-}" ]; } && { echo jcode; return; }
  # Layer 2: walk the parent chain and match the command name.
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    case "$(basename "$comm")" in
      *claude*) echo claude; return ;;
      *codex*) echo codex; return ;;
      *opencode*) echo opencode; return ;;
      *grok*) echo grok; return ;;
      *jcode*) echo jcode; return ;;
      pi) echo pi; return ;;
      node*|python*)
        # Bare interpreter: match the harness name in its script path.
        args=$(ps -o args= -p "$pid" 2>/dev/null)
        case "$args" in
          *claude*) echo claude; return ;;
          *codex*) echo codex; return ;;
          *opencode*) echo opencode; return ;;
          *grok*) echo grok; return ;;
          *jcode*) echo jcode; return ;;
          *" pi "*|*/pi) echo pi; return ;;
        esac ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -z "$pid" ] || [ "$pid" -le 1 ]; then
      break
    fi
  done
  echo unknown
}

# Resolve the effective crewmate harness: config/crew-harness (a bare adapter
# name) wins; absent or "default" mirrors firstmate's own harness.
resolve_crew() {
  local crew=
  [ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
  if [ -z "$crew" ] || [ "$crew" = "default" ]; then detect_own; else echo "$crew"; fi
}

# Resolve the effective secondmate-harness LINE for a given secondmate id: the
# first per-id line "<id>: ..." whose id matches wins; otherwise the first default
# line (no leading "<id>:") applies; otherwise nothing. Prints the line with the
# leading "<id>:" token stripped, so callers always see a bare
# "<harness> [<model>] [<effort>]". An empty/absent id resolves the default line
# only (the historical single-line behavior), so unqualified callers are unchanged.
# A per-id token is recognized as the first whitespace-delimited token ending in a
# colon; everything else is a default line.
secondmate_line() {
  local want_id=${1:-} line first rest
  local default_line='' per_id_line=''
  [ -f "$CONFIG/secondmate-harness" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    # shellcheck disable=SC2086  # deliberate word-splitting to peek the first token
    set -- $line
    first=$1
    case "$first" in
      *:)
        # per-id line: "<id>:" is the first token
        [ -n "$want_id" ] || continue
        [ "${first%:}" = "$want_id" ] || continue
        [ -z "$per_id_line" ] || continue
        shift
        rest="$*"
        per_id_line="$rest"
        ;;
      *)
        [ -n "$default_line" ] || default_line="$line"
        ;;
    esac
  done < "$CONFIG/secondmate-harness"
  if [ -n "$per_id_line" ]; then
    printf '%s\n' "$per_id_line"
  elif [ -n "$default_line" ]; then
    printf '%s\n' "$default_line"
  fi
}

# Print the 1-based whitespace-separated token (1=harness, 2=model, 3=effort) of
# the resolved secondmate_line for <id>, or nothing if the line or that field is absent.
secondmate_field() {
  local idx=$1 want_id=${2:-} line
  line=$(secondmate_line "$want_id")
  [ -n "$line" ] || return 0
  # shellcheck disable=SC2086  # deliberate word-splitting: tokenizing the line into fields
  set -- $line
  case "$idx" in
    1) printf '%s\n' "${1:-}" ;;
    2) printf '%s\n' "${2:-}" ;;
    3) printf '%s\n' "${3:-}" ;;
  esac
}

# Resolve the harness the PRIMARY uses to launch SECONDMATE agents: a fallback
# chain per-id pin -> single-line default -> config/crew-harness -> own. An absent
# or "default" harness token defers to the crew resolution, so an unset
# secondmate-harness behaves exactly as before this knob existed (a secondmate
# launched on the crew harness). config/secondmate-harness is the PRIMARY's own
# setting and is never inherited downstream - secondmates do not spawn secondmates.
resolve_secondmate() {
  local want_id=${1:-} sm
  sm=$(secondmate_field 1 "$want_id")
  if [ -z "$sm" ] || [ "$sm" = "default" ]; then resolve_crew; else echo "$sm"; fi
}

# Print the optional model token (2nd field) from the resolved secondmate line for
# <id>, or empty when the harness token is absent/"default" (harness-only or crew
# fallback) or when no model token is present.
resolve_secondmate_model() {
  local want_id=${1:-} sm
  sm=$(secondmate_field 1 "$want_id")
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field 2 "$want_id"
}

# Print the optional effort token (3rd field) the same way.
resolve_secondmate_effort() {
  local want_id=${1:-} sm
  sm=$(secondmate_field 1 "$want_id")
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field 3 "$want_id"
}

case "${1:-}" in
  crew) resolve_crew ;;
  secondmate) resolve_secondmate "${2:-}" ;;
  secondmate-model) resolve_secondmate_model "${2:-}" ;;
  secondmate-effort) resolve_secondmate_effort "${2:-}" ;;
  *) detect_own ;;
esac
