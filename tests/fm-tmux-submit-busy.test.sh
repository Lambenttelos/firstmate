#!/usr/bin/env bash
# tests/fm-tmux-submit-busy.test.sh - regression: busy pane + pending composer
# after Enter retries must return "empty" (message queued), not "pending".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-tmux-submit-busy.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

# Override fm_pane_is_busy for testing: FM_FAKE_PANE_BUSY=1 means busy.
fm_pane_is_busy() {
  [ "${FM_FAKE_PANE_BUSY:-0}" = 1 ]
}

make_submit_mock() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
COMPOSER="${FM_FAKE_COMPOSER:?}"
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac
    done
    exit 0 ;;
  capture-pane) cat "$COMPOSER" 2>/dev/null; exit 0 ;;
  send-keys)
    shift; is_enter=0
    while [ "$#" -gt 0 ]; do
      case "$1" in -t) shift ;; -l) ;; Enter) is_enter=1 ;; esac; shift
    done
    if [ "$is_enter" = 1 ]; then
      if [ -n "${FM_FAKE_SWALLOW:-}" ] && [ -f "$FM_FAKE_SWALLOW" ]; then
        [ "${FM_FAKE_PERSIST_SWALLOW:-0}" = 1 ] || rm -f "$FM_FAKE_SWALLOW"
      else
        printf '│ > │\n' > "$COMPOSER"
      fi
    fi
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_busy_pane_pending_returns_empty() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/busy-accepted"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '│ > fix findings 1 and 3 │\n' > "$composer"
  : > "$sent"
  touch "$dir/.swallow"
  # Pre-check: composer state should be pending (via function, not $()).
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" fm_tmux_composer_state "win" > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending ] || fail "pre-check: composer state expected pending, got '$(cat "$vfile")'"
  # Now test the submit - write verdict to file to avoid nested $().
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_FAKE_PANE_BUSY=1 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = empty ] || fail "busy-pane pending should return empty, got '$(cat "$vfile")'"
  [ "$(grep -c 'fix findings' "$sent" 2>/dev/null || true)" -eq 0 ] \
    || fail "busy-pane should not retype text"
  pass "fm_tmux_submit_enter_core: busy pane + pending composer returns empty (message queued)"
}

test_idle_pane_pending_returns_pending() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/idle-swallow"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '│ > fix findings 1 and 3 │\n' > "$composer"
  : > "$sent"
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_FAKE_PANE_BUSY=0 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending ] || fail "idle-pane pending should return pending, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: idle pane + pending composer stays pending (genuine swallow preserved)"
}

test_busy_pane_composer_clears_first_try() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/busy-clear"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '│ > fix findings 1 and 3 │\n' > "$composer"
  : > "$sent"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" FM_FAKE_PANE_BUSY=1 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = empty ] || fail "busy-pane with cleared composer should return empty, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: busy pane clears composer on first Enter - returns empty"
}

test_idle_pane_composer_clears_first_try() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/idle-clear"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '│ > fix findings 1 and 3 │\n' > "$composer"
  : > "$sent"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" FM_FAKE_PANE_BUSY=0 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = empty ] || fail "idle-pane with cleared composer should return empty, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: idle pane clears composer on first Enter - returns empty as before"
}

