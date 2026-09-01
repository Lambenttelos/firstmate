#!/usr/bin/env bash
# Behavior tests for the compiled desk (desk/ crate) and its launcher bin/fm-desk.
#
# Every assertion drives an executable interface - the launcher's build/exec
# contract and the binary's terminal behavior over a real pty - never source
# bytes. The WP-2 acceptance gates proven here:
#   - non-tty / TERM=dumb invocation degrades to the static board and touches no
#     terminal modes (no alternate-screen control code emitted);
#   - an interactive run enters the alternate screen and quits cleanly on q,
#     leaving the alternate screen (terminal restored);
#   - SIGINT, SIGHUP (SSH disconnect), and a panic each restore the terminal;
#   - the launcher builds when the binary is missing/stale and reuses it after.
#
# The `w` switch button's plane wiring is proven here too: the desk must invoke
# the switch helper with `--plane jcode` (the plane the fleet runs on), and must
# then surface the restart-to-apply affordance, because a jcode-plane switch
# rewrites ~/.jcode/auth.json and cannot reach an already-live session.
#
# Rust here is NOT on PATH (toolchain under ~/.rustup, ~/.cargo/bin absent), so
# the test resolves the toolchain the same way the launcher does and SKIPS
# cleanly when no cargo is reachable, matching CI on a box without Rust.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

TOOLCHAIN_BIN="$HOME/.rustup/toolchains/1.96.1-x86_64-unknown-linux-gnu/bin"
if [ -x "$TOOLCHAIN_BIN/cargo" ]; then
  export PATH="$TOOLCHAIN_BIN:$PATH"
elif ! command -v cargo >/dev/null 2>&1; then
  echo "skip: cargo not found (Rust toolchain absent)"
  exit 0
fi
export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"

LAUNCHER="$ROOT/bin/fm-desk"
BIN="$ROOT/desk/target/release/fm-desk"

# Build once up front. If the cache cannot satisfy an offline+locked build (a box
# without the crates cached), skip rather than fail - the offline-cache
# availability is an environment fact, not a code regression this suite owns.
if [ ! -x "$BIN" ]; then
  if ! (cd "$ROOT/desk" && cargo build --release --offline --locked) >/dev/null 2>&1; then
    echo "skip: desk crate could not build offline from cache"
    exit 0
  fi
fi

# Drive the launcher under a real pty and report, for one invocation, whether the
# alternate screen was entered and left. Args: env-KEY=VAL pairs, then optional
# --key <bytes> or --signal <SIG>. Prints: "entered=<0|1> left=<0|1> exit=<n>".
pty_run() {
  python3 - "$@" <<'PY'
import os, pty, time, select, signal, sys, fcntl, termios, struct
args = sys.argv[1:]
env = dict(os.environ)
key = None
sig = None
keys = []
dump = None
i = 0
while i < len(args):
    a = args[i]
    if a == "--key":
        key = args[i+1].encode(); i += 2
    elif a == "--keys":
        keys = [k.encode() for k in args[i+1].split(",")]; i += 2
    elif a == "--dump":
        dump = args[i+1]; i += 2
    elif a == "--signal":
        sig = getattr(signal, args[i+1]); i += 2
    elif "=" in a:
        k, v = a.split("=", 1); env[k] = v; i += 1
    else:
        i += 1
launcher = env["FM_DESK_LAUNCHER"]
master, slave = pty.openpty()
# A freshly opened pty has a 0x0 window, which makes a full-screen TUI paint
# nothing at all. Give it a real size so the captured bytes contain the frames
# a captain would actually see.
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 100, 0, 0))
pid = os.fork()
if pid == 0:
    os.setsid()
    os.dup2(slave, 0); os.dup2(slave, 1); os.dup2(slave, 2); os.close(master)
    os.execvpe("bash", ["bash", launcher], env)
    os._exit(127)
os.close(slave)
out = b""
time.sleep(1.2)
r, _, _ = select.select([master], [], [], 0.5)
if r:
    try: out += os.read(master, 65536)
    except OSError: pass
