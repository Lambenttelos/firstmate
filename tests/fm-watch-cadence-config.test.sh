#!/usr/bin/env bash
# tests/fm-watch-cadence-config.test.sh - the watcher cadence config file
# (config/watcher-cadence) read by bin/fm-watch.sh, and the raised
# signal-coalescing default. docs/configuration.md owns the knob; this suite
# pins its present/absent/malformed contract and the raised FM_SIGNAL_GRACE
# default, then drives a real fm-watch.sh subprocess to prove a rapid no-verb
# burst from one lane coalesces into a single wake while a terminal verb still
# surfaces without paying the coalescing linger.
#
# The resolver cases source bin/fm-watch.sh in a subshell (its source guard
# returns before the lock/loop, so only the top-level knob resolution runs) and
# read the resolved values and CADENCE_WARNINGS the runtime would emit. The
# behavioral cases run a real watcher exactly the way fm-watch-triage.test.sh
# does, so the coalescing proof exercises the shipped loop, not a reimplementation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-cadence-config)

# --- resolver harness -------------------------------------------------------
#
# Source the watcher in a subshell with an isolated state/config home, no env
# knobs, and print the three resolved cadence values plus the collected
# CADENCE_WARNINGS. The source guard makes this load the knob block and return
# before acquiring the singleton lock or entering the loop.
# Usage: resolve_cadence <config-dir> [env assignment ...]
resolve_cadence() {  # <config-dir> [VAR=val ...]
  local cfg=$1 state
  shift
  state="$cfg/state"
  mkdir -p "$state"
  # shellcheck disable=SC2016  # the bash -c body must expand in the child shell, not here
  env -u FM_POLL -u FM_SIGNAL_GRACE -u FM_HEARTBEAT \
    FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$cfg" "$@" bash -c '
      . "$1" >/dev/null 2>&1
      printf "poll=%s signal_grace=%s heartbeat=%s\n" "$POLL" "$SIGNAL_GRACE" "$HEARTBEAT"
      printf "warnings=%s\n" "$CADENCE_WARNINGS"
    ' _ "$WATCH"
}

test_absent_uses_defaults() {
  local cfg out
  cfg="$TMP_ROOT/absent"; mkdir -p "$cfg"
  # No config/watcher-cadence file at all.
  out=$(resolve_cadence "$cfg")
  printf '%s' "$out" | grep -q 'poll=300 signal_grace=240 heartbeat=600' \
    || fail "absent cadence file did not yield built-in defaults: $out"
  printf '%s' "$out" | grep -q 'warnings=$' \
    || fail "absent cadence file produced a warning: $out"
  pass "absent config/watcher-cadence uses the built-in defaults (poll 300, signal_grace 240, heartbeat 600), no warning"
}

test_present_overrides() {
  local cfg out
  cfg="$TMP_ROOT/present"; mkdir -p "$cfg"
  cat > "$cfg/watcher-cadence" <<'EOF'
# operator-tuned cadence
signal_grace = 90
poll=120
heartbeat = 300
EOF
  out=$(resolve_cadence "$cfg")
  printf '%s' "$out" | grep -q 'poll=120 signal_grace=90 heartbeat=300' \
    || fail "present cadence file did not override the defaults: $out"
  printf '%s' "$out" | grep -q 'warnings=$' \
    || fail "a clean cadence file produced a warning: $out"
  pass "present config/watcher-cadence overrides all three knobs, no warning"
}

test_malformed_falls_back_loudly() {
  local cfg out
  cfg="$TMP_ROOT/malformed"; mkdir -p "$cfg"
  cat > "$cfg/watcher-cadence" <<'EOF'
signal_grace = later
poll = 120
EOF
  out=$(resolve_cadence "$cfg")
  # The malformed signal_grace falls back to its default 240; the valid poll wins.
  printf '%s' "$out" | grep -q 'poll=120 signal_grace=240 heartbeat=600' \
    || fail "malformed value did not fall back to default while keeping the valid one: $out"
  # And it is reported LOUDLY, never silently.
  printf '%s' "$out" | grep -q "warnings=.*malformed signal_grace 'later'" \
    || fail "malformed cadence value fell back silently (no warning): $out"
  pass "a malformed cadence value falls back to its default AND is reported loudly"
}

