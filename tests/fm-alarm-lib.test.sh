#!/usr/bin/env bash
# Unit tests for the shared alarm dispatcher (bin/fm-alarm-lib.sh).
#
# The library's whole job is to turn a config/wedge-alarm-style channel file into
# best-effort active alerts without ever aborting its caller, so the properties
# worth pinning are the grammar and the safety guarantees:
#   - the platform default resolves correctly;
#   - configured channels, `auto`, and `command:<cmd>` all dispatch;
#   - a single `off` anywhere is a kill switch;
#   - an absent config file behaves as `auto`;
#   - the FM_ALARM_EXEC seam intercepts every channel so no test posts a real
#     notification, and FM_ALARM_CHANNEL overrides the file;
#   - FM_ALARM_FIRED reports whether a real channel was attempted.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-alarm-lib.sh
. "$ROOT/bin/fm-alarm-lib.sh"

TMP=$(fm_test_tmproot fm-alarm-lib)
mkdir -p "$TMP"

# A recorder EXEC seam: a real script that appends "<channel>\t<summary>" per
# call. It must be an executable (not a shell function) because the bounded
# runner dispatches it through `timeout`/exec. Nothing here ever reaches a real
# notifier.
REC="$TMP/alarm.rec"
: > "$REC"
EXEC_SEAM="$TMP/recorder.sh"
cat > "$EXEC_SEAM" <<EOF
#!/usr/bin/env bash
printf '%s\t%s\n' "\$1" "\$2" >> "$REC"
EOF
chmod +x "$EXEC_SEAM"

reset_rec() { : > "$REC"; }

# --- platform default -------------------------------------------------------

case "$(uname)" in
  Darwin)
    [ "$(fm_alarm_platform_default)" = osascript ] \
      || fail "platform default on Darwin should be osascript"
    ;;
  Linux)
    if command -v notify-send >/dev/null 2>&1; then
      [ "$(fm_alarm_platform_default)" = notify-send ] \
        || fail "platform default on Linux with notify-send should be notify-send"
    else
      # No notify-send: platform default is unresolvable (nonzero, no output).
      out=$(fm_alarm_platform_default) && fail "platform default should fail on headless Linux"
      [ -z "$out" ] || fail "unresolved platform default should print nothing"
    fi
    ;;
esac
pass "platform default resolves per OS"

# --- configured channel file dispatches through the seam --------------------

reset_rec
printf 'osascript\ncommand: true\n' > "$TMP/chan"
FM_ALARM_EXEC="$EXEC_SEAM" fm_alarm_notify "$TMP/chan" "hello world"
assert_grep "osascript	hello world" "$REC" "osascript channel should dispatch through the seam"
assert_grep "command	hello world" "$REC" "command channel should dispatch through the seam"
[ "$FM_ALARM_FIRED" -eq 1 ] || fail "FM_ALARM_FIRED should be 1 after a real channel fired"
pass "configured channels dispatch through the EXEC seam"

# --- off anywhere is a kill switch ------------------------------------------

reset_rec
printf 'osascript\noff\ncommand: true\n' > "$TMP/chan-off"
FM_ALARM_EXEC="$EXEC_SEAM" fm_alarm_notify "$TMP/chan-off" "should not fire"
[ ! -s "$REC" ] || fail "a single off directive must disable every channel"
[ "$FM_ALARM_FIRED" -eq 0 ] || fail "FM_ALARM_FIRED should be 0 when off kills all channels"
pass "off is a position-independent kill switch"

# --- absent config behaves as auto ------------------------------------------

reset_rec
FM_ALARM_EXEC="$EXEC_SEAM" fm_alarm_notify "$TMP/does-not-exist" "auto default"
# auto resolves to the platform channel; the seam records that resolved channel.
if grep -q 'auto default' "$REC"; then
  pass "absent config falls back to auto and fires the platform channel"
else
  # On a headless Linux host with no notify-send, auto cannot resolve - that is a
  # correct no-channel outcome, not a failure.
  case "$(uname)" in
    Linux) command -v notify-send >/dev/null 2>&1 \
      && fail "auto should have fired on Linux with notify-send" \
      || pass "absent config -> auto -> no platform channel on headless Linux (expected)" ;;
    *) fail "absent config should fire the platform channel via auto" ;;
  esac
fi

# --- FM_ALARM_CHANNEL overrides the file ------------------------------------

reset_rec
printf 'off\n' > "$TMP/chan-off-file"
FM_ALARM_CHANNEL="command: true" FM_ALARM_EXEC="$EXEC_SEAM" \
  fm_alarm_notify "$TMP/chan-off-file" "override wins"
assert_grep "command	override wins" "$REC" "FM_ALARM_CHANNEL must override an off file"
pass "FM_ALARM_CHANNEL overrides the config file"

# --- comments and blank lines are ignored -----------------------------------

reset_rec
printf '# a comment\n\n   \ncommand: true\n' > "$TMP/chan-comments"
FM_ALARM_EXEC="$EXEC_SEAM" fm_alarm_notify "$TMP/chan-comments" "past comments"
assert_grep "command	past comments" "$REC" "comments and blanks must be skipped"
pass "comment and blank lines are ignored"

# --- a hung channel is bounded ----------------------------------------------

# Dispatch a genuinely hanging command: channel and confirm it returns within a
# bounded time rather than hanging the suite. The seam is deliberately NOT set
# here so the real bounded runner (fm_alarm_run_bounded) executes the sleep.
start=$(date +%s)
FM_ALARM_TIMEOUT_SECS=1 FM_ALARM_CHANNEL="command: sleep 30" \
  fm_alarm_notify "$TMP/none" "bounded" >/dev/null 2>&1 || true
end=$(date +%s)
[ $((end - start)) -lt 10 ] || fail "a hanging channel must be terminated by the bounded runner"
pass "a hung channel is terminated by the timeout"

pass "all fm-alarm-lib tests passed"