if key: os.write(master, key)
for k in keys:
    # Drain between keystrokes so each phase is painted before the next key,
    # and so the captured output contains every intermediate frame.
    deadline_k = time.time() + 1.0
    while time.time() < deadline_k:
        r, _, _ = select.select([master], [], [], 0.2)
        if not r:
            continue
        try: c = os.read(master, 65536)
        except OSError: break
        if not c: break
        out += c
    os.write(master, k)
if sig: os.kill(pid, sig)
deadline = time.time() + 5
while time.time() < deadline:
    r, _, _ = select.select([master], [], [], 0.3)
    if r:
        try: c = os.read(master, 65536)
        except OSError: break
        if not c: break
        out += c
    try:
        w, st = os.waitpid(pid, os.WNOHANG)
        if w: break
    except ChildProcessError:
        break
try: w, st = os.waitpid(pid, 0)
except ChildProcessError: st = 0
os.close(master)
if dump:
    with open(dump, "wb") as f:
        f.write(out)
entered = 1 if b"\x1b[?1049h" in out else 0
left = 1 if b"\x1b[?1049l" in out else 0
code = os.WEXITSTATUS(st) if os.WIFEXITED(st) else 128 + (os.WTERMSIG(st) if os.WIFSIGNALED(st) else 0)
print(f"entered={entered} left={left} exit={code}")
PY
}

export FM_DESK_LAUNCHER="$LAUNCHER"

# A fast fake static board so the degradation cases are not gated on the real
# projection (~21s). The launcher's non-tty fallback shells out to FM_DESK_STATIC
# with --once; this stand-in proves the wiring and the no-takeover property
# without the cost. The real board's own behavior is covered by
# tests/fm-desk-tui.test.sh.
FAKE_STATIC_DIR="$(fm_test_tmproot fm-desk-app)"
mkdir -p "$FAKE_STATIC_DIR"
FAKE_STATIC="$FAKE_STATIC_DIR/fake-static.sh"
cat > "$FAKE_STATIC" <<'SH'
#!/usr/bin/env bash
echo "Captain's Desk (fake static board) $*"
SH
chmod 755 "$FAKE_STATIC"

# 1. Non-tty degradation: piped stdout must print the static board and NEVER emit
#    the alternate-screen control code.
OUT=$(TERM=xterm FM_DESK_STATIC="$FAKE_STATIC" "$LAUNCHER" </dev/null 2>/dev/null | tr -d '\0')
printf '%s' "$OUT" | grep -q "Captain" \
  || fail "non-tty invocation did not print the static desk"
printf '%s' "$OUT" | grep -q $'\x1b\[?1049h' \
  && fail "non-tty invocation emitted the alternate-screen control code"
pass "non-tty invocation degrades to the static board, no terminal takeover"

# 2. TERM=dumb on a real pty must also degrade (static board, no alt screen).
R=$(pty_run TERM=dumb FM_DESK_STATIC="$FAKE_STATIC")
echo "$R" | grep -q "entered=0" || fail "TERM=dumb entered the alternate screen ($R)"
pass "TERM=dumb degrades to the static board on a pty"

# 3. Interactive quit on q: enters and leaves the alternate screen, exit 0.
R=$(pty_run TERM=xterm-256color --key q)
echo "$R" | grep -q "entered=1 left=1 exit=0" \
  || fail "quit-on-q did not enter+restore cleanly ($R)"
pass "interactive run quits on q and restores the terminal"

# 4. SIGINT restores the terminal.
R=$(pty_run TERM=xterm-256color --signal SIGINT)
echo "$R" | grep -q "entered=1 left=1" \
  || fail "SIGINT did not restore the terminal ($R)"
pass "SIGINT restores the terminal"

# 5. SIGHUP (SSH disconnect) restores the terminal.
R=$(pty_run TERM=xterm-256color --signal SIGHUP)
echo "$R" | grep -q "entered=1 left=1" \
  || fail "SIGHUP did not restore the terminal ($R)"
pass "SIGHUP (SSH disconnect) restores the terminal"

# 6. A panic restores the terminal (via the panic hook) - proven with the
#    FM_DESK_PANIC_TEST seam, and the process exits non-zero (101).
R=$(pty_run TERM=xterm-256color FM_DESK_PANIC_TEST=1)
echo "$R" | grep -q "entered=1 left=1 exit=101" \
  || fail "panic did not restore the terminal / wrong exit ($R)"
