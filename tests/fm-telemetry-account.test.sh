#!/usr/bin/env bash
# tests/fm-telemetry-account.test.sh - Visibility Gap-1, the shared account-stamp
# helper (bin/fm-telemetry-lib.sh fm_telemetry_stamp_account) and its two call
# sites. Design: data/design-visibility-improvements/report.md "Gap 1".
#
# Contract pinned here:
#   1. fm_telemetry_stamp_account writes account=<account> AND account_source=
#      <source> onto state/<id>.telemetry through fm_telemetry_set, so the two
#      keys stay one owned shape used by every producer.
#   2. An empty account writes nothing (FAIL-SOFT: no account known = gap, never
#      a bogus line) and exits 0.
#   3. Stamping does not clobber sibling keys (a pre-existing quota_pct or
#      count_429 written by another gap survives).
#   4. Call sites are wired: fm-spawn.sh stamps the resolved account at spawn
#      (account_source spawn), and fm-watch.sh stamps the post-rotation account
#      on a live switch (account_source switch).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-telemetry-lib.sh"
assert_present "$LIB" "bin/fm-telemetry-lib.sh is missing"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-telemetry-lib.sh
. "$LIB"

TMP=$(fm_test_tmproot fm-telemetry-account)
STATE="$TMP/state"
mkdir -p "$STATE"
TEL="$STATE/task1.telemetry"

# --- (1) stamps account + account_source together ----------------------------
fm_telemetry_stamp_account "$TEL" claude-2 spawn || fail "spawn stamp must succeed"
[ "$(fm_meta_get "$TEL" account)" = claude-2 ] || fail "account must read back"
[ "$(fm_meta_get "$TEL" account_source)" = spawn ] || fail "account_source must read back as spawn"
pass "fm_telemetry_stamp_account writes account= and account_source=spawn together"

# --- (2) empty account writes nothing, exits 0 -------------------------------
: > "$TEL"
fm_telemetry_stamp_account "$TEL" "" switch || fail "empty account must exit 0 (fail-soft)"
[ -s "$TEL" ] || pass "empty account leaves the telemetry file untouched"
[ -z "$(fm_meta_get "$TEL" account)" ] || fail "empty account must not write an account line"
pass "empty account stamps nothing (gap, never a bogus line)"

# --- (3) does not clobber sibling keys ----------------------------------------
fm_write_meta "$TEL" "quota_pct=40" "count_429=3"
fm_telemetry_stamp_account "$TEL" claude-1 switch || fail "switch stamp must succeed"
[ "$(fm_meta_get "$TEL" account)" = claude-1 ] || fail "account must update to the switched account"
[ "$(fm_meta_get "$TEL" account_source)" = switch ] || fail "account_source must read back as switch"
[ "$(fm_meta_get "$TEL" quota_pct)" = 40 ] || fail "stamping account must not clobber quota_pct"
[ "$(fm_meta_get "$TEL" count_429)" = 3 ] || fail "stamping account must not clobber count_429"
pass "account stamp preserves sibling telemetry keys (quota_pct, count_429)"

# --- (4) updates account in place, single-valued -----------------------------
fm_telemetry_stamp_account "$TEL" claude-3 spawn || fail "re-stamp must succeed"
[ "$(fm_meta_get "$TEL" account)" = claude-3 ] || fail "account must update in place"
[ "$(grep -c '^account=' "$TEL")" = 1 ] || fail "re-stamp must not leave duplicate account lines"
pass "account re-stamp updates in place, single-valued"

# --- (5) spawn call site is wired --------------------------------------------
SPAWN="$ROOT/bin/fm-spawn.sh"
assert_present "$SPAWN" "bin/fm-spawn.sh is missing"
assert_grep "fm-telemetry-lib.sh" "$SPAWN" "fm-spawn.sh must source the telemetry lib"
assert_grep "fm_telemetry_stamp_account" "$SPAWN" "fm-spawn.sh must stamp the resolved account at spawn"
# The stamp must sit AFTER the resolve-account call that produced SPAWN_ACCOUNT
# (so it stamps the resolved label, not before it), regardless of line drift.
resolve_line=$(grep -n 'fm-account-orchestrator.sh" resolve-account' "$SPAWN" | head -1 | cut -d: -f1)
stamp_line=$(grep -n 'fm_telemetry_stamp_account' "$SPAWN" | head -1 | cut -d: -f1)
[ -n "$resolve_line" ] && [ -n "$stamp_line" ] \
  || fail "could not locate the resolve-account/stamp pair in fm-spawn.sh (line drift?)"
[ "$stamp_line" -gt "$resolve_line" ] \
  || fail "the account stamp must sit after the resolve-account call that resolves SPAWN_ACCOUNT"
pass "fm-spawn.sh wires the account stamp after the SPAWN_ACCOUNT resolution"

# --- (6) switch call site is wired -------------------------------------------
WATCH="$ROOT/bin/fm-watch.sh"
assert_present "$WATCH" "bin/fm-watch.sh is missing"
assert_grep "fm_telemetry_stamp_account" "$WATCH" "fm-watch.sh must stamp the post-rotation account on switch"
watch_stamp_block=$(awk '/^orchestrator_rotate_on_tripwire\(\)/{f=1} f{print} f&&/^\}/{exit}' "$WATCH")
case "$watch_stamp_block" in
  *"fm_telemetry_stamp_account"*"switch"*) : ;;
  *) fail "the watch rotation stamp must call fm_telemetry_stamp_account with account_source switch: $watch_stamp_block" ;;
esac
pass "fm-watch.sh wires the account stamp into the tripwire rotation with account_source switch"

pass "fm-telemetry-account.test.sh: all checks passed"
