#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh --env KEY=VAL override and the
# bin/fm-spawn-joe.sh second-token wrapper.
#
# The parser cases reach the validation error before any tmux/treehouse side
# effect (fm-spawn-batch.test.sh uses the same fast-fail pattern), so they need
# no mocks. The wrapper cases install a fake `fm-spawn` via the
# FM_SPAWN_JOE_TARGET test seam so the wrapper's `--env OPENCODE_API_KEY=...`
# append is observable without launching anything.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
JOE="$ROOT/bin/fm-spawn-joe.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-env)
export FM_BACKEND=tmux

# Clear ambient firstmate overrides so each case owns its environment.
run_spawn() {
  FM_ROOT_OVERRIDE='' \
    FM_HOME='' \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
}

# --- parser validation ------------------------------------------------------

test_env_requires_equals() {
  local out status
  out=$(run_spawn nope-env-z1 projects/none --env BAREVALUE 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "--env without = should fail"
  printf '%s\n' "$out" | grep -F 'error: --env requires KEY=VAL' >/dev/null \
    || fail "--env without = should print the KEY=VAL error"
  pass "--env rejects values without ="
}

test_env_inline_requires_equals() {
  local out status
  out=$(run_spawn nope-env-z2 projects/none --env=BAREVALUE 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "--env= without = should fail"
  printf '%s\n' "$out" | grep -F 'error: --env requires KEY=VAL' >/dev/null \
    || fail "--env= without = should print the KEY=VAL error"
  pass "--env=BAREVALUE is rejected"
}

test_env_rejects_bad_key() {
  local out status
  # KEY must be POSIX: not empty, not starting with a digit, no special chars.
  out=$(run_spawn nope-env-z3 projects/none --env 1BAD=val 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "--env with a digit-leading key should fail"
  printf '%s\n' "$out" | grep -F 'error: --env KEY must be a POSIX env var name' >/dev/null \
    || fail "--env digit-leading key should print the POSIX-name error"
  out=$(run_spawn nope-env-z4 projects/none --env 'BA D=val' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "--env with a space in the key should fail"
  printf '%s\n' "$out" | grep -F 'error: --env KEY must be a POSIX env var name' >/dev/null \
    || fail "--env space-in-key should print the POSIX-name error"
  pass "--env rejects non-POSIX KEY names"
}

test_env_accepts_empty_value() {
  local out status
  # KEY= with empty VAL is valid (clears the var); should pass validation and
  # fast-fail later at the missing-brief check instead of the env validation.
  out=$(run_spawn nope-env-z5 projects/none --env EMPTY_VAL= 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn with --env EMPTY_VAL= should still fail (missing brief)"
  printf '%s\n' "$out" | grep -F 'error: --env requires KEY=VAL' >/dev/null \
    && fail "empty VAL should NOT trip the KEY=VAL validation"
  printf '%s\n' "$out" | grep -F 'error: --env KEY must be a POSIX env var name' >/dev/null \
    && fail "empty VAL should NOT trip the POSIX-name validation"
  pass "--env KEY= accepts empty VAL"
}

# --- wrapper: token resolution + fm-spawn invocation ------------------------

# Install a fake fm-spawn that records its argv to a sentinel file.
install_fake_spawn() {
  local sentinel_file=$1 fake_spawn=$2
  cat > "$fake_spawn" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$sentinel_file"
exit 0
SH
  chmod +x "$fake_spawn"
}

test_no_env_override_survives_set_u() {
  local out status
  # Regression: on bash 3.2 (macOS default), "${ENV_OVERRIDES[@]}" on an empty
  # array under `set -u` throws "unbound variable" and aborts before any
  # validation runs. Spawning with zero --env flags must not hit that.
  out=$(run_spawn nope-env-z9 projects/none 2>&1)
  status=$?
  printf '%s\n' "$out" | grep -F 'unbound variable' >/dev/null \
    && fail "spawn with no --env should not throw unbound variable; got: $out"
  [ "$status" -ne 0 ] || fail "spawn with no brief should still fail (missing brief), got status 0"
  pass "spawn with zero --env overrides does not throw unbound variable under set -u"
}

test_wrapper_passes_token_from_env() {
  local home fake_spawn sentinel out status args
  home="$TMP_ROOT/env-token-z6 home"
  mkdir -p "$home"
  fake_spawn="$TMP_ROOT/z6-fake-fm-spawn.sh"
  sentinel="$TMP_ROOT/z6-args.txt"
  install_fake_spawn "$sentinel" "$fake_spawn"
  out=$(FM_SPAWN_JOE_TARGET="$fake_spawn" \
    OPENCODE_API_KEY_JOE='sk-joe-token-123' \
    HOME="$home" \
    FM_HOME="$home" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 \
    "$JOE" task-id-z6 projects/alpha --harness pi 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "wrapper should exit 0 when token + fake target succeed; got: $out"
  # The fake writes one arg per line; flatten to a single space-separated line for literal asserts.
  args=$(tr '\n' ' ' < "$sentinel")
  printf '%s\n' "$args" | grep -F 'task-id-z6' >/dev/null || fail "wrapper did not forward task id"
  printf '%s\n' "$args" | grep -F -- '--harness pi' >/dev/null || fail "wrapper stripped --harness pi"
  printf '%s\n' "$args" | grep -F -- '--env OPENCODE_API_KEY=sk-joe-token-123' >/dev/null \
    || fail "wrapper did not append --env OPENCODE_API_KEY=<env token>"
  pass "wrapper reads OPENCODE_API_KEY_JOE from env and appends --env to fm-spawn"
}

test_wrapper_reads_token_from_zshenv() {
  local home fake_spawn sentinel out status args
  home="$TMP_ROOT/env-token-z7 home"
  mkdir -p "$home"
  # Write ~/.zshenv with the joe token export (double-quoted form).
  cat > "$home/.zshenv" <<'SH'
export PATH=/usr/bin:/bin
export OPENCODE_API_KEY_JOE="sk-zshenv-token-456"
export OTHER_VAR=unrelated
SH
  fake_spawn="$TMP_ROOT/z7-fake-fm-spawn.sh"
  sentinel="$TMP_ROOT/z7-args.txt"
  install_fake_spawn "$sentinel" "$fake_spawn"
  # OPENCODE_API_KEY_JOE is NOT in the env: wrapper must read it from ~/.zshenv.
  out=$(env -u OPENCODE_API_KEY_JOE \
    FM_SPAWN_JOE_TARGET="$fake_spawn" \
    HOME="$home" \
    FM_HOME="$home" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 \
    "$JOE" task-id-z7 projects/alpha --harness pi 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "wrapper should exit 0 when token resolved from zshenv; got: $out"
  args=$(tr '\n' ' ' < "$sentinel")
  printf '%s\n' "$args" | grep -F -- '--env OPENCODE_API_KEY=sk-zshenv-token-456' >/dev/null \
    || fail "wrapper did not append --env with the zshenv-resolved token"
  pass "wrapper resolves OPENCODE_API_KEY_JOE from ~/.zshenv when env is unset"
}

test_wrapper_fails_loud_when_token_missing() {
  local home fake_spawn out status
  home="$TMP_ROOT/env-token-z8 home"
  mkdir -p "$home"
  # No ~/.zshenv, no env token.
  out=$(env -u OPENCODE_API_KEY_JOE \
    HOME="$home" \
    FM_SPAWN_JOE_TARGET="$TMP_ROOT/should-not-exist-z8" \
    "$JOE" task-id-z8 projects/alpha --harness pi 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "wrapper should exit non-zero when token missing; got: $out"
  printf '%s\n' "$out" | grep -F 'OPENCODE_API_KEY_JOE not set and not found in ~/.zshenv' >/dev/null \
    || fail "wrapper did not print the missing-token error"
  pass "wrapper fails loudly when token is nowhere"
}

test_env_requires_equals
test_env_inline_requires_equals
test_env_rejects_bad_key
test_env_accepts_empty_value
test_no_env_override_survives_set_u
test_wrapper_passes_token_from_env
test_wrapper_reads_token_from_zshenv
test_wrapper_fails_loud_when_token_missing