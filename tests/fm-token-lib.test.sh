#!/usr/bin/env bash
# Tests for the token-sum + cost-if-API + subscription-coverage library
# (bin/fm-token-lib.sh) - PR-T1 of the token-usage-visibility design.
#
# Design of record: data/design-token-usage-visibility/report.md, PR-T1.
# The lib is the ONE owner of token-summing and costing math so every consumer
# (the report CLI in PR-T2, the telemetry writer and dashboard in PR-T5) renders
# the same number. Sourcing is side-effect free; this suite drives the pure
# functions against fixtures and the design's verified worked example.
#
# Covers, per the brief acceptance criteria:
#   - a known session fixture yields EXACT token sums and EXACT cost_if_api
#     matching the design's hand-computed worked example ($264.32, exact
#     decimal 264.3189115)
#   - an unknown-model session yields cost = UNKNOWN (empty), NEVER 0, while
#     its token sums are still reported exactly
#   - a dated model id prices via exact match first, then falls back to its
#     -YYYYMMDD-stripped family (distinct fixture prices prove which branch won)
#   - subscription_covered is true for a claude-oauth provider_key AND for a
#     remote+route_api_method=claude-oauth combo, false for plain claude
#   - cost output annotates price_source + price_cached_at, and cost_if_api_estimate
#     is always false on PR-T1's exact math (the labeling key downstream
#     estimate callers reuse)
#   - fail-closed: missing session file, missing price snapshot, or an
#     incomplete price row all yield an UNKNOWN cost, never a fabricated zero
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=bin/fm-token-lib.sh disable=SC1091
. "$ROOT/bin/fm-token-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-token-lib-tests)

# Value assertion helpers parsing the lib's KEY=VALUE session summary.
summary_val() { # <out> <key>
  local out=$1 key=$2
  printf '%s\n' "$out" | sed -n "s/^$key=//p" | tail -n 1
}

# Realistic price fixture: a subset of the anthropic table with the real
# USD-per-Mtok values and the same header shape the snapshot owner writes.
PRICE_FIXTURE="$TMP_ROOT/price/prices.json"
write_price_fixture() {
  mkdir -p "$(dirname "$PRICE_FIXTURE")"
  cat > "$PRICE_FIXTURE" <<'JSON'
{
  "price_source": "jcode-models-dev-cache",
  "cached_at": "2026-08-17T00:03:10Z",
  "prices": {
    "claude-opus-4-8": {"input_usd_per_mtok": 5, "output_usd_per_mtok": 25, "cache_read_usd_per_mtok": 0.5, "cache_write_usd_per_mtok": 6.25},
    "claude-opus-4-5": {"input_usd_per_mtok": 5, "output_usd_per_mtok": 25, "cache_read_usd_per_mtok": 0.5, "cache_write_usd_per_mtok": 6.25},
    "claude-haiku-4-5": {"input_usd_per_mtok": 1, "output_usd_per_mtok": 5, "cache_read_usd_per_mtok": 0.1, "cache_write_usd_per_mtok": 1.25},
    "claude-haiku-4-5-20251001": {"input_usd_per_mtok": 1, "output_usd_per_mtok": 5, "cache_read_usd_per_mtok": 0.1, "cache_write_usd_per_mtok": 1.25},
    "claude-fable-5": {"input_usd_per_mtok": 10, "output_usd_per_mtok": 50, "cache_read_usd_per_mtok": 1, "cache_write_usd_per_mtok": 12.5}
  }
}
JSON
}

# Write a jcode-shaped session json. Args: path model provider route messages_json
write_session() {
  local path=$1 model=$2 provider=$3 route=$4 messages=$5
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<JSON
{"id":"session_test","model":"$model","provider_key":"$provider","route_api_method":$route,"messages":$messages}
JSON
}

# --- worked example: exact sums and exact cost --------------------------------

