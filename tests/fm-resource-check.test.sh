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

  # A critically loaded host must read as critical: the CPU bound halves the crew
  # count with a floor of 1, so it can never sit at or above the current fleet.
  run_check FM_RESOURCE_LOAD1=40 FM_RESOURCE_LIVE=1
  expect_code 2 "$RC" "single-crew critical exit"
  assert_contains "$OUT" "recommended ceiling 1" \
    "a critical host must not recommend a ceiling above its one live crew"

  run_check FM_RESOURCE_LOAD1=40 FM_RESOURCE_LIVE=2
  expect_code 2 "$RC" "over-ceiling critical exit with two crews"
  assert_contains "$OUT" "recommended ceiling 1" "4.0x per core halves two crews to one"
  assert_contains "$OUT" "SHED 1 crew(s)" "a critical host over its ceiling must advise shedding"

  run_check FM_RESOURCE_LOAD1=20 FM_RESOURCE_LIVE=1
  expect_code 1 "$RC" "under-ceiling degraded exit"
  assert_contains "$OUT" "recommended ceiling 1" "2.0x per core leaves room for one crew"
  assert_not_contains "$OUT" "SHED" "a fleet already under the ceiling has nothing to shed"
  pass "shed advice appears only when live crews exceed the recommended ceiling"
}

# run_in_home <home> <fakebin> <override>...: the healthy baseline minus the
# injected crew count, so the script's own liveness-probing count is exercised.
run_in_home() {
  local home=$1 fakebin=$2
  shift 2
  RC=0
  OUT=$(env PATH="$fakebin:$PATH" FM_RESOURCE_INTERVAL=900 FM_RESOURCE_CORES=10 \
    FM_RESOURCE_RAM_GB=16 FM_RESOURCE_LOAD1=5.0 FM_RESOURCE_AVAIL_MB=8000 \
    FM_RESOURCE_SWAP_USED_MB=100 FM_RESOURCE_SWAP_TOTAL_MB=8192 \
    FM_HOME="$home" "$@" "$CHECK" 2>&1) || RC=$?
}

# fake_tmux <dir> <alive-window-suffix>: a tmux whose pane_current_command reads
# as a live agent only for the named window, and as a bare shell (the confident
# dead verdict) for every other one. An empty suffix makes every probe fail, so
# no verdict is confident and every recorded crew still counts.
fake_tmux() {
  local dir=$1 alive=${2:-} fakebin
  fakebin=$(fm_fakebin "$dir")
  if [ -z "$alive" ]; then
    printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/tmux"
  else
    cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in *$alive) echo claude; exit 0 ;; esac
done
echo zsh
SH
  fi
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_live_crew_count_comes_from_recorded_work() {
  local home fakebin
  home=$(make_home live-count)
  fakebin=$(fake_tmux "$TMP_ROOT/live-count-bin")
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "harness=echo"
  fm_write_meta "$home/state/beta.meta" "window=firstmate:fm-beta" "harness=echo"
  run_in_home "$home" "$fakebin"
  expect_code 0 "$RC" "live-count exit"
  assert_contains "$OUT" "live crews 2" \
    "a crew whose liveness cannot be read must still count"
  pass "recorded work counts as live unless the backend confidently says otherwise"
}

test_live_crew_count_excludes_agents_that_are_not_running() {
  local home fakebin
  home=$(make_home live-count-dead)
  fakebin=$(fake_tmux "$TMP_ROOT/live-count-dead-bin" fm-alpha)
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "harness=claude"
  fm_write_meta "$home/state/beta.meta" "window=firstmate:fm-beta" "harness=claude"
  fm_write_meta "$home/state/gamma.meta" "window=firstmate:fm-gamma" "harness=claude"
  run_in_home "$home" "$fakebin"
  expect_code 0 "$RC" "divergent live-count exit"
  assert_contains "$OUT" "live crews 1" \
    "recorded work whose agent has exited must not count as a live crew"
  pass "the live-crew count follows running agents, not recorded task files"
}

