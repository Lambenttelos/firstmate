#!/usr/bin/env bash
# fm-account-orchestrator.sh - firstmate's thin CALLER of the quota-axi
# account-switch orchestrator (ADR 0031, Phase 1).
#
# firstmate is a CALLER only. The decision brain (quota-axi `decide`) and the
# single fenced mutation verb (quota-axi `switch`) live in quota-axi and own all
# account-selection and actuation logic. This script never reimplements either;
# it builds the pure inputs those verbs consume, invokes them, and reads back
# their versioned JSON. It pins to `decide`'s DecisionResponse (schemaVersion 1:
# decisions[] each with scope/action/chosenAccount?/reasons[]) and `switch`'s
# SwitchResponse (schemaVersion 1: outcomes[]); see the merged shapes in
# projects/quota-axi/src/orchestrator/decide.ts and switch.ts.
#
# Two firstmate integration points call this script:
#   1. SPAWN (bin/fm-spawn.sh, a jcode/Claude worker): `resolve-account` consults
#      `decide` so the worker is pinned to a non-exhausted Claude account rather
#      than launched onto one `decide` reports exhausted (reserve floor crossed,
#      tripwire in the future, priming-gated).
#   2. WATCHER (bin/fm-watch.sh, a live limit-error/tripwire wake): `rotate` calls
#      `switch` (which re-runs decide internally, folds recorded tripwires,
#      actuates the jcode live-session surface, and records the tripwire) so the
#      fleet rotates onto the next non-exhausted Claude account WITHOUT captain
#      intervention. firstmate does not itself touch jcode sessions or write
#      tripwire state; `switch` owns both.
#
# Subcommands (one JSON or a status line on stdout; diagnostics on stderr):
#   resolve-account [--current <acct>] [--now <iso>]
#       Consult `decide` and print the chosen Claude account label on stdout, or
#       print nothing and exit 0 (FAIL-SOFT) when the orchestrator is unavailable,
#       lacks the new verbs, errors, or returns an unusable/keep/hold decision -
#       so a caller keeps the current account rather than blocking the spawn.
#   rotate [--current <acct>] [--now <iso>] [--dry-run]
#       Invoke `switch` to rotate live jcode/Claude sessions off the current
#       (just-tripped) account onto the next non-exhausted one, recording the
#       tripwire. Prints switch's --json result on stdout on success. FAIL-SOFT:
#       an unavailable/verb-lacking/erroring orchestrator exits non-zero with a
#       diagnostic and issues no jcode calls (the manual bin/fm-switch-account.sh
#       broadcast remains the fallback).
#   recognize-tripwire <text...>|-   (- reads stdin)
#       The single owner of the jcode/Claude limit-error catalog: exit 0 when the
#       text is a recognized "account exhausted" limit error, exit 1 otherwise.
#       See is_tripwire_error below and docs/account-orchestrator.md for the
#       catalog and its provenance.
#   supports   Exit 0 when the resolved quota-axi exposes the merged decide/switch
#       verbs, exit 1 otherwise. Cheap capability probe for callers.
#
# The tripwire store PATH is used consistently between the decide-at-spawn read
# (folded into observations here) and the switch-on-tripwire write (switch owns
# the write), so an exhausted account actually stays out. It defaults to
# quota-axi's own store (QUOTA_AXI_TRIPWIRES, else ~/.cache/quota-axi/tripwires.json)
# and is overridable with FM_ORCH_TRIPWIRES for tests.
#
# Environment overrides (all optional; the defaults are the live path):
#   FM_DISPATCH_QUOTA_AXI  quota-axi command (shared with fm-dispatch-select.sh).
#   FM_ORCH_QUOTA_JSON     a quota `--json` fixture file instead of a live call.
#   FM_ORCH_TRIPWIRES      tripwire store path (also exported to quota-axi as
#                          QUOTA_AXI_TRIPWIRES so decide/switch agree on it).
#   FM_ORCH_AUTH_JSON      jcode auth.json (for the active-account default).
#   FM_ORCH_RECOVER_SECS   tripwire recovery window in seconds (switch default 24h).
#   FM_ORCH_NOW            decision clock ISO (tests); else wall clock.
#
# Phase 1 scope (STRICT): jcode workers, Claude accounts, account-only. A non-jcode
# or non-Claude caller never reaches this script. No cross-provider, model-map, or
# model switch is performed here; the switch core keeps rotation account-only.
set -u

RECOVER_SECS="${FM_ORCH_RECOVER_SECS:-}"

log() { printf 'fm-account-orchestrator: %s\n' "$*" >&2; }

