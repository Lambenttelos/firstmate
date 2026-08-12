#!/usr/bin/env bash
# Deterministic return-catch-up gate regression.
#
# Covers the second half of the 2026-07-14 incident: an away-mode blocked event
# survived in durable state, but the ordinary return request could proceed to
# Bearings before Firstmate owned remediation. The shared script now stops,
# drains, preserves evidence, and refuses ordinary work until every live open
# `blocked:` event is resolved or durably reclassified.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-afk-return-tests)

install_runner() {  # <case-dir>
  local dir=$1
  mkdir -p "$dir/bin" "$dir/home/state" "$dir/home/data" "$dir/home/config"
  cp "$ROOT/bin/fm-afk-return.sh" "$dir/bin/"
  # fm-wake-lib.sh sources fm-mutex-lib.sh at load time. Without it the portable
  # lock helpers never get defined, every outbox read fails its bounded acquire,
  # and this fixture silently exercises a degraded no-lock path instead of the
  # real one.
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-mutex-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-pid-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-classify-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-afk-outbox-lib.sh" "$dir/bin/"
  cat > "$dir/bin/fm-afk-launch.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = stop ] || exit 2
printf 'stop\n' >> "$FM_HOME/stop.log"
rm -f "$FM_HOME/state/.afk"
if [ -e "$FM_HOME/state/.fail-terminal-stop-once" ]; then
  rm -f "$FM_HOME/state/.fail-terminal-stop-once"
  exit 1
fi
rm -f "$FM_HOME/state/.afk-daemon-terminal"
SH
  cat > "$dir/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
file="$FM_HOME/state/.fake-drain"
[ -f "$file" ] && cat "$file"
: > "$file"
SH
  # Fake present-mode daemon: records every invocation so a test can assert the
  # return path restarts it (the entry path stopped it). `start` honors a
  # $FM_HOME/state/.fail-present-start-once knob to simulate a launch failure.
  cat > "$dir/bin/fm-present-daemon.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_HOME/present-daemon.log"
if [ "${1:-}" = start ] && [ -e "$FM_HOME/state/.fail-present-start-once" ]; then
  rm -f "$FM_HOME/state/.fail-present-start-once"
  echo "present-daemon: FAILED - simulated" >&2
  exit 1
fi
exit 0
SH
  chmod +x "$dir/bin/"*.sh
  # Fail loudly on an incomplete library set. A missing sourced dependency leaves
  # the portable lock helpers undefined, which degrades every outbox assertion
  # below into a no-lock path that reports a lock timeout instead of exercising
  # the real one - a fixture gap that reads as a product regression.
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    bash -c '. "$1" >/dev/null 2>&1; declare -F fm_lock_acquire_wait >/dev/null' \
    _ "$dir/bin/fm-wake-lib.sh" \
    || fail "install_runner copied an incomplete library set: fm_lock_acquire_wait is undefined"
}

run_return() {  # <case-dir> <mode>
  local dir=$1 mode=$2
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" "$dir/bin/fm-afk-return.sh" "$mode" 2>&1
}

seed_live_blocker() {  # <case-dir> <backend> <key>
  local dir=$1 backend=$2 key=$3 target
  case "$backend" in
    tmux) target='synthetic:fm-repair-task' ;;
    herdr) target='fm-lab-synthetic:w1:p2' ;;
  esac
  cat > "$dir/home/state/repair-task.meta" <<EOF
window=$target
backend=$backend
kind=ship
EOF
  printf 'blocked [key=%s]: firstmate can refresh the synthetic token\n' "$key" > "$dir/home/state/repair-task.status"
}

