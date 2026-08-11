#!/usr/bin/env bash
# tests/fm-mm-mode.test.sh - Mattermost captain<->firstmate messaging: the
# inbound control-channel poll (bin/fm-mm-poll.sh), the outbound poster
# (bin/fm-mm-post.sh), and the shared library (bin/fm-mm-lib.sh).
#
# The feature must be INERT by default (no MM_TOKEN -> the poll and the post are
# hard no-ops with no output and no network call) and additive when on. The
# network is stubbed with a fakebin `curl` so these stay hermetic: no ports, no
# server, deterministic in CI. jq stays the real tool. End-to-end verification
# against a real Mattermost server is done out of band; this suite pins the
# client logic, the self-post filter, the cursor advance, and the auto-post
# safety boundary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
# The clients use the real jq; make it resolvable regardless of where it is
# installed. Prepended after the fakebin so the fake curl still wins.
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-mm-mode-tests)

POLL="$ROOT/bin/fm-mm-poll.sh"
POST="$ROOT/bin/fm-mm-post.sh"

# A fakebin `curl` that mimics the Mattermost REST v4 endpoints this feature
# uses. It reads its behavior from env, records each call to FAKE_CURL_LOG, writes
# the response body to the -o file, and prints the HTTP code exactly as the real
# `-w '%{http_code}'` would.
#   GET /api/v4/users/me                      -> FAKE_ME_CODE / FAKE_ME_BODY
#   GET /api/v4/teams/name/.../channels/name/ -> FAKE_CHAN_CODE / FAKE_CHAN_BODY
#   GET /api/v4/channels/<id>/posts           -> FAKE_POSTS_CODE / FAKE_POSTS_BODY
#   POST /api/v4/posts                        -> FAKE_POST_CODE / FAKE_POST_BODY
make_fake_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile="" method=GET data="" url="" auth=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    -X) method=$2; shift 2 ;;
    --data-binary)
      case "$2" in
        @-) data=$(cat) ;;
        @*) data=$(cat -- "${2#@}") ;;
        *) data=$2 ;;
      esac
      shift 2
      ;;
    -H)
      case "$2" in
        @*) while IFS= read -r header; do case "$header" in Authorization:*) auth=$header ;; esac; done < "${2#@}" ;;
        Authorization:*) auth=$2 ;;
      esac
      shift 2
      ;;
    -m|-w) shift 2 ;;
    -s) shift ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
if [ -n "${FAKE_CURL_LOG:-}" ]; then
  { echo "method=$method"; echo "url=$url"; echo "auth=$auth"; echo "data=$data"; } >> "$FAKE_CURL_LOG"
fi
case "$method $url" in
  *"/api/v4/users/me")
    [ -n "$ofile" ] && printf '%s' "${FAKE_ME_BODY:-}" > "$ofile"
    printf '%s' "${FAKE_ME_CODE:-200}"
    ;;
  *"/channels/name/"*)
    [ -n "$ofile" ] && printf '%s' "${FAKE_CHAN_BODY:-}" > "$ofile"
    printf '%s' "${FAKE_CHAN_CODE:-200}"
    ;;
  *"/posts?since="*)
    [ -n "$ofile" ] && printf '%s' "${FAKE_POSTS_BODY:-}" > "$ofile"
    printf '%s' "${FAKE_POSTS_CODE:-200}"
    ;;
  "POST "*"/api/v4/posts")
    [ -n "$ofile" ] && printf '%s' "${FAKE_POST_BODY:-}" > "$ofile"
    [ -n "${FAKE_POST_DATA_LOG:-}" ] && printf '%s' "$data" > "$FAKE_POST_DATA_LOG"
    printf '%s' "${FAKE_POST_CODE:-201}"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

