#!/usr/bin/env bash
# Tests for bin/fm-bitbucket-lib.sh and the Bitbucket branch of the PR path:
# credential/tool guards, API base resolution, PR open, PR state read, and PR
# merge, all against a mock curl so no network is touched. This is the Bitbucket
# counterpart to the GitHub gh-axi PR coverage in fm-pr-merge.test.sh.
#
# The mock curl reads a scenario from FM_TEST_BB_SCENARIO and emits the body
# followed by the HTTP status code, exactly as the real library expects from
# curl --write-out '%{http_code}'. It also records the request method and URL to
# FM_TEST_BB_LOG so a test can assert the endpoint that was hit, and it copies
# the --config file contents to FM_TEST_BB_CFG so a test can prove the token was
# passed by private config file rather than on the command line.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-bitbucket-lib.sh"
PR_LIB="$ROOT/bin/fm-pr-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-bitbucket-lib)

# Build a fakebin with a curl mock. The mock's behavior is driven by the URL and
# by FM_TEST_BB_STATUS/FM_TEST_BB_BODY exported per call.
make_fakebin() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/curl" <<'SH'
#!/usr/bin/env bash
# Record method, url, and (if any) the --config file's contents; then emit the
# configured body followed by the status code, matching curl --write-out.
method=GET
url=
cfg=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --request) method=$2; shift 2 ;;
    --config) cfg=$2; shift 2 ;;
    --data-binary) shift 2 ;;
    --header|--write-out|--output) shift 2 ;;
    --silent|--show-error) shift ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
{ printf '%s %s\n' "$method" "$url"; } >> "$FM_TEST_BB_LOG"
if [ -n "$cfg" ] && [ -n "${FM_TEST_BB_CFG:-}" ]; then
  cat "$cfg" > "$FM_TEST_BB_CFG"
fi
printf '%s' "${FM_TEST_BB_BODY:-}"
printf '%s' "${FM_TEST_BB_STATUS:-200}"
SH
  chmod +x "$dir/curl"
}

# Run a snippet that sources the library with the mock curl on PATH and the
# credentials set unless the caller unsets them.
run_lib() {
  local case_dir=$1; shift
  FM_TEST_BB_LOG="$case_dir/curl.log" \
  FM_TEST_BB_CFG="$case_dir/cfg.captured" \
  NO_MISTAKES_BITBUCKET_EMAIL="${NO_MISTAKES_BITBUCKET_EMAIL-me@example.com}" \
  NO_MISTAKES_BITBUCKET_API_TOKEN="${NO_MISTAKES_BITBUCKET_API_TOKEN-tok-secret}" \
  FM_TEST_BB_BODY="${FM_TEST_BB_BODY-}" \
  FM_TEST_BB_STATUS="${FM_TEST_BB_STATUS-200}" \
  PATH="$case_dir/fakebin:$PATH" \
    bash -c '
      . "'"$LIB"'"
      '"$*"'
    '
}

test_api_base_default_and_override() {
  local case_dir; case_dir="$TMP_ROOT/api-base"; mkdir -p "$case_dir/fakebin"
  make_fakebin "$case_dir/fakebin"
  local out
  out=$(run_lib "$case_dir" 'fm_bitbucket_api_base')
  [ "$out" = "https://api.bitbucket.org" ] || fail "api-base: default wrong: $out"
  out=$(NO_MISTAKES_BITBUCKET_API_BASE_URL="https://bb.example.com/" run_lib "$case_dir" 'fm_bitbucket_api_base')
  [ "$out" = "https://bb.example.com" ] || fail "api-base: override not stripped: $out"
  if NO_MISTAKES_BITBUCKET_API_BASE_URL="http://insecure" run_lib "$case_dir" 'fm_bitbucket_api_base' >/dev/null 2>&1; then
    fail "api-base: a non-https override should be refused"
  fi
  pass "fm_bitbucket_api_base defaults to api.bitbucket.org, strips a trailing slash, and refuses non-https"
}

test_ready_guard_requires_credentials() {
  local case_dir; case_dir="$TMP_ROOT/ready"; mkdir -p "$case_dir/fakebin"
  make_fakebin "$case_dir/fakebin"
  run_lib "$case_dir" 'fm_bitbucket_ready' >/dev/null 2>&1 \
    || fail "ready: should pass when tools and creds present"
  if NO_MISTAKES_BITBUCKET_API_TOKEN='' run_lib "$case_dir" 'fm_bitbucket_ready' >/dev/null 2>&1; then
    fail "ready: should fail with an empty token"
  fi
  pass "fm_bitbucket_ready requires both credential parts"
}