test_return_gate_orders_catchup_before_bearings() {
  local dir out rc gate wake_count
  dir="$TMP_ROOT/ordering"
  install_runner "$dir"
  seed_live_blocker "$dir" herdr synthetic-dependency
  date +%s > "$dir/home/state/.afk"
  printf 'repair-task.status: blocked synthetic dependency\n' > "$dir/home/state/.subsuper-escalations"
  printf 'fm away-mode inject WEDGED: 4555s undelivered\n' > "$dir/home/state/.subsuper-inject-wedged"
  {
    printf '1784074271\t2\tsignal\trepair-task.status\tsignal: synthetic status\n'
    printf 'wake annotation: latest wake-EVENT observed at drain, not current state: repair-task.status: blocked synthetic dependency\n'
  } > "$dir/home/state/.fake-drain"

  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "return begin should gate on a live blocker (rc=$rc): $out"
  gate="$dir/home/state/.afk-return-catchup"
  [ -s "$gate" ] || fail "return begin did not persist its fail-closed catch-up gate"
  assert_contains "$out" 'firstmate-actionable blocker: repair-task [key=synthetic-dependency]' "return output did not assign blocker remediation to Firstmate"
  grep -F $'evidence\twake\t1784074271' "$gate" >/dev/null || fail "drained wake evidence was not retained in the durable gate"
  grep -F $'evidence\twake\twake annotation: latest wake-EVENT observed at drain, not current state: repair-task.status: blocked synthetic dependency' "$gate" >/dev/null \
    || fail "the separate drain annotation was not retained as away-return evidence"
  grep -F $'evidence\twedge\tfm away-mode inject WEDGED: 4555s undelivered' "$gate" >/dev/null || fail "wedge evidence was not retained in the durable gate"
  grep -F $'evidence\tescalation\trepair-task.status: blocked synthetic dependency' "$gate" >/dev/null || fail "buffered escalation evidence was not retained in the durable gate"
  [ "$(wc -l < "$dir/home/stop.log" | tr -d ' ')" -eq 1 ] || fail "return begin did not stop away mode exactly once"

  # The exact incident regression: Bearings is an ordinary request and must
  # refuse before reading/rendering while this shared gate remains open.
  set +e
  out=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" "$ROOT/bin/fm-bearings-snapshot.sh" --json 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "Bearings should refuse behind the return gate (rc=$rc): $out"
  assert_contains "$out" 'return catch-up is pending' "Bearings refusal did not point to the shared return owner"

  # Restart/re-entry is idempotent: no second stop, no duplicate catch-up line,
  # and the same unresolved blocker remains authoritative.
  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "repeated begin should preserve the unresolved gate"
  [ "$(wc -l < "$dir/home/stop.log" | tr -d ' ')" -eq 1 ] || fail "repeated begin stopped an already-stopped daemon twice"
  wake_count=$(grep -c $'^evidence\twake\t1784074271' "$gate" || true)
  [ "$wake_count" -eq 1 ] || fail "repeated begin duplicated retained wake evidence ($wake_count copies)"
  [ "$(grep -c $'^evidence\twedge\t' "$gate" || true)" -eq 1 ] || fail "repeated begin duplicated retained wedge evidence"
  [ "$(grep -c $'^evidence\tescalation\t' "$gate" || true)" -eq 1 ] || fail "repeated begin duplicated retained escalation evidence"

  printf 'resolved [key=synthetic-dependency]: refreshed the synthetic token and resumed the task\n' >> "$dir/home/state/repair-task.status"
  out=$(run_return "$dir" check) || fail "resolved blocker did not clear return catch-up: $out"
  assert_contains "$out" 'catch-up clear' "successful check did not announce that ordinary work may proceed"
  [ ! -e "$gate" ] || fail "successful check left the return gate behind"
  [ ! -e "$dir/home/state/.subsuper-escalations" ] || fail "successful check left delivered escalation state behind"
  [ ! -e "$dir/home/state/.subsuper-inject-wedged" ] || fail "successful check left the wedge marker behind"

  out=$(run_return "$dir" check) || fail "an already-clear repeated check should be idempotent: $out"
  [ ! -e "$gate" ] || fail "idempotent clear check recreated a gate"
  pass "return catch-up precedes Bearings, owns live blocker remediation, preserves evidence once, and clears idempotently"
}

