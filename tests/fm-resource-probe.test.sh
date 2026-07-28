#!/usr/bin/env bash
# Tests for bin/fm-resource-probe.sh, the watcher's host/crew-liveness probe
# cycle that runs OFF the supervision main loop.
#
# The probe is deliberately NOT a second supervision cycle: it publishes a
# timestamped reading to the state cache, takes its own lock, and never touches
# the watcher singleton lock or the durable wake queue. These tests pin that
# separation, the freshness token the reading carries, and the singleton
# guarantee that keeps two probes from double-reading one host.
#
# Every reading is INJECTED (FM_RESOURCE_* overrides), so no assertion here
# depends on the machine the suite happens to run on.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROBE="$ROOT/bin/fm-resource-probe.sh"
TMP_ROOT=$(fm_test_tmproot fm-resource-probe)

# A critical host: load 40 over 10 cores. Live crews injected so the sweep does
# not probe a real backend (there are none in a temp home anyway).
CRITICAL_ENV=(
  FM_RESOURCE_INTERVAL=900
  FM_RESOURCE_CORES=10
  FM_RESOURCE_RAM_GB=16
  FM_RESOURCE_LOAD1=40
  FM_RESOURCE_AVAIL_MB=8000
  FM_RESOURCE_SWAP_USED_MB=100
  FM_RESOURCE_SWAP_TOTAL_MB=8192
  FM_RESOURCE_LIVE=3
)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

run_probe() {  # <home> <extra-env>...
  local home=$1
  shift
  env "${CRITICAL_ENV[@]}" "$@" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROBE"
}

test_probe_publishes_a_timestamped_reading() {
  local home rec epoch status now age
  home=$(make_home publish)
  run_probe "$home"
  assert_present "$home/state/.resource-reading" "the probe published no reading"
  assert_present "$home/state/.resource-status" "the probe wrote no bare status word"
  assert_present "$home/state/.last-resource" "the probe left no cadence stamp"
  assert_grep critical "$home/state/.resource-status" "the bare status word was not critical"
  rec=$(cat "$home/state/.resource-reading")
  epoch=${rec%%$'\t'*}
  status=$(printf '%s' "${rec#*$'\t'}" | cut -f1)
  case "$epoch" in ''|*[!0-9]*) fail "the reading carries no numeric age token: '$rec'" ;; esac
  [ "$status" = critical ] || fail "the reading's status field was not critical: '$rec'"
  assert_contains "$rec" "load 40" "the reading lost the underlying figures"
  # The age token must be recent, so a consumer can judge freshness from it.
  now=$(date +%s)
  age=$(( now - epoch ))
  [ "$age" -ge 0 ] && [ "$age" -lt 120 ] \
    || fail "the reading's age token is not a recent completion time (age ${age}s)"
  pass "the probe publishes a timestamped, status-labelled reading"
}

test_probe_is_not_a_supervision_cycle() {
  local home
  home=$(make_home not-a-watcher)
  run_probe "$home"
  # It must never contend the watcher singleton or enqueue a wake: exactly one
  # supervision cycle (the watcher) owns those.
  assert_absent "$home/state/.watch.lock" "the probe touched the watcher singleton lock"
  assert_absent "$home/state/.wake-queue" "the probe wrote to the durable wake queue"
  pass "the probe handles no wakes and never fights the watcher singleton"
}

test_probe_publishes_nothing_when_disabled() {
  local home
  home=$(make_home disabled)
  run_probe "$home" FM_RESOURCE_INTERVAL=0
  assert_absent "$home/state/.resource-status" "a disabled monitor must publish nothing"
  assert_absent "$home/state/.resource-reading" "a disabled monitor must publish no reading"
  pass "a disabled monitor publishes nothing"
}

test_a_second_probe_defers_to_a_running_one() {
  local home lock owner sleeper rc
  home=$(make_home singleton)
  # Simulate a probe already running: build the advisory lock by hand, its pid
  # naming a live process, exactly the shape fm-mutex-lib.sh creates.
  sleep 60 &
  sleeper=$!
  lock="$home/state/.resource-probe.lock"
  owner="$home/state/.resource-probe.lock.owner.test"
  mkdir -p "$owner"
  printf '%s\n' "$sleeper" > "$owner/pid"
  ln -s "$owner" "$lock"
  rc=0
  run_probe "$home" || rc=$?
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  expect_code 0 "$rc" "a deferring probe should exit cleanly"
  assert_absent "$home/state/.resource-reading" \
    "a second probe must not publish while another holds the lock"
  pass "a second probe defers to a running one instead of double-reading the host"
}

test_probe_publishes_a_timestamped_reading
test_probe_is_not_a_supervision_cycle
test_probe_publishes_nothing_when_disabled
test_a_second_probe_defers_to_a_running_one
