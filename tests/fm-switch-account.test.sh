#!/usr/bin/env bash
# tests/fm-switch-account.test.sh - contract tests for bin/fm-switch-account.sh,
# the helper that broadcasts jcode's per-session `/account claude switch <label>`
# into every live worker pane.
#
# Two reasons these tests exist:
#
# 1. The no-args pane auto-discovery path. That path used to fail SILENTLY:
#    under `set -euo pipefail`, a state/*.meta with no target (for example a
#    service sidecar such as state/.lavish-lan.meta, which records only
#    port=/bind=/target=) made the discovery grep exit non-zero, that status
#    propagated through the command substitution, and set -e killed the whole
#    script with exit 1 before it reached a real target.
#
# 2. The composer pending-text guard (captain-reported bug): the script used to
#    type `/account claude switch <label>` + Enter into every pane blindly. If a
#    pane held a half-typed prompt the switch command was appended onto it and
#    the whole thing got garbled. The fix checks each pane's composer state and
#    clears pending text with one Escape before sending, skipping panes that
#    stay pending (real human typing) or read unknown (dead/non-agent pane).
#
# 3. The herdr target must be passed VERBATIM (task
#    fix-jcode-composer-probe-unknown-blocks-account-switch): a herdr meta records
#    window= as the full "<session>:<workspace>:<pane>" id (e.g.
#    "default:w1J:p3"), and the herdr adapter's parse_target splits on the FIRST
#    colon only - the leading field is the herdr --session, the remainder is the
#    whole pane id. An earlier version stripped the "default:" prefix, leaving
#    "w1J:p3", which herdr then read as session=w1J pane=p3 and rejected as
#    pane_not_found, so EVERY live jcode composer probe returned `unknown` and the
#    script skipped the whole fleet. The fake fm-backend.sh below emulates that
#    same first-colon split in its composer/send/capture stubs, so a target that
#    is not passed verbatim reads `unknown` here exactly as real herdr would -
#    that is what makes case 1 a genuine regression guard, not a string check.
#
# Everything is injected: a fake repo layout (bin/ + state/) plus a fake
# fm-backend.sh whose composer states are scripted per target, so no assertion
# depends on any real pane, task, backend, or account.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SRC="$ROOT/bin/fm-switch-account.sh"
assert_present "$SRC" "bin/fm-switch-account.sh is missing"
[ -x "$SRC" ] || fail "bin/fm-switch-account.sh must be executable"

TMPROOT=$(fm_test_tmproot fm-switch-account)

# Build a fake repo layout the script cds into: bin/<script> + bin/fm-backend.sh
# + state/*.meta. The script resolves its root as dirname/.. of its own path and
# sources fm-backend.sh from its own bin dir, so a fake fm-backend.sh next to it
# controls every backend primitive.
REPO="$TMPROOT/repo"
mkdir -p "$REPO/bin" "$REPO/state"
cp "$SRC" "$REPO/bin/fm-switch-account.sh"
chmod +x "$REPO/bin/fm-switch-account.sh"

# Per-target scripted composer states. COMPOSER_DIR holds one file per target
# (":"/"/" -> "_"); each line is one state, consumed one per composer_state call,
# so a pane can read pending then empty (Escape cleared it) or pending twice
# (stubborn). A missing file defaults to empty.
COMPOSER_DIR="$TMPROOT/composer"
BACKEND_LOG="$TMPROOT/backend.log"

sanitize() { printf '%s' "$1" | tr ':/' '__'; }

set_composer() {  # <target> <state...>
  local t=$1; shift
  mkdir -p "$COMPOSER_DIR"
  local f
  f="$COMPOSER_DIR/$(sanitize "$t")"
  : > "$f"
  local s
  for s in "$@"; do printf '%s\n' "$s" >> "$f"; done
}

