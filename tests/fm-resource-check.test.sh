#!/usr/bin/env bash
# Tests for host-resource monitoring: bin/fm-resource-check.sh's thresholds and
# ceiling, and the watcher wiring that surfaces pressure to firstmate.
#
# Every reading is INJECTED (FM_RESOURCE_* overrides), so no assertion here
# depends on the machine the suite happens to run on. tests/lib.sh switches the
# monitor off for the rest of the suite; this file re-enables it deliberately.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-resource-check.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-resource-check)

# A healthy 10-core / 16 GB host: load 0.5 per core, plenty of memory, idle swap.
# Each test overrides only the readings it is actually about.
HEALTHY_ENV=(
  FM_RESOURCE_INTERVAL=900
  FM_RESOURCE_CORES=10
  FM_RESOURCE_RAM_GB=16
  FM_RESOURCE_LOAD1=5.0
  FM_RESOURCE_AVAIL_MB=8000
  FM_RESOURCE_SWAP_USED_MB=100
  FM_RESOURCE_SWAP_TOTAL_MB=8192
  FM_RESOURCE_LIVE=3
)

# run_check <override>...: run the check with the healthy baseline plus the given
# overrides, setting OUT and RC. It sets globals rather than echoing, because a
# command substitution would run it in a subshell and throw the exit status away.
OUT=
RC=0
run_check() {
  RC=0
  OUT=$(env "${HEALTHY_ENV[@]}" "$@" "$CHECK" 2>&1) || RC=$?
}

# run_raw <env-assignment>...: same, without the healthy baseline, for the probe
# tests that must leave readings unset.
run_raw() {
  RC=0
  OUT=$(env "$@" "$CHECK" 2>&1) || RC=$?
}

# blind_probe_bin <dir>: a fakebin where no kernel-wide probe can answer.
blind_probe_bin() {
  local dir=$1 fakebin
  mkdir -p "$dir/emptyproc"
  fakebin=$(fm_fakebin "$dir")
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/sysctl"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/vm_stat"
  chmod +x "$fakebin/sysctl" "$fakebin/vm_stat"
  printf '%s\n' "$fakebin"
}

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_healthy_reading_reports_every_metric() {
  run_check
  expect_code 0 "$RC" "healthy host exit"
  assert_contains "$OUT" "resources: healthy" "healthy status missing"
  assert_contains "$OUT" "load 5.0 (0.5x over 10 cores)" "load per core missing"
  assert_contains "$OUT" "avail 8000 MB of 16 GB" "available memory missing"
  assert_contains "$OUT" "swap 1% of 8192M" "swap usage missing"
  assert_contains "$OUT" "recommended ceiling" "recommended ceiling missing"
  assert_not_contains "$OUT" "SHED" "healthy host must not advise shedding"
  pass "a healthy host reports load, memory, swap and a ceiling and exits 0"
}

test_load_thresholds() {
  # 2.0x per core is the degraded edge; 4.0x is the critical edge.
  run_check FM_RESOURCE_LOAD1=19.9
  expect_code 0 "$RC" "just under the degraded load edge"
  assert_contains "$OUT" "resources: healthy" \
    "1.99x per core must stay healthy even though it DISPLAYS as 2.0x"

  run_check FM_RESOURCE_LOAD1=20
  expect_code 1 "$RC" "degraded load exit"
  assert_contains "$OUT" "resources: degraded" "2.0x per core must be degraded"

  run_check FM_RESOURCE_LOAD1=39.9
  expect_code 1 "$RC" "just under the critical load edge"
  assert_contains "$OUT" "resources: degraded" "3.99x per core must stay degraded"

  run_check FM_RESOURCE_LOAD1=40
  expect_code 2 "$RC" "critical load exit"
  assert_contains "$OUT" "resources: critical" "4.0x per core must be critical"
  pass "load per core classifies healthy, degraded and critical at its edges"
}