test_worked_example_exact_sums_and_cost() {
  write_price_fixture
  # The design's verified largest-session numbers (model claude-opus-4-8,
  # provider claude = API-metered), split across two assistant messages with one
  # message that carries NO token_usage (must contribute nothing).
  local session="$TMP_ROOT/workex/session.json" out
  write_session "$session" "claude-opus-4-8" "claude" "null" '[
    {"role":"user","content":"x"},
    {"role":"assistant","token_usage":{"input_tokens":1000000,"output_tokens":500000,"cache_read_input_tokens":1000000,"cache_creation_input_tokens":500000}},
    {"role":"assistant","token_usage":{"input_tokens":405731,"output_tokens":640460,"cache_read_input_tokens":379766913,"cache_creation_input_tokens":5643248}},
    {"role":"assistant","content":"no usage field here"}
  ]'
  out=$(fm_token_sum_session "$session" "$PRICE_FIXTURE")
  [ "$(summary_val "$out" model)" = "claude-opus-4-8" ] || fail "model wrong: $out"
  [ "$(summary_val "$out" token_input)" = "1405731" ] || fail "token_input not exact: $out"
  [ "$(summary_val "$out" token_output)" = "1140460" ] || fail "token_output not exact: $out"
  [ "$(summary_val "$out" token_cache_read)" = "380766913" ] || fail "token_cache_read not exact: $out"
  [ "$(summary_val "$out" token_cache_write)" = "6143248" ] || fail "token_cache_write not exact: $out"
  [ "$(summary_val "$out" cost_if_api)" = "264.3189115" ] || fail "cost_if_api not the hand-computed exact decimal: $out"
  [ "$(summary_val "$out" cost_if_api_estimate)" = "false" ] || fail "exact PR-T1 math must not be labeled ESTIMATE"
  [ "$(summary_val "$out" subscription_covered)" = "false" ] || fail "plain claude must not be subscription-covered: $out"
  [ "$(summary_val "$out" price_source)" = "jcode-models-dev-cache" ] || fail "price_source annotation missing"
  [ "$(summary_val "$out" price_cached_at)" = "2026-08-17T00:03:10Z" ] || fail "price_cached_at annotation wrong"
  # The pure cost function agrees at full precision; $264.32 is the cents view.
  local cost
  cost=$(fm_token_cost 1405731 1140460 380766913 6143248 "claude-opus-4-8" "$PRICE_FIXTURE")
  [ "$cost" = "264.3189115" ] || fail "fm_token_cost disagrees: '$cost'"
  pass "worked-example session yields exact token sums and exact cost_if_api 264.3189115 (\$264.32)"
}

# --- unknown model: cost UNKNOWN, never 0 ------------------------------------

test_unknown_model_cost_is_null_never_zero() {
  local session="$TMP_ROOT/unknown/session.json" out cost status
  write_session "$session" "mock" "claude" "null" '[
    {"role":"assistant","token_usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":2000,"cache_creation_input_tokens":300}}
  ]'
  out=$(fm_token_sum_session "$session" "$PRICE_FIXTURE")
  [ "$(summary_val "$out" token_input)" = "1000" ] || fail "unknown-model token sums must still be exact: $out"
  [ "$(summary_val "$out" cost_if_api)" = "" ] || fail "unknown model rendered a dollar cost, must be empty: $out"
  cost=$(fm_token_cost 1000 500 2000 300 "mock" "$PRICE_FIXTURE"); status=$?
  [ -z "$cost" ] || fail "fm_token_cost printed '$cost' for an unpriced model (must be empty)"
  [ "$status" -ne 0 ] || fail "fm_token_cost returned 0 for an unpriced model"
  # The same for the real store's other unpriced model ids, one non-numeric too.
  cost=$(fm_token_cost 1 1 1 1 "unknown" "$PRICE_FIXTURE") || true
  [ -z "$cost" ] || fail "model 'unknown' priced as '$cost'"
  cost=$(fm_token_cost 1 1 1 1 "panic-on-fork" "$PRICE_FIXTURE") || true
  [ -z "$cost" ] || fail "model 'panic-on-fork' priced as '$cost'"
  pass "unknown/unpriced models cost UNKNOWN (empty, non-zero), never 0, tokens still exact"
}

# --- dated-model lookup: exact first, then -YYYYMMDD family fallback ----------