test_injected_live_count_still_wins() {
  local home fakebin
  home=$(make_home live-count-injected)
  fakebin=$(fake_tmux "$TMP_ROOT/live-count-injected-bin" fm-alpha)
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "harness=claude"
  run_in_home "$home" "$fakebin" FM_RESOURCE_LIVE=6
  expect_code 0 "$RC" "injected live-count exit"
  assert_contains "$OUT" "live crews 6" "an injected crew count must be used verbatim"
  pass "the FM_RESOURCE_LIVE injection seam still overrides the probe"
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

test_usage_error_never_looks_like_a_status() {
  local got rc=0
  got=$("$CHECK" --bogus 2>&1) || rc=$?
  [ "$rc" = 64 ] || fail "a bad argument must not exit with a status code (0-4), got '$rc'"
  assert_contains "$got" "unknown argument" "a bad argument should say so"
  pass "a usage error exits outside the status range, so a typo cannot read as critical"
}

test_help_prints_the_whole_header_contract() {
  local got
  got=$("$CHECK" --help)
  assert_contains "$got" "fm-resource-check.sh - one kernel-wide reading" "help lost its opening line"
  assert_contains "$got" "THRESHOLDS" "help lost the thresholds it owns"
  assert_contains "$got" "CEILING" "help lost the ceiling formula it owns"
  assert_contains "$got" "FM_RESOURCE_PROC_ROOT" "help was truncated before the end of the header"
  assert_not_contains "$got" "set -u" "help ran past the header into the script body"
  pass "--help prints the full header contract, however the header grows"
}

test_spawn_help_reaches_the_end_of_its_header() {
  local got
  got=$("$ROOT/bin/fm-spawn.sh" --help)
  assert_contains "$got" "Spawn a direct report" "spawn help lost its opening line"
  assert_contains "$got" "host-resource reading" \
    "spawn help was truncated before its pre-dispatch resource advisory"
  assert_not_contains "$got" "set -eu" "spawn help ran past the header into the script body"
  pass "fm-spawn.sh --help prints its whole header, however the header grows"
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
  # the cheapest way to observe the annotation a fleet review reads. The monitor
  # is ENABLED and reads critical, so the annotation comes from a live sweep; the
  # already-surfaced level absorbs the resource wake so the heartbeat is what the
  # checkpoint observes.
  : > "$home/state/.afk"
  printf 'critical\n' > "$home/state/.resource-surfaced"
  out="$home/out.txt"
  status=0
  env "${HEALTHY_ENV[@]}" FM_RESOURCE_INTERVAL=1 FM_RESOURCE_LOAD1=40 \
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
  out="$home/out.txt"
  status=0
  env "${HEALTHY_ENV[@]}" FM_RESOURCE_INTERVAL=1 \
    FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=1 "$CHECKPOINT" --seconds 8 >"$out" 2>/dev/null || status=$?
  expect_code 0 "$status" "healthy heartbeat checkpoint exit"
  assert_contains "$(cat "$out")" "heartbeat" "the heartbeat itself went missing"
  assert_not_contains "$(cat "$out")" "host resources" \
    "a healthy host must not annotate the heartbeat"
  pass "a healthy host leaves the heartbeat unannotated"
}

test_disabled_monitor_never_annotates_from_a_stale_reading() {
  local home out status
  home=$(make_home heartbeat-disabled-stale)
  : > "$home/state/.afk"
  # Nothing ever clears .resource-status, so a home that switches the monitor off
  # after a bad stretch keeps a critical file on disk forever. It must not leak
  # into the heartbeat.
  printf 'critical\n' > "$home/state/.resource-status"
  out="$home/out.txt"
  status=0
  env "${HEALTHY_ENV[@]}" FM_RESOURCE_INTERVAL=0 \
    FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=1 "$CHECKPOINT" --seconds 8 >"$out" 2>/dev/null || status=$?
  expect_code 0 "$status" "disabled-monitor heartbeat checkpoint exit"
  assert_contains "$(cat "$out")" "heartbeat" "the heartbeat itself went missing"
  assert_not_contains "$(cat "$out")" "host resources" \
    "a disabled monitor must annotate nothing, however old the cached reading is"
  pass "a disabled monitor never annotates a heartbeat from a stale reading"
}

test_stale_reading_never_annotates_a_heartbeat() {
  local home out status
  home=$(make_home heartbeat-stale)
  : > "$home/state/.afk"
  printf 'critical\n' > "$home/state/.resource-status"
  touch -t 202001010000 "$home/state/.resource-status"
  # A fresh sweep marker keeps the long cadence from firing one immediately and
  # overwriting the stale reading this test is about.
  touch "$home/state/.last-resource"
  out="$home/out.txt"
  status=0
  # Enabled, but with a cadence long enough that no sweep runs inside the
  # checkpoint, so the annotation can only come from the stale cached file.
  env "${HEALTHY_ENV[@]}" FM_RESOURCE_INTERVAL=999999 \
    FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=1 "$CHECKPOINT" --seconds 8 >"$out" 2>/dev/null || status=$?
  expect_code 0 "$status" "stale-reading heartbeat checkpoint exit"
  assert_contains "$(cat "$out")" "heartbeat" "the heartbeat itself went missing"
  assert_not_contains "$(cat "$out")" "host resources" \
    "a reading older than two sweeps must not annotate the heartbeat"
  pass "a heartbeat is never annotated from a reading older than two sweeps"
}

test_healthy_reading_reports_every_metric
test_load_thresholds
test_swap_thresholds
test_memory_headroom_threshold_and_ceiling
test_worst_of_three_decides_the_status
test_shed_advice_names_the_overage_only_when_over_ceiling
test_live_crew_count_comes_from_recorded_work
test_live_crew_count_excludes_agents_that_are_not_running
test_injected_live_count_still_wins
test_unreadable_host_is_unknown_and_never_alarms
test_partial_reading_never_passes_as_healthy
test_interval_knob_is_resolved_in_one_place
test_interval_is_independent_of_the_watcher_poll_cadence
test_disabled_monitor_reports_and_never_classifies
test_usage_error_never_looks_like_a_status
test_help_prints_the_whole_header_contract
test_spawn_help_reaches_the_end_of_its_header
test_watcher_surfaces_pressure_once_and_queues_it
test_watcher_absorbs_already_reported_pressure
test_watcher_stays_quiet_on_a_healthy_host_and_rearms
test_disabled_monitor_leaves_the_watcher_untouched
test_heartbeat_carries_the_cached_pressure
test_heartbeat_is_unannotated_on_a_healthy_host
test_disabled_monitor_never_annotates_from_a_stale_reading
test_stale_reading_never_annotates_a_heartbeat
