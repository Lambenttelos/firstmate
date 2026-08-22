#!/usr/bin/env bash
# Tests for the token-price snapshot owner (bin/fm-token-prices.sh) - PR-T1 of
# the token-usage-visibility design.
#
# Design of record: data/design-token-usage-visibility/report.md, PR-T1 and
# "Price table: one owner". The script is the ONLY writer of the owned price
# snapshot (config/token-prices.json by default, $FM_TOKEN_PRICES when set), so
# a wrong price is traceable to its source and date from the file alone.
#
# Covers, per the brief acceptance criteria:
#   - `--refresh` writes the snapshot with the sourced+dated header: price_source,
#     the source's cached_at_unix_secs + derived cached_at, this snapshot's own
#     written_at timestamps, and EVERY provider table as a straight copy
#   - a missing source cache fails loudly with a clear message, non-zero exit,
#     and writes no guessed snapshot
#   - a source cache with no providers table fails the same way
#   - the flat `prices` map holds only globally unambiguous model ids: a model
#     present in TWO provider tables is excluded so the coster fails loudly on
#     it instead of guessing which provider's price applies
#   - a bare call prints the current snapshot when it exists, or a clear
#     "not yet refreshed" message (never invented prices) when it does not
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SCRIPT="$ROOT/bin/fm-token-prices.sh"
TMP_ROOT=$(fm_test_tmproot fm-token-prices-tests)

# A fixture models.dev cache: header + three provider tables. crof's glm-5.2 is
# unique to crof (flat map includes it); deepseek-v4-flash appears in BOTH crof
# and opencode-go at different prices (flat map must exclude it as ambiguous);
# mimo-v2.5 is unique to opencode-go (flat map includes it).
SOURCE_FIXTURE="$TMP_ROOT/src/models_dev_pricing.json"
OUT_SNAPSHOT="$TMP_ROOT/out/token-prices.json"
write_source_fixture() {
  mkdir -p "$(dirname "$SOURCE_FIXTURE")"
  cat > "$SOURCE_FIXTURE" <<'JSON'
{
  "cached_at_unix_secs": 1786924990,
  "providers": {
    "crof": {
      "glm-5.2": {"input_usd_per_mtok": 0.5, "output_usd_per_mtok": 2.2, "cache_read_usd_per_mtok": 0.08},
      "deepseek-v4-flash": {"input_usd_per_mtok": 0.2, "output_usd_per_mtok": 0.4, "cache_read_usd_per_mtok": 0.02}
    },
    "opencode-go": {
      "deepseek-v4-flash": {"input_usd_per_mtok": 0.22, "output_usd_per_mtok": 0.66, "cache_read_usd_per_mtok": 0.007},
      "mimo-v2.5": {"input_usd_per_mtok": 0.3, "output_usd_per_mtok": 0.6}
    },
    "anthropic": {
      "claude-opus-4-8": {"input_usd_per_mtok": 5, "output_usd_per_mtok": 25, "cache_read_usd_per_mtok": 0.5, "cache_write_usd_per_mtok": 6.25},
      "claude-haiku-4-5": {"input_usd_per_mtok": 1, "output_usd_per_mtok": 5, "cache_read_usd_per_mtok": 0.1, "cache_write_usd_per_mtok": 1.25},
      "claude-haiku-4-5-20251001": {"input_usd_per_mtok": 1, "output_usd_per_mtok": 5, "cache_read_usd_per_mtok": 0.1, "cache_write_usd_per_mtok": 1.25}
    }
  }
}
JSON
}

# --- refresh writes a sourced+dated snapshot ----------------------------------