test_unknown_key_warns() {
  local cfg out
  cfg="$TMP_ROOT/unknown"; mkdir -p "$cfg"
  cat > "$cfg/watcher-cadence" <<'EOF'
poll = 120
signl_grace = 90
EOF
  out=$(resolve_cadence "$cfg")
  # The typo'd key is ignored (defaults stand) but surfaced, so the operator sees
  # why the value they wrote was not honored.
  printf '%s' "$out" | grep -q 'poll=120 signal_grace=240 heartbeat=600' \
    || fail "unknown key changed a knob it should not: $out"
  printf '%s' "$out" | grep -q "warnings=.*unknown cadence key 'signl_grace'" \
    || fail "an unknown cadence key was ignored silently (no warning): $out"
  pass "an unknown cadence key is ignored but reported loudly"
}

test_env_wins_over_file() {
  local cfg out
  cfg="$TMP_ROOT/envwins"; mkdir -p "$cfg"
  cat > "$cfg/watcher-cadence" <<'EOF'
signal_grace = 90
EOF
  out=$(resolve_cadence "$cfg" FM_SIGNAL_GRACE=15)
  printf '%s' "$out" | grep -q 'signal_grace=15' \
    || fail "env FM_SIGNAL_GRACE did not win over the file: $out"
  pass "an explicit env knob still wins over the file (operator override and test seam intact)"
}

test_raised_default_is_240() {
  local cfg out
  cfg="$TMP_ROOT/default240"; mkdir -p "$cfg"
  out=$(resolve_cadence "$cfg")
  printf '%s' "$out" | grep -q 'signal_grace=240' \
    || fail "the raised signal-coalescing default is not 240: $out"
  # Drift guard: the raised default and its evidence-comment live in the tracked file.
  grep -q 'signal_grace 240' "$WATCH" \
    || fail "bin/fm-watch.sh does not document the raised signal_grace default of 240"
  pass "the tracked signal-coalescing default is raised to 240s (from 30)"
}

# --- behavioral: a real watcher over the shipped loop ------------------------

# Portable stat signature, mirroring fm-watch.sh's stat_sig exactly, so a primed
# .seen-* marker matches a pre-existing status and does not fire on it.
seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