test_dated_id_exact_then_family_fallback() {
  # Distinct prices make the branch choice observable: the dated id at input 99
  # must win over its family at input 1 when the dated id is present (exact), and
  # a dated id ABSENT from the table must fall back to the stripped family.
  local lookup="$TMP_ROOT/lookup/prices.json"
  mkdir -p "$TMP_ROOT/lookup"
  cat > "$lookup" <<'JSON'
{
  "price_source": "test-fixture",
  "cached_at": "2026-08-01T00:00:00Z",
  "prices": {
    "claude-haiku-4-5": {"input_usd_per_mtok": 1, "output_usd_per_mtok": 5, "cache_read_usd_per_mtok": 0.1, "cache_write_usd_per_mtok": 1.25},
    "claude-haiku-4-5-20251001": {"input_usd_per_mtok": 99, "output_usd_per_mtok": 5, "cache_read_usd_per_mtok": 0.1, "cache_write_usd_per_mtok": 1.25}
  }
}
JSON
  local row
  row=$(fm_token_model_price "claude-haiku-4-5-20251001" "$lookup") || fail "dated id present in table did not price"
  case "$row" in
    *'"input_usd_per_mtok":99'*) : ;;
    *) fail "dated id priced via family fallback instead of exact match: $row" ;;
  esac
  row=$(fm_token_model_price "claude-haiku-4-5-20250999" "$lookup") || fail "dated id absent from table did not fall back to family"
  case "$row" in
    *'"input_usd_per_mtok":1'*) : ;;
    *) fail "dated id did not fall back to its -YYYYMMDD-stripped family: $row" ;;
  esac
  # A dated id whose stripped family is also unpriced is still UNKNOWN: mock is
  # nowhere in the fixture, so mock-<date> must not glide onto a real family.
  row=$(fm_token_model_price "mock-19990101" "$PRICE_FIXTURE") || true
  [ -z "$row" ] || fail "stripped-family fallback invented a price: $row"
  pass "dated model ids price exact-first, then -YYYYMMDD family fallback"
}

# --- multi-provider: provider-scoped lookup, ambiguity fails loudly -----------

MP_FIXTURE="$TMP_ROOT/multi/prices.json"
write_multi_provider_fixture() {
  mkdir -p "$TMP_ROOT/multi"
  cat > "$MP_FIXTURE" <<'JSON'
{
  "price_source": "test-fixture",
  "cached_at": "2026-08-01T00:00:00Z",
  "providers": {
    "anthropic": {
      "claude-opus-4-8": {"input_usd_per_mtok": 5, "output_usd_per_mtok": 25, "cache_read_usd_per_mtok": 0.5, "cache_write_usd_per_mtok": 6.25},
      "claude-haiku-4-5-20251001": {"input_usd_per_mtok": 99, "output_usd_per_mtok": 5, "cache_read_usd_per_mtok": 0.1, "cache_write_usd_per_mtok": 1.25}
    },
    "opencode-go": {
      "deepseek-v4-flash": {"input_usd_per_mtok": 0.22, "output_usd_per_mtok": 0.66, "cache_read_usd_per_mtok": 0.007},
      "mimo-v2.5": {"input_usd_per_mtok": 0.3, "output_usd_per_mtok": 0.6}
    },
    "crof": {
      "deepseek-v4-flash": {"input_usd_per_mtok": 0.2, "output_usd_per_mtok": 0.4, "cache_read_usd_per_mtok": 0.02},
      "glm-5.2": {"input_usd_per_mtok": 0.5, "output_usd_per_mtok": 2.2, "cache_read_usd_per_mtok": 0.08}
    }
  },
  "prices": {
    "claude-opus-4-8": {"input_usd_per_mtok": 5, "output_usd_per_mtok": 25, "cache_read_usd_per_mtok": 0.5, "cache_write_usd_per_mtok": 6.25},
    "claude-haiku-4-5-20251001": {"input_usd_per_mtok": 99, "output_usd_per_mtok": 5, "cache_read_usd_per_mtok": 0.1, "cache_write_usd_per_mtok": 1.25},
    "mimo-v2.5": {"input_usd_per_mtok": 0.3, "output_usd_per_mtok": 0.6},
    "glm-5.2": {"input_usd_per_mtok": 0.5, "output_usd_per_mtok": 2.2, "cache_read_usd_per_mtok": 0.08}
  }
}
JSON
}

