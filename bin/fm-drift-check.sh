#!/usr/bin/env bash
# fm-drift-check.sh - startup drift alarm for captain-owned operating values.
#
# WHY THIS EXISTS. A captain-owned operating value (the watcher poll cadence was
# the first) drifted for weeks because it had no owner and no provenance: any
# session could lower it for a short-lived debugging reason, nothing recorded the
# captain's standing preference, and nothing compared the live value against it,
# so a temporary value silently became the permanent one. This is the missing
# provenance half of the fix (the missing-ownership half is config/watcher-cadence
# + fm-cadence-lib.sh reading it in preference to the environment). It SHOUTS when
# a live value has drifted from the captain's recorded preference, so the next
# session sees it loudly instead of never.
#
# GENERALIZED, NOT HARD-WIRED TO ONE KEY. A captain-owned value is a row of three
# fields produced by fm_drift_owned_values: a preference key, the LIVE resolved
# value, and a human label. The recorded preferences live in one parseable file,
# config/captain-preferences. To protect the next captain-owned value, append one
# producer to fm_drift_owned_values and document its preference key - the compare
# loop, the loud line format, and the bootstrap wiring are already generic.
#
# CONTRACT.
#   - config/captain-preferences is optional, local, and gitignored. Its format
#     is one `key = value` per line; blank lines and #-comments are ignored;
#     whitespace around key and value is tolerated; the last occurrence of a key
#     wins. A key that is absent, empty, or whitespace records NO preference for
#     that value, so drift is not evaluated for it (absence is not agreement).
#   - For every owned value whose preference IS recorded, this compares the live
#     value against it. On a mismatch it prints exactly one line to stdout:
#       CONFIG_DRIFT: <label> is <live> but the captain's recorded preference is <recorded> (<source-hint>)
#     and nothing when they agree, so a silent run means no drift.
#   - It never mutates anything and never fails the session: it is detect-only,
#     exactly like the rest of the bootstrap detect section, and exits 0.
#
# docs/configuration.md "Captain-owned value drift alarm (config/captain-preferences)"
# owns the user-facing schema; this file owns the mechanism.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-cadence-lib.sh
. "$SCRIPT_DIR/fm-cadence-lib.sh"

PREFS_FILE="$CONFIG/captain-preferences"

# Read one recorded preference by key, or print nothing when absent/empty. Same
# parser shape as the cadence file so the two files behave identically.
fm_drift_recorded() {  # <key>
  local key=$1
  [ -f "$PREFS_FILE" ] || return 0
  sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$PREFS_FILE" 2>/dev/null \
    | grep -v '^[[:space:]]*#' | tail -n 1 | sed 's/[[:space:]]*$//'
}

# Emit one row per captain-owned value: "<pref-key>\t<live-value>\t<label>".
#
# Family 1: the watcher cadence knobs. Their live value is resolved by the SAME
# fm-cadence-lib.sh the watcher uses, against the same config/watcher-cadence and
# the same environment fallback, so the audited value is byte-for-byte the value
# the running watcher would consume. The preference key is the cadence file key
# prefixed with `watcher_`, so it is self-describing and cannot collide with a
# future non-cadence owned value.
#
# To add a NEW captain-owned value family, append its rows here.
fm_drift_owned_values() {
  local cadence_file="$CONFIG/watcher-cadence" file_key env_var default
  while read -r file_key env_var default; do
    [ -n "$file_key" ] || continue
    fm_cadence_resolve "$cadence_file" "$env_var" "$file_key" "$default"
    printf 'watcher_%s\t%s\t%s\n' "$file_key" "$FM_CADENCE_RESULT" "watcher $file_key cadence"
  done <<EOF
$(fm_cadence_registry)
EOF
}

# Compare every owned value with a recorded preference and print a loud
# CONFIG_DRIFT line for each mismatch. Prints nothing when everything agrees or
# nothing is recorded.
fm_drift_report() {
  local pref_key live label recorded
  while IFS="$(printf '\t')" read -r pref_key live label; do
    [ -n "$pref_key" ] || continue
    recorded=$(fm_drift_recorded "$pref_key")
    [ -n "$recorded" ] || continue          # no recorded preference -> not evaluated
    [ "$live" = "$recorded" ] && continue    # agrees -> silent
    printf 'CONFIG_DRIFT: %s is %s but the captain'\''s recorded preference is %s (set config/watcher-cadence to the recorded value, or update config/captain-preferences %s if the change is intended)\n' \
      "$label" "$live" "$recorded" "$pref_key"
  done <<EOF
$(fm_drift_owned_values)
EOF
}

# Running as a script (not sourced) prints the report and exits 0. Sourcing for
# unit tests loads the functions and returns before doing anything.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_drift_report
  exit 0
fi
