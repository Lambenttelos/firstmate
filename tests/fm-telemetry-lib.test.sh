#!/usr/bin/env bash
# tests/fm-telemetry-lib.test.sh - the shared per-task telemetry writer
# (bin/fm-telemetry-lib.sh fm_telemetry_set), the producer half of the
# state/<id>.telemetry artifact (design:
# data/design-visibility-improvements/report.md, "The shared PRODUCER artifact").
#
# The single contract under test: several visibility gaps write different keys
# onto ONE key=value file, so fm_telemetry_set must UPDATE one key in place
# WITHOUT clobbering any other key already present (the brief's requirement 3:
# "the key=value telemetry helper updates count_429 without clobbering a
# pre-existing account= line"). Also pins: append-on-absent, create-on-first-
# write, single-valued rewrite, invalid-key/multi-line-value refusal, and that
# the file it writes is read back by the same fm_meta_get the meta file uses.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-telemetry-lib.sh"
assert_present "$LIB" "bin/fm-telemetry-lib.sh is missing"

# fm_meta_get lives in fm-backend.sh; load both so a written line reads back
# through the exact reader the design promises (zero new parser).
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-telemetry-lib.sh
. "$LIB"

TMP=$(fm_test_tmproot fm-telemetry)
STATE="$TMP/state"
mkdir -p "$STATE"
TEL="$STATE/task1.telemetry"

# --- create on first write ---------------------------------------------------
fm_telemetry_set "$TEL" count_429 1 || fail "fm_telemetry_set must succeed on first write"
assert_present "$TEL" "fm_telemetry_set must create the telemetry file on first write"
[ "$(fm_meta_get "$TEL" count_429)" = 1 ] || fail "first write must be readable by fm_meta_get"
pass "fm_telemetry_set creates the file and the value reads back via fm_meta_get"

# --- update in place (same key) ----------------------------------------------
fm_telemetry_set "$TEL" count_429 2 || fail "update must succeed"
[ "$(fm_meta_get "$TEL" count_429)" = 2 ] || fail "update-in-place must change count_429 to 2"
[ "$(grep -c '^count_429=' "$TEL")" = 1 ] || fail "update must not leave a duplicate count_429 line"
pass "fm_telemetry_set updates an existing key in place, single-valued"

# --- update one key does NOT clobber a pre-existing sibling key (the contract) -
# Seed a sibling account= line the way gap-1 would, then have gap-2 bump
# count_429; the account line must survive verbatim.
fm_write_meta "$TEL" "account=claude-2" "count_429=2" "observed_at=1000"
fm_telemetry_set "$TEL" count_429 3 || fail "clobber-guard update must succeed"
[ "$(fm_meta_get "$TEL" account)" = claude-2 ] \
  || fail "updating count_429 must NOT clobber a pre-existing account= line"
[ "$(fm_meta_get "$TEL" count_429)" = 3 ] || fail "count_429 must be updated to 3"
[ "$(fm_meta_get "$TEL" observed_at)" = 1000 ] || fail "unrelated observed_at must survive"
pass "fm_telemetry_set updates count_429 without clobbering account= or observed_at="

# --- append a new key preserves existing keys --------------------------------
fm_telemetry_set "$TEL" last_429_ts 1699999999 || fail "append new key must succeed"
[ "$(fm_meta_get "$TEL" last_429_ts)" = 1699999999 ] || fail "new key must read back"
[ "$(fm_meta_get "$TEL" account)" = claude-2 ] || fail "append must not disturb account="
[ "$(fm_meta_get "$TEL" count_429)" = 3 ] || fail "append must not disturb count_429="
pass "fm_telemetry_set appends a new key while preserving all existing keys"

# --- refuses an invalid key --------------------------------------------------
if fm_telemetry_set "$TEL" "bad key" x 2>/dev/null; then
  fail "an invalid key (with a space) must be refused"
fi
pass "fm_telemetry_set refuses an invalid key"

# --- refuses a multi-line value ----------------------------------------------
if fm_telemetry_set "$TEL" k "$(printf 'a\nb')" 2>/dev/null; then
  fail "a multi-line value must be refused"
fi
pass "fm_telemetry_set refuses a multi-line value"

pass "fm-telemetry-lib.test.sh: all checks passed"