test_multi_provider_lookup_and_ambiguity() {
  write_multi_provider_fixture
  local row status cost
  # A model name in TWO provider tables is ambiguous: no provider given means
  # the flat map, which excludes it -> UNKNOWN, never a guessed provider price.
  row=$(fm_token_model_price "deepseek-v4-flash" "$MP_FIXTURE"); status=$?
  [ -z "$row" ] || fail "ambiguous model priced without a provider: $row"
  [ "$status" -ne 0 ] || fail "ambiguous model returned 0 without a provider"
  # With the session provider resolved, the provider's own table wins.
  row=$(fm_token_model_price "deepseek-v4-flash" "$MP_FIXTURE" "opencode-go") || fail "opencode-go lookup failed"
  case "$row" in
    *'"input_usd_per_mtok":0.22'*) : ;;
    *) fail "opencode-go price not used: $row" ;;
  esac
  row=$(fm_token_model_price "deepseek-v4-flash" "$MP_FIXTURE" "crof") || fail "crof lookup failed"
  case "$row" in
    *'"input_usd_per_mtok":0.2'*) : ;;
    *) fail "crof price not used: $row" ;;
  esac
  # A provider table that lacks the model falls back to the flat map, and when
  # the model is ambiguous there too it stays UNKNOWN.
  row=$(fm_token_model_price "deepseek-v4-flash" "$MP_FIXTURE" "absent-provider"); status=$?
  [ -z "$row" ] && [ "$status" -ne 0 ] || fail "absent-provider ambiguous lookup must be UNKNOWN: $row"
  # A globally unique model prices from the flat map even without a provider.
  row=$(fm_token_model_price "mimo-v2.5" "$MP_FIXTURE") || fail "unique model must price from the flat map"
  case "$row" in
    *'"input_usd_per_mtok":0.3'*) : ;;
    *) fail "flat-map price wrong: $row" ;;
  esac
  # Provider-scoped lookup still prices a model that is unique in flat.
  cost=$(fm_token_cost 1000 500 2000 0 "deepseek-v4-flash" "$MP_FIXTURE" "opencode-go") || fail "provider-scoped cost failed"
  [ "$cost" = "0.000564" ] || fail "provider-scoped cost wrong: '$cost' (want 0.000564)"
  pass "multi-provider lookup: provider table wins, ambiguity without provider fails loudly, unique ids price from flat"
}

test_provider_key_resolution() {
  [ "$(fm_token_resolve_provider "claude")" = "anthropic" ] \
    || fail "provider_key claude must resolve to anthropic"
  [ "$(fm_token_resolve_provider "claude-oauth")" = "anthropic" ] \
    || fail "provider_key claude-oauth must resolve to anthropic"
  [ "$(fm_token_resolve_provider "remote")" = "anthropic" ] \
    || fail "provider_key remote must resolve to anthropic"
  [ "$(fm_token_resolve_provider "remote-catalog")" = "anthropic" ] \
    || fail "provider_key remote-catalog must resolve to anthropic"
  [ "$(fm_token_resolve_provider "openrouter")" = "openrouter" ] \
    || fail "provider_key openrouter must resolve to openrouter"
  [ "$(fm_token_resolve_provider "openai-compatible:opencode-go")" = "opencode-go" ] \
    || fail "openai-compatible:opencode-go must resolve to opencode-go"
  [ -z "$(fm_token_resolve_provider "openai-compatible")" ] \
    || fail "bare openai-compatible must resolve to nothing"
  [ -z "$(fm_token_resolve_provider "antigravity")" ] \
    || fail "unmapped provider_key must resolve to nothing"
  pass "session provider_key resolves to the models.dev provider that bills it"
}

