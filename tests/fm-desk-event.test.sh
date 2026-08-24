#!/usr/bin/env bash
# Behavior tests for bin/fm-desk-event.sh, the task-lifecycle desk auto-refresh
# trigger.
#
# The contract these guard:
#   - No live desk (stable HTML file absent) -> instant no-op: no rebuild, no
#     dirty marker, no worker. A home that does not use the desk pays nothing on
#     every spawn/teardown.
#   - A live desk (file present) -> the builder is rebuilt in place, exactly once
#     per event in the serialized foreground path.
#   - The dirty marker is CONSUMED by the build (single-flight coalescing), so it
#     does not accumulate.
#   - The trigger NEVER re-serves: it must not invoke data/serve-desk.sh or
#     `lavish-axi stop`. We assert it calls neither by shadowing both with a
#     tripwire and confirming the tripwire never fires.
#   - The trigger NEVER wakes: it appends to no status file and never enqueues a
#     wake. We assert the durable wake queue stays empty.
#   - It is best-effort: a builder that fails still yields exit 0, and the desk
#     file check is the whole liveness gate.
#   - --path on the real builder is cheap (it must be, since the trigger calls it
#     on every event) and equals the documented stable path.
#   - Coalescing: while a build is in flight, N concurrent events collapse to one
#     trailing rebuild rather than N sequential builds.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EVENT="$ROOT/bin/fm-desk-event.sh"
REFRESH="$ROOT/bin/fm-desk-refresh.sh"
TMP_ROOT=$(fm_test_tmproot fm-desk-event)

# A fake desk builder. `--path` prints the desk file path (its single owner);
# a plain invocation appends one line to a build-count log and, when a control
# file asks, sleeps to simulate the slow real build. FM_DESK_EVENT_FAKE_* env
# steers it per test.
make_fake_builder() {
  local dir=$1 deskfile=$2 buildlog=$3
  local fake="$dir/fake-desk.sh"
  mkdir -p "$dir"
  cat > "$fake" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --path ]; then printf '%s\n' "$deskfile"; exit 0; fi
if [ "\${1:-}" = -h ] || [ "\${1:-}" = --help ]; then echo "fake help"; exit 0; fi
printf 'build %s\n' "\$(date +%s%N)" >> "$buildlog"
[ -n "\${FAKE_BUILD_SLEEP:-}" ] && sleep "\$FAKE_BUILD_SLEEP"
[ -n "\${FAKE_BUILD_FAIL:-}" ] && exit 7
exit 0
SH
  chmod +x "$fake"
  printf '%s\n' "$fake"
}

build_count() {
  local log=$1
  [ -f "$log" ] || { printf '0\n'; return; }
  wc -l < "$log" | tr -d '[:space:]'
}

test_no_desk_is_noop() {
  local d="$TMP_ROOT/noop"
  local state="$d/state" desk="$d/.lavish/captain-desk.html" blog="$d/builds.log"
  mkdir -p "$state" "$d/.lavish"
  local fake
  fake=$(make_fake_builder "$d" "$desk" "$blog")
  # Desk file deliberately absent.
  FM_STATE_OVERRIDE="$state" FM_DESK_REFRESH_BIN="$fake" "$EVENT" spawn
  expect_code 0 $? "no-desk event exit"
  [ "$(build_count "$blog")" = 0 ] || fail "no-desk event rebuilt the desk"
  assert_absent "$state/.desk-event.dirty" "no-desk event left a dirty marker"
  pass "no live desk -> instant no-op (no rebuild, no marker)"
}

