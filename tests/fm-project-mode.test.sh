#!/usr/bin/env bash
# Behavior tests for bin/fm-project-mode.sh: it resolves a project's delivery
# mode, yolo flag, and autoland flag from data/projects.md, accepts the four known
# modes, composes the orthogonal +yolo and +autoland flags in any order, and falls
# back to "no-mistakes off off" (with a warning) for an unknown mode or an absent
# project so a typo never silently drops the gate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-mode)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data"
cat > "$HOME_DIR/data/projects.md" <<'EOF'
- plain-proj - legacy default, no bracket (added 2026-07-01)
- nm-proj [no-mistakes] - explicit no-mistakes (added 2026-07-01)
- pr-proj [direct-PR] - direct-PR fixture (added 2026-07-01)
- push-proj [direct-push] - direct-push fixture (added 2026-07-24)
- push-yolo-proj [direct-push +yolo] - direct-push with yolo (added 2026-07-24)
- push-autoland-proj [direct-push +autoland] - direct-push self-land fixture (added 2026-07-26)
- push-yolo-autoland-proj [direct-push +yolo +autoland] - both flags fixture (added 2026-07-26)
- autoland-order-proj [direct-push +autoland +yolo] - flags in reverse order (added 2026-07-26)
- local-autoland-proj [local-only +autoland] - local-only self-land fixture (added 2026-07-26)
- local-proj [local-only] - local-only fixture (added 2026-07-01)
- bogus-proj [made-up] - unknown mode fixture (added 2026-07-01)
EOF

mode_of() { FM_HOME="$HOME_DIR" "$ROOT/bin/fm-project-mode.sh" "$1" 2>/dev/null; }

# Exact-match assertion (lib.sh only ships assert_contains); the three-word output
# contract needs an exact check so a stray extra word cannot slip through.
assert_equals() { # <expected> <actual> <msg>
  [ "$1" = "$2" ] || fail "$3 (expected [$1], got [$2])"
}

# Every resolved line now carries three words: "<mode> <yolo> <autoland>".
test_known_modes_resolve() {
  assert_equals "no-mistakes off off" "$(mode_of plain-proj)" "plain line must default to no-mistakes off off"
  assert_equals "no-mistakes off off" "$(mode_of nm-proj)" "explicit no-mistakes must resolve"
  assert_equals "direct-PR off off" "$(mode_of pr-proj)" "direct-PR must resolve"
  assert_equals "direct-push off off" "$(mode_of push-proj)" "direct-push must be an accepted mode"
  assert_equals "local-only off off" "$(mode_of local-proj)" "local-only must resolve"
  pass "fm-project-mode.sh: all four delivery modes resolve with a default-off autoland word"
}

test_direct_push_carries_yolo() {
  assert_equals "direct-push on off" "$(mode_of push-yolo-proj)" \
    "direct-push +yolo must resolve mode and yolo independently, autoland off"
  pass "fm-project-mode.sh: direct-push composes with the orthogonal yolo flag"
}

# +autoland is orthogonal to mode and +yolo and is order-independent inside the brackets.
test_autoland_flag_resolves() {
  assert_equals "direct-push off on" "$(mode_of push-autoland-proj)" \
    "direct-push +autoland must set autoland on and leave yolo off"
  assert_equals "direct-push on on" "$(mode_of push-yolo-autoland-proj)" \
    "+yolo +autoland must set both flags on"
  assert_equals "direct-push on on" "$(mode_of autoland-order-proj)" \
    "flag order inside the brackets must not matter"
  assert_equals "local-only off on" "$(mode_of local-autoland-proj)" \
    "local-only +autoland must compose too"
  pass "fm-project-mode.sh: +autoland composes orthogonally and order-independently"
}

# An unknown mode and an absent project both fall back to the safe default and
# warn to stderr, so a typo never silently drops the validation gate.
test_unknown_mode_falls_back_to_safe_default() {
  local out err
  out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-project-mode.sh" bogus-proj 2>/dev/null)
  assert_contains "$out" "no-mistakes off" "unknown mode must fall back to no-mistakes off"
  err=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-project-mode.sh" bogus-proj 2>&1 >/dev/null)
  assert_contains "$err" "unknown mode" "unknown mode must warn to stderr"

  out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-project-mode.sh" not-registered 2>/dev/null)
  assert_equals "no-mistakes off off" "$out" "absent project must fall back to no-mistakes off off"
  pass "fm-project-mode.sh: unknown mode and absent project fall back safely"
}

test_known_modes_resolve
test_direct_push_carries_yolo
test_autoland_flag_resolves
test_unknown_mode_falls_back_to_safe_default