# --- claude 2.1.220 NBSP composer: verify-and-retry-Enter end to end ----------
# The empty composer these mocks write is the real claude shape: "❯" padded with
# a U+00A0 NO-BREAK SPACE. It exercises the fm_composer_normalize_ws fold in the
# actual classifier, so a cleared claude composer reads empty (delivered) instead
# of the pre-fix false pending. Enter #N clears iff N > FM_FAKE_SWALLOW_COUNT.
make_nbsp_submit_mock() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
COMPOSER="${FM_FAKE_COMPOSER:?}"
NBSP=$(printf '\302\240')
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac
    done
    exit 0 ;;
  capture-pane) cat "$COMPOSER" 2>/dev/null; exit 0 ;;
  send-keys)
    shift; is_enter=0 is_literal=0
    while [ "$#" -gt 0 ]; do
      case "$1" in -t) shift ;; -l) is_literal=1 ;; Enter) is_enter=1 ;; esac; shift
    done
    if [ "$is_literal" = 1 ]; then printf 'LITERAL\n' >> "${FM_FAKE_SENT:?}"; fi
    if [ "$is_enter" = 1 ]; then
      cnt=$(cat "${FM_FAKE_SWALLOW_CTR:?}" 2>/dev/null || printf 0)
      if [ "$cnt" -gt 0 ]; then
        printf '%s\n' "$((cnt - 1))" > "$FM_FAKE_SWALLOW_CTR"   # swallow this Enter
      else
        printf '❯%s\n' "$NBSP" > "$COMPOSER"                    # submit: clear to claude empty
      fi
    fi
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# Drive fm_tmux_submit_core (type once, then verify-and-retry Enter) against the
# NBSP mock. <swallow> Enters are dropped before one submits. Idle pane.
run_nbsp_submit() {  # <dir> <swallow-count> -> writes verdict file, echoes path
  local dir=$1 swallow=$2 fakebin composer sent ctr vfile nbsp
  fakebin=$(make_nbsp_submit_mock "$dir")
  composer="$dir/composer"; sent="$dir/sent.log"; ctr="$dir/swallow.ctr"; vfile="$dir/verdict"
  nbsp=$(printf '\302\240')
  printf '❯%sfix findings 1 and 3\n' "$nbsp" > "$composer"   # NBSP-padded pending
  : > "$sent"; printf '%s\n' "$swallow" > "$ctr"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW_CTR="$ctr" FM_FAKE_PANE_BUSY=0 \
    fm_tmux_submit_core "win" "fix findings 1 and 3" 3 0.02 0.01 > "$vfile" 2>/dev/null
  printf '%s\n' "$vfile"
}

test_nbsp_verified_first_try() {
  local dir vfile
  dir="$TMP_ROOT/nbsp-first"; vfile=$(run_nbsp_submit "$dir" 0)
  [ "$(cat "$vfile")" = empty ] \
    || fail "NBSP composer cleared on first Enter should verify empty, got '$(cat "$vfile")'"
  [ "$(grep -c LITERAL "$dir/sent.log")" -eq 1 ] || fail "text must be typed exactly once"
  pass "fm_tmux_submit_core: claude NBSP composer, submit verifies on the first Enter (was false pending pre-fix)"
}

test_nbsp_verified_after_one_retry() {
  local dir vfile
  dir="$TMP_ROOT/nbsp-retry"; vfile=$(run_nbsp_submit "$dir" 1)
  [ "$(cat "$vfile")" = empty ] \
    || fail "NBSP composer cleared after one swallowed Enter should verify empty, got '$(cat "$vfile")'"
  [ "$(grep -c LITERAL "$dir/sent.log")" -eq 1 ] || fail "the retry must be Enter-only, never a retype"
  pass "fm_tmux_submit_core: claude NBSP composer, one Enter swallowed then verified on retry (no retype)"
}

test_nbsp_genuinely_swallowed() {
  local dir vfile
  # 99 > retry budget: the Enter is never accepted, idle pane -> genuine swallow.
  dir="$TMP_ROOT/nbsp-swallow"; vfile=$(run_nbsp_submit "$dir" 99)
  [ "$(cat "$vfile")" = pending ] \
    || fail "a never-clearing idle NBSP composer must stay pending, got '$(cat "$vfile")'"
  [ "$(grep -c LITERAL "$dir/sent.log")" -eq 1 ] || fail "a genuine swallow must not retype the text"
  pass "fm_tmux_submit_core: claude NBSP composer, genuinely swallowed Enter stays pending (trustworthy non-zero exit)"
}

test_busy_pane_pending_returns_empty
test_idle_pane_pending_returns_pending
test_busy_pane_composer_clears_first_try
test_idle_pane_composer_clears_first_try
test_nbsp_verified_first_try
test_nbsp_verified_after_one_retry
test_nbsp_genuinely_swallowed
