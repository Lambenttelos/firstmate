#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-sandbox-check.sh, the startup alarm for a root
# no-mistakes daemon that lost IS_SANDBOX=1.
#
# The no-mistakes daemon's review step invokes `claude --dangerously-skip-permissions`,
# which claude refuses under root without IS_SANDBOX=1, instant-failing every
# claude review lane fleet-wide. So this detector must SHOUT one NM_SANDBOX line
# when a live daemon runs under root without the flag, and stay silent on every
# other case: the flag present, not under root, no running daemon, or an
# unreadable environment.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-nm-sandbox-check.sh"
[ -x "$CHECK" ] || fail "bin/fm-nm-sandbox-check.sh is missing or not executable"

trap fm_test_cleanup EXIT

# Run the detector with a fake `id` (forcing a uid), a fake `no-mistakes` whose
# `daemon status` reports the given pid (empty = no running daemon), and a fake
# /proc dir where <pid>/environ holds the given environ lines (__none__ = no
# environ file, i.e. unreadable). Sets FM_OUT to stdout and FM_RC to the exit
# status. It assigns globals rather than echoing so the exit status survives (a
# command-substitution capture would run in a subshell and drop FM_RC).
run_check() {  # <uid> <pid> [environ-content|__none__]
  local uid=$1 pid=$2 environ=${3:-}
  local dir; dir=$(fm_test_tmproot fm-nm-sandbox)
  local fb="$dir/bin"
  mkdir -p "$fb"

  cat > "$fb/id" <<SH
#!/usr/bin/env bash
[ "\$1" = -u ] && { printf '%s\n' "$uid"; exit 0; }
exit 1
SH
  chmod +x "$fb/id"

  # Fake no-mistakes: `daemon status` prints a running line with the pid, or a
  # stopped line when the pid is empty.
  if [ -n "$pid" ]; then
    cat > "$fb/no-mistakes" <<SH
#!/usr/bin/env bash
[ "\$1 \$2" = "daemon status" ] && { printf '  \xe2\x97\x8f daemon running (pid %s)\n' "$pid"; exit 0; }
exit 0
SH
  else
    cat > "$fb/no-mistakes" <<SH
#!/usr/bin/env bash
[ "\$1 \$2" = "daemon status" ] && { printf '  daemon stopped\n'; exit 0; }
exit 0
SH
  fi
  chmod +x "$fb/no-mistakes"

  # Build the fake proc dir. __none__ means no environ file at all. The environ
  # arg is newline-separated KEY=VALUE (bash variables cannot carry the real NUL
  # separator, so translate newlines to NUL when writing the file).
  local proc="$dir/proc"
  if [ -n "$pid" ] && [ "$environ" != "__none__" ]; then
    mkdir -p "$proc/$pid"
    printf '%s\n' "$environ" | tr '\n' '\0' > "$proc/$pid/environ"
  fi

  local out
  out=$( PATH="$fb:$PATH" FM_PROC_DIR="$proc" "$CHECK" ); FM_RC=$?
  FM_OUT=$out
}

# Build a newline-separated environ blob from KEY=VALUE args (run_check
# translates the newlines to the real NUL separator when it writes the file).
environ_blob() {
  printf '%s\n' "$@"
}

test_root_daemon_missing_sandbox_alarms() {
  run_check 0 92045 "$(environ_blob PATH=/usr/bin HOME=/root)"
  expect_code 0 "$FM_RC" "detector must exit 0"
  assert_contains "$FM_OUT" "NM_SANDBOX:" "a root daemon without IS_SANDBOX must alarm"
  assert_contains "$FM_OUT" "pid 92045" "the alarm must name the live daemon pid"
  assert_contains "$FM_OUT" "IS_SANDBOX=1" "the alarm must name the missing flag"
  pass "fm-nm-sandbox-check: root daemon missing IS_SANDBOX alarms"
}

test_root_daemon_with_sandbox_silent() {
  run_check 0 92045 "$(environ_blob PATH=/usr/bin IS_SANDBOX=1)"
  expect_code 0 "$FM_RC" "detector must exit 0"
  assert_not_contains "$FM_OUT" "NM_SANDBOX" "the flag is present, so the detector must stay silent"
  pass "fm-nm-sandbox-check: root daemon with IS_SANDBOX is silent"
}

test_nonroot_never_alarms() {
  run_check 1000 92045 "$(environ_blob PATH=/usr/bin)"
  expect_code 0 "$FM_RC" "detector must exit 0"
  assert_not_contains "$FM_OUT" "NM_SANDBOX" "a non-root host is never probed and never alarms"
  pass "fm-nm-sandbox-check: non-root never alarms (no injection expected there)"
}

test_no_running_daemon_silent() {
  run_check 0 "" ""
  expect_code 0 "$FM_RC" "detector must exit 0"
  assert_not_contains "$FM_OUT" "NM_SANDBOX" "no running daemon means nothing to check"
  pass "fm-nm-sandbox-check: no running daemon is silent"
}

test_unreadable_environ_silent() {
  run_check 0 92045 "__none__"
  expect_code 0 "$FM_RC" "detector must exit 0"
  assert_not_contains "$FM_OUT" "NM_SANDBOX" "an unreadable environ is a blind spot, not a fault"
  pass "fm-nm-sandbox-check: unreadable daemon environ stays silent"
}

test_root_daemon_missing_sandbox_alarms
test_root_daemon_with_sandbox_silent
test_nonroot_never_alarms
test_no_running_daemon_silent
test_unreadable_environ_silent
