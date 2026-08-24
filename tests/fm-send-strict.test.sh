#!/usr/bin/env bash
# fm-send strict target resolution.
#
# A send that cannot be tied to a recorded task/lane or to an explicit
# well-formed backend target must fail loudly. These tests pin the historical
# silent-fallback failures: missing FM_HOME (cwd default when the cwd is a
# valid home, loud refusal otherwise, explicit env always winning), unresolved
# selectors, prefixless herdr pane ids, dead explicit endpoints, and the
# healthy exact/fm-id paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-strict)

make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "${1:-}" >> "$FM_TMUX_LOG"
    exit 0 ;;
  display-message)
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -n "${FM_FAKE_TMUX_DEAD_TARGET:-}" ] && [ "$target" = "$FM_FAKE_TMUX_DEAD_TARGET" ]; then
      exit 1
    fi
    printf '%%1\n'
    exit 0 ;;
  capture-pane)
    printf '\xe2\x94\x82 \xe2\x94\x82\n'
    exit 0 ;;
  list-windows)
    printf 'foreign:%s\n' "${FM_FAKE_TMUX_WINDOW:-fm-lost}"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_home() {  # <name> -> echoes home dir
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

test_exact_lane_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/exact"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home exact); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/mpf-lane-m8.meta" "window=sess:fm-mpf-lane-m8" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" mpf-lane-m8 "lost dispatch" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "exact task id send should succeed when metadata exists"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=1 arg=lost dispatch" "exact id should type literal text to the meta target"
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=0 arg=Enter" "exact id should submit with Enter"
  pass "fm-send strict: exact task/lane ids resolve through home metadata"
}

test_unset_fm_home_non_home_cwd_fails() {
  local dir fb err log rc
  dir="$TMP_ROOT/nohome"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  ( cd "$dir" && PATH="$fb:$PATH" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
      env -u FM_HOME "$SEND" sess:win "hello" >/dev/null 2>"$err" ); rc=$?
  [ "$rc" -ne 0 ] || fail "unset FM_HOME from a non-home cwd should fail"
  assert_contains "$(cat "$err")" "FM_HOME is not set" "unset FM_HOME diagnostic should be explicit"
  assert_contains "$(cat "$err")" "not a firstmate home" "unset FM_HOME diagnostic should name the cwd default attempt"
  [ ! -s "$log" ] || fail "unset FM_HOME still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unset FM_HOME from a non-home cwd fails before target resolution"
}

make_valid_home() {  # <dir> -> creates a valid firstmate home skeleton in <dir>
  mkdir -p "$1/data" "$1/state" "$1/config"
  printf '# firstmate\n' > "$1/AGENTS.md"
}

test_unset_fm_home_valid_cwd_defaults() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/cwddefault"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home="$dir/home"; make_valid_home "$home"
  err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/cwd-lane.meta" "window=sess:fm-cwd-lane" "kind=ship"

  ( cd "$home" && PATH="$fb:$PATH" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
      env -u FM_HOME "$SEND" cwd-lane "hello" >/dev/null 2>"$err" ); rc=$?
  expect_code 0 "$rc" "unset FM_HOME from a valid home cwd should default to the cwd"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-cwd-lane literal=1 arg=hello" "cwd-default send should type literal text to the cwd home's meta target"
  assert_contains "$got" "target=sess:fm-cwd-lane literal=0 arg=Enter" "cwd-default send should submit with Enter"
  pass "fm-send strict: unset FM_HOME defaults to a valid home cwd"
}

