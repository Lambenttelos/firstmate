#!/usr/bin/env bash
# fm-send post-submit settle pause (FM_SEND_SETTLE).
#
# fm-send's success only proves the composer cleared - the Enter landed and the
# text was submitted. The harness then takes a beat to spin up the turn before its
# busy footer appears, so an immediate peek after fm-send returns would see the
# stale idle pane. fm-send therefore pauses FM_SEND_SETTLE seconds (default 1, 0
# disables) after a successful text submit, so the receiving turn has time to
# visibly start. These tests pin that behavior hermetically (stubbed tmux + sleep,
# no real agent):
#   1. A successful text send pauses for the FM_SEND_SETTLE value (default 1).
#   2. FM_SEND_SETTLE=0 produces no pause at all (sleep is never invoked for it).
#   3. The pause is tunable (FM_SEND_SETTLE=7 pauses 7).
#   4. The --key path never pauses (it bypasses the submit/settle path entirely).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-settle)

# A fake tmux that lets fm-send's submit path reach a clean "empty" verdict, plus a
# fake sleep that records every requested duration (one per line) instead of
# sleeping. send-keys always succeeds; display-message yields a numeric cursor_y;
# capture-pane returns an empty bordered composer so fm_tmux_composer_state reads
# "empty" (submit landed) on the first Enter. The sleep log path comes from
# FM_SLEEP_LOG.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys) exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '\xe2\x94\x82 \xe2\x94\x82\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "$FM_SLEEP_LOG"
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# run_send <fakebin> <sleep-log> [env-assignments...] -- <fm-send args...>
# Runs fm-send.sh with the stubs on PATH. FM_ROOT_OVERRIDE points at a non-repo
# temp dir so fm-guard's tangle check stays silent, and FM_HOME at an empty home so
# no in-flight task is seen; guard noise goes to stderr (discarded). Echoes nothing;
# returns fm-send's exit code.
run_send() {
  local fb=$1 log=$2 home; shift 2
  home="$TMP_ROOT/home-$RANDOM"; mkdir -p "$home/state"
  : > "$log"
  env "$@" PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SLEEP_LOG="$log" \
    "$SEND" "sess:win" "hello captain" 2>/dev/null
}

test_default_send_pauses_one_second() {
  local dir fb log rc last
  dir="$TMP_ROOT/default"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  run_send "$fb" "$log"; rc=$?
  expect_code 0 "$rc" "default send should succeed"
  last=$(tail -1 "$log")
  [ "$last" = 1 ] || fail "default send: expected a trailing 1s settle pause, got '$last'"$'\n'"--- sleeps ---"$'\n'"$(cat "$log")"
  pass "fm-send: a successful text send pauses the default 1s after submit"
}

test_zero_disables_pause() {
  local dir fb log rc
  dir="$TMP_ROOT/zero"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  run_send "$fb" "$log" FM_SEND_SETTLE=0; rc=$?
  expect_code 0 "$rc" "FM_SEND_SETTLE=0 send should succeed"
  # The disable path must not invoke sleep with 0 at all - the only sleeps left are
  # the submit core's own settle/enter waits, none of which is "0".
  if grep -qx '0' "$log"; then
    fail "FM_SEND_SETTLE=0 still paused (a sleep 0 was recorded)"$'\n'"--- sleeps ---"$'\n'"$(cat "$log")"
  fi
  pass "fm-send: FM_SEND_SETTLE=0 produces no settle pause"
}

test_pause_is_tunable() {
  local dir fb log rc last
  dir="$TMP_ROOT/tunable"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  run_send "$fb" "$log" FM_SEND_SETTLE=7; rc=$?
  expect_code 0 "$rc" "FM_SEND_SETTLE=7 send should succeed"
  last=$(tail -1 "$log")
  [ "$last" = 7 ] || fail "FM_SEND_SETTLE=7: expected a trailing 7s settle pause, got '$last'"$'\n'"--- sleeps ---"$'\n'"$(cat "$log")"
  pass "fm-send: the settle pause is tunable via FM_SEND_SETTLE"
}

test_key_path_never_pauses() {
  local dir fb log rc home
  dir="$TMP_ROOT/key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  home="$dir/home"; mkdir -p "$home/state"
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SLEEP_LOG="$log" \
    "$SEND" "sess:win" --key Escape 2>/dev/null; rc=$?
  expect_code 0 "$rc" "--key send should succeed"
  [ ! -s "$log" ] || fail "--key path paused but must not"$'\n'"--- sleeps ---"$'\n'"$(cat "$log")"
  pass "fm-send: the --key path never pauses (settle scoped to text submit)"
}