test_open_pr_records_url_and_number() {
  local case_dir; case_dir="$TMP_ROOT/open"; mkdir -p "$case_dir/fakebin"
  make_fakebin "$case_dir/fakebin"
  local out
  # shellcheck disable=SC2016  # The snippet is executed by run_lib's inner bash, not expanded here.
  out=$(FM_TEST_BB_BODY='{"id":42,"state":"OPEN"}' FM_TEST_BB_STATUS=201 \
    run_lib "$case_dir" 'fm_bitbucket_open_pr dashnow hyfin fm/x1 dev "Title" "Body" && printf "N=%s\n" "$FM_BITBUCKET_PR_NUMBER"')
  printf '%s\n' "$out" | grep -qxF 'https://bitbucket.org/dashnow/hyfin/pull-requests/42' \
    || fail "open: canonical PR URL not printed: $out"
  printf '%s\n' "$out" | grep -qxF 'N=42' || fail "open: PR number not set: $out"
  grep -qxF 'POST https://api.bitbucket.org/2.0/repositories/dashnow/hyfin/pullrequests' "$case_dir/curl.log" \
    || fail "open: wrong endpoint hit: $(cat "$case_dir/curl.log")"
  # The token must have been passed via the private --config file, not on argv.
  grep -qF 'tok-secret' "$case_dir/cfg.captured" || fail "open: token was not passed via --config file"
  pass "fm_bitbucket_open_pr posts to the pullrequests endpoint and returns the canonical URL"
}

test_open_pr_refuses_on_non_2xx() {
  local case_dir; case_dir="$TMP_ROOT/open-fail"; mkdir -p "$case_dir/fakebin"
  make_fakebin "$case_dir/fakebin"
  if FM_TEST_BB_BODY='{"error":{"message":"branch not found"}}' FM_TEST_BB_STATUS=400 \
    run_lib "$case_dir" 'fm_bitbucket_open_pr dashnow hyfin fm/x1 dev "Title" ""' >/dev/null 2>&1; then
    fail "open-fail: a 400 response should make open refuse"
  fi
  pass "fm_bitbucket_open_pr refuses on a non-2xx response"
}

test_pr_state_reads_state() {
  local case_dir; case_dir="$TMP_ROOT/state"; mkdir -p "$case_dir/fakebin"
  make_fakebin "$case_dir/fakebin"
  local out
  # shellcheck disable=SC2016  # The snippet is executed by run_lib's inner bash, not expanded here.
  out=$(FM_TEST_BB_BODY='{"id":7,"state":"MERGED"}' FM_TEST_BB_STATUS=200 \
    run_lib "$case_dir" 'fm_bitbucket_pr_state dashnow hyfin 7 && printf "%s\n" "$FM_BITBUCKET_PR_STATE"')
  [ "$out" = MERGED ] || fail "state: expected MERGED, got: $out"
  grep -qxF 'GET https://api.bitbucket.org/2.0/repositories/dashnow/hyfin/pullrequests/7' "$case_dir/curl.log" \
    || fail "state: wrong endpoint: $(cat "$case_dir/curl.log")"
  pass "fm_bitbucket_pr_state reads .state from the pull request endpoint"
}

test_pr_state_silent_without_credentials() {
  local case_dir; case_dir="$TMP_ROOT/state-nocred"; mkdir -p "$case_dir/fakebin"
  make_fakebin "$case_dir/fakebin"
  # No creds: must return non-zero and print nothing, so a poll treats it as
  # "not known merged" rather than a merge.
  if NO_MISTAKES_BITBUCKET_API_TOKEN='' FM_TEST_BB_BODY='{"state":"MERGED"}' \
    run_lib "$case_dir" 'fm_bitbucket_pr_state dashnow hyfin 7' >/dev/null 2>&1; then
    fail "state-nocred: should fail without credentials"
  fi
  pass "fm_bitbucket_pr_state fails silently without credentials"
}

