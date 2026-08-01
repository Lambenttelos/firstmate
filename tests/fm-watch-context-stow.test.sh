#!/usr/bin/env bash
# tests/fm-watch-context-stow.test.sh - the always-on watcher's OWN-context
# stow-nudge sweep (context_stow_sweep in bin/fm-watch.sh). This is the interim
# Option-B enforcement: while NORMAL supervision runs (no away-mode daemon), the
# watcher nudges firstmate to /stow + /compact once its own context crosses the
# stow threshold, so knowledge is persisted before a context reset can lose it.
#
# The sweep is proven behaviorally: below threshold = no nudge; at/above =
# exactly one nudge (queue record + marker + wake reason); a second poll while
# still over = still one (dedupe); after the marker is cleared / count re-armed =
# silent again until a re-crossing; a live away-mode daemon owning triage = the
# watcher stays out of it; and an unreadable / unsupported-harness count fails
# closed. Sourcing fm-watch.sh loads its functions and returns before the
# singleton lock or the blocking loop, so the sweep is called directly.
#
# The daemon-side twin (context_stow_check) is covered in fm-daemon.test.sh; the
# shared threshold/hysteresis reader in fm-secondmate-context.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-context-stow-tests)
mkdir -p "$TMP_ROOT"

WATCH="$ROOT/bin/fm-watch.sh"

# Build a fake claude transcript under <config>/projects/<munged-home> so the
# shared reader (fm_sm_claude_context_tokens) returns a controllable count for
# FM_CONTEXT_STOW_CWD=<home>. The context count is input + cache_creation +
# cache_read input tokens on the last main-thread usage line.
write_own_transcript() {  # <config> <home> <input> <cc> <cr>
  local config=$1 home=$2 input=$3 cc=$4 cr=$5 dir
  dir="$config/projects/$(printf '%s' "$home" | tr '/.' '--')"
  mkdir -p "$dir"
  printf '{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}\n' \
    "$input" "$cc" "$cr" > "$dir/session.jsonl"
}

# Run context_stow_sweep in a subshell with a hermetic environment (state,
# config, claude transcript dir, and the claude harness), capturing the sweep's
# stdout - the "check: ..." wake reason wake() prints, or empty when it stayed
# silent. wake() calls exit 0, so the subshell contains it. The subshell sources
# fm-watch.sh, which returns before the main loop.
run_sweep() {  # <state> <config> <home> [extra env KEY=VAL ...]
  local state=$1 config=$2 home=$3; shift 3
  # shellcheck disable=SC2016  # $1 is expanded by the inner bash -c, not this shell.
  env FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$config" \
    FM_HOME="$home" FM_CONTEXT_STOW_CWD="$home" \
    FM_SUPERVISOR_HARNESS=claude CLAUDE_CONFIG_DIR="$config" \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_POLL=1 \
    "$@" \
    bash -c '. "$1" >/dev/null 2>&1; context_stow_sweep' _ "$WATCH"
}

setup_case() {  # <name> -> echoes "<state> <config> <home>"
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/config" "$dir/home"
  printf '%s %s %s\n' "$dir/state" "$dir/config" "$dir/home"
}

queue_count() {  # <state> - number of context-stow-nudge records in the wake queue
  local state=$1 q
  q="$state/.wake-queue"
  [ -f "$q" ] || { printf '0'; return; }
  grep -c 'context-stow-nudge' "$q" 2>/dev/null || printf '0'
}

test_below_threshold_is_silent() {
  local state config home out
  read -r state config home <<<"$(setup_case below)"
  # 100000 < default 200000
  write_own_transcript "$config" "$home" 10 20 99970
  out=$(run_sweep "$state" "$config" "$home")
  [ -z "$out" ] || fail "below threshold must print no wake reason, got: $out"
  [ -e "$state/.context-stow-nudged" ] && fail "below threshold must not record the nudge marker"
  [ "$(queue_count "$state")" -eq 0 ] || fail "below threshold must enqueue no wake"
  pass "below threshold: no nudge, no marker, no wake"
}

test_at_threshold_nudges_once() {
  local state config home out
  read -r state config home <<<"$(setup_case at)"
  # 250000 >= default 200000
  write_own_transcript "$config" "$home" 10 20 249970
  out=$(run_sweep "$state" "$config" "$home")
  case "$out" in
    "check: context-stow-nudge"*"/stow now"*) : ;;
    *) fail "crossing must print a context-stow-nudge wake reason, got: $out" ;;
  esac
  [ -e "$state/.context-stow-nudged" ] || fail "crossing must record the nudge marker"
  [ "$(queue_count "$state")" -eq 1 ] || fail "crossing must enqueue exactly one wake"
  pass "at/above threshold: exactly one nudge (wake reason + marker + queue record)"
}

test_second_poll_dedupes() {
  local state config home out
  read -r state config home <<<"$(setup_case dedupe)"
  write_own_transcript "$config" "$home" 10 20 249970
  run_sweep "$state" "$config" "$home" >/dev/null
  [ "$(queue_count "$state")" -eq 1 ] || fail "first crossing should enqueue one wake"
  # Second poll, still over threshold: the marker suppresses a re-nudge.
  out=$(run_sweep "$state" "$config" "$home")
  [ -z "$out" ] || fail "a still-over-threshold second poll must stay silent, got: $out"
  [ "$(queue_count "$state")" -eq 1 ] || fail "a still-over-threshold second poll must not re-enqueue"
  pass "second poll while still over threshold: still one nudge (deduplicated by the marker)"
}