test_explicit_reclassification_requires_durable_reason() {
  local backend dir out rc
  for backend in tmux herdr; do
    dir="$TMP_ROOT/reclassify-$backend"
    install_runner "$dir"
    seed_live_blocker "$dir" "$backend" vendor-release
    date +%s > "$dir/home/state/.afk"
    : > "$dir/home/state/.fake-drain"
    set +e
    out=$(run_return "$dir" begin)
    rc=$?
    set -e
    [ "$rc" -eq 3 ] || fail "$backend blocker did not open the return gate"

    # A pause alone cannot mask the keyed blocker. The old concern must be
    # explicitly resolved with the durable reclassification reason first.
    printf 'paused [key=vendor-release]: waiting for the synthetic vendor window\n' >> "$dir/home/state/repair-task.status"
    set +e
    out=$(run_return "$dir" check)
    rc=$?
    set -e
    [ "$rc" -eq 3 ] || fail "$backend pause silently masked an unresolved blocked key"

    printf 'resolved [key=vendor-release]: reclassified as an external wait because the synthetic vendor owns the next event\n' >> "$dir/home/state/repair-task.status"
    printf 'paused [key=vendor-release]: waiting for the synthetic vendor window\n' >> "$dir/home/state/repair-task.status"
    out=$(run_return "$dir" check) || fail "$backend durable reclassification did not clear the return gate: $out"
    [ ! -e "$dir/home/state/.afk-return-catchup" ] || fail "$backend reclassification left a gate behind"
  done
  pass "tmux and Herdr blockers require the same explicit durable reclassification before ordinary work"
}

test_captain_decision_does_not_masquerade_as_firstmate_blocker() {
  local dir out
  dir="$TMP_ROOT/captain-decision"
  install_runner "$dir"
  cat > "$dir/home/state/decision-task.meta" <<'EOF'
window=synthetic:fm-decision-task
backend=tmux
kind=ship
EOF
  printf 'needs-decision [key=api-shape]: captain must choose the synthetic API shape\n' > "$dir/home/state/decision-task.status"
  date +%s > "$dir/home/state/.afk"
  printf '1784074271\t1\tsignal\tdecision-task.status\tsignal: synthetic decision\n' > "$dir/home/state/.fake-drain"
  out=$(run_return "$dir" begin) || fail "captain-owned decision should not be treated as a firstmate blocker: $out"
  assert_contains "$out" 'catch-up wake:' "captain-owned decision wake was not surfaced in catch-up"
  [ ! -e "$dir/home/state/.afk-return-catchup" ] || fail "captain-owned decision incorrectly opened a firstmate blocker gate"
  pass "captain-owned needs-decision remains reportable without masquerading as a firstmate-actionable blocker"
}

# Regression for the 2026-08-12 supervision blackout: away-mode ENTRY stops the
# present-mode supervision daemon (bin/fm-afk-start.sh), but RETURN never
# restarted it, so after an in-session return the beacon re-arm engine was gone
# until the next session start. A long interactive turn then let the beacon age
# past grace three times in one hour. The return path must restart the daemon
# once the away daemon is confirmed stopped, restoring the entry/return symmetry.
test_return_restarts_present_daemon_on_clean_return() {
  local dir out
  dir="$TMP_ROOT/present-restart"
  install_runner "$dir"
  : > "$dir/home/config/present-daemon"
  date +%s > "$dir/home/state/.afk"
  : > "$dir/home/state/.fake-drain"
  out=$(run_return "$dir" begin) || fail "clean return did not clear catch-up: $out"
  assert_contains "$out" 'catch-up clear' "clean return did not announce ordinary work may proceed"
  [ -f "$dir/home/present-daemon.log" ] || fail "return never invoked the present-mode daemon"
  grep -qx start "$dir/home/present-daemon.log" \
    || fail "return did not restart the present-mode daemon on a clean return"
  pass "clean away-return restarts the present-mode supervision daemon"
}

