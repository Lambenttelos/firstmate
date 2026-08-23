#!/usr/bin/env bash
# Tests for spawn-time resume-token capture and stuck-crewmate recovery lookup:
#   - bin/fm-resume-lib.sh (resume-command mapping + token helper)
#   - bin/fm-spawn.sh       (post-launch resume= meta stamp + tasks-axi --resume)
#   - bin/fm-resume-cmd.sh  (recovery lookup, fail-closed)
#
# WHY this change exists: a dead crewmate session can be RESUMED in place instead
# of restarted from scratch, so recovery keeps the session's full turn history
# (the brief and every step of progress) rather than re-deriving it. fm-spawn
# captures the harness resume token at spawn (jcode only today: it is the one
# harness whose resolved session id IS the `--resume` token), and fm-resume-cmd
# maps the recorded harness + token to the exact resume command during recovery.
#
# Covers:
#   - the resume-command mapping: jcode/grok/codex map to their verified by-id
#     resume forms; claude/opencode/pi fail closed; empty/unsafe tokens refused
#   - fm_resume_token_for_harness echoes a jcode session id, empty for others
#   - a jcode spawn stamps resume=<session-id> into meta AND mirrors it into the
#     durable task record via tasks-axi --resume
#   - a jcode spawn whose session cannot be resolved stamps NO resume= and does
#     NOT fail the spawn
#   - a secondmate never mirrors into the backlog (it is not a backlog item)
#   - fm-resume-cmd prints the exact command for a captured jcode task, and fails
#     closed with a clear diagnostic for: no meta, no token, unsupported harness
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=bin/fm-resume-lib.sh disable=SC1091
. "$ROOT/bin/fm-resume-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-resume-capture-tests)

# --- resume-command mapping (bin/fm-resume-lib.sh) ---------------------------

test_resume_command_maps_verified_by_id_forms() {
  local got
  got=$(fm_resume_command jcode session_abc) || fail "jcode mapping returned non-zero"
  [ "$got" = "jcode --resume session_abc" ] || fail "jcode mapping wrong: $got"
  got=$(fm_resume_command grok gsess-1) || fail "grok mapping returned non-zero"
  [ "$got" = "grok --resume gsess-1" ] || fail "grok mapping wrong: $got"
  got=$(fm_resume_command codex csess_1) || fail "codex mapping returned non-zero"
  [ "$got" = "codex resume csess_1" ] || fail "codex mapping wrong: $got"
  pass "resume command maps jcode/grok/codex to their verified by-id resume forms"
}

test_resume_command_fails_closed_for_unsupported_harness() {
  # claude/opencode/pi have no verified resume-BY-ID command (opencode and pi
  # resume by cwd/--continue, not a stored id), so they must fail closed rather
  # than emit a guessed command.
  local h
  for h in claude opencode pi unknownharness ''; do
    if fm_resume_command "$h" session_abc >/dev/null 2>&1; then
      fail "harness '$h' should have no by-id resume command"
    fi
  done
  pass "resume command fails closed for harnesses with no verified by-id resume"
}

test_resume_command_refuses_empty_or_unsafe_token() {
  fm_resume_command jcode '' >/dev/null 2>&1 && fail "empty token was not refused"
  # A token carrying shell metacharacters must never be emitted into a command.
  fm_resume_command jcode 'a b' >/dev/null 2>&1 && fail "spaced token was not refused"
  fm_resume_command jcode 'x;rm -rf /' >/dev/null 2>&1 && fail "semicolon token was not refused"
  # shellcheck disable=SC2016  # single quotes are deliberate: a literal unsafe token, not an expansion
  fm_resume_command jcode 'x$(id)' >/dev/null 2>&1 && fail "command-sub token was not refused"
  # shellcheck disable=SC2016  # single quotes are deliberate: a literal unsafe token, not an expansion
  fm_resume_command jcode '`id`' >/dev/null 2>&1 && fail "backtick token was not refused"
  # A realistic session_<slug> shape is accepted.
  fm_resume_command jcode session_all_a >/dev/null 2>&1 || fail "a normal session id was refused"
  pass "resume command refuses empty and shell-unsafe tokens, accepts a normal session id"
}

