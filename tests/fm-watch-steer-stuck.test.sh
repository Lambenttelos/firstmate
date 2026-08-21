#!/usr/bin/env bash
# tests/fm-watch-steer-stuck.test.sh - Visibility Gap-4, the watcher's
# steer-stuck check (bin/fm-watch.sh steer_stuck_check), which surfaces a
# delivered-but-never-processed steer. Design:
# data/design-visibility-improvements/report.md "Gap 4".
#
# Contract pinned here:
#   1. A FRESH steer whose pane hash has NOT advanced and whose pane is NOT busy
#      fires a steer-aware variant of the EXISTING stale wake
#      (`stale: <window> (steer delivered <age>s ago, pane never processed it -
#      possible stuck composer)`) and sets composer_stuck=1 in
#      state/<id>.telemetry, once per steer (a .steer-stuck-<key> marker holds
#      the warned-for last_steer_ts, so a repeat poll on the same stuck steer
#      does not re-wake).
#   2. A busy pane clears composer_stuck (the steer is being processed).
#   3. A hash ADVANCE clears composer_stuck (the pane produced new output since
#      the steer - it was not stuck), and a pane that processed its steer stays
#      quiet on a later idle poll (the persisted baseline prevents a rebaseline
#      false positive).
#   4. No recorded steer never wakes and never writes composer_stuck.
#   5. An aged-out steer (past FM_STEER_STUCK_WINDOW) clears the flag and drops
#      its tracking files, so a long-idle healthy pane never trips it.
#   6. The stuck flag sets WITHOUT clobbering sibling telemetry keys.
#   7. steer_stuck_check adds NO backend capture to the fast loop: it consumes
#      the stale loop's already-captured tail40/hash/prev as arguments and its
#      body contains no fm_backend_capture, so the loop keeps exactly one
#      capture per window.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
assert_present "$WATCH" "bin/fm-watch.sh is missing"

# fm_meta_get reads the key=value telemetry file the check writes.
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

TMP=$(fm_test_tmproot fm-watch-steer-stuck)
STATE="$TMP/state"
mkdir -p "$STATE"

W="default:w1:p2"
TASK="steertask"
KEY=$(printf '%s' "$W" | tr ':/.' '___')
TEL="$STATE/$TASK.telemetry"
IDLE_TAIL=$'some idle text\n> no busy footer'
BUSY_TAIL=$'some content\nWorking...'
HASH=abc123def456
OTHER_HASH=fff999aaa