test_swap_thresholds() {
  run_check FM_RESOURCE_SWAP_USED_MB=4095   # 49.99% of 8192
  expect_code 0 "$RC" "just under the degraded swap edge"
  assert_contains "$OUT" "resources: healthy" "just under 50% swap must stay healthy"

  run_check FM_RESOURCE_SWAP_USED_MB=4096   # exactly 50%
  expect_code 1 "$RC" "degraded swap exit"
  assert_contains "$OUT" "resources: degraded" "50% swap must be degraded"

  run_check FM_RESOURCE_SWAP_USED_MB=6553   # 79.99%, displays as 80%
  expect_code 1 "$RC" "just under the critical swap edge"
  assert_contains "$OUT" "resources: degraded" \
    "a reading that only ROUNDS to 80% must not be classified critical"

  run_check FM_RESOURCE_SWAP_USED_MB=6554   # 80.005%
  expect_code 2 "$RC" "critical swap exit"
  assert_contains "$OUT" "resources: critical" "80% swap must be critical"
  pass "swap occupancy classifies degraded at 50% and critical at 80%, on exact values"
}

test_memory_headroom_threshold_and_ceiling() {
  run_check FM_RESOURCE_AVAIL_MB=1024
  expect_code 0 "$RC" "1024 MB available is still healthy"
  assert_contains "$OUT" "recommended ceiling 1" "1024 MB supports exactly one crew"

  run_check FM_RESOURCE_AVAIL_MB=1023
  expect_code 2 "$RC" "sub-gigabyte headroom exit"
  assert_contains "$OUT" "resources: critical" "under 1024 MB available must be critical"
  pass "memory headroom classifies critical under 1 GB and binds the ceiling"
}

test_worst_of_three_decides_the_status() {
  run_check FM_RESOURCE_LOAD1=40 FM_RESOURCE_SWAP_USED_MB=4096
  expect_code 2 "$RC" "worst-of-three exit"
  assert_contains "$OUT" "resources: critical" "degraded swap must not soften a critical load"
  pass "the worst of load, swap and memory decides the status"
}

test_shed_advice_names_the_overage_only_when_over_ceiling() {
  run_check FM_RESOURCE_LOAD1=40 FM_RESOURCE_AVAIL_MB=3000 FM_RESOURCE_LIVE=8
  expect_code 2 "$RC" "over-ceiling critical exit"
  assert_contains "$OUT" "recommended ceiling 2" "ceiling should be the memory bound (3000 MB)"
  assert_contains "$OUT" "SHED 6 crew(s)" "shed advice must name the overage"
  assert_contains "$OUT" "test and browser runs" "shed advice must name the expensive work first"

  run_check FM_RESOURCE_LOAD1=40 FM_RESOURCE_LIVE=1
  expect_code 2 "$RC" "under-ceiling critical exit"
  assert_not_contains "$OUT" "SHED" "a fleet already under the ceiling has nothing to shed"
  pass "shed advice appears only when live crews exceed the recommended ceiling"
}

test_live_crew_count_comes_from_recorded_work() {
  local home
  home=$(make_home live-count)
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "harness=echo"
  fm_write_meta "$home/state/beta.meta" "window=firstmate:fm-beta" "harness=echo"
  RC=0
  OUT=$(env FM_RESOURCE_INTERVAL=900 FM_RESOURCE_CORES=10 FM_RESOURCE_RAM_GB=16 \
    FM_RESOURCE_LOAD1=5.0 FM_RESOURCE_AVAIL_MB=8000 FM_RESOURCE_SWAP_USED_MB=100 \
    FM_RESOURCE_SWAP_TOTAL_MB=8192 FM_HOME="$home" "$CHECK" 2>&1) || RC=$?
  expect_code 0 "$RC" "live-count exit"
  assert_contains "$OUT" "live crews 2" "live crews must be counted from recorded work"
  pass "the live-crew count comes from this home's recorded work"
}

test_unreadable_host_is_unknown_and_never_alarms() {
  local fakebin dir
  dir="$TMP_ROOT/unreadable"
  fakebin=$(blind_probe_bin "$dir")
  run_raw PATH="$fakebin:$PATH" FM_RESOURCE_INTERVAL=900 FM_RESOURCE_PROC_ROOT="$dir/emptyproc"
  expect_code 3 "$RC" "unreadable host exit"
  assert_contains "$OUT" "resources: unknown" "an unreadable host must report unknown"
  assert_not_contains "$OUT" "critical" "an unreadable host must not alarm"
  pass "a host with no kernel-wide reading is unknown, not a false alarm"
}