wait_for_exit() {  # <pid> <limit-0.1s-ticks>
  local pid=$1 limit=${2:-40} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# A rapid no-verb burst from ONE lane (a working: append, its turn-end, another
# working: append) must coalesce into a SINGLE queued wake, not several. The
# watcher lingers SIGNAL_GRACE after the first changed signal and re-scans, so
# every write inside that window collapses into one signal: wake. We drive a
# real fm-watch.sh with a short grace (the mechanism is identical at 240; the
# window length is just faster to test) and a provably-working crew so the
# no-verb wake is absorbed-and-queued as one event.
test_burst_coalesces_into_one_wake() {
  local dir state fakebin out i
  dir="$TMP_ROOT/burst"; state="$dir/state"; fakebin="$dir/fakebin"
  mkdir -p "$state" "$fakebin"
  out="$dir/watch.out"
  # A stopped crew makes the no-verb burst actionable (it must surface), which is
  # exactly the case where the coalescing matters: without it firstmate would be
  # woken once per append. We assert the whole burst produces ONE queue record.
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: unknown · source: none · stopped\n'
exit 0
SH
  chmod +x "$fakebin/fm-crew-state.sh"

  # Launch the watcher with a 2s coalescing grace and a fast poll. No status yet,
  # so the first cycle idles; then we write the burst inside one grace window.
  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=2 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    PATH="$fakebin:$PATH" "$WATCH" > "$out" &
  local pid=$!
  # Let the watcher reach its idle wait, then fire the burst quickly.
  sleep 0.5
  printf 'working: step one\n' > "$state/burst.status"
  printf 'working: step two\n' >> "$state/burst.status"
  : > "$state/burst.turn-ended"
  printf 'working: step three\n' >> "$state/burst.status"

  wait_for_exit "$pid" 60 || { reap "$pid"; fail "watcher did not surface the burst: $(cat "$out")"; }
  reap "$pid"

  # Exactly one signal: wake was emitted for the whole burst.
  local emitted
  emitted=$(grep -c '^signal:' "$out" 2>/dev/null || printf 0)
  [ "$emitted" = 1 ] || fail "burst emitted $emitted signal wakes, expected 1 coalesced wake: $(cat "$out")"

  # And the drained queue records all carry the SAME coalesced wake reason: the
  # watcher woke firstmate ONCE for the whole burst. (fm_wake_append writes one
  # queue record per changed file by design, but every record names the one
  # coalesced "signal: <all files>" reason, so firstmate re-arms a single time.)
  local drain_out reasons distinct
  drain_out="$dir/drain.out"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after burst failed"
  reasons=$(grep "$(printf '\tsignal\t')" "$drain_out" 2>/dev/null | sed 's/.*\(signal: .*\)/\1/')
  distinct=$(printf '%s\n' "$reasons" | sort -u | grep -c . )
  [ "$distinct" = 1 ] || fail "burst produced $distinct distinct wake reasons, expected 1 coalesced reason: $(cat "$drain_out")"
  pass "a rapid no-verb burst from one lane coalesces into a single wake and one coalesced wake reason"
}

# A terminal verb present in the FIRST scan must NOT pay the coalescing linger:
# raising SIGNAL_GRACE batches chatter, but a real done:/failed:/needs-decision:/
# blocked: has to surface promptly. We set a LONG grace and assert the watcher
# surfaces the terminal signal well before that grace could elapse.
test_terminal_verb_skips_linger() {
  local dir state fakebin out
  dir="$TMP_ROOT/terminal"; state="$dir/state"; fakebin="$dir/fakebin"
  mkdir -p "$state" "$fakebin"
  out="$dir/watch.out"
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: unknown · source: none · stopped\n'
exit 0
SH
  chmod +x "$fakebin/fm-crew-state.sh"

  # A very long grace: if the terminal verb paid the linger, the watcher would
  # take ~30s to surface. It must surface far faster because the first scan is
  # already actionable by verb.
  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=30 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    PATH="$fakebin:$PATH" "$WATCH" > "$out" &
  local pid=$!
  sleep 0.5
  local started elapsed
  started=$(date +%s)
  printf 'needs-decision: pick A or B\n' > "$state/term.status"

  # Surface within ~6s (well under the 30s grace). Poll is 1s, so a couple of
  # cycles is plenty; a linger-paying path would blow past this bound.
  wait_for_exit "$pid" 60 || { reap "$pid"; fail "terminal verb never surfaced: $(cat "$out")"; }
  elapsed=$(( $(date +%s) - started ))
  reap "$pid"
  grep -q '^signal:' "$out" || fail "terminal verb did not emit a signal wake: $(cat "$out")"
  [ "$elapsed" -lt 15 ] || fail "terminal verb took ${elapsed}s to surface, so it paid the ${FM_SIGNAL_GRACE:-30}s coalescing linger it must skip"
  pass "a terminal verb in the first scan surfaces promptly (${elapsed}s), skipping the coalescing linger"
}

test_absent_uses_defaults
test_present_overrides
test_malformed_falls_back_loudly
test_unknown_key_warns
test_env_wins_over_file
test_raised_default_is_240
test_burst_coalesces_into_one_wake
test_terminal_verb_skips_linger