# The restart must not race the away daemon: it runs only AFTER the away daemon
# is confirmed stopped. When away shutdown fails, the return gate stays open and
# the present daemon must NOT be started (two supervisors must never race).
test_return_skips_present_daemon_when_shutdown_fails() {
  local dir out rc
  dir="$TMP_ROOT/present-restart-interlock"
  install_runner "$dir"
  : > "$dir/home/config/present-daemon"
  date +%s > "$dir/home/state/.afk"
  : > "$dir/home/state/.fake-drain"
  touch "$dir/home/state/.fail-terminal-stop-once"
  printf 'herdr\tsynthetic:pane\tsynthetic-workspace\n' > "$dir/home/state/.afk-daemon-terminal"
  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "failed away shutdown should keep the return gated (rc=$rc): $out"
  if [ -f "$dir/home/present-daemon.log" ]; then
    grep -qx start "$dir/home/present-daemon.log" \
      && fail "present daemon was started while away shutdown had failed (supervisors would race)"
  fi
  pass "return does not start the present daemon while away shutdown is unresolved"
}

test_away_reentry_refuses_pending_return_gate() {
  local dir out rc
  dir="$TMP_ROOT/reentry"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config"
  printf 'schema\tfm-afk-return.v1\nphase\tblocked\n' > "$dir/home/state/.afk-return-catchup"
  set +e
  out=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" "$ROOT/bin/fm-afk-launch.sh" start-native 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "away re-entry succeeded while return catch-up was pending"
  assert_contains "$out" 'return catch-up is still pending' "away re-entry refusal did not explain the pending owner"
  [ ! -e "$dir/home/state/.afk" ] || fail "away re-entry wrote .afk despite the pending return gate"
  pass "away-mode re-entry fails closed while the prior return catch-up is pending"
}

test_check_retries_recorded_terminal_teardown() {
  local dir gate out rc
  dir="$TMP_ROOT/terminal-teardown"
  install_runner "$dir"
  gate="$dir/home/state/.afk-return-catchup"
  date +%s > "$dir/home/state/.afk"
  printf 'herdr\tsynthetic:pane\tsynthetic-workspace\n' > "$dir/home/state/.afk-daemon-terminal"
  touch "$dir/home/state/.fail-terminal-stop-once"

  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "failed terminal teardown should keep return catch-up gated (rc=$rc): $out"
  [ -e "$gate" ] || fail "failed terminal teardown cleared the return gate"
  [ -e "$dir/home/state/.afk-daemon-terminal" ] || fail "failed terminal teardown discarded its durable record"
  [ ! -e "$dir/home/state/.afk" ] || fail "failed terminal teardown did not preserve stop ordering"

  out=$(run_return "$dir" check) || fail "check did not retry recorded terminal teardown: $out"
  [ ! -e "$dir/home/state/.afk-daemon-terminal" ] || fail "successful check left the terminal teardown record behind"
  [ ! -e "$gate" ] || fail "successful terminal teardown retry left the return gate behind"
  [ "$(wc -l < "$dir/home/stop.log" | tr -d ' ')" -eq 2 ] || fail "check did not retry terminal teardown exactly once"
  pass "check retries recorded terminal teardown and keeps catch-up gated until success"
}

# An away session with no supervisor pane delivers through the durable outbox
# instead of the escalation buffer, so a digest the reader never picked up lives
# there. Return catch-up must report it as the same evidence and clear it only
# after the gate closes.
test_return_reports_undelivered_inbox_records() {
  local dir gate out
  dir="$TMP_ROOT/paneless-catchup"
  install_runner "$dir"
  gate="$dir/home/state/.afk-return-catchup"
  date +%s > "$dir/home/state/.afk"
  : > "$dir/home/state/.fake-drain"
  printf 'paneless\n' > "$dir/home/state/.afk-delivery"
  printf '1784074271\t1\tescalation\tSupervisor escalate (1 event(s)): omega.status: done: PR 7\n' \
    > "$dir/home/state/.afk-outbox"
  seed_live_blocker "$dir" tmux inbox-blocker

  set +e
  out=$(run_return "$dir" begin)
  set -e
  assert_contains "$out" 'omega.status: done: PR 7' "an undelivered inbox record was not reported at return"
  grep -F $'evidence\tescalation\t' "$gate" >/dev/null \
    || fail "the undelivered inbox record was not retained as durable catch-up evidence"
  [ -s "$dir/home/state/.afk-outbox" ] || fail "return discarded an undelivered record while the gate was still open"

  printf 'resolved [key=inbox-blocker]: refreshed the synthetic token\n' >> "$dir/home/state/repair-task.status"
  out=$(run_return "$dir" check) || fail "resolved blocker did not clear return catch-up: $out"
  [ ! -e "$dir/home/state/.afk-outbox" ] || fail "successful check left reported inbox records behind"
  [ ! -e "$dir/home/state/.afk-delivery" ] || fail "successful check left the recorded delivery mode behind"
  pass "return catch-up reports undelivered inbox records as evidence and clears them only after the gate closes"
}

