#!/usr/bin/env bash
# Behavior tests for the external liveness watchdog (bin/fm-liveness-watchdog.sh).
#
# The watchdog observes durable on-disk state from OUTSIDE the agent process tree
# and, when the primary's supervision is gone with work in flight, re-wakes the
# primary's own supervisor pane and writes a durable escalation the captain sees
# on next attach. There is NO phone push. The properties worth pinning are its
# decision matrix, its resume behavior against the recorded supervisor pane, and
# its lifecycle safety:
#   - inert until config/liveness-watchdog exists;
#   - quiet when nothing is in flight, or when a watcher beacon is fresh;
#   - on work-in-flight + stale beacon: write a durable escalation AND act on the
#     recorded supervisor pane - an Enter nudge for a live-but-idle pane, a
#     configured relaunch only for a confidently dead shell, and a clean
#     escalation (no action) when the pane is dead with no relaunch configured or
#     when no supervisor pane was recorded;
#   - idempotent within one down-episode; capped, then escalate;
#   - stands down under away mode;
#   - record/escalation/ack surface the durable escalation correctly;
#   - the loop detaches (its own session leader) so a disconnecting parent cannot
#     reap it, is a home-scoped singleton, and stops cleanly;
#   - and an end-to-end proof: a fake primary killed with work in flight leaves a
#     stale beacon, and the watchdog nudges the recorded pane and records the
#     escalation.
#
# Every resume routes through a FAKE fm-backend.sh, so no test ever drives a real
# herdr pane or resumes a real agent.
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

# A home carrying the watchdog, every library it sources, and a FAKE fm-backend.sh
# that records send-key / send-text-submit calls and reports a configurable
# supervisor-pane liveness. Nothing here ever drives a real herdr pane.
make_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state" "$dir/config"
  cp "$ROOT"/bin/fm-liveness-watchdog.sh "$ROOT"/bin/fm-wake-lib.sh \
     "$ROOT"/bin/fm-supervision-lib.sh "$ROOT"/bin/fm-supervisor-target-lib.sh \
     "$ROOT"/bin/fm-mutex-lib.sh "$ROOT"/bin/fm-pid-lib.sh "$dir/bin/"
  chmod +x "$dir/bin/fm-liveness-watchdog.sh"
  # Fake backend: liveness is read from $dir/fake-liveness (default unknown);
  # send-key and send-text-submit append to $dir/sent.log.
  cat > "$dir/bin/fm-backend.sh" <<EOF
fm_backend_agent_alive() { cat "$dir/fake-liveness" 2>/dev/null || echo unknown; }
fm_backend_send_key() { printf 'KEY\t%s\t%s\t%s\n' "\$1" "\$2" "\$3" >> "$dir/sent.log"; return 0; }
fm_backend_send_text_submit() { printf 'TEXT\t%s\t%s\t%s\n' "\$1" "\$2" "\$3" >> "$dir/sent.log"; return 0; }
EOF
  # A recorded supervisor pane so resume has a target by default.
  printf 'herdr\tdefault:w1:p1\n' > "$dir/state/.supervisor-target"
}

enable_flag() { : > "$1/config/liveness-watchdog"; }

wd() {  # <dir> <subcommand>...
  local dir=$1
  shift
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_GUARD_GRACE=2 FM_LIVENESS_INTERVAL=1 \
    "$dir/bin/fm-liveness-watchdog.sh" "$@"
}

fresh_beacon() { touch "$1/state/.last-watcher-beat"; }
stale_beacon() {
  touch -d '30 seconds ago' "$1/state/.last-watcher-beat" 2>/dev/null \
    || touch -t 202001010000 "$1/state/.last-watcher-beat"
}
in_flight() { : > "$1/state/task-abc.meta"; }
set_liveness() { printf '%s\n' "$2" > "$1/fake-liveness"; }

