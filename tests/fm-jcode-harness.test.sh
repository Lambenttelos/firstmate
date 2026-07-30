#!/usr/bin/env bash
# Behavior tests for the jcode harness adapter: self-detection, session-lock holder
# detection, and the crewmate/secondmate spawn-target facts.
# jcode (github.com/1jehuang/jcode) is a Claude-Agent-SDK runtime that does NOT set
# CLAUDECODE; it sets JCODE_ACTIVE_PROVIDER / JCODE_RUNTIME_PROVIDER and runs as comm
# "jcode". Without recognition, fm-lock.sh could not find a harness in the ancestry and
# every jcode-run session fell into read-only mode (verified 2026-07-30).
#
# The spawn-target facts pinned below (all verified 2026-07-30 on jcode server
# 0.64.2, evidence in the harness-adapters skill):
#   - jcode takes NO positional prompt, so its launch command carries no brief
#     placeholder and cannot smuggle one in.
#   - Its busy signature is the composer prompt row flipping from "3>" to "4…",
#     and the busy regex must recognize it on both the watcher and tmux paths.
#   - An IDLE jcode composer row must read `empty`, not `pending`: before the
#     adapter landed, the tmux reader called it pending, which is the shape that
#     wedges away-mode injection and misreports every delivered submit.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-jcode-harness)

# The real captured composer rows, padding shortened. Bright truecolor
# throughout, so nothing is de-emphasised and the ghost stripper keeps the row:
# red turn counter, blue prompt glyph, default-foreground text area, amber ⏳.
JCODE_ROW_IDLE=$'\033[38;2;255;80;80m3\033[38;2;138;180;248m> \033[39m        \033[38;2;255;193;7m\xe2\x8f\xb3'
JCODE_ROW_TYPED=$'\033[38;2;255;80;80m3\033[38;2;138;180;248m> \033[39mhello unsubmitted text        \033[38;2;255;193;7m\xe2\x8f\xb3'
JCODE_ROW_BUSY=$'\033[38;2;255;80;80m4\033[38;2;138;180;248m\xe2\x80\xa6 \033[39m        \033[38;2;255;193;7m\xe2\x8f\xb3'

# A fake tmux serving one styled composer row, the same shape
# tests/fm-composer-ghost.test.sh uses: capture-pane -e returns the styled
# fixture, a plain capture returns it with SGR sequences stripped.
make_fake_tmux() {  # <dir>
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '%s\n' "${FM_FAKE_CY:-0}"; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    has_e=0
    for a in "$@"; do [ "$a" = "-e" ] && has_e=1; done
    f="${FM_FAKE_STYLED:-/dev/null}"
    if [ "$has_e" = 1 ]; then
      cat "$f" 2>/dev/null
    else
      LC_ALL=C awk '{gsub(/\033\[[0-9;]*m/, ""); print}' "$f" 2>/dev/null
    fi
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 1
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

test_tmux_composer_state_reads_jcode_rows() {
  local dir fb capture out
  dir="$TMP_ROOT/composer"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"

  printf '%s\n' "$JCODE_ROW_IDLE" > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 fm_tmux_composer_state fakepane)
  [ "$out" = empty ] \
    || fail "an idle jcode composer row must read empty on the tmux path, got '$out'"

  printf '%s\n' "$JCODE_ROW_BUSY" > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 fm_tmux_composer_state fakepane)
  [ "$out" = empty ] \
    || fail "a mid-turn jcode composer row must read empty on the tmux path, got '$out'"

  printf '%s\n' "$JCODE_ROW_TYPED" > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 fm_tmux_composer_state fakepane)
  [ "$out" = pending ] \
    || fail "real text in a jcode composer must read pending on the tmux path, got '$out'"
  pass "fm_tmux_composer_state: jcode idle/busy rows read empty, typed text reads pending"
}

test_busy_regex_matches_jcode_busy_row_only() {
  local plain_busy plain_idle
  # The busy predicate greps the plain pane tail, so assert against the plain rows.
  plain_busy=$(printf '%s\n' "$JCODE_ROW_BUSY" | fm_composer_strip_ansi)
  plain_idle=$(printf '%s\n' "$JCODE_ROW_IDLE" | fm_composer_strip_ansi)
  printf '%s\n' "$plain_busy" | grep -qE "$FM_TMUX_BUSY_REGEX_DEFAULT" \
    || fail "the shared busy regex must match jcode's mid-turn composer row"
  ! printf '%s\n' "$plain_idle" | grep -qE "$FM_TMUX_BUSY_REGEX_DEFAULT" \
    || fail "the shared busy regex must NOT match jcode's idle composer row"
  # fm-watch.sh keeps its own copy of the default; they must agree.
  grep -q 'esc (to )?interrupt|Working\\.\\.\\.|Ctrl\\+c:cancel|\^\[0-9\]+…' "$ROOT/bin/fm-watch.sh" \
    || fail "bin/fm-watch.sh's BUSY_REGEX default does not carry jcode's busy signature"
  pass "busy regex: jcode's mid-turn composer row matches, its idle row does not, and both owners agree"
}

