#!/usr/bin/env bash
# tests/fm-drift-check.test.sh - the captain-owned value drift alarm
# (bin/fm-drift-check.sh) and its config/captain-preferences schema.
# docs/configuration.md "Captain-owned value drift alarm" owns the contract; this
# suite pins that a recorded preference is compared against the LIVE resolved
# value (via the shared bin/fm-cadence-lib.sh resolver, so the audited value is
# byte-for-byte the watcher's), that a mismatch SHOUTS exactly one CONFIG_DRIFT
# line while agreement is silent, that an absent or empty preference is not
# evaluated (absence is not agreement), that the alarm is config-authoritative
# (a config/watcher-cadence value can itself be the drifting live value), and
# that the mechanism is generalized across every recognized cadence knob.
#
# It also proves the alarm is wired into bin/fm-bootstrap.sh in BOTH detect-only
# (read-only) and full modes, because a read-only session still needs to see a
# silent drift.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ROOT is exported by tests/lib.sh above.
# shellcheck disable=SC2153  # ROOT comes from lib.sh, not a BOOT misspelling
DRIFT="$ROOT/bin/fm-drift-check.sh"
BOOT="$ROOT/bin/fm-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-drift-check)

# Run the drift check against an isolated config dir with a clean env (no cadence
# knobs unless a case sets them). Usage: run_drift <config-dir> [VAR=val ...]
run_drift() {  # <config-dir> [VAR=val ...]
  local cfg=$1
  shift
  env -u FM_POLL -u FM_SIGNAL_GRACE -u FM_HEARTBEAT \
    FM_CONFIG_OVERRIDE="$cfg" "$@" "$DRIFT"
}

test_no_prefs_file_is_silent() {
  local cfg out
  cfg="$TMP_ROOT/noprefs"; mkdir -p "$cfg"
  out=$(run_drift "$cfg")
  [ -z "$out" ] || fail "an absent config/captain-preferences produced output: $out"
  pass "an absent config/captain-preferences records no preference and is silent"
}

test_agreement_is_silent() {
  local cfg out
  cfg="$TMP_ROOT/agree"; mkdir -p "$cfg"
  # Recorded 300 matches the built-in live default of 300.
  printf 'watcher_poll = 300\n' > "$cfg/captain-preferences"
  out=$(run_drift "$cfg")
  [ -z "$out" ] || fail "a recorded preference equal to the live value still shouted: $out"
  pass "a recorded preference equal to the live value is silent"
}

test_empty_pref_not_evaluated() {
  local cfg out
  cfg="$TMP_ROOT/emptypref"; mkdir -p "$cfg"
  # An empty value records NO preference, so drift is not evaluated even though the
  # env has driven the live value far from any default.
  printf 'watcher_poll =\n' > "$cfg/captain-preferences"
  out=$(run_drift "$cfg" FM_POLL=60)
  [ -z "$out" ] || fail "an empty recorded preference was evaluated (absence is not agreement): $out"
  pass "an empty recorded preference is not evaluated (absence is not agreement)"
}

test_env_drift_below_recorded_shouts() {
  local cfg out
  cfg="$TMP_ROOT/envdrift"; mkdir -p "$cfg"
  # A stale FM_POLL a prior session left in the environment: live 60, recorded 300.
  printf 'watcher_poll = 300\n' > "$cfg/captain-preferences"
  out=$(run_drift "$cfg" FM_POLL=60)
  printf '%s\n' "$out" | grep -q '^CONFIG_DRIFT: watcher poll cadence is 60 but the captain'"'"'s recorded preference is 300' \
    || fail "a live-vs-recorded mismatch did not shout the expected CONFIG_DRIFT line: $out"
  [ "$(printf '%s\n' "$out" | grep -c '^CONFIG_DRIFT:')" = 1 ] \
    || fail "expected exactly one CONFIG_DRIFT line: $out"
  pass "a live value drifted below the recorded preference shouts exactly one CONFIG_DRIFT line"
}

test_config_file_value_is_the_live_value() {
  local cfg out
  cfg="$TMP_ROOT/configdrift"; mkdir -p "$cfg"
  # The alarm is config-authoritative: a value set in config/watcher-cadence is
  # itself the live value the watcher would consume, so it can be the drifting one.
  printf 'poll=120\n' > "$cfg/watcher-cadence"
  printf 'watcher_poll = 300\n' > "$cfg/captain-preferences"
  out=$(run_drift "$cfg")
  printf '%s\n' "$out" | grep -q '^CONFIG_DRIFT: watcher poll cadence is 120 but the captain'"'"'s recorded preference is 300' \
    || fail "a drifting config/watcher-cadence value was not audited as the live value: $out"
  pass "the alarm audits the config/watcher-cadence value as the live value (config-authoritative)"
}