escalation_summary() { sed -n 's/^summary=//p' "$1/state/.liveness-escalation" 2>/dev/null; }
sent_log() { cat "$1/sent.log" 2>/dev/null || true; }
nudge_count() { [ -f "$1/sent.log" ] || { echo 0; return; }; grep -c '^KEY' "$1/sent.log"; }
relaunch_count() { [ -f "$1/sent.log" ] || { echo 0; return; }; grep -c '^TEXT' "$1/sent.log"; }
reset_run_state() {
  rm -f "$1/sent.log" "$1/state/.liveness-escalation" \
    "$1/state/.liveness-watchdog-episode" "$1/state/.liveness-watchdog-resumes" \
    "$1/state/.liveness-watchdog-capreported" "$1/state/.wake-queue" 2>/dev/null || true
}

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
in_flight "$H"; stale_beacon "$H"; set_liveness "$H" alive
wd "$H" tick
[ -z "$(escalation_summary "$H")" ] && [ -z "$(sent_log "$H")" ] \
  || fail "watchdog must be inert with no config/liveness-watchdog flag"
pass "inert until config/liveness-watchdog exists"

# --- quiet when nothing is in flight ----------------------------------------

H=$TMP_ROOT/quiet-idle
make_home "$H"; enable_flag "$H"
stale_beacon "$H"   # stale beacon but NO meta
wd "$H" tick
[ -z "$(escalation_summary "$H")" ] || fail "a quiet fleet with nothing in flight must not escalate"
pass "quiet when nothing is in flight"

# --- quiet when a watcher beacon is fresh -----------------------------------

H=$TMP_ROOT/quiet-fresh
make_home "$H"; enable_flag "$H"
in_flight "$H"; fresh_beacon "$H"; set_liveness "$H" alive
wd "$H" tick
[ -z "$(escalation_summary "$H")" ] && [ -z "$(sent_log "$H")" ] \
  || fail "a fresh watcher beacon means supervision is alive; no action"
pass "quiet when the watcher beacon is fresh"

# --- down + ALIVE supervisor -> Enter nudge + escalation --------------------

H=$TMP_ROOT/nudge
make_home "$H"; enable_flag "$H"
in_flight "$H"; stale_beacon "$H"; set_liveness "$H" alive
wd "$H" tick
assert_contains "$(sent_log "$H")" "KEY	herdr	default:w1:p1	Enter" \
  "a live-but-idle supervisor pane must get an Enter nudge"
assert_contains "$(escalation_summary "$H")" "Enter nudge" \
  "the durable escalation must record the Enter nudge"
[ "$(relaunch_count "$H")" -eq 0 ] || fail "a live pane must never be relaunched"
pass "down with a live supervisor pane: Enter nudge and escalation, no relaunch"

# --- idempotent within an episode, capped, then final escalation ------------

wd "$H" tick
wd "$H" tick
[ "$(nudge_count "$H")" -eq 3 ] || fail "nudges should reach the cap of 3, got $(nudge_count "$H")"
wd "$H" tick   # past the cap
[ "$(nudge_count "$H")" -eq 3 ] || fail "no nudge should be sent once the cap is hit"
assert_contains "$(escalation_summary "$H")" "did NOT recover it after 3 attempt" \
  "past the cap the watchdog must escalate that resume did not recover the primary"
pass "resume is capped within an episode, then escalates once"

# --- down + DEAD supervisor, no relaunch configured -> escalate, no action --

H=$TMP_ROOT/dead-noconfig
make_home "$H"; enable_flag "$H"
in_flight "$H"; stale_beacon "$H"; set_liveness "$H" dead
wd "$H" tick
[ -z "$(sent_log "$H")" ] || fail "a dead shell with no relaunch command must not drive the pane"
assert_contains "$(escalation_summary "$H")" "No relaunch command configured" \
  "a dead shell with no relaunch config must escalate for manual recovery"
pass "dead supervisor without a relaunch command escalates cleanly, no action"

# --- down + DEAD supervisor, relaunch configured -> relaunch runs -----------