pass "panic restores the terminal and exits non-zero"

# 7. Launcher rebuilds a stale binary, then reuses it.
touch "$ROOT/desk/src/main.rs"
ERR1=$("$LAUNCHER" </dev/null 2>&1 >/dev/null)
echo "$ERR1" | grep -q "building release" \
  || fail "launcher did not rebuild after a source change"
ERR2=$("$LAUNCHER" </dev/null 2>&1 >/dev/null)
echo "$ERR2" | grep -q "building release" \
  && fail "launcher rebuilt when the binary was already fresh"
pass "launcher builds a stale binary then reuses the fresh one"

# 8. The switch button acts on the JCODE plane, and the desk then tells the
#    captain to restart. Drive the real binary over a pty: w opens the overlay,
#    1 picks the seeded account, y confirms. A recorder stands in for the switch
#    helper (FM_DESK_SWITCH_CMD), so no real credential is touched, and it
#    captures the exact argument vector the desk passed.
SW_TMP="$(fm_test_tmproot fm-desk-app-switch)"
mkdir -p "$SW_TMP"
MODEL_JSON="$SW_TMP/model.json"
cat > "$MODEL_JSON" <<'JSON'
{
  "schema": "fm-desk.v1",
  "now": "2026-08-25 09:00:00 UTC",
  "away": false,
  "health": { "beat_age_seconds": 5 },
  "header": {
    "summary": "nothing needs your word.",
    "accounts": {
      "caption": "Claude accounts (configured store)",
      "lines": ["1 captain@example.test  5h 12%"],
      "accounts": [ { "email": "captain@example.test" } ]
    }
  },
  "gaps": [],
  "sections": {
    "captains_call": { "status": "ok", "total": 0, "full_total": 0, "shown": 0, "more": 0, "more_hint": "", "rows": [] },
    "under_way": { "status": "ok", "total": 0, "full_total": 0, "shown": 0, "more": 0, "more_hint": "", "rows": [] },
    "charted": { "status": "ok", "total": 0, "full_total": 0, "shown": 0, "more": 0, "more_hint": "", "rows": [] },
    "landed": { "status": "ok", "total": 0, "full_total": 0, "shown": 0, "more": 0, "more_hint": "", "rows": [] },
    "merge": { "total": 0, "full_total": 0, "shown": 0, "more": 0, "more_hint": "", "rows": [] },
    "secondmates": { "status": "ok", "total": 0, "full_total": 0, "shown": 0, "more": 0, "more_hint": "", "rows": [] }
  }
}
JSON

ARGS_LOG="$SW_TMP/switch-args.txt"
RECORDER="$SW_TMP/recorder.sh"
cat > "$RECORDER" <<SH
#!/usr/bin/env bash
# Stand-in for bin/fm-claude-switch.sh: record the exact argv, change nothing.
printf '%s\n' "\$*" >> '$ARGS_LOG'
exit 0
SH
chmod 755 "$RECORDER"

SW_DUMP="$SW_TMP/pty.out"
R=$(pty_run TERM=xterm-256color \
  FM_DESK_MODEL="$MODEL_JSON" \
  FM_DESK_SWITCH_CMD="$RECORDER" \
  --keys "w,1,y,q" --dump "$SW_DUMP")

[ -s "$ARGS_LOG" ] || fail "the desk never invoked the switch helper ($R)"
SW_ARGS=$(cat "$ARGS_LOG")
case "$SW_ARGS" in
  *"captain@example.test --plane jcode"*) : ;;
  *) fail "the switch helper was not called with --plane jcode: [$SW_ARGS]" ;;
esac
case "$SW_ARGS" in
  *"--plane both"* | *"--plane cswap"*)
    fail "the switch helper was called on the wrong plane: [$SW_ARGS]"
    ;;
esac
pass "the desk switch button invokes the helper with --plane jcode"

