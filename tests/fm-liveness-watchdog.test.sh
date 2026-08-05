#!/usr/bin/env bash
# Behavior tests for the external liveness watchdog (bin/fm-liveness-watchdog.sh).
#
# The watchdog's whole value is that it observes durable on-disk state from
# OUTSIDE the agent process tree and alerts + resumes when the primary's
# supervision is gone, so the properties worth pinning are its decision matrix
# and its lifecycle safety:
#   - inert until config/liveness-watchdog exists;
#   - quiet when nothing is in flight, or when a watcher beacon is fresh;
#   - on work-in-flight + stale beacon: fire the alarm AND run a capped resume;
#   - idempotent within one down-episode; capped, then escalate;
#   - a wedged-but-ALIVE primary (alive-probe says alive) gets an alert but is
#     NEVER auto-resumed;
#   - stands down under away mode;
#   - the loop detaches (its own session leader) so a disconnecting parent cannot
#     reap it, is a home-scoped singleton, and stops cleanly;
#   - and an end-to-end proof: a fake primary killed with work in flight produces
#     an alarm and a completed resume.
#
# Every alarm and resume routes through recorder scripts, so no test ever posts a
# real notification or resumes a real agent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-liveness-watchdog)
mkdir -p "$TMP_ROOT"
STARTED_PIDS=()

cleanup() {
  local pid
  for pid in "${STARTED_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup EXIT

# --- fixtures ---------------------------------------------------------------

# A home carrying the watchdog and every library it sources, plus recorder-based
# alarm and resume so nothing real ever fires.
make_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state" "$dir/config"
  cp "$ROOT"/bin/fm-liveness-watchdog.sh "$ROOT"/bin/fm-alarm-lib.sh \
     "$ROOT"/bin/fm-wake-lib.sh "$ROOT"/bin/fm-supervision-lib.sh \
     "$ROOT"/bin/fm-mutex-lib.sh "$ROOT"/bin/fm-pid-lib.sh "$dir/bin/"
  chmod +x "$dir/bin/fm-liveness-watchdog.sh"
  # Alarm recorder: one line per alarm summary.
  printf 'command: printf "%%s\\n" "$1" >> %s/alarm.log\n' "$dir" > "$dir/config/liveness-alarm"
  # Resume recorder: one RESUMED line per attempt.
  printf 'printf "RESUMED\\n" >> %s/resume.log\n' "$dir" > "$dir/config/liveness-resume"
}

enable_flag() {  # <dir>
  : > "$1/config/liveness-watchdog"
}

wd() {  # <dir> <subcommand>...
  local dir=$1
  shift
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_GUARD_GRACE=2 FM_LIVENESS_INTERVAL=1 \
    "$dir/bin/fm-liveness-watchdog.sh" "$@"
}

# A fresh beacon (now) and a stale one (older than the 2s grace we run with).
fresh_beacon() {  # <dir>
  touch "$1/state/.last-watcher-beat"
}
stale_beacon() {  # <dir>
  touch -d '30 seconds ago' "$1/state/.last-watcher-beat" 2>/dev/null \
    || touch -t 202001010000 "$1/state/.last-watcher-beat"
}
in_flight() {  # <dir>
  : > "$1/state/task-abc.meta"
}

alarm_log() { cat "$1/alarm.log" 2>/dev/null || true; }
resume_count() { grep -c RESUMED "$1/resume.log" 2>/dev/null || echo 0; }
reset_logs() { rm -f "$1/alarm.log" "$1/resume.log"; }