test_multi_provider_session_costing() {
  write_multi_provider_fixture
  local session out
  # A real fleet shape: deepseek-v4-flash dispatched through opencode-go bills at
  # opencode-go's price, even though the same name exists in other tables.
  session="$TMP_ROOT/multi/deepseek.json"
  write_session "$session" "deepseek-v4-flash" "openai-compatible:opencode-go" "null" '[
    {"role":"assistant","token_usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":2000,"cache_creation_input_tokens":0}}
  ]'
  out=$(fm_token_sum_session "$session" "$MP_FIXTURE")
  [ "$(summary_val "$out" cost_if_api)" = "0.000564" ] \
    || fail "opencode-go session cost wrong: $(summary_val "$out" cost_if_api)"
  # The same model via a provider with no matching table (openrouter here) is
  # ambiguous and stays UNKNOWN, never guessed at another provider's price.
  session="$TMP_ROOT/multi/deepseek-openrouter.json"
  write_session "$session" "deepseek-v4-flash" "openrouter" "null" '[
    {"role":"assistant","token_usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":2000,"cache_creation_input_tokens":0}}
  ]'
  out=$(fm_token_sum_session "$session" "$MP_FIXTURE")
  [ "$(summary_val "$out" cost_if_api)" = "" ] \
    || fail "openrouter deepseek session must stay UNKNOWN: $(summary_val "$out" cost_if_api)"
  # Claude sessions keep billing against the anthropic table.
  session="$TMP_ROOT/multi/opus.json"
  write_session "$session" "claude-opus-4-8" "claude" "null" '[
    {"role":"assistant","token_usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":2000,"cache_creation_input_tokens":0}}
  ]'
  # 1000@5 + 500@25 + 2000@0.5 = 18500 -> 0.0185 (cache_write billed 0).
  out=$(fm_token_sum_session "$session" "$MP_FIXTURE")
  [ "$(summary_val "$out" cost_if_api)" = "0.0185" ] \
    || fail "claude session cost wrong: $(summary_val "$out" cost_if_api)"
  pass "session costing resolves the provider and stays UNKNOWN on ambiguity"
}

# --- missing cache price: zero tokens tolerate it, billed tokens do not -------

test_missing_cache_price_semantics() {
  local sparse="$TMP_ROOT/sparse/prices.json"
  mkdir -p "$TMP_ROOT/sparse"
  cat > "$sparse" <<'JSON'
{"price_source":"test-fixture","cached_at":"2026-08-01T00:00:00Z","prices":{"sparse-model":{"input_usd_per_mtok":1,"output_usd_per_mtok":2}}}
JSON
  local cost status
  # No cache tokens billed: the omitted cache prices contribute zero.
  cost=$(fm_token_cost 1000 500 0 0 "sparse-model" "$sparse") || fail "sparse row with zero cache tokens must cost"
  [ "$cost" = "0.002" ] || fail "sparse-row cost wrong: '$cost' (want 0.002)"
  # Cache tokens billed with no cache price: UNKNOWN, never a fabricated zero.
  cost=$(fm_token_cost 1000 500 100 0 "sparse-model" "$sparse"); status=$?
  [ -z "$cost" ] && [ "$status" -ne 0 ] || fail "billed cache_read with no price must be UNKNOWN: '$cost'"
  cost=$(fm_token_cost 1000 500 0 100 "sparse-model" "$sparse"); status=$?
  [ -z "$cost" ] && [ "$status" -ne 0 ] || fail "billed cache_write with no price must be UNKNOWN: '$cost'"
  # A row missing input OR output is garbage no matter what: UNKNOWN.
  local broken="$TMP_ROOT/sparse/broken.json"
  cat > "$broken" <<'JSON'
{"price_source":"test-fixture","cached_at":"2026-08-01T00:00:00Z","prices":{"broken-model":{"output_usd_per_mtok":2}}}
JSON
  cost=$(fm_token_cost 1000 500 0 0 "broken-model" "$broken"); status=$?
  [ -z "$cost" ] && [ "$status" -ne 0 ] || fail "row without an input price must be UNKNOWN: '$cost'"
  pass "missing cache prices are tolerated only for components with zero billed tokens"
}

# --- subscription_covered OR logic -------------------------------------------

