#!/usr/bin/env bash
# Behavior tests for bin/fm-project-mode.sh: it resolves a project's delivery
# mode and yolo flag from data/projects.md, accepts the four known modes, and
# falls back to "no-mistakes off" (with a warning) for an unknown mode or an
# absent project so a typo never silently drops the gate.
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
- local-proj [local-only] - local-only fixture (added 2026-07-01)
- bogus-proj [made-up] - unknown mode fixture (added 2026-07-01)
EOF

mode_of() { FM_HOME="$HOME_DIR" "$ROOT/bin/fm-project-mode.sh" "$1" 2>/dev/null; }

test_known_modes_resolve() {
  assert_contains "$(mode_of plain-proj)" "no-mistakes off" "plain line must default to no-mistakes off"
  assert_contains "$(mode_of nm-proj)" "no-mistakes off" "explicit no-mistakes must resolve"
  assert_contains "$(mode_of pr-proj)" "direct-PR off" "direct-PR must resolve"
  assert_contains "$(mode_of push-proj)" "direct-push off" "direct-push must be an accepted mode"
  assert_contains "$(mode_of local-proj)" "local-only off" "local-only must resolve"
  pass "fm-project-mode.sh: all four delivery modes resolve, direct-push included"
}

test_direct_push_carries_yolo() {
  assert_contains "$(mode_of push-yolo-proj)" "direct-push on" \
    "direct-push +yolo must resolve mode and yolo independently"
  pass "fm-project-mode.sh: direct-push composes with the orthogonal yolo flag"
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
  assert_contains "$out" "no-mistakes off" "absent project must fall back to no-mistakes off"
  pass "fm-project-mode.sh: unknown mode and absent project fall back safely"
}

test_known_modes_resolve
test_direct_push_carries_yolo
test_unknown_mode_falls_back_to_safe_default