# The exact flag must still exist in the helper's own contract - assert against
# its LIVE --help so a renamed or removed flag fails here rather than silently
# switching nothing.
SW_HELP=$("$ROOT/bin/fm-claude-switch.sh" --help 2>&1 || true)
printf '%s' "$SW_HELP" | grep -q -- "--plane both|cswap|jcode" \
  || fail "fm-claude-switch.sh --help no longer documents --plane both|cswap|jcode"
pass "fm-claude-switch.sh still supports the --plane jcode flag the desk passes"

# The restart-to-apply affordance must reach the captain's screen after the
# switch lands. Read it out of the captured pty bytes (ANSI stripped).
SW_TEXT=$(python3 - "$SW_DUMP" <<'PY'
import re, sys
raw = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
print(re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", raw))
PY
)
printf '%s' "$SW_TEXT" | grep -q "Restart to apply" \
  || fail "the desk did not surface the restart-to-apply affordance after the switch"
printf '%s' "$SW_TEXT" | grep -q "keep the old account until restarted" \
  || fail "the desk did not state that running sessions keep the old account"
pass "the desk surfaces restart-to-apply after a jcode-plane switch"

# 9. THE ORPHAN-LEAK REGRESSION (the reason this task exists). A validation run
#    starts the interactive desk, then its worktree is deleted - modeled here by
#    closing the pty master out from under a running interactive desk. Without
#    the hangup guard the desk busy-loops at 100% CPU forever and ignores
#    SIGTERM (an orphan); with it, the desk exits on its own. This drives the
#    SAME real binary both ways via the FM_DESK_DISABLE_HANGUP_GUARD seam, so it
#    is a genuine break-and-restore proof, not two different builds.
#
# hangup_probe <extra-env...> -> prints "state=<X|Z|gone> cpu=<ticks/0.6s>".
#   state=gone: the desk exited on its own after the tty hung up (fixed).
#   state=R with cpu~=60: the desk is spinning (the leak).
hangup_probe() {
  python3 - "$@" <<'PY'
import os, pty, time, signal, sys, fcntl, termios, struct
env = dict(os.environ)
for a in sys.argv[1:]:
    if "=" in a:
        k, v = a.split("=", 1); env[k] = v
launcher = env["FM_DESK_LAUNCHER"]
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 100, 0, 0))
pid = os.fork()
if pid == 0:
    os.setsid()
    os.dup2(slave, 0); os.dup2(slave, 1); os.dup2(slave, 2); os.close(master)
    os.execvpe("bash", ["bash", launcher], env)
    os._exit(127)
os.close(slave)
# Let it enter the interactive alternate-screen loop.
time.sleep(1.5)
try: os.read(master, 65536)
except OSError: pass
# The worktree/terminal goes away: hang up the pty.
os.close(master)
# The guard must break the loop WITHOUT any signal. Give it a moment.
time.sleep(0.6)
w, _ = os.waitpid(pid, os.WNOHANG)
if w:
    print("state=gone cpu=0"); sys.exit(0)
# Still alive: is it spinning (the leak) and does it ignore SIGTERM?
def sample():
    p = open(f"/proc/{pid}/stat").read().split()
    return int(p[13]) + int(p[14]), p[2]
os.kill(pid, signal.SIGTERM)  # the orphans ignore this
time.sleep(0.3)
a, st = sample(); time.sleep(0.6); b, _ = sample()
print(f"state={st} cpu={b-a}")
os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0)
PY
}

# 9a. Guard DISABLED: the leak must reproduce (proves the test is not vacuous and
#     that the guard is the thing that matters).
R=$(hangup_probe TERM=xterm-256color FM_DESK_DISABLE_HANGUP_GUARD=1)
echo "$R" | grep -q "state=R" \
  || fail "with the guard disabled, a hung-up terminal should leave a spinning orphan ($R)"
pass "orphan leak reproduces on a hung-up terminal when the guard is disabled"

# 9b. Guard ENABLED (normal): the desk exits on its own, no orphan, no signal.
R=$(hangup_probe TERM=xterm-256color)
echo "$R" | grep -q "state=gone" \
  || fail "the hangup guard must make the desk exit itself on a torn-down terminal ($R)"
pass "the hangup guard closes the orphan leak: the desk exits when its terminal is torn down"

echo "all fm-desk-app tests passed"
