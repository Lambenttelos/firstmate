#!/usr/bin/env bash
# Regression test for fm-spawn.sh exporting FM_HEAVY_SLOTS_FILE into every
# spawned crew/secondmate environment (task fm-spawn-pass-heavy-slots-file).
#
# The bug (data/learnings.md 2026-08-13 HEAVY-RUN): the heavy-run ledger is
# host-global, so every home must resolve one shared ceiling through
# FM_HEAVY_SLOTS_FILE pointing at the primary home's config/heavy-run-slots.
# fm-spawn did NOT export it, so a waiter in a secondmate home fell back to its
# own (absent = default 1) config/heavy-run-slots while the real ceiling was
# higher, starving that lane. This test drives a real spawn with a fake tmux
# that records every send-keys line, and asserts the export lands and points at
# the SPAWNING home's config/heavy-run-slots (the primary), not the child's.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-heavy-slots-file)

# A fake tmux that behaves like the settle test's (reports the settled worktree
# path for pane_current_path) but ALSO appends every send-keys payload to a
# capture file so a test can assert the exact export line the spawn sent.
make_capturing_tmux() {
  local dir=$1 capture=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
CAPTURE='$capture'
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys)
    # argv: send-keys -t <target> <payload> [Enter]. Record the payload only.
    shift  # send-keys
    while [ "\${1:-}" != "-t" ] && [ \$# -gt 0 ]; do shift; done
    [ \$# -gt 0 ] && shift  # -t
    [ \$# -gt 0 ] && shift  # target
    printf '%s\n' "\${1:-}" >> "\$CAPTURE"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# Build a home with one own-clone project and its worktree, plus a capturing
# fake tmux. Echoes: home|proj|wt|fakebin|capture
make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin capture
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$home/projects/project"
  wt="$case_dir/wt"
  capture="$case_dir/sendkeys"
  fakebin=$(make_capturing_tmux "$case_dir/fake" "$capture")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s|%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin" "$capture"
}

run_spawn() {  # <home> <proj> <wt> <fakebin> <id> [extra FM_HEAVY_SLOTS_FILE value]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5 slots=${6-}
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$wt" \
    FM_HEAVY_SLOTS_FILE="$slots" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" 2>&1
}

# A primary-home spawn (no inherited FM_HEAVY_SLOTS_FILE) must export the
# pointer at THIS home's config/heavy-run-slots, absolute.
test_primary_spawn_exports_own_config() {
  local rec home proj wt fakebin capture id out status expect
  id=heavy-slots-z1
  rec=$(make_case primary "$id")
  IFS='|' read -r home proj wt fakebin capture <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  # config resolves absolute; the export must name that exact file. The value
  # is shell-quoted (single quotes) so a path with a special char is safe.
  expect=$(cd "$home/config" && pwd -P)/heavy-run-slots
  assert_grep "export FM_HEAVY_SLOTS_FILE='$expect'" "$capture" \
    "spawn did not export FM_HEAVY_SLOTS_FILE at this home's config/heavy-run-slots"
  pass "a primary-home spawn exports FM_HEAVY_SLOTS_FILE at its own config/heavy-run-slots"
}

# When this spawn already inherited an authoritative FM_HEAVY_SLOTS_FILE (the
# secondmate-spawning-its-own-crew case), it must propagate that primary pointer
# verbatim, NOT overwrite it with the child home's config.
test_inherited_pointer_is_propagated() {
  local rec home proj wt fakebin capture id out status primary_slots
  id=heavy-slots-z2
  rec=$(make_case inherited "$id")
  IFS='|' read -r home proj wt fakebin capture <<EOF
$rec
EOF
  # A primary slots file somewhere else entirely - must win over $home/config.
  primary_slots="$TMP_ROOT/primary-home/config/heavy-run-slots"
  mkdir -p "$(dirname "$primary_slots")"
  printf '4\n' > "$primary_slots"
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$primary_slots")
  status=$?
  expect_code 0 "$status" "spawn should succeed"
  assert_grep "export FM_HEAVY_SLOTS_FILE='$primary_slots'" "$capture" \
    "spawn did not propagate the inherited primary FM_HEAVY_SLOTS_FILE"
  assert_no_grep "export FM_HEAVY_SLOTS_FILE='$home/config/heavy-run-slots'" "$capture" \
    "spawn wrongly overwrote the inherited pointer with the child home's config"
  pass "an inherited authoritative FM_HEAVY_SLOTS_FILE is propagated to the child, not overwritten"
}

test_primary_spawn_exports_own_config
test_inherited_pointer_is_propagated

echo "# all fm-spawn-heavy-slots-file tests passed"