test_config_restore_clears_drift() {
  local cfg out
  cfg="$TMP_ROOT/restore"; mkdir -p "$cfg"
  # Restoring the config value to the recorded preference silences the alarm, even
  # with a stale env value present - the config owner wins.
  printf 'poll=300\n' > "$cfg/watcher-cadence"
  printf 'watcher_poll = 300\n' > "$cfg/captain-preferences"
  out=$(run_drift "$cfg" FM_POLL=60)
  [ -z "$out" ] || fail "restoring config/watcher-cadence to the recorded value did not clear the drift: $out"
  pass "restoring the config value to the recorded preference clears the drift (config wins over a stale env)"
}

test_generalized_across_knobs() {
  local cfg out
  cfg="$TMP_ROOT/general"; mkdir -p "$cfg"
  # Not hard-wired to poll: signal_grace and heartbeat are audited by the same
  # generic mechanism. Drive two knobs off their recorded preference at once.
  printf 'watcher_signal_grace = 240\nwatcher_heartbeat = 600\n' > "$cfg/captain-preferences"
  out=$(run_drift "$cfg" FM_SIGNAL_GRACE=30 FM_HEARTBEAT=99)
  printf '%s\n' "$out" | grep -q '^CONFIG_DRIFT: watcher signal_grace cadence is 30 ' \
    || fail "signal_grace drift was not audited: $out"
  printf '%s\n' "$out" | grep -q '^CONFIG_DRIFT: watcher heartbeat cadence is 99 ' \
    || fail "heartbeat drift was not audited: $out"
  pass "the drift mechanism is generalized across every recognized cadence knob, not hard-wired to poll"
}

# --- bootstrap wiring: the alarm surfaces in both read-only and full modes ----

# A minimal fake toolchain so bootstrap reaches the drift check without spewing
# unrelated MISSING lines; we only assert on the CONFIG_DRIFT line's presence.
make_fake_toolchain() {  # <fakebin>
  local fakebin=$1
  mkdir -p "$fakebin"
  local t
  for t in tmux node gh-axi chrome-devtools-axi lavish-axi quota-axi git; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/$t"
    chmod +x "$fakebin/$t"
  done
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = get ] && [ "${2:-}" = --help ] && { printf 'Usage: treehouse get [--lease]\n'; exit 0; }
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf 'no-mistakes version v1.31.2 (fake)\n'; exit 0; }
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
}

run_bootstrap_drift() {  # <home> <detect-only 0|1>
  local home=$1 detect=$2 fakebin
  fakebin="$home/fakebin"
  make_fake_toolchain "$fakebin"
  env -u FM_POLL -u FM_SIGNAL_GRACE -u FM_HEARTBEAT \
    PATH="$fakebin:/usr/bin:/bin" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_BOOTSTRAP_DETECT_ONLY="$detect" "$BOOT" 2>/dev/null
}

test_bootstrap_surfaces_drift_both_modes() {
  local home out mode detect
  home="$TMP_ROOT/boot-home"; mkdir -p "$home/config"
  printf 'manual\n' > "$home/config/backlog-backend"
  printf 'poll=60\n' > "$home/config/watcher-cadence"
  printf 'watcher_poll = 300\n' > "$home/config/captain-preferences"
  while IFS='^' read -r mode detect; do
    [ -n "$mode" ] || continue
    out=$(run_bootstrap_drift "$home" "$detect")
    printf '%s\n' "$out" | grep -q '^CONFIG_DRIFT: watcher poll cadence is 60 ' \
      || fail "bootstrap ($mode mode) did not surface the CONFIG_DRIFT line: $out"
  done <<'ROWS'
detect-only^1
full^0
ROWS
  pass "bootstrap surfaces CONFIG_DRIFT in both read-only and full modes"
}

test_bootstrap_silent_on_agreement() {
  local home out
  home="$TMP_ROOT/boot-home-agree"; mkdir -p "$home/config"
  printf 'manual\n' > "$home/config/backlog-backend"
  printf 'poll=300\n' > "$home/config/watcher-cadence"
  printf 'watcher_poll = 300\n' > "$home/config/captain-preferences"
  out=$(run_bootstrap_drift "$home" 1)
  printf '%s\n' "$out" | grep -q '^CONFIG_DRIFT:' \
    && fail "bootstrap shouted CONFIG_DRIFT when the value agreed with the preference: $out"
  pass "bootstrap is silent about drift when the live value agrees with the recorded preference"
}

test_no_prefs_file_is_silent
test_agreement_is_silent
test_empty_pref_not_evaluated
test_env_drift_below_recorded_shouts
test_config_file_value_is_the_live_value
test_config_restore_clears_drift
test_generalized_across_knobs
test_bootstrap_surfaces_drift_both_modes
test_bootstrap_silent_on_agreement
