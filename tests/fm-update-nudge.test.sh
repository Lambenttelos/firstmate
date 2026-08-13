#!/usr/bin/env bash
# Tests for bin/fm-update-nudge.sh: batch the /updatefirstmate re-read nudge to
# AT MOST ONCE PER SESSION, sent as a no-reply-expected one-way message.
#
# The guarantees under test (retrospective P5: 28 nudge wakes over 4 days):
#   - Two runs in the same session nudge each secondmate at most once; the
#     second run reports "already nudged this session" and sends nothing.
#   - The nudge opens NO pending-reply expectation: state/pending-replies/ stays
#     empty for it (verified by driving the REAL fm-send against a secondmate
#     meta, not a mock, so the no-reply path is exercised end to end).
#   - The nudge carries the latest commit id/summary.
#   - A NEW session (new session-lock pid) nudges again.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NUDGE="$ROOT/bin/fm-update-nudge.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-update-nudge-tests)

# A fake tmux that accepts every send-keys/display-message/capture-pane call so
# the real fm-send can drive its whole submit-and-verify path against a fixture
# secondmate endpoint. Logs each send-keys -l literal so a test can confirm the
# nudge text (and its commit id) actually went out.
make_fakebin() {  # <dir> -> echoes fakebin dir; literals logged to $FM_SEND_LOG
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    # Log only the literal text payload (send-keys -t <target> -l <text>).
    prev=
    for a in "$@"; do
      [ "$prev" = -l ] && printf '%s\n' "$a" >> "${FM_SEND_LOG:?}"
      prev=$a
    done
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '\xe2\x94\x82 \xe2\x94\x82\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# A firstmate home whose FM_ROOT is a real git repo (so the nudge can read the
# latest commit) and whose state/ carries a secondmate meta plus a session lock.
# Sets globals HOME_DIR and HOME_ROOT rather than echoing, so the caller keeps
# both without a subshell dropping the second one.
new_home() {  # <name> -> sets HOME_DIR (the firstmate home) and HOME_ROOT (git FM_ROOT)
  local name=$1 home root
  home="$TMP_ROOT/$name"
  root="$TMP_ROOT/$name-root"
  mkdir -p "$home/state" "$home/data" "$root"

  # A real git repo for the commit id/summary the nudge quotes.
  git -C "$root" init -q
  printf '# Firstmate\n' > "$root/AGENTS.md"
  git -C "$root" add AGENTS.md
  git -C "$root" commit -qm "initial firstmate commit" >/dev/null

  # A live secondmate endpoint fm-send resolves through this home's meta.
  fm_write_secondmate_meta "$home/state/sm1.meta" "$home/sm1-home" "sess:win" alpha

  # A locked session: the pid keys the per-session dedup marker.
  printf '4242\n' > "$home/state/.lock"

  HOME_DIR=$home
  HOME_ROOT=$root
}

run_nudge() {  # <home> <window...>
  local home=$1; shift
  env PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$HOME_ROOT" FM_HOME="$home" \
    FM_SEND_LOG="$SEND_LOG" FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    "$NUDGE" "$@" 2>/dev/null
}

FAKEBIN=$(make_fakebin "$TMP_ROOT/fake")
SEND_LOG="$TMP_ROOT/send.log"

# --- T1: once-per-session dedup --------------------------------------------
test_dedup_once_per_session() {
  local home out1 out2
  new_home t1; home=$HOME_DIR
  : > "$SEND_LOG"

  out1=$(run_nudge "$home" fm-sm1)
  assert_contains "$out1" "nudge fm-sm1: sent" "first run sends the nudge"

  out2=$(run_nudge "$home" fm-sm1)
  assert_contains "$out2" "nudge fm-sm1: skipped (already nudged this session)" \
    "second run in same session does not re-nudge"

  # Exactly one nudge literal reached the endpoint across both runs.
  local sent
  sent=$(grep -c 're-read your AGENTS.md' "$SEND_LOG" || true)
  [ "$sent" -eq 1 ] || fail "expected exactly 1 nudge sent across two runs, got $sent"
  pass "T1 two runs in one session nudge a secondmate at most once"
}

# --- T2: no pending-reply expectation opened -------------------------------
test_no_pending_reply() {
  local home out
  new_home t2; home=$HOME_DIR
  : > "$SEND_LOG"

  out=$(run_nudge "$home" fm-sm1)
  assert_contains "$out" "nudge fm-sm1: sent" "nudge sent"

  # The no-reply-expected path must open no correlation record.
  if [ -d "$home/state/pending-replies" ]; then
    local records
    records=$(find "$home/state/pending-replies" -type f | wc -l | tr -d ' ')
    [ "$records" -eq 0 ] \
      || fail "nudge opened $records pending-reply record(s); expected 0 (no-reply-expected)"
  fi
  pass "T2 the nudge opens no pending-reply expectation"
}

# --- T3: the nudge carries the latest commit id/summary --------------------
test_carries_latest_commit() {
  local home short
  new_home t3; home=$HOME_DIR
  short=$(git -C "$HOME_ROOT" rev-parse --short HEAD)
  : > "$SEND_LOG"

  run_nudge "$home" fm-sm1 >/dev/null
  assert_contains "$(cat "$SEND_LOG")" "$short" "nudge text carries the latest commit id"
  assert_contains "$(cat "$SEND_LOG")" "initial firstmate commit" \
    "nudge text carries the latest commit summary"
  pass "T3 the nudge carries the latest commit id and summary"
}

# --- T4: a new session re-nudges -------------------------------------------
test_new_session_renudges() {
  local home out
  new_home t4; home=$HOME_DIR
  : > "$SEND_LOG"

  run_nudge "$home" fm-sm1 >/dev/null

  # Simulate a new session: a different session-lock holder pid.
  printf '9999\n' > "$home/state/.lock"

  out=$(run_nudge "$home" fm-sm1)
  assert_contains "$out" "nudge fm-sm1: sent" "a new session nudges again"
  local sent
  sent=$(grep -c 're-read your AGENTS.md' "$SEND_LOG" || true)
  [ "$sent" -eq 2 ] || fail "expected 2 nudges across two sessions, got $sent"
  pass "T4 a new session nudges the secondmate again"
}

# --- T5: multiple windows in one call, each deduped independently ----------
test_multiple_windows() {
  local home out out2
  new_home t5; home=$HOME_DIR
  fm_write_secondmate_meta "$home/state/sm2.meta" "$home/sm2-home" "sess:win2" beta
  : > "$SEND_LOG"

  out=$(run_nudge "$home" fm-sm1 fm-sm2)
  assert_contains "$out" "nudge fm-sm1: sent" "first window nudged"
  assert_contains "$out" "nudge fm-sm2: sent" "second window nudged"

  out2=$(run_nudge "$home" fm-sm1 fm-sm2)
  assert_contains "$out2" "nudge fm-sm1: skipped" "first window deduped on second run"
  assert_contains "$out2" "nudge fm-sm2: skipped" "second window deduped on second run"
  pass "T5 multiple windows nudged in one call, each deduped per session"
}

test_dedup_once_per_session
test_no_pending_reply
test_carries_latest_commit
test_new_session_renudges
test_multiple_windows

echo "# all fm-update-nudge tests passed"