wait_until() {  # <seconds> <command>...
  local bound=$1 i=0 limit
  shift
  limit=$((bound * 20))
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

# --- inert until enabled ----------------------------------------------------

H=$TMP_ROOT/inert
make_home "$H"
in_flight "$H"
stale_beacon "$H"
wd "$H" tick
[ -z "$(alarm_log "$H")" ] || fail "watchdog must be inert with no config/liveness-watchdog flag"
pass "inert until config/liveness-watchdog exists"

# --- quiet when nothing is in flight ----------------------------------------

H=$TMP_ROOT/quiet-idle
make_home "$H"; enable_flag "$H"
stale_beacon "$H"   # stale beacon but NO meta -> healthy quiet fleet
wd "$H" tick
[ -z "$(alarm_log "$H")" ] || fail "a quiet fleet with nothing in flight must not alert"
pass "quiet when nothing is in flight"

# --- quiet when a watcher beacon is fresh -----------------------------------

H=$TMP_ROOT/quiet-fresh
make_home "$H"; enable_flag "$H"
in_flight "$H"; fresh_beacon "$H"
wd "$H" tick
[ -z "$(alarm_log "$H")" ] || fail "a fresh watcher beacon means supervision is alive; no alert"
pass "quiet when the watcher beacon is fresh"

# --- TRIGGER: in flight + stale beacon -> alarm + resume --------------------

H=$TMP_ROOT/trigger
make_home "$H"; enable_flag "$H"
in_flight "$H"; stale_beacon "$H"
wd "$H" tick
assert_contains "$(alarm_log "$H")" "Auto-resume attempt 1 SUCCEEDED" \
  "a down primary with work in flight must alert with the resume outcome"
[ "$(resume_count "$H")" -eq 1 ] || fail "exactly one resume should have run on the first trigger tick"
pass "trigger fires an alarm and runs a capped resume"

# --- idempotent within one down-episode, then capped, then escalate ---------

# Two more ticks in the SAME episode: resume count climbs to the cap, then stops.
wd "$H" tick
wd "$H" tick
[ "$(resume_count "$H")" -eq 3 ] || fail "resume attempts should reach the cap of 3, got $(resume_count "$H")"
reset_logs "$H"
wd "$H" tick   # past the cap
[ "$(resume_count "$H")" -eq 0 ] || fail "no resume should run once the cap is hit"
assert_contains "$(alarm_log "$H")" "auto-resume FAILED after 3 attempt" \
  "past the cap the watchdog must escalate through the alarm instead of retrying"
pass "resume is capped within an episode, then escalates once"

# --- recovery ends the episode; a later restale re-arms fresh ---------------

fresh_beacon "$H"
reset_logs "$H"
wd "$H" tick
[ -z "$(alarm_log "$H")" ] || fail "a recovered watcher must silence the watchdog"
# New down-episode with a NEW beacon mtime resets the resume counter.
stale_beacon "$H"
touch -d '25 seconds ago' "$H/state/.last-watcher-beat"  # distinct mtime = new episode
wd "$H" tick
[ "$(resume_count "$H")" -eq 1 ] || fail "a new down-episode should reset and resume again"
pass "recovery ends the episode and a later outage re-arms fresh"

# --- wedged-but-alive primary: alert, NEVER resume --------------------------

H=$TMP_ROOT/wedged
make_home "$H"; enable_flag "$H"
printf 'exit 0\n' > "$H/config/liveness-alive-probe"   # probe: primary is ALIVE
in_flight "$H"; stale_beacon "$H"
wd "$H" tick
assert_contains "$(alarm_log "$H")" "still ALIVE" \
  "a wedged-but-alive primary must be reported as a possible wedge"
[ "$(resume_count "$H")" -eq 0 ] || fail "a live primary must NEVER be auto-resumed"
pass "a wedged-but-alive primary is alerted but never resumed"

# --- stands down under away mode --------------------------------------------

H=$TMP_ROOT/afk
make_home "$H"; enable_flag "$H"
in_flight "$H"; stale_beacon "$H"
: > "$H/state/.afk"
wd "$H" tick
[ -z "$(alarm_log "$H")" ] || fail "the watchdog must stand down under away mode"
pass "stands down under away mode"

# --- no resume command configured: alert says manual, does not crash --------

H=$TMP_ROOT/noresume
make_home "$H"; enable_flag "$H"
rm -f "$H/config/liveness-resume"
in_flight "$H"; stale_beacon "$H"
wd "$H" tick
assert_contains "$(alarm_log "$H")" "NO auto-resume command is configured" \
  "with no resume command the alarm must say manual recovery is needed"
pass "no resume command configured is reported, not crashed"

# --- lifecycle: detached singleton that stops cleanly -----------------------

H=$TMP_ROOT/lifecycle
make_home "$H"; enable_flag "$H"
out=$(wd "$H" start)
assert_contains "$out" "started pid=" "start should launch the detached loop"
pid=$(cat "$H/state/.liveness-watchdog.lock/pid" 2>/dev/null || true)
[ -n "$pid" ] || fail "start must record the loop pid in the lock"
STARTED_PIDS+=("$pid")
# Detached: its own session leader (ppid reparented away from this shell).
sess=$(ps -o sess= -p "$pid" 2>/dev/null | tr -d ' ')
[ "$sess" = "$pid" ] || fail "the loop must be its own session leader (detached), got sess=$sess"
# Singleton: a second start is a no-op that reports the same pid.
out2=$(wd "$H" start)
assert_contains "$out2" "already running pid=$pid" "a second start must be an idempotent no-op"
# Status reports running.
wd "$H" status | grep -q "running pid=$pid" || fail "status should report the running loop"
# Stop it cleanly.
out3=$(wd "$H" stop)
assert_contains "$out3" "stopped pid=$pid" "stop should stop the recorded loop"
wait_until 3 sh -c "! FM_HOME='$H' FM_ROOT_OVERRIDE='$H' '$H/bin/fm-liveness-watchdog.sh' status >/dev/null 2>&1" \
  || fail "status should report not running after stop"
pass "lifecycle: detached singleton starts, is idempotent, and stops cleanly"

# --- END-TO-END PROOF: kill a fake primary, observe alarm + resume ----------
#
# A fake primary process writes a heartbeat beacon in a loop, exactly as the real
# supervision watcher touches state/.last-watcher-beat. Killing it (the failure
# this watchdog defends against) freezes the beacon. With work in flight and the
# watchdog loop running, the beacon goes stale past grace, and the watchdog fires
# the alarm and runs the resume - the whole point of the feature, proven from a
# real process death rather than a hand-staled file.

H=$TMP_ROOT/e2e
make_home "$H"; enable_flag "$H"
in_flight "$H"
# Fake primary: beats the beacon every 0.2s. Detached from this shell.
beat_script="$H/fake-primary.sh"
cat > "$beat_script" <<EOF
#!/usr/bin/env bash
while :; do touch "$H/state/.last-watcher-beat"; sleep 0.2; done
EOF
chmod +x "$beat_script"
setsid "$beat_script" </dev/null >/dev/null 2>&1 &
primary_pid=$!
STARTED_PIDS+=("$primary_pid")
# Let it establish a fresh beacon.
wait_until 2 test -f "$H/state/.last-watcher-beat" || fail "fake primary never wrote a beacon"

# Start the watchdog loop with a short grace and interval so the test is fast.
FM_HOME="$H" FM_ROOT_OVERRIDE="$H" FM_GUARD_GRACE=2 FM_LIVENESS_INTERVAL=1 \
  "$H/bin/fm-liveness-watchdog.sh" start >/dev/null 2>&1
wd_pid=$(cat "$H/state/.liveness-watchdog.lock/pid" 2>/dev/null || true)
[ -n "$wd_pid" ] || fail "e2e: watchdog loop did not start"
STARTED_PIDS+=("$wd_pid")

# While the primary beats, the watchdog stays quiet.
sleep 1
[ -z "$(alarm_log "$H")" ] || fail "e2e: watchdog alerted while the fake primary was still alive"

# KILL the fake primary. Its beacon now freezes.
kill -KILL "$primary_pid" 2>/dev/null || true

# Within a few grace+interval windows, the watchdog must alert and resume.
wait_until 8 sh -c "grep -q RESUMED '$H/resume.log' 2>/dev/null" \
  || fail "e2e: watchdog did not run the resume after the primary died"
assert_contains "$(alarm_log "$H")" "Auto-resume attempt" \
  "e2e: the alarm must state the resume outcome after the primary died"
# Stop the loop.
FM_HOME="$H" FM_ROOT_OVERRIDE="$H" "$H/bin/fm-liveness-watchdog.sh" stop >/dev/null 2>&1 || true
pass "end-to-end: killing the fake primary triggers an alarm and a resume"

pass "all fm-liveness-watchdog tests passed"