# Fake fm-backend.sh: meta helpers plus scripted composer/send/capture. It reads
# COMPOSER_DIR and appends every send to BACKEND_LOG.
cat > "$REPO/bin/fm-backend.sh" <<'SH'
#!/usr/bin/env bash
fm_meta_get() { grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
fm_backend_of_meta() { local v; v=$(fm_meta_get "$1" backend); printf '%s' "${v:-tmux}"; }
fm_backend_target_of_meta() {
  local meta=$1 backend terminal window
  backend=$(fm_backend_of_meta "$meta")
  if [ "$backend" = orca ]; then
    terminal=$(fm_meta_get "$meta" terminal)
    [ -n "$terminal" ] && { printf '%s' "$terminal"; return 0; }
  fi
  window=$(fm_meta_get "$meta" window)
  [ -n "$window" ] && printf '%s' "$window"
}
_fst_san() { printf '%s' "$1" | tr ':/' '__'; }
# Emulate the herdr adapter's fm_backend_herdr_parse_target: a herdr target is
# "<session>:<workspace>:<pane>" and it splits on the FIRST colon only, using
# the leading field as the herdr --session. Our fake live panes all live under
# the "default" session, so a herdr target whose first field is not "default"
# is a target that was NOT passed verbatim (e.g. a "default:"-stripped id) and
# reads unknown, exactly as real herdr would return pane_not_found. tmux targets
# are opaque here and always resolve.
_fst_herdr_bad_target() {  # <backend> <target> -> 0 when herdr and NOT default:*
  [ "$1" = herdr ] || return 1
  case "$2" in default:*) return 1 ;; *) return 0 ;; esac
}
fm_backend_composer_state() {  # <backend> <target>
  local target=$2 f line
  _fst_herdr_bad_target "$1" "$target" && { printf 'unknown'; return 0; }
  f="$COMPOSER_DIR/$(_fst_san "$target")"
  [ -f "$f" ] || { printf 'empty'; return 0; }
  line=$(head -1 "$f")
  # consume the first line so the next call sees the following state
  sed -i '1d' "$f" 2>/dev/null || tail -n +2 "$f" > "$f.n" && mv "$f.n" "$f" 2>/dev/null || true
  printf '%s' "${line:-empty}"
}
fm_backend_send_key() {  # <backend> <target> <key>
  printf 'send_key %s %s %s\n' "$1" "$2" "$3" >> "$BACKEND_LOG"
}
fm_backend_send_text_submit() {  # <backend> <target> <text> ...
  printf 'send_text %s %s %s\n' "$1" "$2" "$3" >> "$BACKEND_LOG"
  printf 'empty'
}
fm_backend_capture() {  # <backend> <target> <lines>
  printf 'capture %s %s\n' "$1" "$2" >> "$BACKEND_LOG"
  echo "stub pane content"
}
SH

export COMPOSER_DIR BACKEND_LOG
# Skip real waits.
export FM_SWITCH_SEND_SETTLE=0 FM_SWITCH_CONFIRM_WAIT=0 FM_SWITCH_CLEAR_SETTLE=0

run_switch() {  # <args...> -> sets OUT / RC
  : > "$BACKEND_LOG"
  OUT=$(cd "$REPO" && ./bin/fm-switch-account.sh "$@" 2>&1)
  RC=$?
}

# --- case 1: no-args discovery lists the recorded targets verbatim ------------
# herdr-backed metas keep their full "default:<ws>:<pane>" id (the adapter needs
# it verbatim). bravo omits backend= so it resolves to tmux (P1 compat).
fm_write_meta "$REPO/state/alpha.meta" "backend=herdr" "window=default:w1:p2" "project=alpha"
fm_write_meta "$REPO/state/bravo.meta" "window=w2:p3" "project=bravo"
fm_write_meta "$REPO/state/.lavish-lan.meta" "port=4388" "bind=0.0.0.0" "target=4387"

run_switch claude-2
expect_code 0 "$RC" "no-args discovery must exit 0 with a windowless meta present"
assert_contains "$OUT" "in 2 pane(s)" "discovery must find exactly the two windowed panes"
assert_contains "$OUT" "default:w1:p2" "discovery must keep the herdr target verbatim (adapter splits on the first colon)"
assert_contains "$OUT" "w2:p3" "discovery must include the second windowed pane"
assert_not_contains "$OUT" "no target panes" "discovery must not report an empty target set"
pass "no-args discovery lists windowed panes verbatim and skips a windowless meta"

# --- case 2: each discovered target is sent on its recorded backend -----------
# alpha resolves to herdr with its FULL id (default:w1:p2), bravo has no
# backend= so it resolves to tmux (P1 compat) and keeps its full id.
run_switch claude-2
assert_grep "send_text herdr default:w1:p2 /account claude switch claude-2" "$BACKEND_LOG" "herdr meta must be sent on herdr with its verbatim id"
assert_grep "send_text tmux w2:p3 /account claude switch claude-2" "$BACKEND_LOG" "backendless meta must be sent on tmux"
pass "each discovered target is sent on its recorded backend"

# --- case 3: an empty composer is sent the switch command normally ------------
set_composer "default:w1:p2" empty
set_composer "w2:p3" empty
run_switch claude-2
expect_code 0 "$RC" "empty composers must exit 0"
assert_grep "send_text herdr default:w1:p2 /account claude switch claude-2" "$BACKEND_LOG" "empty composer must receive the switch"
assert_no_grep "send_key" "$BACKEND_LOG" "an empty composer must never get an Escape"
pass "an empty composer is sent the switch command with no Escape"

# --- case 3b: REGRESSION - a live herdr composer must NOT read unknown ---------
# The bug this task fixes: the script stripped "default:" from the herdr target,
# leaving "w1:p2", which the adapter read as session=w1 pane=p2 and rejected,
# so every live jcode composer probed `unknown` and the whole fleet was skipped
# with zero switched. The fake backend above emulates that same first-colon
# split, so a stripped target would read unknown here too. Assert the live
# herdr pane is actually switched (verbatim target reaches the send path) and
# is never reported skipped-as-unknown.
set_composer "default:w1:p2" empty
set_composer "w2:p3" empty
run_switch claude-2
assert_grep "send_text herdr default:w1:p2 /account claude switch claude-2" "$BACKEND_LOG" "a live herdr composer must actually be switched, not skipped as unknown"
assert_not_contains "$OUT" "default:w1:p2: SKIPPED" "a live herdr composer must never be skipped as unknown (the stripped-target regression)"
pass "a live herdr composer is switched, never skipped unknown from a mangled target"