test_post_stow_marker_is_silent_then_rearms() {
  local state config home out
  read -r state config home <<<"$(setup_case rearm)"
  write_own_transcript "$config" "$home" 10 20 249970
  run_sweep "$state" "$config" "$home" >/dev/null
  [ -e "$state/.context-stow-nudged" ] || fail "first crossing should record the marker"
  # A post-stow / compacted session drops below (threshold - hysteresis) = 180000:
  # the marker must clear and the poll stay silent.
  write_own_transcript "$config" "$home" 10 20 99970
  out=$(run_sweep "$state" "$config" "$home")
  [ -z "$out" ] || fail "a below-hysteresis poll must stay silent, got: $out"
  [ -e "$state/.context-stow-nudged" ] && fail "dropping below the hysteresis band must clear the marker"
  # Re-crossing after re-arm nudges again.
  write_own_transcript "$config" "$home" 10 20 249970
  out=$(run_sweep "$state" "$config" "$home")
  case "$out" in
    "check: context-stow-nudge"*) : ;;
    *) fail "re-crossing after re-arm must nudge again, got: $out" ;;
  esac
  [ "$(queue_count "$state")" -eq 2 ] || fail "re-crossing should enqueue a second wake"
  pass "post-stow marker clears, poll goes silent, and a re-crossing nudges again"
}

test_within_hysteresis_stays_armed() {
  local state config home out
  read -r state config home <<<"$(setup_case hysteresis)"
  write_own_transcript "$config" "$home" 10 20 249970
  run_sweep "$state" "$config" "$home" >/dev/null
  [ -e "$state/.context-stow-nudged" ] || fail "first crossing should record the marker"
  # Dip below threshold (200000) but ABOVE (threshold - hysteresis)=180000.
  write_own_transcript "$config" "$home" 10 20 189970
  out=$(run_sweep "$state" "$config" "$home")
  [ -z "$out" ] || fail "a dip into the hysteresis band must stay silent, got: $out"
  [ -e "$state/.context-stow-nudged" ] || fail "a dip into the hysteresis band must NOT re-arm the marker"
  pass "a count that only dips into the hysteresis band keeps the nudge armed"
}

test_fails_closed_on_unreadable_and_unsupported() {
  local state config home out
  read -r state config home <<<"$(setup_case failclosed)"
  # No transcript at all -> unreadable count.
  out=$(run_sweep "$state" "$config" "$home")
  [ -z "$out" ] || fail "an unreadable count must stay silent, got: $out"
  [ -e "$state/.context-stow-nudged" ] && fail "an unreadable count must record no marker (fail closed)"
  [ "$(queue_count "$state")" -eq 0 ] || fail "an unreadable count must enqueue nothing"
  # An unsupported harness reads unknown even with a transcript present.
  write_own_transcript "$config" "$home" 10 20 249970
  out=$(run_sweep "$state" "$config" "$home" FM_SUPERVISOR_HARNESS=codex)
  [ -z "$out" ] || fail "an unsupported harness must stay silent, got: $out"
  [ -e "$state/.context-stow-nudged" ] && fail "an unsupported harness must record no marker (fail closed)"
  pass "unreadable and unsupported-harness counts produce no nudge (fail closed)"
}

test_away_daemon_owns_triage_suppresses_watcher_nudge() {
  local state config home out
  read -r state config home <<<"$(setup_case afk-owned)"
  write_own_transcript "$config" "$home" 10 20 249970
  # A live away-mode daemon owning this home's supervision must keep the watcher
  # out of the nudge - the daemon's own context_stow_check owns it then. Redefine
  # the ownership predicate to "owned" after sourcing, rather than standing up a
  # real daemon, and confirm the sweep stays out.
  # shellcheck disable=SC2016  # $1 is expanded by the inner bash -c, not this shell.
  out=$(env FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$config" \
    FM_HOME="$home" FM_CONTEXT_STOW_CWD="$home" \
    FM_SUPERVISOR_HARNESS=claude CLAUDE_CONFIG_DIR="$config" \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_POLL=1 \
    bash -c '. "$1" >/dev/null 2>&1; afk_daemon_owns_triage() { return 0; }; context_stow_sweep' _ "$WATCH")
  [ -z "$out" ] || fail "a daemon-owned home must not nudge from the watcher, got: $out"
  [ -e "$state/.context-stow-nudged" ] && fail "a daemon-owned home must record no watcher marker"
  [ "$(queue_count "$state")" -eq 0 ] || fail "a daemon-owned home must enqueue no watcher wake"
  pass "while a live away-mode daemon owns triage the watcher sweep stays silent"
}

test_below_threshold_is_silent
test_at_threshold_nudges_once
test_second_poll_dedupes
test_post_stow_marker_is_silent_then_rearms
test_within_hysteresis_stays_armed
test_fails_closed_on_unreadable_and_unsupported
test_away_daemon_owns_triage_suppresses_watcher_nudge

echo "# all fm-watch-context-stow tests passed"