test_explicit_fm_home_wins_over_valid_cwd() {
  local dir fb home_a home_b err log rc got
  dir="$TMP_ROOT/envwins"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home_a="$dir/home-a"; home_b="$dir/home-b"
  make_valid_home "$home_a"; make_valid_home "$home_b"
  err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home_a/state/a-lane.meta" "window=sess:fm-a-lane" "kind=ship"
  fm_write_meta "$home_b/state/b-lane.meta" "window=sess:fm-b-lane" "kind=ship"

  ( cd "$home_a" && PATH="$fb:$PATH" FM_HOME="$home_b" FM_ROOT_OVERRIDE="$home_b" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
      "$SEND" b-lane "hello" >/dev/null 2>"$err" ); rc=$?
  expect_code 0 "$rc" "explicit FM_HOME should win over a valid cwd home"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-b-lane literal=1 arg=hello" "explicit FM_HOME send should resolve the env home's meta target, not the cwd's"

  : > "$log"; : > "$err"
  ( cd "$home_a" && PATH="$fb:$PATH" FM_HOME="$home_b" FM_ROOT_OVERRIDE="$home_b" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
      "$SEND" a-lane "hello" >/dev/null 2>"$err" ); rc=$?
  [ "$rc" -ne 0 ] || fail "explicit FM_HOME should not fall back to the cwd home's meta"
  [ ! -s "$log" ] || fail "explicit FM_HOME still resolved the cwd home's target"$'\n'"$(cat "$log")"
  pass "fm-send strict: explicit FM_HOME wins over a valid cwd home"
}

test_unresolvable_target_does_not_tmux_fallback() {
  local dir fb home err log rc
  dir="$TMP_ROOT/unresolved"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home unresolved); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_WINDOW=lost-target FM_SEND_SETTLE=0 \
    "$SEND" lost-target "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unresolvable target should fail"
  assert_contains "$(cat "$err")" "not resolvable" "unresolvable diagnostic should be loud"
  assert_contains "$(cat "$err")" "metadata window/terminal lookup" "unresolvable diagnostic should name the attempted lookup"
  assert_contains "$(cat "$err")" "backend=none" "unresolvable diagnostic should name that no backend was assumed"
  [ ! -s "$log" ] || fail "unresolvable target fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unresolvable selectors do not fall back to tmux"
}

test_prefixless_herdr_pane_id_fails() {
  local dir fb home err log rc
  dir="$TMP_ROOT/herdr-pane"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home herdr); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/nudge.meta" \
    "window=default:wB:p2" "backend=herdr" "herdr_session=default" "herdr_pane_id=wB:p2" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" wB:p2 "nudge" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "prefixless herdr pane id should fail"
  assert_contains "$(cat "$err")" "matches herdr_pane_id" "herdr pane diagnostic should name the meta match"
  assert_contains "$(cat "$err")" "expected <herdr-session>:<pane-id>" "herdr pane diagnostic should show expected shape"
  assert_contains "$(cat "$err")" "default:wB:p2" "herdr pane diagnostic should show the canonical target"
  [ ! -s "$log" ] || fail "prefixless herdr pane id fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: prefixless herdr pane ids are rejected before tmux fallback"
}

test_unmatched_single_colon_target_must_exist() {
  local dir fb home err log rc
  dir="$TMP_ROOT/dead-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home deadexplicit); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_DEAD_TARGET=sess:missing FM_SEND_SETTLE=0 \
    "$SEND" sess:missing "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "dead explicit tmux-shaped target should fail"
  assert_contains "$(cat "$err")" "not a live tmux endpoint" "dead explicit target diagnostic should name the assumed backend"
  assert_contains "$(cat "$err")" "backend=tmux" "dead explicit target diagnostic should name the tried backend"
  [ ! -s "$log" ] || fail "dead explicit target still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unmatched single-colon explicit targets must verify live before sending"
}

test_healthy_fm_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/healthy"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home healthy); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-ok.meta" "window=sess:fm-lane-ok" "kind=ship" "harness=codex"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" fm-lane-ok "hello captain" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "healthy fm-id send should succeed"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-lane-ok literal=1 arg=hello captain" "healthy send should type literal text to the meta target"
  assert_contains "$got" "target=sess:fm-lane-ok literal=0 arg=Enter" "healthy send should submit with Enter"
  assert_contains "$(cat "$err")" "requested message WILL still be sent" "fm-send guard banner should keep send-specific continuation wording"
  pass "fm-send strict: healthy fm-<id> sends still type once and submit"
}

test_exact_lane_id_send_still_works
test_unset_fm_home_non_home_cwd_fails
test_unset_fm_home_valid_cwd_defaults
test_explicit_fm_home_wins_over_valid_cwd
test_unresolvable_target_does_not_tmux_fallback
test_prefixless_herdr_pane_id_fails
test_unmatched_single_colon_target_must_exist
test_healthy_fm_id_send_still_works