H=$TMP_ROOT/dead-config
make_home "$H"; enable_flag "$H"
printf 'jcode --resume PRIMARY\n' > "$H/config/liveness-resume"
in_flight "$H"; stale_beacon "$H"; set_liveness "$H" dead
wd "$H" tick
assert_contains "$(sent_log "$H")" "TEXT	herdr	default:w1:p1	jcode --resume PRIMARY" \
  "a dead shell with a relaunch command must run it in the pane"
assert_contains "$(escalation_summary "$H")" "Ran the configured relaunch command" \
  "the escalation must record the relaunch"
pass "dead supervisor with a relaunch command runs it"

# --- down but NO supervisor pane recorded -> escalate cannot-resume ---------

H=$TMP_ROOT/no-target
make_home "$H"; enable_flag "$H"
rm -f "$H/state/.supervisor-target"
in_flight "$H"; stale_beacon "$H"; set_liveness "$H" alive
wd "$H" tick
[ -z "$(sent_log "$H")" ] || fail "with no recorded pane there is nothing to drive"
assert_contains "$(escalation_summary "$H")" "NO supervisor pane recorded" \
  "a missing supervisor-target record must escalate that resume is impossible"
pass "no recorded supervisor pane escalates cannot-resume"

# --- recovery ends the episode; a later restale re-arms fresh ---------------

H=$TMP_ROOT/recover
make_home "$H"; enable_flag "$H"
in_flight "$H"; stale_beacon "$H"; set_liveness "$H" alive
wd "$H" tick
[ "$(nudge_count "$H")" -eq 1 ] || fail "first outage should nudge once"
fresh_beacon "$H"
reset_run_state "$H"
wd "$H" tick
[ -z "$(escalation_summary "$H")" ] || fail "a recovered watcher must silence the watchdog"
stale_beacon "$H"
touch -d '25 seconds ago' "$H/state/.last-watcher-beat"  # distinct mtime = new episode
wd "$H" tick
[ "$(nudge_count "$H")" -eq 1 ] || fail "a new down-episode should reset and nudge again"
pass "recovery ends the episode and a later outage re-arms fresh"

# --- stands down under away mode --------------------------------------------

H=$TMP_ROOT/afk
make_home "$H"; enable_flag "$H"
in_flight "$H"; stale_beacon "$H"; set_liveness "$H" alive
: > "$H/state/.afk"
wd "$H" tick
[ -z "$(escalation_summary "$H")" ] && [ -z "$(sent_log "$H")" ] \
  || fail "the watchdog must stand down under away mode"
pass "stands down under away mode"

# --- record / escalation / ack ----------------------------------------------

H=$TMP_ROOT/surface
make_home "$H"; enable_flag "$H"
# record without any backend env cannot resolve a pane; it must fail gracefully,
# not crash, and leave any prior record intact.
rm -f "$H/state/.supervisor-target"
FM_HOME="$H" FM_ROOT_OVERRIDE="$H" FM_SUPERVISOR_TARGET="" FM_SUPERVISOR_BACKEND="" \
  "$H/bin/fm-liveness-watchdog.sh" record >/dev/null 2>&1 || true
# record WITH an explicit supervisor target writes the file.
FM_HOME="$H" FM_ROOT_OVERRIDE="$H" FM_SUPERVISOR_TARGET="default:w2:p3" FM_SUPERVISOR_BACKEND="herdr" \
  "$H/bin/fm-liveness-watchdog.sh" record >/dev/null 2>&1
assert_grep "herdr	default:w2:p3" "$H/state/.supervisor-target" "record must persist the resolved supervisor pane"
# escalation prints the record; ack clears it.
printf 'time=T\nsummary=demo\n' > "$H/state/.liveness-escalation"
out=$(FM_HOME="$H" FM_ROOT_OVERRIDE="$H" "$H/bin/fm-liveness-watchdog.sh" escalation)
assert_contains "$out" "summary=demo" "escalation must print the durable record"
FM_HOME="$H" FM_ROOT_OVERRIDE="$H" "$H/bin/fm-liveness-watchdog.sh" ack >/dev/null 2>&1
[ ! -f "$H/state/.liveness-escalation" ] || fail "ack must clear the durable escalation record"
pass "record persists the pane; escalation prints and ack clears the record"

