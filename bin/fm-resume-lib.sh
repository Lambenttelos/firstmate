# shellcheck shell=bash
# Resume-command mapping + resume-token helpers for stuck-crewmate recovery.
# Sourced by bin/fm-spawn.sh (spawn-time capture) and bin/fm-resume-cmd.sh
# (recovery lookup). NEVER executed directly. Sourcing is SIDE-EFFECT-FREE on
# purpose (like bin/fm-token-sessions-lib.sh and bin/fm-pid-lib.sh): it defines
# functions only and creates nothing, so a read-only caller can source it safely.
#
# WHY this exists: a dead crewmate session can be RESUMED in place instead of
# restarted from scratch. Resume restores the harness session's full turn history
# - the original brief and every step of progress - so recovery keeps that work
# instead of re-deriving it from a fresh spawn plus a hand-written progress note.
# fm-spawn captures the harness resume token at spawn (jcode only today: it is the
# one harness whose session store is readable AND whose resolved session id is
# itself the `--resume` token, so the token equals the session_id captured by
# bin/fm-token-sessions-lib.sh; every other harness resolves no session at spawn
# and is skipped, never guessed - the same limitation the session_id= stamp has).
# Recovery maps that token plus the recorded harness= to the exact resume command.
#
# ONE-OWNER NOTE: the resume COMMAND per harness is owned by the harness-adapters
# skill's adapter table. This file mirrors ONLY the by-id resume forms that table
# VERIFIES, and cross-references it rather than inventing new ones:
#   jcode -> `jcode --resume <token>`   (harness-adapters "jcode": Resume row)
#   grok  -> `grok --resume <token>`    (harness-adapters "grok": Resume row)
#   codex -> `codex resume <token>`     (harness-adapters "codex": "Resume after exit")
# claude, opencode, and pi have NO verified resume-BY-ID command in that table
# (opencode and pi resume by cwd/`--continue`, not by a stored session id), so
# they FAIL CLOSED here - fm_resume_command returns non-zero without printing -
# rather than emit a guessed command that could resume the wrong session or fail.

# fm_resume_token_for_harness <harness> <session_id>
# Print the opaque resume token for a just-resolved harness session, or nothing
# when the harness's resolved session id is not usable as a resume token. For
# jcode the session id printed on /quit and returned by fm_resolve_crew_session_id
# IS the `jcode --resume <id>` token, so they coincide and this echoes it back.
# Kept as its own function (rather than reusing session_id= directly at the call
# site) so a FUTURE harness whose resume token DIFFERS from its attribution
# session id has a single place to diverge, without overloading session_id=.
# Always returns 0 (an empty print is the "no token" signal), so a `set -e`
# caller assigning its output in a command substitution is never aborted.
fm_resume_token_for_harness() {
  local harness=$1 session_id=$2
  [ -n "$session_id" ] || return 0
  case "$harness" in
    jcode) printf '%s' "$session_id" ;;
    *) return 0 ;;
  esac
}

# fm_resume_command <harness> <token>
# Print the exact resume launch command for <harness> resuming <token>, or return
# 1 without printing when the harness has no verified by-id resume command or the
# token is empty or unsafe. FAIL-CLOSED: a caller must never fabricate a command
# from a missing or unsupported mapping - an empty print plus non-zero return is
# the signal to fall back to a fresh spawn. The token is validated against a
# conservative charset (real harness session ids are `session_<slug>` shaped:
# letters, digits, and `._-`), so a value carrying shell metacharacters is
# refused rather than emitted into a command line. The printed command is meant to
# run in the task's OWN worktree pane - resume restores the session, not the cwd.
fm_resume_command() {
  local harness=$1 token=$2
  [ -n "$token" ] || return 1
  case "$token" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  case "$harness" in
    jcode) printf 'jcode --resume %s' "$token" ;;
    grok)  printf 'grok --resume %s' "$token" ;;
    codex) printf 'codex resume %s' "$token" ;;
    *) return 1 ;;
  esac
}