test_subscription_covered_or_logic() {
  [ "$(fm_token_subscription_covered "claude-oauth" "None")" = true ] \
    || fail "provider_key claude-oauth must be covered"
  [ "$(fm_token_subscription_covered "remote" "claude-oauth")" = true ] \
    || fail "remote+route_api_method=claude-oauth combo must be covered (the design's OR case)"
  [ "$(fm_token_subscription_covered "claude-oauth" "claude-oauth")" = true ] \
    || fail "claude-oauth+claude-oauth must be covered"
  [ "$(fm_token_subscription_covered "claude" "None")" = false ] \
    || fail "plain claude must NOT be covered"
  [ "$(fm_token_subscription_covered "remote" "None")" = false ] \
    || fail "remote without oauth must NOT be covered"
  [ "$(fm_token_subscription_covered "openrouter" "None")" = false ] \
    || fail "openrouter must NOT be covered"
  [ "$(fm_token_subscription_covered "None" "None")" = false ] \
    || fail "missing provider must NOT be covered"
  pass "subscription_covered is the claude-oauth OR over provider_key and route_api_method"
}

# --- fail-closed on missing session and incomplete price row ------------------

test_missing_or_incomplete_inputs_fail_closed() {
  local out status cost
  out=$(fm_token_sum_session "$TMP_ROOT/nonexistent.json" "$PRICE_FIXTURE"); status=$?
  [ "$status" -ne 0 ] || fail "fm_token_sum_session succeeded on a missing session file"
  # A priced row MISSING a billed component (cache_write) is UNKNOWN, never a
  # partial cost with a fabricated zero for the missing component.
  local partial="$TMP_ROOT/partial/prices.json"
  mkdir -p "$TMP_ROOT/partial"
  cat > "$partial" <<'JSON'
{"price_source":"test-fixture","cached_at":"2026-08-01T00:00:00Z","prices":{"claude-opus-4-8":{"input_usd_per_mtok":5,"output_usd_per_mtok":25,"cache_read_usd_per_mtok":0.5}}}
JSON
  cost=$(fm_token_cost 1000 1000 1000 1000 "claude-opus-4-8" "$partial") || true
  [ -z "$cost" ] || fail "incomplete price row cost '$cost' (must be UNKNOWN)"
  # A missing price snapshot is UNKNOWN, never a guess.
  cost=$(fm_token_cost 1000 1000 1000 1000 "claude-opus-4-8" "$TMP_ROOT/noprice.json") || true
  [ -z "$cost" ] || fail "missing price snapshot cost '$cost'"
  pass "missing session, incomplete price row, and missing snapshot all fail closed"
}

# --- price snapshot path and header fields ------------------------------------

test_price_path_and_header_fields() {
  write_price_fixture
  [ "$(fm_token_prices_path)" = "$ROOT/config/token-prices.json" ] \
    || fail "default price path wrong: $(fm_token_prices_path)"
  local val status
  val=$(FM_TOKEN_PRICES="$TMP_ROOT/override/prices.json" fm_token_prices_path)
  [ "$val" = "$TMP_ROOT/override/prices.json" ] || fail "FM_TOKEN_PRICES override not honored: $val"
  [ "$(fm_token_prices_field price_source "$PRICE_FIXTURE")" = "jcode-models-dev-cache" ] \
    || fail "price_source field read wrong"
  [ "$(fm_token_prices_field cached_at "$PRICE_FIXTURE")" = "2026-08-17T00:03:10Z" ] \
    || fail "cached_at field read wrong"
  val=$(fm_token_prices_field price_source "$TMP_ROOT/absent.json"); status=$?
  [ -z "$val" ] && [ "$status" -ne 0 ] || fail "missing snapshot header read must be empty and non-zero"
  pass "price snapshot path (default + FM_TOKEN_PRICES override) and header fields read correctly"
}

test_worked_example_exact_sums_and_cost
test_unknown_model_cost_is_null_never_zero
test_dated_id_exact_then_family_fallback
test_multi_provider_lookup_and_ambiguity
test_provider_key_resolution
test_multi_provider_session_costing
test_missing_cache_price_semantics
test_subscription_covered_or_logic
test_missing_or_incomplete_inputs_fail_closed
test_price_path_and_header_fields