# A fake tmux whose composer row keeps real typed text, so the submit core reads
# "pending" on every Enter check and fm-send reports a swallowed Enter (a
# non-delivery) after the retry budget. Same stub skeleton as make_stubs.
make_pending_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys) exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '\xe2\x94\x82 hello \xe2\x94\x82\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "$FM_SLEEP_LOG"
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# Visibility Gap-4: a CONFIRMED text delivery stamps last_steer_ts= into the
# target task's state/<id>.telemetry (the watcher's stuck-steer reader), while
# a failed/unconfirmed send and an explicit endpoint with no recorded meta never
# write. These tests pin that stamp contract hermetically.
test_confirmed_delivery_stamps_last_steer_ts() {
  local dir fb log rc home tel
  dir="$TMP_ROOT/stamp"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  home="$dir/home"; mkdir -p "$home/state"
  fm_write_meta "$home/state/stamptask.meta" "window=sess:win" "kind=ship" "harness=codex"
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SLEEP_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" fm-stamptask "hello captain" 2>/dev/null; rc=$?
  expect_code 0 "$rc" "confirmed delivery send should succeed"
  tel="$home/state/stamptask.telemetry"
  assert_present "$tel" "a confirmed delivery must create the task telemetry file"
  grep -q '^last_steer_ts=' "$tel" || fail "a confirmed delivery must stamp last_steer_ts="$'\n'"$(cat "$tel")"
  pass "fm-send: a confirmed text delivery stamps last_steer_ts into the task telemetry"
}

test_stamp_preserves_sibling_telemetry_keys() {
  local dir fb log rc home tel
  dir="$TMP_ROOT/sibling"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  home="$dir/home"; mkdir -p "$home/state"
  fm_write_meta "$home/state/stamptask.meta" "window=sess:win" "kind=ship" "harness=codex"
  tel="$home/state/stamptask.telemetry"
  fm_write_meta "$tel" "account=claude-2" "count_429=5"
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SLEEP_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" fm-stamptask "hello captain" 2>/dev/null; rc=$?
  expect_code 0 "$rc" "sibling-key send should succeed"
  grep -q '^last_steer_ts=' "$tel" || fail "delivery must stamp last_steer_ts next to sibling keys"$'\n'"$(cat "$tel")"
  [ "$(grep '^account=' "$tel" | cut -d= -f2-)" = claude-2 ] \
    || fail "stamping last_steer_ts must NOT clobber the existing account= key"$'\n'"$(cat "$tel")"
  [ "$(grep '^count_429=' "$tel" | cut -d= -f2-)" = 5 ] \
    || fail "stamping last_steer_ts must NOT clobber the existing count_429= key"$'\n'"$(cat "$tel")"
  pass "fm-send: last_steer_ts stamps without clobbering sibling telemetry keys"
}

test_non_delivery_does_not_stamp() {
  local dir fb log rc home tel
  dir="$TMP_ROOT/pending"; mkdir -p "$dir"
  fb=$(make_pending_stubs "$dir"); log="$dir/sleep.log"
  home="$dir/home"; mkdir -p "$home/state"
  fm_write_meta "$home/state/stamptask.meta" "window=sess:win" "kind=ship" "harness=codex"
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SLEEP_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" fm-stamptask "hello captain" 2>/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "an Enter-swallowed send must fail (non-delivery)"
  tel="$home/state/stamptask.telemetry"
  if [ -e "$tel" ] && grep -q '^last_steer_ts=' "$tel"; then
    fail "a non-delivery must NOT stamp last_steer_ts"$'\n'"$(cat "$tel")"
  fi
  pass "fm-send: a swallowed Enter (non-delivery) never stamps last_steer_ts"
}

test_explicit_target_without_meta_does_not_stamp() {
  local dir fb log rc home tel
  dir="$TMP_ROOT/explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"
  home="$dir/home"; mkdir -p "$home/state"
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SLEEP_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" "sess:win" "hello captain" 2>/dev/null; rc=$?
  expect_code 0 "$rc" "explicit target send should succeed"
  if compgen -G "$home/state/*.telemetry" >/dev/null; then
    fail "an explicit endpoint with no meta must not fabricate a telemetry file"
  fi
  pass "fm-send: an explicit endpoint with no recorded meta writes no telemetry stamp"
}

test_default_send_pauses_one_second
test_zero_disables_pause
test_pause_is_tunable
test_key_path_never_pauses
test_confirmed_delivery_stamps_last_steer_ts
test_stamp_preserves_sibling_telemetry_keys
test_non_delivery_does_not_stamp
test_explicit_target_without_meta_does_not_stamp