test_resume_token_for_harness() {
  local got
  got=$(fm_resume_token_for_harness jcode session_abc)
  [ "$got" = "session_abc" ] || fail "jcode token should equal the session id, got '$got'"
  # Non-jcode harnesses have no spawn-time capture, so no token.
  got=$(fm_resume_token_for_harness grok session_abc)
  [ -z "$got" ] || fail "grok should yield no spawn-time resume token, got '$got'"
  got=$(fm_resume_token_for_harness jcode '')
  [ -z "$got" ] || fail "an empty session id should yield no token, got '$got'"
  pass "resume-token helper echoes a jcode session id and is empty for others"
}

# --- spawn integration -------------------------------------------------------
#
# Drive the REAL bin/fm-spawn.sh with a fake tmux backend against a real own-clone
# worktree, a fake jcode session store, and a real tasks-axi markdown backlog, and
# assert the resume= meta stamp + the durable task-record mirror. Mirrors the
# scaffold in tests/fm-token-sessions.test.sh.

SPAWN="$ROOT/bin/fm-spawn.sh"

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# Write a jcode-shaped session json. Args: dir sid working_dir created_at.
write_session() {
  local dir=$1 sid=$2 wd=$3 created=$4
  cat > "$dir/session_$sid.json" <<EOF
{"id":"session_$sid","created_at":"$created","working_dir":"$wd","updated_at":"$created"}
EOF
}

# Build a jcode-crew home with one own-clone project + worktree and a tasks-axi
# markdown backlog carrying the task already in flight. Echoes: home|proj|wt|fakebin
make_spawn_home() {  # <name> <id> [--no-backlog]
  local name=$1 id=$2 flag=${3:-} case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$home/projects/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$case_dir/sessions"
  printf 'jcode\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  if [ "$flag" != "--no-backlog" ]; then
    # A tasks-axi markdown backlog with the task in flight, so the spawn's
    # `tasks-axi update --resume` mirror has a task to write to.
    cat > "$home/.tasks.toml" <<EOF
backend = "markdown"
[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
EOF
    ( cd "$home" && tasks-axi add "$id" "resume capture task" --kind ship --start ) >/dev/null 2>&1 || true
  fi
  printf '%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin"
}

run_spawn_jcode() {  # <home> <proj> <wt> <fakebin> <id> <sessions_dir> [extra args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5 sdir=$6
  shift 6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$wt" \
    FM_SPAWN_JCODE_READY_POLLS=0 \
    JCODE_SESSIONS_DIR="$sdir" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" "$@" 2>&1
}

test_spawn_stamps_resume_and_mirrors_to_backlog() {
  command -v git >/dev/null 2>&1 || { echo "skip: git not found"; return 0; }
  command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; return 0; }
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  local rec home proj wt fakebin id sdir out status wt_real
  id=resume-spawn-1
  rec=$(make_spawn_home resume1 "$id")
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  sdir="$TMP_ROOT/resume1/sessions"
  wt_real=$(cd "$wt" && pwd -P)
  # An older pooled session shares the worktree and must lose; the crew session
  # (newest, at/after spawn) wins and is the resume token.
  write_session "$sdir" pooled "$wt_real" "2020-01-01T00:00:00Z"
  write_session "$sdir" crew "$wt_real" "2099-01-01T00:00:00Z"
  out=$(run_spawn_jcode "$home" "$proj" "$wt" "$fakebin" "$id" "$sdir")
  status=$?
  expect_code 0 "$status" "jcode spawn should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  # The meta carries the resume= stamp with the resolved session id.
  assert_grep "resume=session_crew" "$home/state/$id.meta" \
    "spawn did not stamp resume= into meta"
  # The durable task record was updated too (survives a later meta teardown).
  ( cd "$home" && tasks-axi show "$id" 2>/dev/null ) | grep -q 'resume: session_crew' \
    || fail "spawn did not mirror the resume token into the task record"
  pass "a jcode spawn stamps resume= into meta and mirrors it into the durable task record"
}