# run_check <tail> <hash> <prev> -> OUT (the wake reason on stdout, or NOWAKE).
# Drive steer_stuck_check in a subshell: source the watcher (its guard returns
# before the lock/loop, loading only functions and libs), override STATE and the
# wake queue path, then call the function. wake() exits 0 after printing its
# reason, so a stuck case ends the subshell with the reason on stdout; a calm
# case returns and we echo a sentinel.
run_check() {  # <tail> <hash> <prev>
  OUT=$(FM_STATE_OVERRIDE="$STATE" FM_WAKE_QUEUE="$STATE/.wake-queue" \
        FM_WAKE_QUEUE_LOCK="$STATE/.wake-queue.lock" bash -c '
        . "'"$WATCH"'" >/dev/null 2>&1
        STATE="'"$STATE"'"
        steer_stuck_check "'"$W"'" "'"$TASK"'" "$1" "$2" "$3"
        echo "NOWAKE"
      ' _ "$1" "$2" "$3" 2>&1)
}

fresh_steer() {
  printf 'last_steer_ts=%s\n' "$(date +%s)" > "$TEL"
}

# --- (1) fresh steer + unchanged hash + idle -> steer-aware stale wake --------
rm -rf "$STATE"; mkdir -p "$STATE"
fresh_steer
run_check "$IDLE_TAIL" "$HASH" "$HASH"
assert_contains "$OUT" "stale: $W" "a stuck steer must surface as an existing stale wake"
assert_contains "$OUT" "possible stuck composer" "the stale wake must carry the steer-stuck reason"
assert_contains "$OUT" "pane never processed it" "the stale wake must explain the pane never processed the steer"
[ "$(fm_meta_get "$TEL" composer_stuck)" = 1 ] || fail "a stuck steer must set composer_stuck=1 in telemetry"
assert_present "$STATE/.steer-stuck-$KEY" "the steer-aware wake must be armed once per steer via its marker"
pass "a fresh steer with an unchanged idle hash fires the steer-aware stale wake and sets composer_stuck=1"

# A repeat poll on the same stuck steer must NOT re-wake (one wake per steer).
run_check "$IDLE_TAIL" "$HASH" "$HASH"
assert_contains "$OUT" "NOWAKE" "a repeat poll on the same stuck steer must not re-wake"
[ "$(fm_meta_get "$TEL" composer_stuck)" = 1 ] || fail "composer_stuck must stay 1 on the repeat stuck poll"
pass "the stuck wake fires once per steer (no re-wake on repeat polls)"

# --- (2) a busy pane clears the stuck flag -----------------------------------
run_check "$BUSY_TAIL" "$HASH" "$HASH"
assert_contains "$OUT" "NOWAKE" "a busy pane must NOT wake as stuck"
[ "$(fm_meta_get "$TEL" composer_stuck)" = 0 ] || fail "a busy pane must clear composer_stuck to 0"
pass "a busy pane clears composer_stuck=0 without a wake"

# --- (3) a hash advance clears the stuck flag --------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
fresh_steer
printf 'composer_stuck=1\n' >> "$TEL"
run_check "$IDLE_TAIL" "$OTHER_HASH" "$HASH"
assert_contains "$OUT" "NOWAKE" "a hash advance must NOT wake as stuck"
[ "$(fm_meta_get "$TEL" composer_stuck)" = 0 ] || fail "a hash advance must clear composer_stuck to 0"
pass "a hash advance clears composer_stuck=0 without a wake"

# A pane that INSTALLED its steer (hash advanced) is never flagged, and the next
# poll's unchanged NEW hash is not mistaken for stuck: the persisted pre-steer
# baseline holds, so a later idle poll on the new hash cannot rebaseline onto it.
rm -rf "$STATE"; mkdir -p "$STATE"
fresh_steer
run_check "$IDLE_TAIL" "$OTHER_HASH" "$HASH"          # first poll: hash advanced vs pre-steer
assert_contains "$OUT" "NOWAKE" "a pane that processed its steer must never wake"
run_check "$IDLE_TAIL" "$OTHER_HASH" "$OTHER_HASH"    # later idle poll on the new hash
assert_contains "$OUT" "NOWAKE" "an idle post-processing pane must never wake as stuck"
[ "$(fm_meta_get "$TEL" composer_stuck)" != 1 ] || fail "a processed steer must never be flagged composer_stuck=1"
pass "a pane that processed its steer stays quiet (no false stuck on a later idle poll)"

# --- (4) no recorded steer never wakes ---------------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
: > "$TEL"
run_check "$IDLE_TAIL" "$HASH" "$HASH"
assert_contains "$OUT" "NOWAKE" "no recorded steer must never wake"
[ -z "$(fm_meta_get "$TEL" composer_stuck)" ] \
  || fail "no recorded steer must not write composer_stuck"$'\n'"$(cat "$TEL")"
pass "no recorded steer never wakes and writes no composer_stuck"

# --- (5) an aged-out steer clears the flag and drops its tracking -------------
rm -rf "$STATE"; mkdir -p "$STATE"
printf 'last_steer_ts=1\ncomposer_stuck=1\n' > "$TEL"
printf '1 %s\n' "$HASH" > "$STATE/.steer-baseline-$KEY"
printf '1\n' > "$STATE/.steer-stuck-$KEY"
run_check "$IDLE_TAIL" "$HASH" "$HASH"
assert_contains "$OUT" "NOWAKE" "an aged-out steer must never wake"
[ "$(fm_meta_get "$TEL" composer_stuck)" = 0 ] || fail "an aged-out steer must clear composer_stuck to 0"
assert_absent "$STATE/.steer-baseline-$KEY" "an aged-out steer must drop its baseline file"
assert_absent "$STATE/.steer-stuck-$KEY" "an aged-out steer must drop its warned marker"
pass "an aged-out steer clears the flag and drops its tracking files"

# --- (6) sibling telemetry keys survive the stuck wake ------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
printf 'account=claude-2\ncount_429=7\nlast_steer_ts=%s\n' "$(date +%s)" > "$TEL"
run_check "$IDLE_TAIL" "$HASH" "$HASH"
assert_contains "$OUT" "possible stuck composer" "a fresh stuck steer with sibling keys must still wake"
[ "$(fm_meta_get "$TEL" composer_stuck)" = 1 ] || fail "composer_stuck must be set on the stuck steer"
[ "$(fm_meta_get "$TEL" account)" = claude-2 ] || fail "composer_stuck=1 must NOT clobber account="
[ "$(fm_meta_get "$TEL" count_429)" = 7 ] || fail "composer_stuck=1 must NOT clobber count_429="
pass "the stuck flag sets without clobbering sibling telemetry keys"

# --- (7) ZERO new backend capture in the fast loop ---------------------------
check_body=$(awk '/^steer_stuck_check\(\)/{f=1} f{print} f&&/^}/{exit}' "$WATCH")
if printf '%s' "$check_body" | grep -q 'fm_backend_capture'; then
  fail "steer_stuck_check must add NO fm_backend_capture (it reuses the passed tail40/hash/prev)"
fi
# shellcheck disable=SC2016  # literal grep pattern, no expansion intended.
caps=$(grep -c 'fm_backend_capture "\$(window_backend' "$WATCH" || true)
[ "$caps" = 1 ] || fail "the stale loop must keep exactly one per-window fm_backend_capture, found $caps"
pass "steer_stuck_check adds zero backend captures; the loop keeps its single capture"

pass "fm-watch-steer-stuck.test.sh: all checks passed"