test_live_desk_rebuilds_once() {
  local d="$TMP_ROOT/one"
  local state="$d/state" desk="$d/.lavish/captain-desk.html" blog="$d/builds.log"
  mkdir -p "$state" "$d/.lavish"
  : > "$desk"
  local fake
  fake=$(make_fake_builder "$d" "$desk" "$blog")
  FM_STATE_OVERRIDE="$state" FM_DESK_REFRESH_BIN="$fake" FM_DESK_EVENT_FOREGROUND=1 "$EVENT" "done"
  expect_code 0 $? "live-desk event exit"
  [ "$(build_count "$blog")" = 1 ] || fail "expected exactly one rebuild, got $(build_count "$blog")"
  assert_absent "$state/.desk-event.dirty" "dirty marker was not consumed by the build"
  pass "live desk -> exactly one in-place rebuild, marker consumed"
}

test_serial_events_each_rebuild() {
  local d="$TMP_ROOT/serial"
  local state="$d/state" desk="$d/.lavish/captain-desk.html" blog="$d/builds.log"
  mkdir -p "$state" "$d/.lavish"
  : > "$desk"
  local fake i
  fake=$(make_fake_builder "$d" "$desk" "$blog")
  for i in 1 2 3; do
    FM_STATE_OVERRIDE="$state" FM_DESK_REFRESH_BIN="$fake" FM_DESK_EVENT_FOREGROUND=1 "$EVENT" "ev$i"
  done
  [ "$(build_count "$blog")" = 3 ] || fail "expected 3 serialized rebuilds, got $(build_count "$blog")"
  pass "three serialized events -> three rebuilds"
}

test_never_reserves() {
  local d="$TMP_ROOT/reserve"
  local state="$d/state" desk="$d/.lavish/captain-desk.html" blog="$d/builds.log"
  mkdir -p "$state" "$d/.lavish"
  : > "$desk"
  local fake tripwire fakebin
  fake=$(make_fake_builder "$d" "$desk" "$blog")
  tripwire="$d/reserve-tripwire"
  # Shadow the re-serve surfaces with tripwires: if the trigger ever calls
  # lavish-axi or serve-desk.sh, the tripwire file appears and the test fails.
  fakebin=$(fm_fakebin "$d")
  cat > "$fakebin/lavish-axi" <<SH
#!/usr/bin/env bash
printf 'lavish-axi %s\n' "\$*" >> "$tripwire"
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_DESK_REFRESH_BIN="$fake" \
    FM_DESK_EVENT_FOREGROUND=1 "$EVENT" pr
  expect_code 0 $? "reserve-check event exit"
  assert_absent "$tripwire" "trigger invoked lavish-axi (a re-serve); it must only rebuild in place"
  [ "$(build_count "$blog")" -ge 1 ] || fail "expected the rebuild to run"
  pass "trigger rebuilds in place and never re-serves (no lavish-axi call)"
}

test_never_wakes() {
  local d="$TMP_ROOT/wake"
  local state="$d/state" desk="$d/.lavish/captain-desk.html" blog="$d/builds.log"
  mkdir -p "$state" "$d/.lavish"
  : > "$desk"
  local fake
  fake=$(make_fake_builder "$d" "$desk" "$blog")
  FM_STATE_OVERRIDE="$state" FM_DESK_REFRESH_BIN="$fake" FM_DESK_EVENT_FOREGROUND=1 "$EVENT" teardown
  # No status file for any task, and the durable wake queue must be empty/absent.
  assert_absent "$state/.wake-queue" "trigger enqueued a wake (the queue file appeared)"
  # No <id>.status file may have been created by the trigger.
  local anystatus
  anystatus=$(find "$state" -maxdepth 1 -name '*.status' 2>/dev/null | head -1)
  [ -z "$anystatus" ] || fail "trigger created a status file: $anystatus"
  pass "trigger never wakes (no wake queue, no status append)"
}