test_merge_pr_default_squash() {
  local case_dir; case_dir="$TMP_ROOT/merge"; mkdir -p "$case_dir/fakebin"
  make_fakebin "$case_dir/fakebin"
  FM_TEST_BB_BODY='{"state":"MERGED"}' FM_TEST_BB_STATUS=200 \
    run_lib "$case_dir" 'fm_bitbucket_merge_pr dashnow hyfin 7' >/dev/null 2>&1 \
    || fail "merge: default squash merge should succeed"
  grep -qxF 'POST https://api.bitbucket.org/2.0/repositories/dashnow/hyfin/pullrequests/7/merge' "$case_dir/curl.log" \
    || fail "merge: wrong endpoint: $(cat "$case_dir/curl.log")"
  pass "fm_bitbucket_merge_pr posts to the merge endpoint"
}

test_merge_pr_refuses_on_conflict() {
  local case_dir; case_dir="$TMP_ROOT/merge-conflict"; mkdir -p "$case_dir/fakebin"
  make_fakebin "$case_dir/fakebin"
  # Bitbucket returns a non-2xx on a conflict or red required check, so the merge
  # must refuse rather than report success.
  if FM_TEST_BB_BODY='{"error":{"message":"merge conflict"}}' FM_TEST_BB_STATUS=409 \
    run_lib "$case_dir" 'fm_bitbucket_merge_pr dashnow hyfin 7' >/dev/null 2>&1; then
    fail "merge-conflict: a 409 response should make merge refuse"
  fi
  pass "fm_bitbucket_merge_pr refuses when Bitbucket rejects the merge"
}

test_merge_pr_rejects_bad_strategy() {
  local case_dir; case_dir="$TMP_ROOT/merge-badstrat"; mkdir -p "$case_dir/fakebin"
  make_fakebin "$case_dir/fakebin"
  if run_lib "$case_dir" 'fm_bitbucket_merge_pr dashnow hyfin 7 rebase_evil' >/dev/null 2>&1; then
    fail "merge-badstrat: an invalid strategy should be refused"
  fi
  [ ! -s "$case_dir/curl.log" ] || fail "merge-badstrat: curl was called for an invalid strategy"
  pass "fm_bitbucket_merge_pr refuses an invalid merge strategy before calling curl"
}

# --- URL parse + origin slug (no network) ----------------------------------

test_url_parse_and_origin_slug() {
  # shellcheck source=bin/fm-pr-lib.sh
  . "$PR_LIB"
  fm_pr_url_parse 'https://bitbucket.org/dashnow/hyfin/pull-requests/42' \
    || fail "parse: valid Bitbucket PR URL rejected"
  [ "$FM_PR_PROVIDER" = bitbucket ] || fail "parse: provider not bitbucket"
  [ "$FM_PR_WORKSPACE" = dashnow ] || fail "parse: workspace wrong: $FM_PR_WORKSPACE"
  [ "$FM_PR_REPO" = hyfin ] || fail "parse: repo wrong: $FM_PR_REPO"
  [ "$FM_PR_NUMBER" = 42 ] || fail "parse: number wrong: $FM_PR_NUMBER"
  fm_pr_url_parse 'https://bitbucket.org/dashnow/hyfin/pull-requests/0' \
    && fail "parse: number 0 should be rejected"
  fm_pr_url_parse 'https://bitbucket.org/a/b/c/pull-requests/1' \
    && fail "parse: three-segment path should be rejected"

  local dir; dir="$TMP_ROOT/slug-clone"; mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin 'git@bitbucket.org:dashnow/hyfin.git'
  local slug; slug=$(fm_pr_bitbucket_origin_slug "$dir") || fail "slug: could not resolve bitbucket origin"
  [ "$slug" = dashnow/hyfin ] || fail "slug: wrong: $slug"
  # An own-repo target passes; a foreign target is refused.
  fm_pr_refuse_unowned_bitbucket_target dashnow hyfin "$dir" \
    || fail "target-guard: own repo should pass"
  if fm_pr_refuse_unowned_bitbucket_target evilcorp hyfin "$dir" 2>/dev/null; then
    fail "target-guard: a foreign workspace should be refused"
  fi
  pass "Bitbucket URL parse, origin-slug resolution, and own-repo target guard behave"
}

test_api_base_default_and_override
test_ready_guard_requires_credentials
test_open_pr_records_url_and_number
test_open_pr_refuses_on_non_2xx
test_pr_state_reads_state
test_pr_state_silent_without_credentials
test_merge_pr_default_squash
test_merge_pr_refuses_on_conflict
test_merge_pr_rejects_bad_strategy
test_url_parse_and_origin_slug