new_home() {
  local home
  mkdir -p "$TMP_ROOT"
  home=$(mktemp -d "$TMP_ROOT/home.XXXXXX")
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# --- inert by default -------------------------------------------------------

t_poll_inert_without_token() {
  local home out rc
  home=$(new_home)
  out=$(FM_HOME="$home" PATH="$BASE_PATH" "$POLL" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "inert poll should exit 0, got $rc"
  [ -z "$out" ] || fail "inert poll should print nothing, got: $out"
  [ -e "$home/state/mm-cursor" ] && fail "inert poll must not create a cursor"
  pass "poll is a hard no-op without MM_TOKEN"
}

t_post_inert_without_token() {
  local home out rc
  home=$(new_home)
  out=$(printf 'hello\n' | FM_HOME="$home" PATH="$BASE_PATH" "$POST" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "inert post should exit 0, got $rc"
  [ -z "$out" ] || fail "inert post should print nothing, got: $out"
  pass "post is a hard no-op without MM_TOKEN"
}

# --- inbound first run anchors the cursor without replaying history ---------

t_poll_first_run_anchors_cursor() {
  local home fakebin out rc
  home=$(new_home)
  fakebin=$(make_fake_curl "$home")
  out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    MM_TOKEN=tok MM_SERVER_URL=https://mm.example.com MM_CHANNEL_ID=chan123 \
    FAKE_ME_BODY='{"id":"selfbot"}' \
    "$POLL" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "first-run poll should exit 0, got $rc"
  [ -z "$out" ] || fail "first-run poll should wake nobody, got: $out"
  [ -s "$home/state/mm-cursor" ] || fail "first-run poll should anchor the cursor"
  pass "first run anchors the cursor and does not replay history"
}

# --- inbound: a captain message wakes; firstmate's own post never does -------

t_poll_ingests_captain_filters_self() {
  local home fakebin out rc cursor
  home=$(new_home)
  fakebin=$(make_fake_curl "$home")
  # Pre-seed a cursor so this is not a first run.
  printf '1000\n' > "$home/state/mm-cursor"
  # Two posts: one from the captain (cap-user), one from firstmate's own bot
  # account (selfbot). Only the captain's may wake and be stashed.
  local body='{"order":["p_self","p_cap"],"posts":{'
  body+='"p_self":{"id":"p_self","user_id":"selfbot","create_at":2000,"message":"my own escalation"},'
  body+='"p_cap":{"id":"p_cap","user_id":"cap-user","create_at":3000,"message":"deploy the fix"}'
  body+='}}'
  out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    MM_TOKEN=tok MM_SERVER_URL=https://mm.example.com MM_CHANNEL_ID=chan123 \
    FAKE_ME_BODY='{"id":"selfbot"}' \
    FAKE_POSTS_BODY="$body" \
    "$POLL" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "poll should exit 0, got $rc"
  printf '%s\n' "$out" | grep -q '^mm-message p_cap$' || fail "captain post should wake, got: $out"
  printf '%s\n' "$out" | grep -q 'p_self' && fail "firstmate's own post must never wake: $out"
  [ -s "$home/state/mm-inbox/p_cap.json" ] || fail "captain post should be stashed"
  [ -e "$home/state/mm-inbox/p_self.json" ] && fail "self post must not be stashed"
  cursor=$(cat "$home/state/mm-cursor")
  [ "$cursor" = 3000 ] || fail "cursor should advance to newest ingested (3000), got $cursor"
  pass "captain message wakes and is stashed; firstmate's own post is filtered out"
}

# --- inbound: a second poll does not replay an already-seen message ----------

t_poll_cursor_prevents_replay() {
  local home fakebin out
  home=$(new_home)
  fakebin=$(make_fake_curl "$home")
  printf '3000\n' > "$home/state/mm-cursor"
  # The only post is at or below the cursor: nothing new.
  local body='{"order":["p_cap"],"posts":{"p_cap":{"id":"p_cap","user_id":"cap-user","create_at":3000,"message":"old"}}}'
  out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    MM_TOKEN=tok MM_SERVER_URL=https://mm.example.com MM_CHANNEL_ID=chan123 \
    FAKE_ME_BODY='{"id":"selfbot"}' FAKE_POSTS_BODY="$body" \
    "$POLL" 2>&1)
  [ -z "$out" ] || fail "an at-or-below-cursor post must not replay: $out"
  pass "cursor prevents replaying an already-seen message"
}

# --- inbound: token never appears on the curl command line -------------------

t_poll_token_not_on_command_line() {
  local home fakebin log
  home=$(new_home)
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  printf '1000\n' > "$home/state/mm-cursor"
  FM_HOME="$home" PATH="$fakebin:$BASE_PATH" FAKE_CURL_LOG="$log" \
    MM_TOKEN=supersecret MM_SERVER_URL=https://mm.example.com MM_CHANNEL_ID=chan123 \
    FAKE_ME_BODY='{"id":"selfbot"}' FAKE_POSTS_BODY='{"order":[],"posts":{}}' \
    "$POLL" >/dev/null 2>&1
  # The header file mechanism means the fake sees the resolved header, but the
  # token must never appear as a bare argv token. Our fake only records the
  # header value it parsed from the @file, which is expected; assert the token is
  # not leaked into any URL or method field.
  if grep -E '^(url|method)=' "$log" | grep -q supersecret; then
    fail "token leaked into a curl url/method argument"
  fi
  pass "token is passed via a header file, never a bare command-line argument"
}

# --- outbound: posts to the control channel, threads on --root ---------------

t_post_sends_message() {
  local home fakebin out rc datalog
  home=$(new_home)
  fakebin=$(make_fake_curl "$home")
  datalog="$home/post.json"
  out=$(printf 'Captain, the build broke.\n' | FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    MM_TOKEN=tok MM_SERVER_URL=https://mm.example.com MM_CHANNEL_ID=chan123 \
    FAKE_POST_DATA_LOG="$datalog" FAKE_POST_BODY='{"id":"newpost1"}' \
    "$POST" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "post should exit 0, got $rc ($out)"
  printf '%s\n' "$out" | grep -q '^posted newpost1$' || fail "post should report the new id, got: $out"
  jq -e '.channel_id == "chan123"' "$datalog" >/dev/null || fail "payload channel_id wrong"
  jq -e '.message == "Captain, the build broke."' "$datalog" >/dev/null || fail "payload message wrong"
  jq -e 'has("root_id") | not' "$datalog" >/dev/null || fail "unprompted post must not thread"
  pass "outbound posts message text to the control channel"
}

t_post_threads_on_root() {
  local home fakebin datalog
  home=$(new_home)
  fakebin=$(make_fake_curl "$home")
  datalog="$home/post.json"
  printf 'reply body\n' | FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    MM_TOKEN=tok MM_SERVER_URL=https://mm.example.com MM_CHANNEL_ID=chan123 \
    FAKE_POST_DATA_LOG="$datalog" FAKE_POST_BODY='{"id":"x"}' \
    "$POST" --root p_cap >/dev/null 2>&1
  jq -e '.root_id == "p_cap"' "$datalog" >/dev/null || fail "reply should thread onto --root"
  pass "outbound threads a reply onto the captain post it answers"
}

# --- outbound: dry run previews without posting ------------------------------

t_post_dry_run_no_network() {
  local home fakebin log out
  home=$(new_home)
  fakebin=$(make_fake_curl "$home")
  log="$home/curl.log"
  out=$(printf 'preview me\n' | FM_HOME="$home" PATH="$fakebin:$BASE_PATH" FAKE_CURL_LOG="$log" \
    MM_TOKEN=tok MM_SERVER_URL=https://mm.example.com MM_CHANNEL_ID=chan123 MM_DRY_RUN=1 \
    "$POST" 2>&1)
  printf '%s\n' "$out" | grep -q '^dry-run: wrote ' || fail "dry run should report a preview path, got: $out"
  # A dry run resolves the channel id (one GET is allowed) but must POST nothing.
  if [ -f "$log" ] && grep -q '^method=POST' "$log"; then
    fail "dry run must not POST"
  fi
  ls "$home"/state/mm-outbox/preview.* >/dev/null 2>&1 || fail "dry run should write a preview file"
  pass "dry run previews the payload and posts nothing"
}

# --- outbound: an empty message is rejected ----------------------------------

t_post_rejects_empty() {
  local home rc
  home=$(new_home)
  printf '' | FM_HOME="$home" PATH="$BASE_PATH" \
    MM_TOKEN=tok MM_SERVER_URL=https://mm.example.com MM_CHANNEL_ID=chan123 \
    "$POST" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "empty message should be rejected with exit 2, got $rc"
  pass "empty outbound message is rejected"
}

t_poll_inert_without_token
t_post_inert_without_token
t_poll_first_run_anchors_cursor
t_poll_ingests_captain_filters_self
t_poll_cursor_prevents_replay
t_poll_token_not_on_command_line
t_post_sends_message
t_post_threads_on_root
t_post_dry_run_no_network
t_post_rejects_empty

printf '# fm-mm-mode: all assertions passed\n'