test_refresh_writes_snapshot_with_sourced_and_dated_header() {
  write_source_fixture
  local out status
  out=$(FM_TOKEN_PRICES="$OUT_SNAPSHOT" FM_TOKEN_PRICES_SOURCE="$SOURCE_FIXTURE" "$SCRIPT" --refresh 2>&1)
  status=$?
  expect_code 0 "$status" "refresh should succeed" \
    || fail "refresh failed: $out"
  assert_present "$OUT_SNAPSHOT" "refresh wrote no snapshot"
  local header
  header=$(python3 - "$OUT_SNAPSHOT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(d["price_source"])
print(d["cached_at_unix_secs"])
print(d["cached_at"])
print(d["written_at_unix_secs"])
print(d["written_at"])
print(json.dumps(sorted(d["providers"].keys())))
print(json.dumps(sorted(d["prices"].keys())))
print(d["providers"]["opencode-go"]["deepseek-v4-flash"]["input_usd_per_mtok"])
print(len(d["prices"]))
PY
)
  [ "$(echo "$header" | sed -n 1p)" = "jcode-models-dev-cache" ] \
    || fail "price_source not jcode-models-dev-cache: $out"
  [ "$(echo "$header" | sed -n 2p)" = "1786924990" ] \
    || fail "cached_at_unix_secs not carried from source"
  [ "$(echo "$header" | sed -n 3p)" = "2026-08-17T00:03:10Z" ] \
    || fail "cached_at ISO derived wrong"
  [ "$(echo "$header" | sed -n 4p)" -gt 0 ] || fail "written_at_unix_secs missing"
  case "$(echo "$header" | sed -n 5p)" in
    20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) : ;;
    *) fail "written_at ISO format wrong: $(echo "$header" | sed -n 5p)" ;;
  esac
  [ "$(echo "$header" | sed -n 6p)" = '["anthropic", "crof", "opencode-go"]' ] \
    || fail "providers map must carry every provider table: $(echo "$header" | sed -n 6p)"
  [ "$(echo "$header" | sed -n 7p)" = '["claude-haiku-4-5", "claude-haiku-4-5-20251001", "claude-opus-4-8", "glm-5.2", "mimo-v2.5"]' ] \
    || fail "flat prices map must hold exactly the unambiguous models: $(echo "$header" | sed -n 7p)"
  [ "$(echo "$header" | sed -n 8p)" = "0.22" ] \
    || fail "provider-scoped price row must be the straight copy: $(echo "$header" | sed -n 8p)"
  [ "$(echo "$header" | sed -n 9p)" = "5" ] || fail "expected exactly 5 unambiguous fixture models"
  echo "$header" | sed -n 7p | grep -q "claude-haiku-4-5-20251001" || fail "dated model missing from snapshot"
  echo "$header" | sed -n 7p | grep -q "glm-5.2" || fail "unique non-anthropic model must land in the flat map"
  echo "$header" | sed -n 7p | grep -q "deepseek-v4-flash" && fail "ambiguous model must be EXCLUDED from the flat map"
  # The snapshot's per-model price rows keep jcode's exact shape.
  python3 - "$OUT_SNAPSHOT" <<'PY' || fail "anthropic price row shape wrong"
import json, sys
d = json.load(open(sys.argv[1]))
row = d["prices"]["claude-opus-4-8"]
assert row == {"input_usd_per_mtok": 5, "output_usd_per_mtok": 25,
               "cache_read_usd_per_mtok": 0.5, "cache_write_usd_per_mtok": 6.25}, row
PY
  pass "refresh writes the snapshot with a sourced+dated header and the anthropic price rows"
}

# --- refresh fails loudly on a missing or empty source ------------------------