usage() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0" >&2
}

# --- the limit-error catalog -------------------------------------------------
#
# is_tripwire_error is the SINGLE OWNER of the jcode/Claude "account exhausted"
# recognizer. It is derived from the REAL error strings jcode's Anthropic runtime
# emits and classifies, observed in the merged jcode clone (not invented):
#   - crates/jcode-provider-anthropic-runtime/src/lib.rs is_retryable_error and
#     is_fable_scoped_limit_error match "rate limit"/"rate_limit", "usage limit"/
#     "usage_limit", "429 too many requests", and a JSON body
#     {"type":"rate_limit_error",...}.
#   - crates/jcode-provider-anthropic-runtime/src/anthropic_tests.rs asserts the
#     live shapes: `429 {"type":"rate_limit_error","message":"You have reached
#     your weekly Fable limit"}`, `usage limit reached for the 7-day model
#     window`, and `global 5-hour rate limit reached`.
#
# CRITICAL EXCLUSION: an "overloaded"/"overloaded_error" or a 5xx is a TRANSIENT
# server fault jcode retries, NOT account exhaustion, so it must NOT trip a
# rotation (anthropic_tests.rs asserts is_fable_scoped_limit_error is false for
# "429 overloaded_error: service temporarily overloaded"). A bare network drop is
# likewise excluded. Matching those would rotate the whole fleet off a healthy
# account on a transient blip.
#
# This recognizer is deliberately NARROW: it is the smallest safe set that covers
# the observed real limit errors and nothing transient. The related status-line
# vocabulary (a worker's own `blocked:`/`paused:` note carrying "usage limit",
# "quota", etc.) is owned separately by bin/fm-classify-lib.sh's
# FM_CLASSIFY_AUTH_EXHAUSTION_RE; that catalog classifies a worker's SELF-REPORT,
# while this one classifies a RAW provider error string. Keep the two aligned but
# distinct - see docs/account-orchestrator.md.
FM_ORCH_TRIPWIRE_RE_DEFAULT='rate[ _-]?limit|usage[ _-]?limit|429 too many requests|"type"[[:space:]]*:[[:space:]]*"rate_limit_error"|reached your[a-z0-9 -]*limit|limit reached'

is_tripwire_error() {  # <text>
  local text=$1 lower
  lower=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')
  # Transient faults are never account exhaustion: exclude them first so an
  # "overloaded" 429 or a 5xx never trips a rotation.
  case "$lower" in
    *overloaded*) return 1 ;;
  esac
  case "$lower" in
    *'500 internal server error'*|*'502 bad gateway'*|\
    *'503 service unavailable'*|*'504 gateway timeout'*) return 1 ;;
  esac
  printf '%s' "$lower" | grep -qE "${FM_ORCH_TRIPWIRE_RE:-$FM_ORCH_TRIPWIRE_RE_DEFAULT}"
}

# --- quota-axi resolution and capability -------------------------------------

quota_cmd() { printf '%s' "${FM_DISPATCH_QUOTA_AXI:-quota-axi}"; }

# 0 when the resolved quota-axi exposes the merged decide AND switch verbs. The
# OLD upstream (v0.1.x) accepts `<verb> --help` but silently routes it to the
# top-level quota help and exits 0, so a per-verb --help exit code CANNOT tell the
# versions apart. Instead probe the top-level help's own command list: the merged
# CLI advertises `decide` and `switch` in its `commands[...]:` line, the old CLI
# lists only `quota, auth`. This fails closed for the old CLI (and for a missing
# binary), so every caller degrades to its fail-soft path rather than shelling a
# verb the installed CLI silently ignores.
orch_supports() {
  local cmd help; cmd=$(quota_cmd)
  command -v "$cmd" >/dev/null 2>&1 || return 1
  help=$("$cmd" --help 2>&1) || return 1
  printf '%s' "$help" | grep -qiE '(^|[^a-z])decide([^a-z]|$)' || return 1
  printf '%s' "$help" | grep -qiE '(^|[^a-z])switch([^a-z]|$)' || return 1
  return 0
}

# Resolve the tripwire store path and export it to quota-axi so decide (via the
# observations we fold) and switch (which writes it) agree on ONE store.
tripwire_store() {
  if [ -n "${FM_ORCH_TRIPWIRES:-}" ]; then
    printf '%s' "$FM_ORCH_TRIPWIRES"
    return 0
  fi
  if [ -n "${QUOTA_AXI_TRIPWIRES:-}" ]; then
    printf '%s' "$QUOTA_AXI_TRIPWIRES"
    return 0
  fi
  printf '%s' "${XDG_CACHE_HOME:-$HOME/.cache}/quota-axi/tripwires.json"
}