# An outbox that could not be READ is not an outbox that is EMPTY. Swallowing the
# read failure would file no escalation evidence and then delete the outbox on the
# way out, losing undelivered escalations this gate never actually saw.
test_return_refuses_to_clear_an_unreadable_inbox() {
  local dir gate out rc lock holder i=0
  dir="$TMP_ROOT/paneless-unreadable"
  install_runner "$dir"
  gate="$dir/home/state/.afk-return-catchup"
  date +%s > "$dir/home/state/.afk"
  : > "$dir/home/state/.fake-drain"
  printf 'paneless\n' > "$dir/home/state/.afk-delivery"
  printf '1784074271\t1\tescalation\tSupervisor escalate (1 event(s)): omega.status: blocked: needs a token\n' \
    > "$dir/home/state/.afk-outbox"

  # Hold the outbox lock in a live process so the gate's bounded read genuinely
  # fails. No live blocker is seeded: without the failed read this run would
  # close the gate and delete the outbox.
  lock="$dir/home/state/.afk-outbox.lock"
  bash -c '
    # shellcheck disable=SC1090
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$2"
    sleep 15
  ' _ "$ROOT" "$lock" >/dev/null 2>&1 &
  holder=$!
  while [ ! -e "$lock" ]; do
    [ "$i" -lt 100 ] || fail "the background lock holder never took the outbox lock"
    sleep 0.1
    i=$((i + 1))
  done

  set +e
  out=$(FM_AFK_OUTBOX_LOCK_TRIES=2 run_return "$dir" begin)
  rc=$?
  set -e
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  [ "$rc" -eq 3 ] || fail "an unreadable inbox must block return catch-up (rc=$rc): $out"
  # The gate gets one pass and then deletes the outbox, so a lock timeout that a
  # retrying reader would survive is still a blocker here, named for what it was.
  assert_contains "$out" 'away-mode inbox lock could not be acquired' "the read failure was not reported as a blocker: $out"
  [ -s "$dir/home/state/.afk-outbox" ] \
    || fail "return deleted an inbox whose content it never read"
  [ -e "$gate" ] || fail "the return gate did not stay open after an unreadable inbox"

  # With the lock released the retry reads it, reports it, and only then clears.
  out=$(run_return "$dir" check) || fail "return check failed once the inbox was readable again: $out"
  assert_contains "$out" 'omega.status: blocked: needs a token' "the retry did not report the record it finally read"
  [ ! -e "$dir/home/state/.afk-outbox" ] || fail "a successful read did not clear the reported inbox"
  pass "return catch-up blocks on an unreadable inbox and never deletes records it did not read"
}

# The same gate against the other way a read fails: the outbox file itself is
# present but unreadable, so the failure surfaces past the lock in the record scan
# rather than in the acquire. Preserving the records matters most here, because
# nothing else on disk holds an escalation the gate never saw.
test_return_refuses_to_clear_an_unreadable_inbox_file() {
  local dir gate out rc
  if [ "$(id -u)" = 0 ]; then
    pass "skipped: running as root, where mode 000 does not deny a read"
    return 0
  fi
  dir="$TMP_ROOT/paneless-unreadable-file"
  install_runner "$dir"
  gate="$dir/home/state/.afk-return-catchup"
  date +%s > "$dir/home/state/.afk"
  : > "$dir/home/state/.fake-drain"
  printf 'paneless\n' > "$dir/home/state/.afk-delivery"
  printf '1784074271\t1\tescalation\tSupervisor escalate (1 event(s)): omega.status: blocked: needs a token\n' \
    > "$dir/home/state/.afk-outbox"
  chmod 000 "$dir/home/state/.afk-outbox"

  set +e
  out=$(run_return "$dir" begin)
  rc=$?
  set -e

  [ "$rc" -eq 3 ] || fail "an unreadable inbox file must block return catch-up (rc=$rc): $out"
  assert_contains "$out" 'away-mode inbox could not be read' "the read failure was not reported as a blocker: $out"
  [ -e "$dir/home/state/.afk-outbox" ] \
    || fail "return deleted an inbox file whose content it never read"
  [ -e "$gate" ] || fail "the return gate did not stay open after an unreadable inbox file"

  chmod 644 "$dir/home/state/.afk-outbox"
  out=$(run_return "$dir" check) || fail "return check failed once the inbox was readable again: $out"
  assert_contains "$out" 'omega.status: blocked: needs a token' "the retry did not report the record it finally read"
  [ ! -e "$dir/home/state/.afk-outbox" ] || fail "a successful read did not clear the reported inbox"
  pass "return catch-up blocks on an unreadable inbox FILE and never deletes records it did not read"
}