# --- case 4: a pending composer gets Escape-cleared then sent -----------------
# First read pending, Escape, second read empty -> proceed.
set_composer "default:w1:p2" pending empty
set_composer "w2:p3" empty
run_switch claude-2
expect_code 0 "$RC" "an Escape-clearable pending composer must exit 0"
assert_grep "send_key herdr default:w1:p2 Escape" "$BACKEND_LOG" "a pending composer must get one Escape"
assert_grep "send_text herdr default:w1:p2 /account claude switch claude-2" "$BACKEND_LOG" "a cleared composer must then be sent the switch"
pass "a pending composer is Escape-cleared before the switch is sent"

# --- case 5: a stubbornly-pending composer is SKIPPED, never garbled ----------
# pending on both reads (Escape did not clear) -> skip, no send.
set_composer "default:w1:p2" pending pending
set_composer "w2:p3" empty
run_switch claude-2
expect_code 0 "$RC" "a stubborn pending pane must not fail the run"
assert_grep "send_key herdr default:w1:p2 Escape" "$BACKEND_LOG" "the stubborn pane must still have been Escape-tried once"
assert_contains "$OUT" "SKIPPED" "a stubborn pending pane must be reported skipped"
assert_no_grep "send_text herdr default:w1:p2 " "$BACKEND_LOG" "a stubborn pending pane must never be sent the switch"
assert_grep "send_text tmux w2:p3 /account claude switch claude-2" "$BACKEND_LOG" "the other pane must still be switched"
pass "a stubbornly-pending composer is skipped, never garbled"

# --- case 6: an unknown composer state is SKIPPED, never blind-injected -------
set_composer "default:w1:p2" unknown
set_composer "w2:p3" empty
run_switch claude-2
expect_code 0 "$RC" "an unknown pane must not fail the run"
assert_contains "$OUT" "SKIPPED" "an unknown composer must be reported skipped"
assert_no_grep "send_text herdr default:w1:p2 " "$BACKEND_LOG" "an unknown composer must never be injected into"
assert_grep "send_text tmux w2:p3 /account claude switch claude-2" "$BACKEND_LOG" "the healthy pane must still be switched"
pass "an unknown composer state is skipped, never blind-injected"

# --- case 7: explicit pane-id args bypass discovery and use herdr -------------
# Explicit ids have no meta, so they keep the historical herdr assumption and
# are used verbatim. Per the fixed contract they must be the full
# "<session>:<workspace>:<pane>" form the adapter needs (the same value meta
# records in window=), so the fake backend's first-colon split resolves them.
set_composer "default:wX:p9" empty
set_composer "default:wY:p1" empty
run_switch claude-4 default:wX:p9 default:wY:p1
expect_code 0 "$RC" "explicit pane args must exit 0"
assert_contains "$OUT" "in 2 pane(s)" "explicit args must target exactly the given panes"
assert_grep "send_text herdr default:wX:p9 /account claude switch claude-4" "$BACKEND_LOG" "explicit pane default:wX:p9 must be targeted on herdr"
assert_grep "send_text herdr default:wY:p1 /account claude switch claude-4" "$BACKEND_LOG" "explicit pane default:wY:p1 must be targeted on herdr"
assert_no_grep "default:w1:p2" "$BACKEND_LOG" "explicit args must not fall back to discovered panes"
pass "explicit pane-id args bypass discovery and use herdr"

# --- case 8: a state/ with zero windowed metas reports no targets and exits 1 -
EMPTY="$TMPROOT/empty"
mkdir -p "$EMPTY/bin" "$EMPTY/state"
cp "$SRC" "$EMPTY/bin/fm-switch-account.sh"
chmod +x "$EMPTY/bin/fm-switch-account.sh"
cp "$REPO/bin/fm-backend.sh" "$EMPTY/bin/fm-backend.sh"
fm_write_meta "$EMPTY/state/.lavish-lan.meta" "port=4388" "bind=0.0.0.0"
OUT=$(cd "$EMPTY" && ./bin/fm-switch-account.sh claude-2 2>&1); RC=$?
expect_code 1 "$RC" "a state dir with no windowed metas must exit 1"
assert_contains "$OUT" "no target panes found" "empty discovery must report no target panes"
pass "no windowed metas reports no targets and exits 1"

# --- case 9: a missing label exits 2 with usage -------------------------------
OUT=$(cd "$REPO" && ./bin/fm-switch-account.sh 2>&1); RC=$?
expect_code 2 "$RC" "a missing label must exit 2"
assert_contains "$OUT" "usage:" "a missing label must print usage"
pass "a missing label argument exits 2 with usage"

# --- case 10: no stray e_* files left in the repo root ------------------------
strays=""
for f in "$REPO"/e_*; do
  [ -e "$f" ] && strays="$strays $(basename "$f")"
done
[ -z "$strays" ] || fail "run left stray stderr files in repo root:$strays"
pass "no stray e_* stderr files are created"

pass "fm-switch-account.sh: all checks passed"
