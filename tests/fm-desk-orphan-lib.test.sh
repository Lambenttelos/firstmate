#!/usr/bin/env bash
# Behavior tests for the leaked-fm-desk-orphan detector (bin/fm-desk-orphan-lib.sh).
#
# THE LEAK: a no-mistakes validation run of the desk crate can leave the
# interactive fm-desk alive after its worktree is deleted, spinning at 100% CPU
# and ignoring SIGTERM. The desk crate's hangup guard closes the leak at its
# source; this detector is the cheap belt that flags any orphan that still slips
# through so it cannot hide for five days again.
#
# Every assertion drives the library's executable interface (the classifier and
# the diagnostic function) over a FAKE /proc built from real symlinks - never the
# script's source bytes. The FM_DESK_ORPHAN_PROC_ROOT seam points the scan at
# that fixture so the exe-path logic is exercised without a live orphan. One case
# also builds a REAL fm-desk-named binary whose file is unlinked while it runs,
# proving the classifier reads the actual kernel "(deleted)" suffix, not a string
# baked into the fixture.
#
# The cases pin the safety-critical distinctions:
#   - an orphan (deleted exe under .no-mistakes/worktrees) IS flagged;
#   - a healthy captain desk (real repo path) is NOT flagged;
#   - a rebuilt-but-live desk (deleted exe but REAL repo path, the in-place
#     `cargo build` case) is NOT flagged - deleted-alone is not the test;
#   - a non-desk process is NOT flagged (never a name match);
#   - the diagnostic is silent when there are no orphans and names exact PIDs and
#     the kill -9 remedy when there are.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-desk-orphan-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-desk-orphan-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-desk-orphan)

# fake_proc <dir>: build a fake /proc from rows of "pid|exe-target". Each becomes
# <dir>/<pid>/exe -> <target>. The target strings mirror what readlink returns:
# the kernel appends " (deleted)" to an unlinked binary's exe link.
fake_proc() {
  local root=$1 pid target
  shift
  while IFS='|' read -r pid target; do
    [ -n "$pid" ] || continue
    mkdir -p "$root/$pid"
    ln -s "$target" "$root/$pid/exe"
  done
}

# --- classifier: the four cases the safety of this detector rests on ---------

test_classifier() {
  local proc="$TMP_ROOT/proc-classify"
  rm -rf "$proc"
  fake_proc "$proc" <<'ROWS'
111|/home/x/.no-mistakes/worktrees/abc/RUN/desk/target/release/fm-desk (deleted)
222|/home/x/Repos/firstmate/desk/target/release/fm-desk
333|/home/x/Repos/firstmate/desk/target/release/fm-desk (deleted)
444|/usr/bin/bash
555|/home/x/.no-mistakes/worktrees/abc/RUN/desk/target/release/fm-desk
ROWS

  FM_DESK_ORPHAN_PROC_ROOT="$proc" fm_desk_orphan_is_leaked 111 \
    || fail "an orphan (deleted exe under .no-mistakes/worktrees) must be flagged"
  FM_DESK_ORPHAN_PROC_ROOT="$proc" fm_desk_orphan_is_leaked 222 \
    && fail "a healthy captain desk (real repo path) must NOT be flagged"
  FM_DESK_ORPHAN_PROC_ROOT="$proc" fm_desk_orphan_is_leaked 333 \
    && fail "a rebuilt-but-live desk (deleted exe, real repo path) must NOT be flagged"
  FM_DESK_ORPHAN_PROC_ROOT="$proc" fm_desk_orphan_is_leaked 444 \
    && fail "a non-desk process must NOT be flagged (never a name match)"
  # A deleted fm-desk under a validation worktree is the orphan; a NON-deleted
  # fm-desk under one (a run mid-flight) is not yet leaked and must not be flagged.
  FM_DESK_ORPHAN_PROC_ROOT="$proc" fm_desk_orphan_is_leaked 555 \
    && fail "a non-deleted desk under a worktree must NOT be flagged"
  pass "classifier flags only a deleted fm-desk under a deleted validation worktree"
}

# --- real kernel signal: not a fixture string ------------------------------

# Prove the classifier reads the ACTUAL "(deleted)" suffix the kernel produces,
# by unlinking a running binary's own file and pointing the scan at real /proc.
# This is the harness-independent proof that the exe-path signal is real.
test_real_deleted_exe() {
  command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || {
    echo "skip: no C compiler for the real-deleted-exe case"; return 0; }
  local cc; cc=$(command -v cc || command -v gcc)
  # A binary NAMED fm-desk placed under a fake .no-mistakes validation worktree,
  # so its real /proc exe link matches the orphan signature once unlinked.
  local wt="$TMP_ROOT/live/.no-mistakes/worktrees/abc/RUN/desk/target/release"
  mkdir -p "$wt"
  printf 'int main(void){ for(;;){ } }\n' > "$TMP_ROOT/spin.c"
  "$cc" -o "$wt/fm-desk" "$TMP_ROOT/spin.c" 2>/dev/null \
    || { echo "skip: could not build the spin stand-in"; return 0; }
  local exe_real; exe_real=$(readlink -f "$wt/fm-desk")
  "$wt/fm-desk" & local pid=$!
  # The unlink must not race the child's execve: removing the file first makes
  # the exec fail with ENOENT instead of producing a deleted-exe process, so
  # wait until the kernel's exe link resolves to the built binary.
  local tries=0
  until [ "$(readlink "/proc/$pid/exe" 2>/dev/null)" = "$exe_real" ]; do
    tries=$((tries + 1))
    if [ "$tries" -ge 100 ]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      echo "skip: spin stand-in never reached exec"
      return 0
    fi
    sleep 0.05
  done
  # Unlink the binary out from under the running process (what worktree deletion
  # does), then confirm the classifier sees the kernel's "(deleted)" exe.
  rm -f "$wt/fm-desk"
  local ok=1
  fm_desk_orphan_is_leaked "$pid" || ok=0
  # Also prove it appears in the pid enumeration and the diagnostic.
  local pids diag
  pids=$(fm_desk_orphan_pids)
  printf '%s\n' "$pids" | grep -qx "$pid" || ok=0
  diag=$(fm_desk_orphan_diagnostic)
  kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  [ "$ok" = 1 ] || fail "a really-unlinked fm-desk under a worktree must be flagged as an orphan"
  assert_contains "$diag" "DESK_ORPHAN:" "the diagnostic must carry the DESK_ORPHAN label"
  assert_contains "$diag" "$pid" "the diagnostic must name the exact orphan PID"
  assert_contains "$diag" "kill -9" "the diagnostic must give the SIGKILL remedy (orphans ignore SIGTERM)"
  pass "the classifier reads the real kernel (deleted) exe and the diagnostic names the PID + kill -9"
}

# --- diagnostic: silent when clean -----------------------------------------

test_diagnostic_silent_when_clean() {
  local proc="$TMP_ROOT/proc-clean"
  rm -rf "$proc"
  fake_proc "$proc" <<'ROWS'
222|/home/x/Repos/firstmate/desk/target/release/fm-desk
444|/usr/bin/bash
ROWS
  local out
  out=$(FM_DESK_ORPHAN_PROC_ROOT="$proc" fm_desk_orphan_diagnostic)
  [ -z "$out" ] || fail "the diagnostic must be silent when there are no orphans (got: $out)"
  pass "the diagnostic is silent for a healthy fleet (a live desk, a non-desk process)"
}

test_classifier
test_real_deleted_exe
test_diagnostic_silent_when_clean

echo "all fm-desk-orphan tests passed"