# --- lifecycle: detached singleton that stops cleanly -----------------------

H=$TMP_ROOT/lifecycle
make_home "$H"; enable_flag "$H"
out=$(wd "$H" start)
assert_contains "$out" "started pid=" "start should launch the detached loop"
pid=$(cat "$H/state/.liveness-watchdog.lock/pid" 2>/dev/null || true)
[ -n "$pid" ] || fail "start must record the loop pid in the lock"
STARTED_PIDS+=("$pid")
sess=$(ps -o sess= -p "$pid" 2>/dev/null | tr -d ' ')
[ "$sess" = "$pid" ] || fail "the loop must be its own session leader (detached), got sess=$sess"
out2=$(wd "$H" start)
assert_contains "$out2" "already running pid=$pid" "a second start must be an idempotent no-op"
wd "$H" status | grep -q "running pid=$pid" || fail "status should report the running loop"
out3=$(wd "$H" stop)
assert_contains "$out3" "stopped pid=$pid" "stop should stop the recorded loop"
wait_until 3 sh -c "! FM_HOME='$H' FM_ROOT_OVERRIDE='$H' '$H/bin/fm-liveness-watchdog.sh' status >/dev/null 2>&1" \
  || fail "status should report not running after stop"
pass "lifecycle: detached singleton starts, is idempotent, and stops cleanly"

# --- END-TO-END PROOF: kill a fake primary, observe nudge + escalation ------
#
# A fake primary process writes a heartbeat beacon in a loop, exactly as the real
# supervision watcher touches state/.last-watcher-beat. Killing it (the failure
# this watchdog defends against) freezes the beacon. With work in flight and the
# watchdog loop running, the beacon goes stale past grace, and the watchdog drives
# the recorded supervisor pane (an Enter nudge, since the fake backend reports the
# pane alive) and records the durable escalation - proven from a real process
# death rather than a hand-staled file.

H=$TMP_ROOT/e2e
make_home "$H"; enable_flag "$H"
in_flight "$H"; set_liveness "$H" alive
beat_script="$H/fake-primary.sh"
cat > "$beat_script" <<EOF
#!/usr/bin/env bash
while :; do touch "$H/state/.last-watcher-beat"; sleep 0.2; done
EOF
chmod +x "$beat_script"
setsid "$beat_script" </dev/null >/dev/null 2>&1 &
primary_pid=$!
STARTED_PIDS+=("$primary_pid")
wait_until 2 test -f "$H/state/.last-watcher-beat" || fail "fake primary never wrote a beacon"

FM_HOME="$H" FM_ROOT_OVERRIDE="$H" FM_GUARD_GRACE=2 FM_LIVENESS_INTERVAL=1 \
  "$H/bin/fm-liveness-watchdog.sh" start >/dev/null 2>&1
wd_pid=$(cat "$H/state/.liveness-watchdog.lock/pid" 2>/dev/null || true)
[ -n "$wd_pid" ] || fail "e2e: watchdog loop did not start"
STARTED_PIDS+=("$wd_pid")

sleep 1
[ -z "$(escalation_summary "$H")" ] || fail "e2e: watchdog acted while the fake primary was still alive"

kill -KILL "$primary_pid" 2>/dev/null || true

wait_until 8 sh -c "grep -q 'Enter nudge' '$H/state/.liveness-escalation' 2>/dev/null" \
  || fail "e2e: watchdog did not record a supervisor-pane resume escalation after the primary died"
assert_contains "$(sent_log "$H")" "KEY	herdr	default:w1:p1	Enter" \
  "e2e: the watchdog must have driven the recorded supervisor pane after the primary died"
FM_HOME="$H" FM_ROOT_OVERRIDE="$H" "$H/bin/fm-liveness-watchdog.sh" stop >/dev/null 2>&1 || true
pass "end-to-end: killing the fake primary drives the supervisor pane and records an escalation"

pass "all fm-liveness-watchdog tests passed"
