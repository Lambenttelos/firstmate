#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-daemon.sh, the firstmate-owned no-mistakes daemon
# launch path.
#
# The no-mistakes daemon inherits its environment from the shell that starts it,
# and its review step invokes `claude --dangerously-skip-permissions`, which
# claude refuses under root without IS_SANDBOX=1. So the launch path must export
# IS_SANDBOX=1 when running as root for the subcommands that (re)launch the
# daemon (start/restart), and must NOT alter the environment on a non-root host
# or for non-launching subcommands (status/stop).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$ROOT/bin/fm-nm-daemon.sh"
[ -x "$WRAPPER" ] || fail "bin/fm-nm-daemon.sh is missing or not executable"

# Register temp-dir cleanup: run_wrapper appends its per-call sandbox dirs to
# FM_TEST_CLEANUP_DIRS (from lib.sh), and this trap removes them on exit.
trap fm_test_cleanup EXIT

# assert_eq <expected> <actual> <msg>: exact string equality.
assert_eq() {
  [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"
}

# Run the wrapper with a fake `id` (forcing a uid) and a fake `no-mistakes` that
# records the value of IS_SANDBOX it was invoked with, plus the args it received.
# Returns via files under a per-call dir: <dir>/sandbox and <dir>/args.
run_wrapper() {  # <uid> <subcmd> [extra args...]
  local uid=$1; shift
  local subcmd=$1; shift
  # Create the per-call sandbox with an absolute, self-contained mktemp. NEVER
  # derive it from a possibly-empty variable: if $dir were empty, "$dir/bin"
  # would resolve to the system /bin and this test would overwrite real tools.
  # Hard-fail instead so a broken temp root can never touch the host PATH.
  local dir; dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-daemon-call.XXXXXX") || \
    fail "mktemp failed to create the per-call sandbox dir"
  case "$dir" in
    /tmp/*|"${TMPDIR:-/tmp}"/*) : ;;
    *) fail "refusing to use an unexpected sandbox dir '$dir'" ;;
  esac
  FM_TEST_CLEANUP_DIRS+=("$dir")
  local fb="$dir/bin"
  mkdir -p "$fb"

  cat > "$fb/id" <<SH
#!/usr/bin/env bash
[ "\$1" = -u ] && { printf '%s\n' "$uid"; exit 0; }
exit 1
SH
  chmod +x "$fb/id"

  cat > "$fb/no-mistakes" <<SH
#!/usr/bin/env bash
# Record whether IS_SANDBOX was set in the environment, and the args passed.
if [ -n "\${IS_SANDBOX+x}" ]; then
  printf 'IS_SANDBOX=%s\n' "\$IS_SANDBOX" > "$dir/sandbox"
else
  printf 'UNSET\n' > "$dir/sandbox"
fi
printf '%s\n' "\$*" > "$dir/args"
exit 0
SH
  chmod +x "$fb/no-mistakes"

  ( PATH="$fb:$PATH"; "$WRAPPER" "$subcmd" "$@" ) >/dev/null 2>&1
  local rc=$?
  printf '%s\n' "$dir"
  return "$rc"
}

test_root_start_injects_sandbox() {
  local dir; dir=$(run_wrapper 0 start)
  assert_eq "IS_SANDBOX=1" "$(cat "$dir/sandbox")" \
    "under root, 'start' must launch the daemon with IS_SANDBOX=1"
  assert_eq "daemon start" "$(cat "$dir/args")" \
    "the subcommand must be passed through verbatim as 'daemon start'"
  pass "fm-nm-daemon start: root injects IS_SANDBOX=1"
}

test_root_restart_injects_sandbox() {
  local dir; dir=$(run_wrapper 0 restart)
  assert_eq "IS_SANDBOX=1" "$(cat "$dir/sandbox")" \
    "under root, 'restart' must launch the daemon with IS_SANDBOX=1"
  pass "fm-nm-daemon restart: root injects IS_SANDBOX=1"
}

test_root_status_leaves_env_unchanged() {
  local dir; dir=$(run_wrapper 0 status)
  assert_eq "UNSET" "$(cat "$dir/sandbox")" \
    "'status' does not launch the daemon, so it must not set IS_SANDBOX"
  pass "fm-nm-daemon status: root leaves IS_SANDBOX unset (no daemon launch)"
}

test_root_stop_leaves_env_unchanged() {
  local dir; dir=$(run_wrapper 0 stop)
  assert_eq "UNSET" "$(cat "$dir/sandbox")" \
    "'stop' does not launch the daemon, so it must not set IS_SANDBOX"
  pass "fm-nm-daemon stop: root leaves IS_SANDBOX unset (no daemon launch)"
}

test_nonroot_start_leaves_env_unchanged() {
  local dir; dir=$(run_wrapper 1000 start)
  assert_eq "UNSET" "$(cat "$dir/sandbox")" \
    "a non-root host must keep a byte-identical environment (no IS_SANDBOX)"
  assert_eq "daemon start" "$(cat "$dir/args")" \
    "the subcommand must still be passed through verbatim"
  pass "fm-nm-daemon start: non-root does not set IS_SANDBOX"
}

test_extra_args_passed_through() {
  local dir; dir=$(run_wrapper 0 start --root /root/.no-mistakes)
  assert_eq "daemon start --root /root/.no-mistakes" "$(cat "$dir/args")" \
    "extra args after the subcommand must be forwarded to no-mistakes"
  pass "fm-nm-daemon: extra args are forwarded verbatim"
}

test_missing_subcommand_refuses() {
  local out rc
  out=$("$WRAPPER" 2>&1); rc=$?
  [ "$rc" -eq 2 ] || fail "a missing subcommand must exit 2, got $rc"
  case "$out" in
    *"a daemon subcommand is required"*) : ;;
    *) fail "expected a missing-subcommand error, got '$out'" ;;
  esac
  pass "fm-nm-daemon: a missing subcommand refuses with usage"
}

test_root_start_injects_sandbox
test_root_restart_injects_sandbox
test_root_status_leaves_env_unchanged
test_root_stop_leaves_env_unchanged
test_nonroot_start_leaves_env_unchanged
test_extra_args_passed_through
test_missing_subcommand_refuses