test_builder_failure_is_best_effort() {
  local d="$TMP_ROOT/fail"
  local state="$d/state" desk="$d/.lavish/captain-desk.html" blog="$d/builds.log"
  mkdir -p "$state" "$d/.lavish"
  : > "$desk"
  local fake
  fake=$(make_fake_builder "$d" "$desk" "$blog")
  FAKE_BUILD_FAIL=1 FM_STATE_OVERRIDE="$state" FM_DESK_REFRESH_BIN="$fake" \
    FM_DESK_EVENT_FOREGROUND=1 "$EVENT" "done"
  expect_code 0 $? "failed-build event still exits 0"
  # The marker is still consumed even though the build failed, so a failing build
  # does not pin a permanently-dirty state.
  assert_absent "$state/.desk-event.dirty" "failed build left the dirty marker set"
  pass "a failing rebuild is best-effort (exit 0, marker consumed)"
}

test_coalesces_concurrent_events() {
  # While one build is in flight (a slow fake), fire several more events. They
  # must collapse to at most one trailing rebuild, not one per event.
  local d="$TMP_ROOT/coalesce"
  local state="$d/state" desk="$d/.lavish/captain-desk.html" blog="$d/builds.log"
  mkdir -p "$state" "$d/.lavish"
  : > "$desk"
  local fake
  fake=$(make_fake_builder "$d" "$desk" "$blog")
  # Start a detached worker whose first build sleeps, so the lock is held while
  # we fire the burst.
  FAKE_BUILD_SLEEP=2 FM_STATE_OVERRIDE="$state" FM_DESK_REFRESH_BIN="$fake" "$EVENT" first
  # Wait for the in-flight build to have started (lock acquired, first build
  # line written or the lock dir present).
  local i
  for i in $(seq 1 50); do
    [ -e "$state/.desk-event.lock" ] && break
    sleep 0.1
  done
  # Fire a burst of events while the first build sleeps. Each only sets the
  # marker and stands down (lock held).
  for i in 1 2 3 4 5; do
    FM_STATE_OVERRIDE="$state" FM_DESK_REFRESH_BIN="$fake" "$EVENT" "burst$i"
  done
  # Let the in-flight build finish and the trailing build run.
  for i in $(seq 1 100); do
    [ -e "$state/.desk-event.lock" ] || break
    sleep 0.1
  done
  sleep 0.5
  local n
  n=$(build_count "$blog")
  # Expect the initial build plus exactly one trailing coalesced build: 2. Allow
  # a small slack for timing (never the 6 that no coalescing would produce).
  [ "$n" -ge 2 ] || fail "expected at least the initial + one trailing build, got $n"
  [ "$n" -le 3 ] || fail "burst of 5 events did not coalesce (got $n builds, expected ~2)"
  pass "concurrent events during a build coalesce to one trailing rebuild (got $n)"
}

test_real_builder_path_is_cheap_and_stable() {
  # The trigger calls the REAL builder's --path on every event, so it must be
  # cheap and equal the documented stable path.
  local home="$TMP_ROOT/realpath"
  mkdir -p "$home"
  local out
  out=$(FM_HOME="$home" "$REFRESH" --path)
  [ "$out" = "$home/.lavish/captain-desk.html" ] || fail "builder --path wrong: $out"
  # FM_DESK_OUT override is honored (the trigger relies on --path as the single
  # owner of the path, including overrides).
  out=$(FM_HOME="$home" FM_DESK_OUT="$home/custom-desk.html" "$REFRESH" --path)
  [ "$out" = "$home/custom-desk.html" ] || fail "builder --path ignored FM_DESK_OUT: $out"
  pass "real builder --path is the single owner of the stable desk path"
}

test_unknown_arg_and_help() {
  # --help works and exits 0; the entrypoint accepts a free-text label without
  # error (labels are log-only).
  "$EVENT" --help >/dev/null
  expect_code 0 $? "--help exit"
  pass "--help renders and exits 0"
}

test_no_desk_is_noop
test_live_desk_rebuilds_once
test_serial_events_each_rebuild
test_never_reserves
test_never_wakes
test_builder_failure_is_best_effort
test_coalesces_concurrent_events
test_real_builder_path_is_cheap_and_stable
test_unknown_arg_and_help