# The reader this away session armed exits only on its NEXT poll, so it can still
# be running when return clears the delivery artifacts, and that poll may be
# inside an acknowledgement's compaction - which lands by renaming a sibling over
# the outbox file. Deleting outbox state outside the outbox lock races that
# rename: the finished session's records come back with the acknowledgement mark
# gone, so the next away session's reader replays them as fresh escalations. The
# clear must therefore go through the library's own locked owner and simply leave
# everything alone when it cannot take the lock.
#
# The outbox FILE is left absent on purpose: a pending read short-circuits on an
# absent outbox without taking the lock, so the gate still reaches the clearing
# step while the lock is held.
test_return_clears_inbox_state_only_under_the_outbox_lock() {
  local dir gate out holder lock i=0
  dir="$TMP_ROOT/locked-clear"
  install_runner "$dir"
  gate="$dir/home/state/.afk-return-catchup"
  date +%s > "$dir/home/state/.afk"
  : > "$dir/home/state/.fake-drain"
  printf 'paneless\n' > "$dir/home/state/.afk-delivery"
  printf '7\n' > "$dir/home/state/.afk-outbox.ack"
  printf '7\n' > "$dir/home/state/.afk-outbox.seq"
  lock="$dir/home/state/.afk-outbox.lock"

  bash -c '
    # shellcheck disable=SC1090
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$2"
    sleep 30
  ' _ "$ROOT" "$lock" >/dev/null 2>&1 &
  holder=$!
  while [ ! -e "$lock" ]; do
    [ "$i" -lt 100 ] || fail "the background lock holder never took the outbox lock"
    sleep 0.1
    i=$((i + 1))
  done

  set +e
  out=$(FM_AFK_OUTBOX_LOCK_TRIES=2 run_return "$dir" begin)
  set -e
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  [ ! -e "$gate" ] || fail "a clear that could not take the lock reopened the return gate: $out"
  [ -e "$dir/home/state/.afk-outbox.ack" ] \
    || fail "return deleted the acknowledgement mark while another process held the outbox lock"
  [ -e "$dir/home/state/.afk-outbox.seq" ] \
    || fail "return deleted the sequence counter while another process held the outbox lock"
  [ -e "$dir/home/state/.afk-delivery" ] \
    || fail "return deleted the recorded delivery mode while another process held the outbox lock"
  assert_contains "$out" 'could not clear stale away-mode artifact' \
    "return cleared inbox state without naming the lock it could not take: $out"
  pass "return clears inbox state under the outbox lock and leaves it intact when the lock is held"
}

test_return_gate_orders_catchup_before_bearings
test_explicit_reclassification_requires_durable_reason
test_captain_decision_does_not_masquerade_as_firstmate_blocker
test_return_restarts_present_daemon_on_clean_return
test_return_skips_present_daemon_when_shutdown_fails
test_away_reentry_refuses_pending_return_gate
test_check_retries_recorded_terminal_teardown
test_return_reports_undelivered_inbox_records
test_return_refuses_to_clear_an_unreadable_inbox
test_return_refuses_to_clear_an_unreadable_inbox_file
test_return_clears_inbox_state_only_under_the_outbox_lock