test_partial_reading_never_passes_as_healthy() {
  local fakebin dir
  dir="$TMP_ROOT/partial"
  fakebin=$(blind_probe_bin "$dir")
  # Everything but swap is injected; swap has no probe left to answer it.
  run_raw PATH="$fakebin:$PATH" FM_RESOURCE_INTERVAL=900 FM_RESOURCE_PROC_ROOT="$dir/emptyproc" \
    FM_RESOURCE_CORES=10 FM_RESOURCE_RAM_GB=16 FM_RESOURCE_LOAD1=1.0 \
    FM_RESOURCE_AVAIL_MB=8000 FM_RESOURCE_LIVE=0
  expect_code 3 "$RC" "partial reading exit"
  assert_contains "$OUT" "resources: unknown" "a partial reading must report unknown"
  pass "a partially readable host is unknown rather than reported healthy"
}

test_interval_knob_is_resolved_in_one_place() {
  local got
  got=$(FM_RESOURCE_INTERVAL='' "$CHECK" --interval)
  [ "$got" = 900 ] || fail "default interval should be 900, got '$got'"
  got=$(FM_RESOURCE_INTERVAL=120 "$CHECK" --interval)
  [ "$got" = 120 ] || fail "explicit interval should be honored, got '$got'"
  got=$(FM_RESOURCE_INTERVAL=nonsense "$CHECK" --interval)
  [ "$got" = 900 ] || fail "a malformed interval must fall back to the default, got '$got'"
  got=$(FM_RESOURCE_INTERVAL=0 "$CHECK" --interval)
  [ "$got" = 0 ] || fail "0 should resolve as disabled, got '$got'"
  pass "the sweep interval resolves from one place, with a safe malformed fallback"
}

test_interval_is_independent_of_the_watcher_poll_cadence() {
  local got
  got=$(FM_POLL=15 FM_CHECK_INTERVAL=30 FM_RESOURCE_INTERVAL='' "$CHECK" --interval)
  [ "$got" = 900 ] || fail "the resource cadence must not follow FM_POLL/FM_CHECK_INTERVAL, got '$got'"
  pass "the resource cadence is independent of the watcher poll and check cadences"
}

test_disabled_monitor_reports_and_never_classifies() {
  run_check FM_RESOURCE_INTERVAL=0 FM_RESOURCE_LOAD1=40
  expect_code 4 "$RC" "disabled monitor exit"
  assert_contains "$OUT" "monitoring disabled" "disabled monitor must say so"
  assert_not_contains "$OUT" "critical" "a disabled monitor must not classify the host"
  pass "FM_RESOURCE_INTERVAL=0 switches the monitor off with its own exit status"
}

# --- watcher wiring ---------------------------------------------------------

test_watcher_surfaces_pressure_once_and_queues_it() {
  local home out status drained
  home=$(make_home watcher-critical)
  out="$home/out.txt"
  status=0
  env "${HEALTHY_ENV[@]}" FM_RESOURCE_INTERVAL=1 FM_RESOURCE_LOAD1=40 \
    FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 8 >"$out" 2>/dev/null || status=$?
  expect_code 0 "$status" "resource wake checkpoint exit"
  assert_contains "$(cat "$out")" "check: host-resources" "host pressure was not surfaced"
  assert_contains "$(cat "$out")" "critical" "the surfaced wake lost the status"
  assert_contains "$(cat "$out")" "load 40" "the surfaced wake lost the reading"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tcheck\thost-resources\t' "the resource wake was not queued durably"
  assert_grep critical "$home/state/.resource-status" "the reading was not cached for the heartbeat"
  assert_grep critical "$home/state/.resource-surfaced" "the surfaced level was not recorded"
  pass "the watcher surfaces host pressure as an actionable wake and queues it durably"
}

test_watcher_absorbs_already_reported_pressure() {
  local home out status
  home=$(make_home watcher-repeat)
  printf 'critical\n' > "$home/state/.resource-surfaced"
  out="$home/out.txt"
  status=0
  env "${HEALTHY_ENV[@]}" FM_RESOURCE_INTERVAL=1 FM_RESOURCE_LOAD1=40 \
    FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 4 >"$out" 2>/dev/null || status=$?
  expect_code 124 "$status" "repeat-pressure checkpoint should stay quiet"
  assert_not_contains "$(cat "$out")" "host-resources" "already-reported pressure must not re-wake"
  pass "pressure firstmate already knows about is absorbed instead of nagged"
}

