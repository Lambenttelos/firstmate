#!/usr/bin/env bash
# Library: read a secondmate agent's live context-window occupancy from its
# harness session transcript, and resolve the handoff threshold. Sourced by
# bin/fm-secondmate-context.sh (the reporter), bin/fm-secondmate-handoff.sh
# (the orchestrator), and bin/fm-watch.sh (the threshold monitor). Never prints
# a guess: an unreadable or unsupported harness yields empty output so every
# caller fails closed (no false handoff). See docs/secondmate-context-handoff.md
# for the evidence behind the claude read and the not-applicable verdict for the
# other harnesses.

# Default handoff threshold in context tokens. ~200000 is the point a 200k-window
# model reaches auto-compact; a larger-window model should raise the knob.
FM_SM_CONTEXT_THRESHOLD_DEFAULT=200000

# fm_sm_context_threshold: the configured token threshold, or the default.
# Reads config/secondmate-context-threshold (a single integer, first non-empty
# non-comment line). Absent, non-integer, or non-positive falls back to the
# default rather than failing, so a typo never disables the safety net silently.
# This is the PRIMARY's monitoring knob and is not inherited into secondmate
# homes (secondmates do not spawn secondmates, so nothing downstream reads it).
fm_sm_context_threshold() {  # <config-dir>
  local config=$1 file line
  file="$config/secondmate-context-threshold"
  [ -f "$file" ] || { printf '%s' "$FM_SM_CONTEXT_THRESHOLD_DEFAULT"; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    if [[ "$line" =~ ^[1-9][0-9]*$ ]]; then
      printf '%s' "$line"
    else
      printf '%s' "$FM_SM_CONTEXT_THRESHOLD_DEFAULT"
    fi
    return 0
  done < "$file"
  printf '%s' "$FM_SM_CONTEXT_THRESHOLD_DEFAULT"
}

# fm_sm_claude_projects_dir: the base directory holding claude's per-session
# transcript project folders. Honors $CLAUDE_CONFIG_DIR, else ~/.claude.
fm_sm_claude_projects_dir() {
  printf '%s/projects' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

# fm_sm_munge_path: claude's project-folder name for a launch directory - every
# "/" and "." replaced by "-". Verified in docs/secondmate-context-handoff.md.
fm_sm_munge_path() {  # <absolute-path>
  printf '%s' "$1" | tr '/.' '--'
}

# fm_sm_claude_transcript: the newest-mtime *.jsonl transcript for the claude
# session launched in <cwd>, or empty when none exists. Newest = active session.
fm_sm_claude_transcript() {  # <cwd>
  local cwd=$1 dir f newest=''
  dir="$(fm_sm_claude_projects_dir)/$(fm_sm_munge_path "$cwd")"
  [ -d "$dir" ] || return 0
  # Newest-mtime *.jsonl via -nt (portable, no ls/stat): the active session.
  for f in "$dir"/*.jsonl; do
    [ -f "$f" ] || continue
    if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then
      newest=$f
    fi
  done
  [ -n "$newest" ] && printf '%s' "$newest"
}

# fm_sm_claude_context_tokens: the most recent main-thread turn's context-window
# occupancy (input + cache_creation + cache_read input tokens) from <cwd>'s
# claude transcript. Empty when the transcript, jq, or a usable usage line is
# missing - the caller then treats context as unknown and fails closed.
fm_sm_claude_context_tokens() {  # <cwd>
  local cwd=$1 f line tokens
  command -v jq >/dev/null 2>&1 || return 0
  f=$(fm_sm_claude_transcript "$cwd") || return 0
  [ -n "$f" ] || return 0
  # Last completed MAIN-thread assistant turn: a line carrying message.usage and
  # not a sub-agent sidechain (a Task turn is a separate context). grep streams
  # the file, so a multi-MB transcript stays cheap on the slow-poll cadence.
  line=$(grep '"usage"' "$f" 2>/dev/null | grep -v '"isSidechain":true' | tail -1 || true)
  [ -n "$line" ] || return 0
  tokens=$(printf '%s' "$line" | jq '
      (.message.usage.input_tokens // 0)
    + (.message.usage.cache_creation_input_tokens // 0)
    + (.message.usage.cache_read_input_tokens // 0)' 2>/dev/null || true)
  [[ "$tokens" =~ ^[0-9]+$ ]] || return 0
  [ "$tokens" -gt 0 ] || return 0
  printf '%s' "$tokens"
}

# fm_sm_context_tokens: dispatch the context read by harness. claude and jcode
# have a verified read (docs/secondmate-context-handoff.md); every other harness
# yields empty so the monitor fails closed. <cwd> is the agent's launch
# directory, which for a secondmate is its home= (state/<id>.meta) and for
# firstmate's own read is its operational home (FM_HOME).
#
# jcode (github.com/1jehuang/jcode) is a Claude-Agent-SDK runtime that persists
# the SAME per-session JSONL transcript claude does, under
# <config-dir>/projects/<munged-cwd>/<session-id>.jsonl with a message.usage
# object per assistant turn (verified 2026-08-01; see
# docs/secondmate-context-handoff.md). Its read is therefore byte-identical to
# claude's, so it dispatches to the same reader rather than a duplicate one.
fm_sm_context_tokens() {  # <cwd> <harness>
  local cwd=$1 harness=$2
  [ -n "$cwd" ] || return 0
  case "$harness" in
    claude|jcode) fm_sm_claude_context_tokens "$cwd" ;;
    *) return 0 ;;
  esac
}

# --- firstmate's OWN context stow-nudge threshold ---------------------------
# The point firstmate's OWN context is considered full enough that the away-mode
# daemon should nudge it to /stow (and /compact when the session cannot
# auto-compact). This is a SEPARATE knob from the secondmate handoff threshold
# above: that one decides when to hand a secondmate off to a fresh agent, this
# one decides when to tell firstmate to persist its own knowledge before a
# context reset can lose it. The daemon owns the crossing logic and the nudge
# (bin/fm-supervise-daemon.sh); this library owns only the threshold read and
# the harness dispatch it shares with the secondmate monitor.
FM_CONTEXT_STOW_THRESHOLD_DEFAULT=200000

# fm_context_stow_threshold: the configured own-context stow threshold, or the
# default. Reads config/context-stow-threshold (a single integer, first
# non-empty non-comment line). Absent, non-integer, or non-positive falls back
# to the default rather than failing, so a typo never disables the nudge
# silently - identical robustness to fm_sm_context_threshold above.
fm_context_stow_threshold() {  # <config-dir>
  local config=$1 file line
  file="$config/context-stow-threshold"
  [ -f "$file" ] || { printf '%s' "$FM_CONTEXT_STOW_THRESHOLD_DEFAULT"; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    if [[ "$line" =~ ^[1-9][0-9]*$ ]]; then
      printf '%s' "$line"
    else
      printf '%s' "$FM_CONTEXT_STOW_THRESHOLD_DEFAULT"
    fi
    return 0
  done < "$file"
  printf '%s' "$FM_CONTEXT_STOW_THRESHOLD_DEFAULT"
}