test_refresh_missing_source_fails_loudly() {
  write_source_fixture
  local out status out_missing="$TMP_ROOT/out-missing/token-prices.json"
  out=$(FM_TOKEN_PRICES="$out_missing" FM_TOKEN_PRICES_SOURCE="$TMP_ROOT/missing/feed.json" "$SCRIPT" --refresh 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "refresh succeeded with a missing source cache"
  assert_contains "$out" "source cache not found" "missing-source failure is not loud/clear"
  assert_absent "$out_missing" "refresh wrote a snapshot from a missing source (guessed prices)"
  pass "missing source cache fails loudly, non-zero, and writes no guesses"
}

test_refresh_no_providers_table_fails_loudly() {
  local empty="$TMP_ROOT/noprov/feed.json"
  mkdir -p "$TMP_ROOT/noprov"
  cat > "$empty" <<'JSON'
{"cached_at_unix_secs": 1, "other": {"x": {}}}
JSON
  local out status out_noprov="$TMP_ROOT/out-noprov/token-prices.json"
  out=$(FM_TOKEN_PRICES="$out_noprov" FM_TOKEN_PRICES_SOURCE="$empty" "$SCRIPT" --refresh 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "refresh succeeded with no providers table"
  assert_contains "$out" "has no providers table" "no-providers failure is not loud/clear"
  assert_absent "$out_noprov" "refresh wrote a snapshot without a providers table"
  pass "a source cache with no providers table fails loudly, non-zero, and writes nothing"
}

test_refresh_unreadable_source_fails_loudly() {
  local bogus="$TMP_ROOT/bogus/feed.json"
  mkdir -p "$TMP_ROOT/bogus"
  printf 'not json\n' > "$bogus"
  local out status out_bogus="$TMP_ROOT/out-bogus/token-prices.json"
  out=$(FM_TOKEN_PRICES="$out_bogus" FM_TOKEN_PRICES_SOURCE="$bogus" "$SCRIPT" --refresh 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "refresh succeeded on a non-JSON source"
  assert_contains "$out" "not valid JSON" "non-JSON source failure is not loud/clear"
  assert_absent "$out_bogus" "refresh wrote a snapshot from a non-JSON source"
  pass "a non-JSON source cache fails loudly and writes nothing"
}

# --- bare call: prints current snapshot or a clear not-yet message -------------

test_bare_call_prints_snapshot_when_present() {
  write_source_fixture
  FM_TOKEN_PRICES="$OUT_SNAPSHOT" FM_TOKEN_PRICES_SOURCE="$SOURCE_FIXTURE" "$SCRIPT" --refresh >/dev/null 2>&1 \
    || fail "precondition refresh failed"
  local out status
  out=$(FM_TOKEN_PRICES="$OUT_SNAPSHOT" "$SCRIPT" 2>&1)
  status=$?
  expect_code 0 "$status" "bare call should succeed with a snapshot present"
  assert_contains "$out" '"price_source": "jcode-models-dev-cache"' "bare call did not print the snapshot"
  assert_contains "$out" '"claude-opus-4-8"' "bare call output missing model prices"
  pass "a bare call prints the current snapshot when it exists"
}

test_bare_call_no_snapshot_prints_not_yet_refreshed() {
  local out status
  out=$(FM_TOKEN_PRICES="$TMP_ROOT/never/snapshot.json" "$SCRIPT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "bare call with no snapshot exited 0"
  assert_contains "$out" "not yet refreshed" "no-snapshot message missing 'not yet refreshed'"
  assert_contains "$out" "never invents prices" "no-snapshot message must state it never invents prices"
  pass "a bare call with no snapshot prints a clear not-yet-refreshed message, never prices"
}

test_unknown_argument_refused() {
  local out status
  out=$(FM_TOKEN_PRICES="$OUT_SNAPSHOT" "$SCRIPT" --frobnicate 2>&1)
  status=$?
  [ "$status" = 2 ] || fail "unknown argument exited $status, want 2"
  assert_contains "$out" "unknown argument" "unknown-argument refusal is not clear"
  pass "an unknown argument is refused with usage"
}

test_refresh_writes_snapshot_with_sourced_and_dated_header
test_refresh_missing_source_fails_loudly
test_refresh_no_providers_table_fails_loudly
test_refresh_unreadable_source_fails_loudly
test_bare_call_prints_snapshot_when_present
test_bare_call_no_snapshot_prints_not_yet_refreshed
test_unknown_argument_refused