test_watcher_stays_quiet_on_a_healthy_host_and_rearms() {
  local home out status
  home=$(make_home watcher-healthy)
  printf 'critical\n' > "$home/state/.resource-surfaced"
  out="$home/out.txt"
  status=0
  env "${HEALTHY_ENV[@]}" FM_RESOURCE_INTERVAL=1 \
    FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 4 >"$out" 2>/dev/null || status=$?
  expect_code 124 "$status" "healthy-host checkpoint should stay quiet"
  assert_not_contains "$(cat "$out")" "host-resources" "a healthy host must not wake firstmate"
  assert_grep healthy "$home/state/.resource-surfaced" "recovery must re-arm the surfaced level"
  pass "recovery to a healthy host re-arms the monitor silently"
}

test_disabled_monitor_leaves_the_watcher_untouched() {
  local home out status
  home=$(make_home watcher-disabled)
  out="$home/out.txt"
  status=0
  env "${HEALTHY_ENV[@]}" FM_RESOURCE_INTERVAL=0 FM_RESOURCE_LOAD1=40 \
    FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$CHECKPOINT" --seconds 4 >"$out" 2>/dev/null || status=$?
  expect_code 124 "$status" "disabled-monitor checkpoint should stay quiet"
  assert_not_contains "$(cat "$out")" "host-resources" "a disabled monitor must not wake firstmate"
  assert_absent "$home/state/.resource-status" "a disabled monitor must not write state"
  pass "a disabled monitor adds nothing to the watcher"
}

test_heartbeat_carries_the_cached_pressure() {
  local home out status
  home=$(make_home heartbeat-annotation)
  # The daemon owns triage while away mode is on, so every heartbeat is queued -
  # the cheapest way to observe the annotation a fleet review reads.
  : > "$home/state/.afk"
  printf 'critical\n' > "$home/state/.resource-status"
  out="$home/out.txt"
  status=0
  env "${HEALTHY_ENV[@]}" FM_RESOURCE_INTERVAL=0 \
    FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=1 "$CHECKPOINT" --seconds 8 >"$out" 2>/dev/null || status=$?
  expect_code 0 "$status" "heartbeat checkpoint exit"
  assert_contains "$(cat "$out")" "heartbeat (host resources critical)" \
    "the heartbeat lost its host-resource annotation"
  pass "every heartbeat carries the host's latest known pressure"
}

test_heartbeat_is_unannotated_on_a_healthy_host() {
  local home out status
  home=$(make_home heartbeat-healthy)
  : > "$home/state/.afk"
  printf 'healthy\n' > "$home/state/.resource-status"
  out="$home/out.txt"
  status=0
  env "${HEALTHY_ENV[@]}" FM_RESOURCE_INTERVAL=0 \
    FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=1 "$CHECKPOINT" --seconds 8 >"$out" 2>/dev/null || status=$?
  expect_code 0 "$status" "healthy heartbeat checkpoint exit"
  assert_contains "$(cat "$out")" "heartbeat" "the heartbeat itself went missing"
  assert_not_contains "$(cat "$out")" "host resources" \
    "a healthy host must not annotate the heartbeat"
  pass "a healthy host leaves the heartbeat unannotated"
}

test_healthy_reading_reports_every_metric
test_load_thresholds
test_swap_thresholds
test_memory_headroom_threshold_and_ceiling
test_worst_of_three_decides_the_status
test_shed_advice_names_the_overage_only_when_over_ceiling
test_live_crew_count_comes_from_recorded_work
test_unreadable_host_is_unknown_and_never_alarms
test_partial_reading_never_passes_as_healthy
test_interval_knob_is_resolved_in_one_place
test_interval_is_independent_of_the_watcher_poll_cadence
test_disabled_monitor_reports_and_never_classifies
test_watcher_surfaces_pressure_once_and_queues_it
test_watcher_absorbs_already_reported_pressure
test_watcher_stays_quiet_on_a_healthy_host_and_rearms
test_disabled_monitor_leaves_the_watcher_untouched
test_heartbeat_carries_the_cached_pressure
test_heartbeat_is_unannotated_on_a_healthy_host
