#!/usr/bin/env bash
# Behavior tests for bin/fm-grill-reserve.sh: it allocates the next free ADR
# number from max(product-repo scan, ledger max) + 1, records the claim in the
# firstmate-private ledger under a lock, creates the session directory, is
# idempotent per slug, refuses malformed input, and never writes into a product
# repo.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-grill-reserve)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data"

LEDGER="$HOME_DIR/data/grilling/adr-reservations.md"

reserve() { FM_HOME="$HOME_DIR" "$ROOT/bin/fm-grill-reserve.sh" "$@"; }

field() { # <output> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p"
}

# First reservation with an empty ledger and a product-repo scan of 15 must
# claim 0016 (scan max + 1), write the ledger and the session directory.
test_first_reservation_uses_scan_max() {
  local out adr dir
  out=$(reserve --slug fee-scope --date 2026-07-28 --project hyfin --adr-scan-max 15) \
    || fail "first reservation must succeed"
  adr=$(field "$out" adr)
  dir=$(field "$out" session_dir)
  [ "$adr" = "0016" ] || fail "expected adr 0016 from scan max 15, got '$adr'"
  assert_present "$dir" "session directory must be created"
  [ "$dir" = "$HOME_DIR/data/grilling/2026-07-28-fee-scope" ] \
    || fail "session dir path wrong: '$dir'"
  assert_grep "| 2026-07-28 | fee-scope | hyfin | 0016 | reserved |" "$LEDGER" \
    "ledger row must be recorded"
  pass "fm-grill-reserve.sh: first reservation claims scan-max + 1 and records it"
}

# A second, different slug must not reuse the number; with a lower scan than the
# ledger max it advances from the ledger max instead.
test_second_reservation_advances_from_ledger() {
  local out adr
  out=$(reserve --slug other-thing --date 2026-07-28 --project hyfin --adr-scan-max 3) \
    || fail "second reservation must succeed"
  adr=$(field "$out" adr)
  [ "$adr" = "0017" ] || fail "expected 0017 (ledger max 16 + 1), got '$adr'"
  pass "fm-grill-reserve.sh: distinct slug advances from ledger max, never collides"
}

# Re-running with an already-reserved slug replays the same number, never a new
# one, so a retried prepare is safe.
test_idempotent_per_slug() {
  local out adr
  out=$(reserve --slug fee-scope --date 2026-07-28 --project hyfin --adr-scan-max 99) \
    || fail "replay reservation must succeed"
  adr=$(field "$out" adr)
  [ "$adr" = "0016" ] || fail "replay must return original 0016, got '$adr'"
  local rows
  rows=$(grep -c "| fee-scope |" "$LEDGER")
  [ "$rows" = "1" ] || fail "replay must not add a second ledger row (got $rows)"
  pass "fm-grill-reserve.sh: idempotent per slug on replay"
}

test_rejects_bad_input() {
  reserve --slug Bad_Slug --date 2026-07-28 --project hyfin --adr-scan-max 1 2>/dev/null \
    && fail "must reject uppercase/underscore slug"
  reserve --slug ok --date 2026-7-8 --project hyfin --adr-scan-max 1 2>/dev/null \
    && fail "must reject malformed date"
  reserve --slug ok --date 2026-07-28 --project hyfin --adr-scan-max x 2>/dev/null \
    && fail "must reject non-numeric scan max"
  reserve --slug ok --date 2026-07-28 --project "" --adr-scan-max 1 2>/dev/null \
    && fail "must reject empty project"
  pass "fm-grill-reserve.sh: rejects malformed input"
}

# The script must confine writes to $FM_HOME/data/grilling. Point it at a fresh
# home and confirm it touches nothing elsewhere under data.
test_writes_only_under_grilling() {
  local h2="$TMP_ROOT/home2"
  mkdir -p "$h2/data"
  FM_HOME="$h2" "$ROOT/bin/fm-grill-reserve.sh" \
    --slug clean --date 2026-07-28 --project alpha --adr-scan-max 0 >/dev/null \
    || fail "reservation in fresh home must succeed"
  local stray
  stray=$(find "$h2/data" -mindepth 1 -maxdepth 1 ! -name grilling)
  [ -z "$stray" ] || fail "must write only under data/grilling, found: $stray"
  pass "fm-grill-reserve.sh: confines writes to data/grilling"
}

test_first_reservation_uses_scan_max
test_second_reservation_advances_from_ledger
test_idempotent_per_slug
test_rejects_bad_input
test_writes_only_under_grilling