# The currently-active Claude account label, best effort, from jcode's auth.json.
# Empty when it cannot be read - decide then makes a fresh (no-current) choice.
active_account() {
  local auth="${FM_ORCH_AUTH_JSON:-${JCODE_HOME:-$HOME/.jcode}/auth.json}"
  [ -f "$auth" ] || return 0
  grep -o '"active_anthropic_account"[[:space:]]*:[[:space:]]*"[^"]*"' "$auth" 2>/dev/null \
    | head -1 | sed 's/.*"\([^"]*\)"$/\1/'
}

# The live quota --json (or the FM_ORCH_QUOTA_JSON fixture). Prints nothing and
# fails when quota data is unavailable, so callers fail-soft.
quota_json() {
  if [ -n "${FM_ORCH_QUOTA_JSON:-}" ]; then
    cat "$FM_ORCH_QUOTA_JSON" 2>/dev/null || return 1
    return 0
  fi
  local cmd; cmd=$(quota_cmd)
  command -v "$cmd" >/dev/null 2>&1 || return 1
  "$cmd" --json 2>/dev/null
}

# Build the observations file `decide`/`switch` consume. It projects the ONE
# active account's live claude window telemetry (Phase 1 fetches no per-account
# telemetry for the others), then folds the durable tripwire store so a tripped
# account stays out. When <force-current-exhausted> is 1 the active account is
# marked exhausted so decide rotates OFF it (the tripwire path).
#
# Args: <out-file> <current-account> <now-iso> <force-current-exhausted:0|1>
build_observations() {
  local out=$1 current=$2 now=$3 force=$4
  local qjson store recover_until
  qjson=$(quota_json) || return 1
  store=$(tripwire_store)

  # Claude provider windows -> {windowId: percentRemaining}. Absent/invalid quota
  # yields an empty window map, which decide treats as unknown telemetry (never a
  # reason to switch away from a working account), so this stays fail-soft.
  local windows_json
  windows_json=$(printf '%s' "$qjson" | jq -c '
    ([.providers[]? | select(.provider == "claude") | .windows // []] | add // [])
    | map(select((.percentRemaining|type) == "number"))
    | map({(.id|tostring): .percentRemaining}) | add // {}
  ' 2>/dev/null) || windows_json='{}'
  [ -n "$windows_json" ] || windows_json='{}'

  # Recovery deadline used when forcing the current account exhausted.
  local secs="${RECOVER_SECS:-86400}"
  recover_until=$(date -u -d "@$(( $(date -u -d "$now" +%s 2>/dev/null || date -u +%s) + secs ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')

  # Assemble observations with jq: the active account carries the live windows
  # (and, when forced, an exhaustedUntil), then fold every recorded tripwire.
  local tripwires_json='{}'
  if [ -f "$store" ]; then
    tripwires_json=$(jq -c '.tripwires // {}' "$store" 2>/dev/null || printf '{}')
    [ -n "$tripwires_json" ] || tripwires_json='{}'
  fi

  jq -n \
    --arg now "$now" \
    --arg current "$current" \
    --argjson windows "$windows_json" \
    --argjson tripwires "$tripwires_json" \
    --arg force "$force" \
    --arg until "$recover_until" '
    def sess: if ($current | length) > 0 then [{id: "spawn", currentAccount: $current}] else [{id: "spawn"}] end;
    # Base observation for the active account.
    (if ($current | length) > 0 then
       { ($current): (
           { windows: $windows, freshness: "known" }
           + (if $force == "1" and ($until | length) > 0 then { exhaustedUntil: $until } else {} end)
         ) }
     else {} end) as $base
    # Fold recorded tripwires (exhaustedUntil) for every account, without
    # clobbering the active account base beyond adding the deadline.
    | ($tripwires | to_entries | map({ key: .key, value: { windows: {}, exhaustedUntil: .value.exhaustedUntil } }) | from_entries) as $tw
    | ($tw * $base) as $obs
    | {
        now: $now,
        harness: "jcode",
        provider: "claude",
        sessions: sess,
        observations: $obs
      }
  ' > "$out" 2>/dev/null || return 1
  return 0
}

now_iso() {
  if [ -n "${FM_ORCH_NOW:-}" ]; then printf '%s' "$FM_ORCH_NOW"; return 0; fi
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# --- subcommands -------------------------------------------------------------

cmd_resolve_account() {
  local current="" now=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --current) current=${2:-}; shift 2 ;;
      --current=*) current=${1#--current=}; shift ;;
      --now) now=${2:-}; shift 2 ;;
      --now=*) now=${1#--now=}; shift ;;
      *) log "resolve-account: ignoring unknown arg '$1'"; shift ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || { log "jq missing; keeping current account"; return 0; }
  [ -n "$current" ] || current=$(active_account)
  [ -n "$now" ] || now=$(now_iso)

  if ! orch_supports; then
    log "quota-axi decide/switch unavailable; keeping current account (fail-soft)"
    return 0
  fi

  local store; store=$(tripwire_store)
  local tmp; tmp=$(mktemp 2>/dev/null) || { log "mktemp failed; keeping current account"; return 0; }
  if ! QUOTA_AXI_TRIPWIRES="$store" build_observations "$tmp" "$current" "$now" 0; then
    rm -f "$tmp"
    log "could not build observations (quota data unavailable); keeping current account"
    return 0
  fi

  local out chosen action
  out=$(QUOTA_AXI_TRIPWIRES="$store" "$(quota_cmd)" decide --observations "$tmp" --json 2>/dev/null)
  local rc=$?
  rm -f "$tmp"
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    log "decide failed (exit $rc); keeping current account"
    return 0
  fi
  action=$(printf '%s' "$out" | jq -r '.decisions[0].action // ""' 2>/dev/null)
  chosen=$(printf '%s' "$out" | jq -r '.decisions[0].chosenAccount // ""' 2>/dev/null)
  if [ -z "$chosen" ] || [ "$chosen" = null ]; then
    log "decide returned action=${action:-none} with no chosen account; keeping current account"
    return 0
  fi
  log "decide chose account '$chosen' (action=${action:-unknown}, current=${current:-none})"
  printf '%s\n' "$chosen"
  return 0
}

cmd_rotate() {
  local current="" now="" dry=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --current) current=${2:-}; shift 2 ;;
      --current=*) current=${1#--current=}; shift ;;
      --now) now=${2:-}; shift 2 ;;
      --now=*) now=${1#--now=}; shift ;;
      --dry-run) dry=1; shift ;;
      *) log "rotate: ignoring unknown arg '$1'"; shift ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || { log "jq missing; cannot rotate"; return 1; }
  [ -n "$current" ] || current=$(active_account)
  [ -n "$now" ] || now=$(now_iso)

  if ! orch_supports; then
    log "quota-axi decide/switch unavailable; NOT rotating (manual fallback: bin/fm-switch-account.sh)"
    return 1
  fi

  local store; store=$(tripwire_store)
  local tmp; tmp=$(mktemp 2>/dev/null) || { log "mktemp failed; cannot rotate"; return 1; }
  # Force the current account exhausted so decide (run inside switch) rotates off
  # it; switch records the durable tripwire so it stays out until recovery.
  if ! QUOTA_AXI_TRIPWIRES="$store" build_observations "$tmp" "$current" "$now" 1; then
    rm -f "$tmp"
    log "could not build observations; cannot rotate"
    return 1
  fi

  local args=(switch --observations "$tmp" --tripwires "$store" --json)
  [ -n "${RECOVER_SECS:-}" ] && args+=(--recover-after-seconds "$RECOVER_SECS")
  [ "$dry" -eq 1 ] && args+=(--dry-run)

  local out rc
  out=$(QUOTA_AXI_TRIPWIRES="$store" "$(quota_cmd)" "${args[@]}" 2>/dev/null)
  rc=$?
  rm -f "$tmp"
  if [ "$rc" -ne 0 ]; then
    log "switch exited $rc; rotation did not complete (manual fallback: bin/fm-switch-account.sh)"
    [ -n "$out" ] && printf '%s\n' "$out"
    return 1
  fi
  printf '%s\n' "$out"
  return 0
}

cmd_recognize_tripwire() {
  local text
  if [ "$#" -eq 0 ] || [ "$1" = "-" ]; then
    text=$(cat)
  else
    text="$*"
  fi
  is_tripwire_error "$text"
}

main() {
  local sub="${1:-}"
  [ "$#" -gt 0 ] && shift || true
  case "$sub" in
    resolve-account) cmd_resolve_account "$@" ;;
    rotate) cmd_rotate "$@" ;;
    recognize-tripwire) cmd_recognize_tripwire "$@" ;;
    supports) orch_supports ;;
    -h|--help|help|'') usage; [ -z "$sub" ] && return 2 || return 0 ;;
    *) log "unknown subcommand '$sub'"; usage; return 2 ;;
  esac
}

main "$@"
