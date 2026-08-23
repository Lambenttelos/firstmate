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
  # Scope the probe lock into this home so concurrent test runs (and a real
  # host-global probe) never collide; the default lock is host-global.
  env "${CRITICAL_ENV[@]}" "$@" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_RESOURCE_PROBE_LOCK="$home/state/.resource-probe.lock" "$PROBE"
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

# The probe lock is HOST-GLOBAL by default, not scoped to one home's state dir,
# so N treehouse worktrees on one host cannot each launch a heavy sweep at once
# (the OOM defect in data/20260823T031739Z-home-oom-fm-resource-probe-runaway).
test_default_lock_is_host_global_not_per_home() {
  local home path
  home=$(make_home global-lock)
  # Ask the script for the default lock with NO override; it must live outside
  # this home's state dir, keyed per operating user under TMPDIR.
  path=$(env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROBE" --lock-path)
  case "$path" in
    "$home"/*) fail "the default probe lock is inside the home ($path); it must be host-global" ;;
  esac
  assert_contains "$path" "fm-resource-probe-" \
    "the host-global lock path lost its per-user probe name: '$path'"
  pass "the default probe lock is host-global, shared across every worktree and home"
}

# A probe holding the host-global lock blocks a probe from a DIFFERENT home
# pointed at the same lock: exactly the cross-worktree cap the per-home lock
# lacked. run_probe scopes the lock per-home, so this test shares one lock
# between two homes explicitly to exercise the cross-home path.
test_host_global_lock_serializes_across_homes() {
  local home_b shared sleeper rc
  home_b=$(make_home cross-b)
  shared="$TMP_ROOT/shared-host.lock"
  sleep 60 &
  sleeper=$!
  mkdir -p "$shared.owner.test"
  printf '%s\n' "$sleeper" > "$shared.owner.test/pid"
  ln -s "$shared.owner.test" "$shared"
  rc=0
  env "${CRITICAL_ENV[@]}" FM_HOME="$home_b" FM_STATE_OVERRIDE="$home_b/state" \
    FM_RESOURCE_PROBE_LOCK="$shared" "$PROBE" || rc=$?
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  expect_code 0 "$rc" "a probe deferring on the host-global lock should exit cleanly"
  assert_absent "$home_b/state/.resource-reading" \
    "a probe from another home must defer while the host-global lock is held"
  pass "the host-global lock serializes probes across homes, not just within one worktree"
}

# The address-space ceiling is inherited by the sweep and its backend children.
# Rather than starve a real sweep (fragile, and noisy under an extreme cap), drive
# a fake sweep that simply reports the `ulimit -v` it inherited, so the assertion
# is deterministic and proves the cap actually binds child processes.
test_memory_ceiling_binds_child_processes() {
  local home fakeroot seen want
  home=$(make_home mem-cap)
  fakeroot="$TMP_ROOT/memroot"
  mkdir -p "$fakeroot/bin"
  cat > "$fakeroot/bin/fm-resource-check.sh" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  --interval) echo 900; exit 0 ;;
esac
# Report the inherited address-space limit (KB) so the test can assert the cap
# reached this child, then a normal critical reading so the probe still publishes.
printf 'resources: critical | ulimitv=%s | load 99\n' "$(ulimit -v)"
exit 2
FAKE
  chmod +x "$fakeroot/bin/fm-resource-check.sh"
  cp "$PROBE" "$fakeroot/bin/fm-resource-probe.sh"
  cp "$ROOT/bin/fm-mutex-lib.sh" "$fakeroot/bin/fm-mutex-lib.sh"
  cp "$ROOT/bin/fm-pid-lib.sh" "$fakeroot/bin/fm-pid-lib.sh"
  env "${CRITICAL_ENV[@]}" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_RESOURCE_PROBE_LOCK="$home/state/.resource-probe.lock" \
    FM_RESOURCE_PROBE_MEM_MB=512 \
    "$fakeroot/bin/fm-resource-probe.sh"
  assert_present "$home/state/.resource-reading" \
    "the probe with a memory ceiling should still publish a reading"
  seen=$(sed -n 's/.*ulimitv=\([0-9]*\).*/\1/p' "$home/state/.resource-reading")
  want=$(( 512 * 1024 ))
  [ -n "$seen" ] || fail "the fake sweep did not report its inherited ulimit -v"
  [ "$seen" = "$want" ] \
    || fail "the sweep child inherited ulimit -v $seen KB, expected $want KB from the cap"
  pass "the address-space ceiling is inherited by the sweep and its children"
}

# A disabled ceiling (0) must not break a normal reading.
test_memory_ceiling_zero_disables_the_cap() {
  local home
  home=$(make_home mem-cap-off)
  run_probe "$home" FM_RESOURCE_PROBE_MEM_MB=0
  assert_present "$home/state/.resource-reading" \
    "a probe with the memory ceiling disabled should still publish normally"
  pass "a zero memory ceiling disables the cap without changing the reading"
}

# The captured-output cap truncates a huge sweep stream instead of reading it all
# into memory, while preserving the sweep's own exit status. Drive it with a fake
# check script through FM_ROOT_OVERRIDE so no real backend is touched.
test_output_cap_truncates_a_runaway_sweep() {
  local home fakeroot rec reading
  home=$(make_home out-cap)
  fakeroot="$TMP_ROOT/fakeroot"
  mkdir -p "$fakeroot/bin"
  # A fake sweep that floods stdout then exits 2 (critical), the status the probe
  # must still honor after truncation.
  cat > "$fakeroot/bin/fm-resource-check.sh" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  --interval) echo 900; exit 0 ;;
esac
yes "resources: critical | load 99 spam spam spam spam spam" 2>/dev/null
exit 2
FAKE
  chmod +x "$fakeroot/bin/fm-resource-check.sh"
  # Point the probe at the fake check dir by copying itself beside it so its
  # SCRIPT_DIR resolves the fake sibling.
  cp "$PROBE" "$fakeroot/bin/fm-resource-probe.sh"
  cp "$ROOT/bin/fm-mutex-lib.sh" "$fakeroot/bin/fm-mutex-lib.sh"
  cp "$ROOT/bin/fm-pid-lib.sh" "$fakeroot/bin/fm-pid-lib.sh"
  env "${CRITICAL_ENV[@]}" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_RESOURCE_PROBE_LOCK="$home/state/.resource-probe.lock" \
    FM_RESOURCE_PROBE_MAX_BYTES=4096 \
    "$fakeroot/bin/fm-resource-probe.sh"
  assert_present "$home/state/.resource-reading" \
    "the probe should still publish the truncated critical reading"
  assert_grep critical "$home/state/.resource-status" \
    "the sweep's critical status must survive output truncation"
  rec=$(cat "$home/state/.resource-reading")
  reading=${rec#*$'\t'*$'\t'}
  [ "${#reading}" -le 4096 ] \
    || fail "the captured reading was not truncated to the cap (${#reading} bytes)"
  pass "the output cap truncates a runaway sweep while preserving its status"
}

test_probe_publishes_a_timestamped_reading
test_probe_is_not_a_supervision_cycle
test_probe_publishes_nothing_when_disabled
test_a_second_probe_defers_to_a_running_one
test_default_lock_is_host_global_not_per_home
test_host_global_lock_serializes_across_homes
test_memory_ceiling_binds_child_processes
test_memory_ceiling_zero_disables_the_cap
test_output_cap_truncates_a_runaway_sweep
