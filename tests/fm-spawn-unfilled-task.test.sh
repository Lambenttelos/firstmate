#!/usr/bin/env bash
# Regression test for fm-spawn.sh's unfilled-{TASK}-placeholder guard
# (bin/fm-spawn.sh, immediately after the brief-existence check).
#
# fm-brief.sh scaffolds every brief with a literal {TASK} placeholder as the
# body of the `# Task` section, meant to be replaced with the task description
# before dispatch. When that replacement is forgotten, the old behaviour
# dispatched the empty brief: the crewmate could only stop and report the
# unfilled placeholder, wasting the whole spawn. The guard these tests pin
# refuses such a spawn loudly at spawn time - the scaffold cannot know the task
# text, so the check lives here - and records no task metadata. The match is
# structural: the bare placeholder standing alone as a line. A filled brief that
# merely quotes the token in prose or backticks (the scaffold's own Herdr
# declaration does) is accepted, not refused.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-unfilled-task)

# make_fakebin <dir> builds a fake tmux/treehouse so a spawn that reaches the
# launch path does not need a real backend; a spawn refused before launch never
# uses it, but the accepted control case does.
make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_case <name> <id> <brief-body> builds a home with its own project clone
# and real worktree, then writes <brief-body> as the task's brief so each test
# controls whether the placeholder is present.
make_case() {
  local name=$1 id=$2 body=$3 case_dir home proj own_wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/home/projects/project"
  own_wt="$case_dir/own-wt"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$own_wt" "own-$name"
  mkdir -p "$home/data/$id"
  printf '%s\n' "$body" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$own_wt|$fakebin"
}

read_case() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR OWN_WT FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local id=$1 pane=$2
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$pane" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" 2>&1
}

# A brief that still carries the {TASK} placeholder is refused before launch and
# leaves no task metadata behind.
test_unfilled_placeholder_is_refused() {
  local rec id out status
  id="unfilled-task-z1"
  rec=$(make_case unfilled "$id" $'# Task\n{TASK}\n\nrest of the brief')
  read_case "$rec"

  out=$(run_spawn "$id" "$OWN_WT")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a brief with an unfilled {TASK} placeholder: $out"
  assert_contains "$out" "{TASK}" "refusal did not name the unfilled placeholder"
  assert_contains "$out" "$HOME_DIR/data/$id/brief.md" "refusal did not name the offending brief"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused unfilled-placeholder spawn still recorded task metadata"
  pass "a brief with an unfilled {TASK} placeholder is refused, not dispatched"
}

# The honest signal is structural: an unfilled brief holds the bare placeholder
# as the entire body of a line. A filled brief whose task body merely quotes the
# token in explanatory prose is fully filled and must be accepted, not refused -
# refusing it forces the operator to edit legitimate text to spawn.
test_placeholder_in_prose_is_accepted() {
  local rec id out status
  id="filled-task-z2"
  rec=$(make_case prose "$id" $'# Task\nDo the real work described here.\n\nSee {TASK} for context.')
  read_case "$rec"

  out=$(run_spawn "$id" "$OWN_WT")
  status=$?
  expect_code 0 "$status" "spawn should accept a filled brief that only quotes {TASK} in prose: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success for a prose-mention brief"
  pass "a brief that merely quotes {TASK} in prose is accepted"
}

# The scaffold's own Herdr safety declaration quotes `{TASK}` inline in backticks.
# A fully filled brief that still carries that generated declaration must be
# accepted; the earlier substring guard refused it, forcing the operator to edit
# generated safety text to spawn.
test_filled_brief_with_herdr_declaration_is_accepted() {
  local rec id out status
  id="filled-task-z4"
  rec=$(make_case herdr "$id" $'# Task\nAdd a regression test for the widget parser.\n\n# Herdr lifecycle declaration - NOT ENABLED\n**HARD SAFETY GATE:** this scaffold cannot inspect the task text that replaces `{TASK}` later.\nIf the task will drive Herdr lifecycle behavior, regenerate with `--herdr-lab`.\n\nrest of the brief')
  read_case "$rec"

  out=$(run_spawn "$id" "$OWN_WT")
  status=$?
  expect_code 0 "$status" "spawn should accept a filled brief carrying the Herdr declaration: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success for a brief with the Herdr declaration"
  pass "a fully filled brief with the Herdr declaration present is accepted"
}

# The legitimate case must keep working: a fully filled brief still spawns.
test_filled_brief_is_accepted() {
  local rec id out status
  id="filled-task-z3"
  rec=$(make_case filled "$id" $'# Task\nAdd a regression test for the widget parser.\n\nrest of the brief')
  read_case "$rec"

  out=$(run_spawn "$id" "$OWN_WT")
  status=$?
  expect_code 0 "$status" "spawn should accept a fully filled brief: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success for a filled brief"
  pass "a fully filled brief is still accepted"
}

test_unfilled_placeholder_is_refused
test_placeholder_in_prose_is_accepted
test_filled_brief_is_accepted
test_filled_brief_with_herdr_declaration_is_accepted

echo "# all fm-spawn-unfilled-task tests passed"