test_spawn_launch_template_has_no_positional_brief() {
  local launch
  # jcode rejects a positional prompt ("unrecognized subcommand"), so its launch
  # command must not carry the brief, and the brief must be delivered afterwards.
  local fn="$TMP_ROOT/launch_template.sh"
  mkdir -p "$TMP_ROOT"
  awk '/^launch_template\(\) \{/ { inside = 1 } inside { print } inside && /^\}/ { exit }' \
    "$ROOT/bin/fm-spawn.sh" > "$fn"
  [ -s "$fn" ] || fail "could not extract launch_template() from bin/fm-spawn.sh"
  # shellcheck source=/dev/null
  . "$fn"
  launch=$(launch_template jcode ship)
  [ "$launch" = 'jcode --no-update' ] \
    || fail "the jcode launch template must be exactly 'jcode --no-update', got '$launch'"
  grep -q 'jcode_post_launch_delivery "\$T" "\$BRIEF"' "$ROOT/bin/fm-spawn.sh" \
    || fail "fm-spawn.sh must deliver the jcode brief after launch"
  grep -q 'FM_SPAWN_JCODE_READY_POLLS' "$ROOT/bin/fm-spawn.sh" \
    || fail "fm-spawn.sh must bound the wait for jcode's composer"
  pass "fm-spawn.sh: the jcode launch command carries no positional brief and delivery happens after launch"
}

test_spawn_installs_no_jcode_turnend_hook() {
  # jcode's native turn_end hook is read by its shared background server, not by
  # the launched client, so no per-task hook can be armed and none may be
  # written. Supervision is stale-pane only (harness-adapters).
  local hook_block
  hook_block=$(sed -n '/^if \[ "\$KIND" != secondmate \]; then/,/^fi$/p' "$ROOT/bin/fm-spawn.sh")
  ! printf '%s\n' "$hook_block" | grep -q 'jcode' \
    || fail "fm-spawn.sh must not install a turn-end hook for jcode"
  pass "fm-spawn.sh: no turn-end hook or token is installed for a jcode task"
}

test_dispatch_select_accepts_jcode_profile() {
  local out
  out=$("$ROOT/bin/fm-dispatch-select.sh" '{"harness":"jcode","model":"claude-opus-4-8","effort":"high"}' 2>&1) \
    || fail "a jcode dispatch profile must validate, got: $out"
  assert_contains "$out" '"harness":"jcode"' "the resolved profile did not name jcode"
  out=$("$ROOT/bin/fm-dispatch-select.sh" '{"harness":"jcode","effort":"bogus"}' 2>&1) \
    && fail "an unsupported jcode effort must be refused, got: $out"
  assert_contains "$out" "unsupported harness/effort pair" "the refusal did not name the harness/effort pair"
  pass "fm-dispatch-select.sh: jcode is a verified harness with the shared effort vocabulary"
}

test_harness_detects_jcode_by_env_marker() {
  local out
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    JCODE_ACTIVE_PROVIDER=claude "$ROOT/bin/fm-harness.sh")
  assert_contains "$out" "jcode" "fm-harness did not detect jcode via JCODE_ACTIVE_PROVIDER"
  pass "fm-harness detects jcode via env marker"
}

test_fm_lock_recognizes_jcode_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/Users/cyuan/.jcode/builds/shared-server/jcode'; exit 0 ;;
  *"args="*) printf '%s\n' 'jcode'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize jcode as a live holder"
  pass "fm-lock recognizes jcode harness processes"
}

test_harness_detects_jcode_by_env_marker
test_fm_lock_recognizes_jcode_holder
test_tmux_composer_state_reads_jcode_rows
test_busy_regex_matches_jcode_busy_row_only
test_spawn_launch_template_has_no_positional_brief
test_spawn_installs_no_jcode_turnend_hook
test_dispatch_select_accepts_jcode_profile
