#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's jcode launch-profile VERIFY-AND-RETRY
# (task spawn-model-verify-enforce, incident 2026-08-23, data/learnings.md
# "MODEL DRIFT INCIDENT"). A slash command that loses jcode's popup submit race
# is a silent no-op, so after the brief lands, jcode_post_launch_delivery reads
# the session's ACTUAL model and reasoning_effort back from the jcode session
# store and, on a mismatch with the requested profile, re-sends the slash
# commands and re-reads, bounded by FM_SPAWN_JCODE_VERIFY_TRIES (3). Exhaustion
# appends `blocked: model-drift wanted=<m>/<e> actual=<m>/<e>` to the status
# file and prints the same to the caller; a verified profile is stamped into the
# meta as the CONFIRMED model=/effort= (last-write-wins over the requested
# values the spawn recorded). A default profile, an unresolvable session id, or
# an unreadable store never blocks: verification is skipped with a warning.
#
# These tests extract jcode_post_launch_delivery from bin/fm-spawn.sh (the same
# awk-extraction the brief-submit suite uses) and drive it against a scriptable
# fake backend plus a fake jcode session store (JCODE_SESSIONS_DIR), so no live
# jcode server is needed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-jcode-profile-verify)

# Extract the functions under test from bin/fm-spawn.sh verbatim.
FN_FILE="$TMP_ROOT/jcode_delivery.sh"
SESS_DIR="$TMP_ROOT/sessions"
STATE_DIR="$TMP_ROOT/state"
mkdir -p "$TMP_ROOT" "$SESS_DIR" "$STATE_DIR"
awk '
  /^jcode_post_launch_delivery\(\) \{/ { grab = 1 }
  /^jcode_submit_brief_verified\(\) \{/ { grab = 1 }
  grab { print }
  grab && /^\}/ { grab = 0 }
' "$ROOT/bin/fm-spawn.sh" > "$FN_FILE"
grep -q '^jcode_post_launch_delivery()' "$FN_FILE" \
  || fail "could not extract jcode_post_launch_delivery() from bin/fm-spawn.sh"
grep -q '^jcode_submit_brief_verified()' "$FN_FILE" \
  || fail "could not extract jcode_submit_brief_verified() from bin/fm-spawn.sh"

export FM_ROOT="$ROOT"
export BACKEND=fake
# Zero the settle/wait so the tests run instantly. Keep the retry count at its
# default (3) unless a test overrides it.
export FM_SPAWN_JCODE_READY_POLLS=1
export FM_SPAWN_JCODE_BRIEF_SETTLE=0
export FM_SPAWN_JCODE_BRIEF_SUBMIT_TRIES=3
export FM_SPAWN_JCODE_VERIFY_SETTLE=0
export FM_SPAWN_JCODE_VERIFY_TRIES=3

# The real resolver + store reader run against the fake store dir.
# shellcheck source=bin/fm-token-sessions-lib.sh
. "$ROOT/bin/fm-token-sessions-lib.sh"
export JCODE_SESSIONS_DIR="$SESS_DIR"

# A fake session record the resolver can find: working_dir must realpath-match
# the anchor and created_at must be >= the spawn_ts anchor. The store file stem
# IS the session id (jcode names it <id>.json and the id carries the `session_`
# prefix), so the id field and the filename stem must match.
PROBE_WT="$TMP_ROOT/probe-worktree"
mkdir -p "$PROBE_WT"
SPAWN_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

write_store() {  # <model|-> <effort|->
  local model=$1 effort=$2 sess_file="$SESS_DIR/session_probe.json"
  # A "-" axis becomes a JSON null; a real value is a quoted JSON string.
  if [ "$model" = - ]; then model=null; else model="\"$model\""; fi
  if [ "$effort" = - ]; then effort=null; else effort="\"$effort\""; fi
  cat > "$sess_file" <<EOF
{"id":"session_probe","model":$model,"reasoning_effort":$effort,"working_dir":"$PROBE_WT","created_at":"$SPAWN_TS"}
EOF
}

# --- scriptable fake backend (same contract as the brief-submit suite) ------

SUBMIT_Q="$TMP_ROOT/submit_q"
COMPOSER_Q="$TMP_ROOT/composer_q"
SUBMIT_I="$TMP_ROOT/submit_i"
COMPOSER_I="$TMP_ROOT/composer_i"
CALLS_F="$TMP_ROOT/calls"
STATUS_F="$STATE_DIR/probe.status"
META_F="$STATE_DIR/probe.meta"

_queue_next() {  # <queue-file> <index-file> <default>
  local qf=$1 idxf=$2 def=$3 idx n line
  idx=$(cat "$idxf" 2>/dev/null || printf 0)
  n=$(wc -l < "$qf" 2>/dev/null || printf 0)
  n=${n// /}
  if [ "$n" -eq 0 ]; then
    printf '%s' "$def"
    return 0
  fi
  if [ "$idx" -ge "$n" ]; then
    sed -n "${n}p" "$qf"
    return 0
  fi
  idx=$((idx + 1))
  printf '%s' "$idx" > "$idxf"
  sed -n "${idx}p" "$qf"
}

fm_backend_send_text_submit() {  # <backend> <target> <text> [tries] [alpha] [settle]
  local text=$3 n
  printf 'submit:%s\n' "$text" >> "$CALLS_F"
  # MODEL/MAX are bound by the calling test; when a re-send of the same slash
  # line happens (a RETRY with FIX_ON_RESEND set), apply the profile to the
  # store exactly as a successful slash command would, so the next read verifies.
  if [ -n "${MODEL:-}" ] && [ -n "${FIX_ON_RESEND:-}" ] && [ "$text" = "/model $MODEL" ]; then
    n=$(grep -cF "submit:/model $MODEL" "$CALLS_F")
    if [ "$n" -gt 1 ]; then
      write_store "$MODEL" "${EFFORT:--}"
    fi
  fi
  _queue_next "$SUBMIT_Q" "$SUBMIT_I" unknown
}

fm_backend_composer_state() {  # <backend> <target>
  local v
  v=$(_queue_next "$COMPOSER_Q" "$COMPOSER_I" unknown)
  printf 'composer=%s\n' "$v" >> "$CALLS_F"
  printf '%s' "$v"
}

fm_backend_send_key() {  # <backend> <target> <key>
  printf 'key:%s\n' "$3" >> "$CALLS_F"
  return 0
}

# shellcheck source=/dev/null
. "$FN_FILE"

set_submit_queue() { printf '%s\n' "$@" > "$SUBMIT_Q"; }
set_composer_queue() { printf '%s\n' "$@" > "$COMPOSER_Q"; }

reset_fake() {
  : > "$SUBMIT_Q"; : > "$COMPOSER_Q"; : > "$CALLS_F"
  printf 0 > "$SUBMIT_I"; printf 0 > "$COMPOSER_I"
  : > "$STATUS_F"; : > "$META_F"
  unset MODEL EFFORT FIX_ON_RESEND
}

calls_joined() { paste -sd'|' "$CALLS_F" 2>/dev/null || true; }

count_submit() {  # <text>
  grep -cF "submit:$1" "$CALLS_F" 2>/dev/null || true
}

# run_delivery: drive the extracted function with the given profile + anchors.
# Prints the function's stdout/stderr and its exit code as "$rc <output>".
run_delivery() {  # <model> <effort> [<fix-on-resend:0|1>]
  local model=$1 effort=$2 fix=${3:-0} out rc
  [ "$fix" = 1 ] && export FIX_ON_RESEND=1
  export MODEL="$model" EFFORT="$effort"
  out=$(jcode_post_launch_delivery fakepane /tmp/brief.md "$model" "$effort" "" \
    "$PROBE_WT" "$SPAWN_TS" "$STATUS_F" "$META_F" 2>&1)
  rc=$?
  printf '%s|%s' "$rc" "$out"
}

# --- tests ------------------------------------------------------------------

test_verified_profile_stamps_confirmed_meta() {
  # Happy path: the store already shows the requested profile, so the first
  # read verifies. No re-send, no blocked line; the meta gets the CONFIRMED
  # model=/effort= stamp.
  reset_fake
  set_composer_queue empty
  set_submit_queue empty
  write_store deepseek-v4-flash high
  got=$(run_delivery deepseek-v4-flash high)
  [ "${got%%|*}" = 0 ] || fail "delivery must succeed when the store verifies on the first read; got: $got"
  [ "$(count_submit /model)" = 1 ] || fail "no /model re-send may happen on a verified first read; calls: $(calls_joined)"
  [ "$(count_submit /effort)" = 1 ] || fail "no /effort re-send may happen on a verified first read; calls: $(calls_joined)"
  grep -qx "model=deepseek-v4-flash" "$META_F" \
    || fail "the CONFIRMED model must be stamped into the meta; meta: $(cat "$META_F")"
  grep -qx "effort=high" "$META_F" \
    || fail "the CONFIRMED effort must be stamped into the meta; meta: $(cat "$META_F")"
  [ -s "$STATUS_F" ] && fail "no blocked status may appear on a verified profile; status: $(cat "$STATUS_F")"
  pass "a store that matches on the first read verifies instantly and stamps the confirmed profile"
}

test_lost_model_recovers_through_retry() {
  # The /model slash lost the popup race (store shows a different model). The
  # re-send applies it (FIX_ON_RESEND flips the store on the retry submit, as a
  # successful slash command would), and the SECOND read verifies. Exactly one
  # re-send of each slash line, no blocked status.
  reset_fake
  set_composer_queue empty
  set_submit_queue empty
  write_store claude-opus-4-8 max
  got=$(run_delivery deepseek-v4-flash high 1)
  [ "${got%%|*}" = 0 ] || fail "delivery must succeed once the retried slash applies; got: $got"
  [ "$(count_submit /model)" = 2 ] || fail "exactly one /model re-send expected on a lost-first-submit; calls: $(calls_joined)"
  [ "$(count_submit /effort)" = 2 ] || fail "exactly one /effort re-send expected on a lost-first-submit; calls: $(calls_joined)"
  grep -qx "model=deepseek-v4-flash" "$META_F" \
    || fail "the confirmed model must be stamped after a successful retry; meta: $(cat "$META_F")"
  [ -s "$STATUS_F" ] && fail "no blocked status may appear when the retry recovers; status: $(cat "$STATUS_F")"
  pass "a slash command lost to the popup race is re-sent and verified on the retry read"
}

test_persistent_mismatch_fails_loud_after_bounded_retries() {
  # The slash commands never land (store keeps a foreign profile across every
  # read). Bounded retries: exactly 3 store reads = the initial submit plus 2
  # re-sends per slash line, then a `blocked: model-drift wanted=<m>/<e>
  # actual=<m>/<e>` status line, the same line on stderr, no confirmed stamps.
  reset_fake
  set_composer_queue empty
  set_submit_queue empty
  write_store claude-opus-4-8 max
  out=$(run_delivery deepseek-v4-flash high)
  rc=${out%%|*}
  rest=${out#*|}
  [ "$rc" = 1 ] || fail "delivery must fail after bounded retries still mismatch; rc=$rc out=$out"
  [ "$(count_submit /model)" = 3 ] || fail "bounded retries: exactly 3 /model submits expected (1 initial + 2 re-sends); calls: $(calls_joined)"
  [ "$(count_submit /effort)" = 3 ] || fail "bounded retries: exactly 3 /effort submits expected; calls: $(calls_joined)"
  grep -qx 'blocked: model-drift wanted=deepseek-v4-flash/high actual=claude-opus-4-8/max' "$STATUS_F" \
    || fail "the blocked model-drift line must be appended to the status file; status: $(cat "$STATUS_F")"
  case "$rest" in
    *"blocked: model-drift wanted=deepseek-v4-flash/high actual=claude-opus-4-8/max"*) : ;;
    *) fail "the same blocked line must reach the spawn caller; output: $rest" ;;
  esac
  grep -q "model=deepseek" "$META_F" \
    && fail "no confirmed stamp may be written for a profile that never verified; meta: $(cat "$META_F")"
  pass "a persistently mismatched profile fails loud with a bounded retry count and a blocked: model-drift status"
}

test_default_profile_skips_verification() {
  # A default profile (no requested axis) must not verify at all: no store
  # file needed, no slash submits, no meta stamps, no blocked status - the
  # normal-spawn path stays byte-identical.
  reset_fake
  set_composer_queue empty
  set_submit_queue empty
  SESS_SAVE="$SESS_DIR/session_probe.json"
  rm -f "$SESS_SAVE"
  got=$(run_delivery default default)
  [ "${got%%|*}" = 0 ] || fail "a default-profile delivery must succeed; got: $got"
  [ ! -e "$STATUS_F" ] || [ ! -s "$STATUS_F" ] \
    || fail "no blocked status may appear for a default profile; status: $(cat "$STATUS_F")"
  [ ! -s "$META_F" ] || fail "no confirmed stamps may appear for a default profile; meta: $(cat "$META_F")"
  pass "a default profile spawns exactly as before: no verification, no stamps, no escalation"
}

test_unresolvable_session_warns_and_succeeds() {
  # No session file in the store: the sid cannot be resolved, so verification
  # is skipped with a warning - never a blocked status and never a failure.
  reset_fake
  set_composer_queue empty
  set_submit_queue empty
  rm -f "$SESS_DIR"/session_*.json
  out=$(run_delivery deepseek-v4-flash high)
  rc=${out%%|*}
  rest=${out#*|}
  [ "$rc" = 0 ] || fail "delivery must succeed when the session cannot be resolved; rc=$rc out=$out"
  case "$rest" in
    *"could not resolve the jcode session id"*) : ;;
    *) fail "an unresolvable session id must warn, not silently pass; output: $rest" ;;
  esac
  [ ! -s "$STATUS_F" ] || fail "no blocked status may appear when verification is skipped; status: $(cat "$STATUS_F")"
  pass "an unresolvable session id skips verification with a warning, never a blocked lane"
}

test_effort_only_profile_verifies_effort_axis() {
  # Only the effort axis is requested: the model axis is never compared, and a
  # mismatch on it alone must not block (the sweep enforces only requested
  # axes). A matching effort verifies; the confirmed effort is stamped.
  reset_fake
  set_composer_queue empty
  set_submit_queue empty
  write_store claude-opus-4-8 max
  got=$(run_delivery default max)
  [ "${got%%|*}" = 0 ] || fail "an effort-only verification against a matching store must succeed; got: $got"
  grep -qx "effort=max" "$META_F" \
    || fail "the confirmed effort must be stamped; meta: $(cat "$META_F")"
  grep -q "^model=" "$META_F" \
    && fail "the model axis must not be stamped when it was not requested; meta: $(cat "$META_F")"
  [ -s "$STATUS_F" ] && fail "no blocked status may appear when the requested axis matches; status: $(cat "$STATUS_F")"
  pass "an effort-only profile verifies and stamps only the requested axis"
}

test_verified_profile_stamps_confirmed_meta
test_lost_model_recovers_through_retry
test_persistent_mismatch_fails_loud_after_bounded_retries
test_default_profile_skips_verification
test_unresolvable_session_warns_and_succeeds
test_effort_only_profile_verifies_effort_axis