test_spawn_unresolvable_stamps_no_resume() {
  command -v git >/dev/null 2>&1 || { echo "skip: git not found"; return 0; }
  command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; return 0; }
  local rec home proj wt fakebin id sdir out status
  id=resume-spawn-2
  rec=$(make_spawn_home resume2 "$id")
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  sdir="$TMP_ROOT/resume2/sessions"
  # No session in the leased worktree: resolve is empty.
  write_session "$sdir" elsewhere "$TMP_ROOT/resume2/elsewhere" "2099-01-01T00:00:00Z"
  out=$(run_spawn_jcode "$home" "$proj" "$wt" "$fakebin" "$id" "$sdir")
  status=$?
  expect_code 0 "$status" "an unresolvable capture must not fail the spawn"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_no_grep "resume=" "$home/state/$id.meta" \
    "spawn stamped a resume= with no resolvable session"
  pass "a jcode spawn whose session cannot be resolved stamps no resume= and still succeeds"
}

test_spawn_resume_cmd_roundtrip() {
  # End-to-end: the exact command bin/fm-resume-cmd.sh prints for a captured task
  # is the verified jcode resume form for the stamped token.
  command -v git >/dev/null 2>&1 || { echo "skip: git not found"; return 0; }
  command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; return 0; }
  local rec home proj wt fakebin id sdir wt_real cmd
  id=resume-spawn-3
  rec=$(make_spawn_home resume3 "$id" --no-backlog)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  sdir="$TMP_ROOT/resume3/sessions"
  wt_real=$(cd "$wt" && pwd -P)
  write_session "$sdir" crew "$wt_real" "2099-01-01T00:00:00Z"
  run_spawn_jcode "$home" "$proj" "$wt" "$fakebin" "$id" "$sdir" >/dev/null 2>&1
  cmd=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-resume-cmd.sh" "$id") \
    || fail "fm-resume-cmd failed for a captured task"
  [ "$cmd" = "jcode --resume session_crew" ] || fail "fm-resume-cmd printed the wrong command: $cmd"
  pass "fm-resume-cmd prints the exact jcode resume command for a captured task"
}

# --- recovery lookup (bin/fm-resume-cmd.sh) fail-closed branches -------------

RESUME_CMD="$ROOT/bin/fm-resume-cmd.sh"

run_resume_cmd() {  # <home> <id>
  local home=$1 id=$2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$RESUME_CMD" "$id" 2>&1
}

test_resume_cmd_fail_closed_branches() {
  local home="$TMP_ROOT/rc/home" out status
  mkdir -p "$home/state"
  # No meta at all.
  out=$(run_resume_cmd "$home" no-such-task); status=$?
  expect_code 1 "$status" "missing meta should fail"
  assert_contains "$out" "no metadata" "missing-meta diagnostic wrong: $out"
  # Meta with a harness but no captured token (e.g. claude, never captured).
  fm_write_meta "$home/state/rc-claude.meta" "harness=claude" "window=s:w"
  out=$(run_resume_cmd "$home" rc-claude); status=$?
  expect_code 1 "$status" "no-token should fail"
  assert_contains "$out" "no captured resume token" "no-token diagnostic wrong: $out"
  # Meta with a token but an unsupported harness (defensive: should not occur
  # since only jcode captures, but fm-resume-cmd must still fail closed).
  fm_write_meta "$home/state/rc-oc.meta" "harness=opencode" "resume=oc-1"
  out=$(run_resume_cmd "$home" rc-oc); status=$?
  expect_code 1 "$status" "unsupported-harness should fail"
  assert_contains "$out" "no verified by-id resume command" "unsupported-harness diagnostic wrong: $out"
  # A well-formed jcode meta prints the command and exits 0.
  fm_write_meta "$home/state/rc-jcode.meta" "harness=jcode" "resume=session_ok"
  out=$(run_resume_cmd "$home" rc-jcode); status=$?
  expect_code 0 "$status" "a captured jcode task should succeed"
  [ "$out" = "jcode --resume session_ok" ] || fail "jcode resume command wrong: $out"
  # An invalid task id is a usage error (exit 2).
  out=$(run_resume_cmd "$home" 'bad id!'); status=$?
  expect_code 2 "$status" "an invalid task id should be a usage error"
  pass "fm-resume-cmd fails closed on missing meta, no token, and unsupported harness"
}

test_resume_command_maps_verified_by_id_forms
test_resume_command_fails_closed_for_unsupported_harness
test_resume_command_refuses_empty_or_unsafe_token
test_resume_token_for_harness
test_spawn_stamps_resume_and_mirrors_to_backlog
test_spawn_unresolvable_stamps_no_resume
test_spawn_resume_cmd_roundtrip
test_resume_cmd_fail_closed_branches
