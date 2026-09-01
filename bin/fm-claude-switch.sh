#!/usr/bin/env bash
# fm-claude-switch.sh - switch the GLOBAL Claude account across both credential
# stores from the captain's desk. The captain asked to swap which account each
# jcode is on, straight from the board.
#
# WHY both stores (two separate stores, deliberately not bridged by captain
# ruling):
#   - the Claude Code store - what `cswap` rotates. Switched with `cswap switch`.
#   - the jcode store (~/.jcode/auth.json) - anthropic_accounts[] + one global
#     active_anthropic_account. Switched by rewriting that one field here.
# The two planes can legitimately sit on different accounts, so this switches
# BOTH by default, and each plane can be targeted alone.
#
# GLOBAL, not per-session. This changes the CONFIGURED global account. It does
# NOT retarget a running session: a live jcode caches its token in process for
# hours, so an already-running agent keeps its old account until it restarts.
# The desk says this plainly; a separate investigation covers per-session.
#
# SAFETY. Real credential state changes here, so:
#   - The jcode write is atomic (temp in the same dir + rename), preserves mode
#     0600, and backs the file up first (auth.json.fm-bak).
#   - Nothing here prints, logs, or copies a token, refresh token, or
#     organizationUuid. Only the label/email index and the active pointer move.
#   - A cswap switch is delegated to `cswap switch`; this never edits the Claude
#     Code credentials file itself.
#
# Usage:
#   fm-claude-switch.sh <email|number> [--plane both|cswap|jcode]
#   fm-claude-switch.sh --list                 print the resolvable targets
#   fm-claude-switch.sh --help
#
# --plane both (default) switches both stores; cswap or jcode targets one.
# A number resolves against `cswap list --json`; an email matches either store.
#
# Exit status:
#   0  the requested plane(s) switched
#   1  a switch failed (message on stderr); any completed plane is reported
#   64 usage error
#   65 the target could not be resolved to a known account
set -euo pipefail

CSWAP_BIN="${FM_CSWAP_BIN:-cswap}"
JCODE_AUTH="${FM_JCODE_AUTH:-$HOME/.jcode/auth.json}"

usage() {
  sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'
}

die() { printf 'fm-claude-switch: %s\n' "$1" >&2; exit "${2:-1}"; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but not found"; }

# resolve_cswap_email <target>: echo the email cswap knows for a number or email,
# empty when it cannot resolve. Read-only.
resolve_cswap_email() {
  local target=$1 raw
  raw=$("$CSWAP_BIN" list --json 2>/dev/null) || return 1
  printf '%s' "$raw" | jq -r --arg t "$target" '
    (.accounts // [])
    | map(select((.number|tostring) == $t or .email == $t))
    | (.[0].email // "")' 2>/dev/null
}

# jcode_label_for_email <email>: echo the jcode label whose email matches, empty
# when none. Read-only.
jcode_label_for_email() {
  local email=$1
  [ -r "$JCODE_AUTH" ] || return 1
  jq -r --arg e "$email" '
    (.anthropic_accounts // [])
    | map(select(.email == $e))
    | (.[0].label // "")' "$JCODE_AUTH" 2>/dev/null
}

# switch_cswap <target>: delegate to cswap switch. cswap owns its own resolution.
switch_cswap() {
  local target=$1
  "$CSWAP_BIN" switch "$target" >/dev/null 2>&1 \
    || die "cswap switch $target failed" 1
}

# switch_jcode <email>: set active_anthropic_account to the label whose email
# matches. Atomic write, mode 0600 preserved, backup first. Never touches tokens.
switch_jcode() {
  local email=$1 label tmp
  [ -r "$JCODE_AUTH" ] || die "jcode auth store not readable: $JCODE_AUTH" 1
  label=$(jcode_label_for_email "$email")
  [ -n "$label" ] || die "no jcode account has email $email" 65

  # Back up before any mutation, so a bad write is recoverable.
  cp -p "$JCODE_AUTH" "$JCODE_AUTH.fm-bak" 2>/dev/null \
    || die "could not back up $JCODE_AUTH" 1

  tmp=$(mktemp "$(dirname "$JCODE_AUTH")/.auth.fm.XXXXXX") \
    || die "could not create a temp file next to $JCODE_AUTH" 1
  # 0600 on the temp before it carries any credential material.
  chmod 600 "$tmp" 2>/dev/null || true
  if ! jq --arg l "$label" '.active_anthropic_account = $l' "$JCODE_AUTH" > "$tmp"; then
    rm -f "$tmp"
    die "failed to rewrite the jcode active account" 1
  fi
  # Preserve the original mode explicitly, then atomically move into place.
  chmod --reference="$JCODE_AUTH" "$tmp" 2>/dev/null || chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$JCODE_AUTH" || { rm -f "$tmp"; die "atomic move failed" 1; }
  printf 'jcode: active account -> %s (%s)\n' "$label" "$email"
}

list_targets() {
  need jq
  local raw
  if raw=$("$CSWAP_BIN" list --json 2>/dev/null); then
    printf 'Claude Code store (cswap):\n'
    printf '%s' "$raw" | jq -r '
      (.accounts // [])[]
      | "  \(.number) \(.email)\(if .active then "  (active)" else "" end)\(if .disabled then "  (disabled)" else "" end)"'
  fi
  if [ -r "$JCODE_AUTH" ]; then
    printf 'jcode store (~/.jcode/auth.json):\n'
    jq -r '
      .active_anthropic_account as $a
      | (.anthropic_accounts // [])[]
      | "  \(.label) \(.email)\(if .label == $a then "  (active)" else "" end)"' "$JCODE_AUTH"
  fi
}

main() {
  local target="" plane="both"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --list) list_targets; exit 0 ;;
      --plane) plane="${2:-}"; [ -n "$plane" ] || die "--plane needs a value" 64; shift 2 ;;
      --plane=*) plane="${1#--plane=}"; shift ;;
      -*) die "unknown option: $1" 64 ;;
      *)
        if [ -z "$target" ]; then target="$1"; else die "unexpected argument: $1" 64; fi
        shift ;;
    esac
  done
  [ -n "$target" ] || die "a target account (email or number) is required" 64
  case "$plane" in both|cswap|jcode) ;; *) die "--plane must be both, cswap, or jcode" 64 ;; esac

  need jq
  need "$CSWAP_BIN"

  # Resolve the email once so both planes act on the same account. A number is
  # only meaningful to cswap; the jcode plane needs the email it maps to.
  local email="$target"
  case "$target" in
    *@*) : ;;                                   # already an email
    *) email=$(resolve_cswap_email "$target"); [ -n "$email" ] || die "could not resolve account $target" 65 ;;
  esac

  case "$plane" in
    cswap) switch_cswap "$target" ;;
    jcode) switch_jcode "$email" ;;
    both)
      # Both planes mutate, so resolve and validate the target in BOTH stores up
      # front. A target missing from either plane fails here, before either store
      # changes, so the two can never end up on different accounts. A number is
      # already cswap-resolved above; re-check an email against cswap as well.
      case "$target" in
        *@*) [ -n "$(resolve_cswap_email "$target")" ] || die "could not resolve account $target" 65 ;;
      esac
      [ -r "$JCODE_AUTH" ] || die "jcode auth store not readable: $JCODE_AUTH" 1
      [ -n "$(jcode_label_for_email "$email")" ] || die "no jcode account has email $email" 65
      switch_cswap "$target"
      printf 'Claude Code: switched to %s\n' "$email"
      switch_jcode "$email"
      ;;
  esac
}

main "$@"
