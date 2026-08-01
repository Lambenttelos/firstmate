#!/usr/bin/env bash
# tests/fm-secondmate-liveness.test.sh - the session-start secondmate LIVENESS
# guarantee: bin/fm-backend.sh's fm_backend_agent_alive probe (dispatching to
# fm_backend_tmux_agent_alive / fm_backend_herdr_agent_alive) and
# bin/fm-bootstrap.sh's secondmate_liveness_sweep() that acts on it.
#
# The gap under test (AGENTS.md "Session start"; evidence 2026-07-07): a
# secondmate agent that has exited leaves its backend endpoint alive as a bare
# shell. fm_backend_target_exists only checks pane PRESENCE, so it reports
# that shell "alive"; recovery only respawns endpoints reported dead, and the
# watcher deliberately exempts secondmates from stale-pane detection (an idle
# secondmate pane is healthy by design). A dead-shell secondmate was therefore
# invisible to every existing check and sat dead indefinitely.
#
# The guarantees under test:
#   - fm_backend_tmux_agent_alive classifies a verified-harness foreground
#     process as alive, a bare shell as dead, and anything ambiguous
#     (including a bare interpreter name) as unknown - never dead.
#   - fm_backend_herdr_agent_alive is a thin wrapper over the already-verified
#     fm_backend_herdr_pane_agent_state husk classifier: dead/no-agent -> dead,
#     live -> alive, unknown -> unknown.
#   - fm_backend_agent_alive routes to the right per-backend classifier and
#     reports unknown for a backend with no verified classifier (never errors).
#   - bin/fm-bootstrap.sh's secondmate_liveness_sweep respawns a confidently
#     DEAD secondmate (killing the stale endpoint first, since the tmux
#     adapter refuses to create a same-named window over a live one), keeps
#     handled DEAD and ALIVE results silent, and never acts on an inconclusive
#     (UNKNOWN) reading.
#   - The sweep converges: once a secondmate reads alive, a later run never
#     re-touches it (idempotent by construction, not by remembering what it
#     already did).
#   - The sweep is skipped entirely under FM_BOOTSTRAP_DETECT_ONLY=1 (the
#     read-only session path), matching the other mutating sweeps.
#   - The sweep is naturally scoped to the primary: with no kind=secondmate
#     meta present (a secondmate's own state/ never holds one, since
#     secondmates never spawn secondmates), it is a silent no-op.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-secondmate-liveness)

# --- unit level: fm_backend_tmux_agent_alive --------------------------------

# make_probe_tmux <dir> <pane_current_command>: a fake tmux whose
# #{pane_current_command} display-message query answers with the fixed value;
# every other subcommand is a silent no-op success.
make_probe_tmux() {
  local dir=$1 comm=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  display-message)
    for a in "\$@"; do case "\$a" in *pane_current_command*) printf '%s\n' '$comm'; exit 0 ;; esac; done
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_tmux_agent_alive_classifies() {
  local fb

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-claude" claude)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = alive ] \
    || fail "a live claude foreground process should classify as alive"

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-codex" codex)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = alive ] \
    || fail "a live codex foreground process should classify as alive"

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-opencode" opencode)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = alive ] \
    || fail "a live opencode foreground process should classify as alive"

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-grok" grok)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = alive ] \
    || fail "a live grok foreground process should classify as alive"

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-zsh" zsh)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = dead ] \
    || fail "a bare zsh foreground process should classify as dead"

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-bash" bash)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = dead ] \
    || fail "a bare bash foreground process should classify as dead"

  # Defensive: this adapter strips a leading login-shell dash even though real
  # tmux 3.6a was observed to already normalize #{pane_current_command} itself
  # (docs/tmux-backend.md "Agent liveness probe").
  fb=$(make_probe_tmux "$TMP_ROOT/tmux-dashzsh" -zsh)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = dead ] \
    || fail "a defensively-stripped login-shell name should still classify as dead"

  # A bare interpreter name is ambiguous (pi's own launcher execs into a
  # generic "node" process - docs/tmux-backend.md "Known gap") - must be
  # unknown, never dead, so the sweep can never respawn on a false-dead read.
  fb=$(make_probe_tmux "$TMP_ROOT/tmux-node" node)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = unknown ] \
    || fail "an ambiguous bare-interpreter (node) foreground process should classify as unknown, never dead"

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-vim" vim)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = unknown ] \
    || fail "an unrecognized foreground process should classify as unknown"

  pass "fm_backend_tmux_agent_alive: alive/dead/unknown classification"
}

# --- unit level: fm_backend_herdr_agent_alive -------------------------------
# Reuses the already-verified fm_backend_herdr_pane_agent_state husk
# classifier (docs/herdr-backend.md "Respawn idempotency" /
# "Agent liveness probe reuses the husk classifier"); this wrapper's own
# mapping logic is tested in isolation by overriding that classifier, exactly
# as tests/fm-backend-herdr.test.sh already overrides `sleep` in a bash -c
# string for the same kind of isolated-unit assertion.

test_herdr_agent_alive_maps_pane_agent_state() {
  local out

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "dead"; }; fm_backend_herdr_agent_alive "sess:p1"' "$ROOT")
  [ "$out" = dead ] || fail "herdr pane_agent_state=dead should map to dead, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "live"; }; fm_backend_herdr_agent_alive "sess:p1"' "$ROOT")
  [ "$out" = alive ] || fail "herdr pane_agent_state=live should map to alive, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "unknown"; }; fm_backend_herdr_agent_alive "sess:p1"' "$ROOT")
  [ "$out" = unknown ] || fail "herdr pane_agent_state=unknown should stay unknown, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_agent_alive "no-colon-target"' "$ROOT")
  [ "$out" = unknown ] || fail "an unparseable target should classify as unknown, got '$out'"

  pass "fm_backend_herdr_agent_alive: dead->dead, live->alive, unknown->unknown"
}

# no-agent is NO LONGER an unconditional dead: herdr never registers a jcode
# agent, so a live jcode secondmate reads no-agent exactly like a dead bare-shell
# husk. The wrapper now corroborates a no-agent pane's content before collapsing
# it to dead (fm_backend_herdr_no_agent_liveness). Test that delegation in
# isolation by overriding the corroboration helper; the content-based classifier
# itself is exercised with real jcode fixtures in tests/fm-backend-herdr.test.sh.
test_herdr_agent_alive_no_agent_delegates_to_content_corroboration() {
  local out

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "no-agent"; }; fm_backend_herdr_no_agent_liveness() { printf "alive"; }; fm_backend_herdr_agent_alive "sess:p1"' "$ROOT")
  [ "$out" = alive ] || fail "no-agent with a live-jcode-content corroboration must read alive, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "no-agent"; }; fm_backend_herdr_no_agent_liveness() { printf "dead"; }; fm_backend_herdr_agent_alive "sess:p1"' "$ROOT")
  [ "$out" = dead ] || fail "no-agent with a bare-shell-content corroboration must stay dead, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "no-agent"; }; fm_backend_herdr_no_agent_liveness() { printf "unknown"; }; fm_backend_herdr_agent_alive "sess:p1"' "$ROOT")
  [ "$out" = unknown ] || fail "no-agent with an unreadable-content corroboration must read unknown (never dead), got '$out'"

  pass "fm_backend_herdr_agent_alive: no-agent delegates to content corroboration (jcode live->alive, husk->dead, unreadable->unknown)"
}

# --- unit level: the generic fm_backend_agent_alive dispatcher --------------

test_agent_alive_dispatcher_routes_and_falls_back() {
  local fb out

  fb=$(make_probe_tmux "$TMP_ROOT/dispatch-tmux" claude)
  out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive tmux sess:win' "$ROOT")
  [ "$out" = alive ] || fail "dispatcher should route tmux to fm_backend_tmux_agent_alive, got '$out'"

  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source herdr; fm_backend_herdr_pane_agent_state() { printf "live"; }; fm_backend_agent_alive herdr sess:p1' "$ROOT")
  [ "$out" = alive ] || fail "dispatcher should route herdr to fm_backend_herdr_agent_alive, got '$out'"

  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive zellij sess:win' "$ROOT")
  [ "$out" = unknown ] || fail "dispatcher should report unknown for a backend with no verified classifier, got '$out'"

  pass "fm_backend_agent_alive: routes tmux/herdr correctly, unknown for an unverified backend"
}

# --- sweep level: bin/fm-bootstrap.sh's secondmate_liveness_sweep -----------

# make_toolchain <dir>: the fixed set of stubs bin/fm-bootstrap.sh's read-only
# diagnostics need to stay quiet (mirrors tests/fm-secondmate-sync.test.sh's
# make_fake_toolchain), MINUS tmux - callers add their own controllable tmux.
make_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" node gh-axi chrome-devtools-axi lavish-axi
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.31.2 (fake)'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf '%s\n' '0.1.1' ;;
  "update --help") printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --archive-body' ;;
  "mv --help") printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$fakebin"
}

# make_liveness_tmux <dir>: a tmux stub whose #{pane_current_command} answer is
# read fresh from $FM_TEST_PANE_CMD on every query (so a test can flip it
# between bootstrap runs), and which logs every new-window/kill-window call
# (the only two operations a respawn performs) to $FM_TMUX_CALL_LOG.
make_liveness_tmux() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *pane_current_command*) printf '%s\n' "${FM_TEST_PANE_CMD:-zsh}"; exit 0 ;; esac; done
    exit 0 ;;
  new-window|kill-window)
    printf '%s\n' "$*" >> "${FM_TMUX_CALL_LOG:?}"
    exit 0 ;;
  list-windows|has-session) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# make_liveness_herdr <dir>: a herdr stub for the sweep's herdr agent-liveness
# path. It answers `status --json` (server running, protocol 14), reports the
# task pane as structurally present (`pane get`), reports agent_not_found for
# `agent get` (herdr NEVER registers a jcode agent - the whole reason a live
# jcode secondmate reads no-agent), and answers `pane read` from a controllable
# $FM_TEST_HERDR_PANE_READ file so a test can make the corroborating content read
# a live jcode composer row or a bare shell. It logs any pane close (a respawn's
# kill step) to $FM_HERDR_CALL_LOG so a test can assert a live secondmate is
# never touched.
make_liveness_herdr() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
# Positional subcommand is "$1 $2" (the trailing "--session <name>" the adapter
# appends does not change the leading two args).
case "${1:-} ${2:-}" in
  "status --json")
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
    exit 0 ;;
  "pane get")
    printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}"
    exit 0 ;;
  "agent get")
    # agent_not_found: exactly what herdr returns for every live jcode pane.
    printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "${3:-}"
    exit 0 ;;
  "pane read")
    [ -f "${FM_TEST_HERDR_PANE_READ:-}" ] && cat "$FM_TEST_HERDR_PANE_READ"
    exit 0 ;;
  "pane close")
    printf '%s\n' "$*" >> "${FM_HERDR_CALL_LOG:?}"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$fakebin"
}

# new_world <name>: a scratch firstmate HOME (state/, watcher beacon, pinned
# harness) with no kind=secondmate meta yet. FM_ROOT is left to resolve
# naturally to the real checkout under test ($ROOT), exactly as production
# always has it - this sweep's own fm-spawn.sh invocation resolves the
# secondmate harness through $FM_ROOT/bin/fm-harness.sh, which only exists in
# the real tree. The harness is pinned because ambient own-harness detection is
# environment-dependent: interactive harness sessions expose markers or parent
# process names, while a plain pipeline shell can fall through to "unknown",
# which has no fm-spawn.sh launch template.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/config"
  touch "$w/home/state/.last-watcher-beat"
  printf 'codex\n' > "$w/home/config/crew-harness"
  printf '%s\n' "$w"
}

# add_sm_home <w> <id> <window>: a plain (non-git) secondmate home - the
# probe/respawn machinery under test never requires the home to be a real
# worktree; a non-git home just makes the unrelated fast-forward sweep log a
# harmless "not a git repo" skip.
add_sm_home() {
  local w=$1 id=$2 window=$3 harness=${4:-claude} backend=${5:-}
  local home="$w/$id"
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'charter\n' > "$home/data/charter.md"
  {
    printf 'window=%s\n' "$window"
    printf 'kind=secondmate\n'
    printf 'harness=%s\n' "$harness"
    [ -n "$backend" ] && printf 'backend=%s\n' "$backend"
    printf 'home=%s\n' "$home"
  } > "$w/home/state/$id.meta"
}

run_bootstrap() {  # <fakebin> <home> <pane-cmd> <call-log> [extra env...] -> stdout
  local fb=$1 home=$2 cmd=$3 log=$4; shift 4
  PATH="$fb:$BASE_PATH" TMUX='' FM_BACKEND=tmux FM_HOME="$home" \
    FM_TEST_PANE_CMD="$cmd" FM_TMUX_CALL_LOG="$log" \
    env "$@" "$ROOT/bin/fm-bootstrap.sh" 2>&1
}

run_bootstrap_herdr() {  # <fakebin> <home> <pane-read-file> <herdr-call-log> [extra env...] -> stdout
  local fb=$1 home=$2 pane_read=$3 log=$4; shift 4
  PATH="$fb:$BASE_PATH" TMUX='' FM_BACKEND=herdr FM_HOME="$home" \
    FM_TEST_HERDR_PANE_READ="$pane_read" FM_HERDR_CALL_LOG="$log" \
    env "$@" "$ROOT/bin/fm-bootstrap.sh" 2>&1
}

test_sweep_respawns_confirmed_dead_secondmate() {
  local w fb tmuxfb log out
  w=$(new_world sweep-dead)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: respawned" \
    "a successfully respawned secondmate should be handled silently"
  assert_contains "$(cat "$log")" "kill-window -t firstmate:fm-sm1" \
    "the stale endpoint must be killed before respawn (tmux refuses a same-named window over a live one)"
  assert_contains "$(cat "$log")" "new-window" \
    "a confirmed-dead secondmate should actually be relaunched"
  pass "sweep: a confirmed-dead secondmate endpoint is killed and respawned"
}

test_sweep_leaves_alive_secondmate_untouched() {
  local w fb tmuxfb log out
  w=$(new_world sweep-alive)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: already-live" \
    "an already-live secondmate should be handled silently"
  [ ! -s "$log" ] || fail "an already-live secondmate must never be killed or respawned: $(cat "$log")"
  pass "sweep: an already-live secondmate is left untouched (no kill, no respawn)"
}

test_sweep_never_acts_on_inconclusive_reading() {
  local w fb tmuxfb log out
  w=$(new_world sweep-unknown)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  # "node" is the ambiguous bare-interpreter case (docs/tmux-backend.md
  # "Known gap") - ANY reading less than confident-dead must never respawn.
  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" node "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: liveness probe inconclusive" \
    "an inconclusive (unknown) probe reading should be reported as skipped"
  [ ! -s "$log" ] || fail "an inconclusive reading must NEVER trigger a kill or respawn (would risk a duplicate agent): $(cat "$log")"
  pass "sweep: a transient/unknown probe reading is reported but never acted on"
}

test_sweep_never_acts_on_unverified_harness_dead_reading() {
  local w fb tmuxfb log out
  w=$(new_world sweep-unverified-harness)
  add_sm_home "$w" sm1 firstmate:fm-sm1 custom-agent
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: liveness probe inconclusive" \
    "an unverified harness should not let a dead-looking endpoint become actionable"
  [ ! -s "$log" ] || fail "an unverified harness must NEVER trigger a kill or respawn: $(cat "$log")"
  pass "sweep: an unverified harness makes a dead-looking probe inconclusive"
}

test_sweep_converges_no_retouch_once_alive() {
  local w fb tmuxfb log out1 out2
  w=$(new_world sweep-idempotent)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  # Round 1: dead -> respawned silently (kill + new-window logged).
  out1=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")
  assert_not_contains "$out1" "SECONDMATE_LIVENESS: secondmate sm1: respawned" "round 1 should handle the successful respawn silently"
  [ -s "$log" ] || fail "round 1 should have logged the kill+respawn window operations"

  # Round 2: the (now-respawned) secondmate is genuinely alive - a second
  # sweep must converge to a pure no-op, not respawn again.
  : > "$log"
  out2=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log")
  assert_not_contains "$out2" "SECONDMATE_LIVENESS: secondmate sm1: already-live" "round 2 should handle the already-live secondmate silently"
  [ ! -s "$log" ] || fail "round 2 must not re-kill or re-respawn an already-live secondmate: $(cat "$log")"
  pass "sweep: idempotent by construction - a live secondmate is never re-touched on a later run"
}

test_sweep_skipped_under_detect_only() {
  local w fb tmuxfb log out
  w=$(new_world sweep-detect-only)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  mkdir -p "$w/home/config"
  printf 'codex\n' > "$w/home/config/crew-harness"
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log" FM_BOOTSTRAP_DETECT_ONLY=1)

  assert_not_contains "$out" "CREW_HARNESS_OVERRIDE:" \
    "detect-only should keep routine harness facts silent"
  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "the read-only detect-only path must never run the mutating liveness sweep"
  [ ! -s "$log" ] || fail "detect-only must never touch any endpoint: $(cat "$log")"
  pass "sweep: skipped entirely under FM_BOOTSTRAP_DETECT_ONLY=1, exactly like the other mutating sweeps"
}

test_sweep_noop_with_no_secondmate_meta() {
  local w fb tmuxfb log out
  w=$(new_world sweep-no-secondmates)
  # No add_sm_home call: this state/ dir looks exactly like what a
  # secondmate's OWN home always has (secondmates never spawn secondmates),
  # proving the sweep's primary-only scoping falls out naturally.
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "with no kind=secondmate meta present, the sweep must print nothing"
  [ ! -s "$log" ] || fail "with no secondmate meta, no endpoint should ever be touched: $(cat "$log")"
  pass "sweep: a silent no-op with no kind=secondmate meta present (a secondmate home's own natural scoping)"
}

# --- sweep level, herdr backend: the jcode false-`dead` respawn-loop fix ------
# The exact fleet bug (verified 2026-08-01): herdr never registers a jcode agent,
# so a live idle jcode secondmate's `agent get` returns agent_not_found ->
# no-agent, and the old sweep killed and respawned it every session start,
# destroying its context. These two tests pin BOTH directions on the sweep it
# actually runs: a live-jcode-content endpoint is left untouched, while a
# genuinely dead (bare-shell) endpoint is still respawned.
test_sweep_herdr_live_jcode_secondmate_is_not_respawned() {
  local w fb herdrfb log pane_read out
  w=$(new_world sweep-herdr-jcode-live)
  add_sm_home "$w" sm1 "default:w1:p2" jcode herdr
  fb=$(make_toolchain "$w"); herdrfb=$(make_liveness_herdr "$w")
  log="$w/herdr-calls.log"; : > "$log"
  # A live idle jcode composer row ("3>" numbered prompt + right-aligned ⏳).
  pane_read="$w/pane-read"
  printf ' 1\xe2\x80\xba Reply with exactly OK and nothing else.\n OK\n\x1b[38;2;255;80;80m3\x1b[38;2;138;180;248m> \x1b[39m        \x1b[38;2;255;193;7m\xe2\x8f\xb3\n' > "$pane_read"

  out=$(run_bootstrap_herdr "$herdrfb:$fb" "$w/home" "$pane_read" "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: respawn failed" \
    "a live jcode secondmate must not even attempt a respawn"
  [ ! -s "$log" ] || fail "a live jcode secondmate endpoint must NEVER be closed/respawned (the false-dead context-destroying bug): $(cat "$log")"
  pass "sweep (herdr): a live jcode secondmate (agent_not_found but a live jcode composer row) is left untouched, never respawned"
}

test_sweep_herdr_dead_jcode_secondmate_still_self_heals() {
  local w fb herdrfb log pane_read out
  w=$(new_world sweep-herdr-jcode-dead)
  add_sm_home "$w" sm1 "default:w1:p2" jcode herdr
  fb=$(make_toolchain "$w"); herdrfb=$(make_liveness_herdr "$w")
  log="$w/herdr-calls.log"; : > "$log"
  # A bare login shell: the same agent_not_found as a live jcode pane, but the
  # content shows no jcode composer row, so the sweep must still self-heal it.
  pane_read="$w/pane-read"
  printf 'Last login: Fri Aug  1 07:00:00 on ttys001\nuser@host ~/project %% \n' > "$pane_read"

  out=$(run_bootstrap_herdr "$herdrfb:$fb" "$w/home" "$pane_read" "$log")

  # The respawn kills the stale endpoint first (pane close). Its own fm-spawn.sh
  # relaunch may fail in this stubbed environment, which is reported - what
  # matters here is that a genuinely dead endpoint is ACTED ON, not skipped as
  # inconclusive or left alone like a live one.
  assert_contains "$(cat "$log")" "pane close" \
    "a genuinely dead jcode secondmate endpoint must still be killed before respawn (self-heal)"
  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: liveness probe inconclusive" \
    "a bare-shell jcode endpoint is a CONFIDENT dead, never an inconclusive skip"
  pass "sweep (herdr): a genuinely dead jcode secondmate (agent_not_found + bare shell) is still killed and respawned"
}

test_tmux_agent_alive_classifies
test_herdr_agent_alive_maps_pane_agent_state
test_herdr_agent_alive_no_agent_delegates_to_content_corroboration
test_agent_alive_dispatcher_routes_and_falls_back
test_sweep_respawns_confirmed_dead_secondmate
test_sweep_leaves_alive_secondmate_untouched
test_sweep_never_acts_on_inconclusive_reading
test_sweep_never_acts_on_unverified_harness_dead_reading
test_sweep_converges_no_retouch_once_alive
test_sweep_skipped_under_detect_only
test_sweep_noop_with_no_secondmate_meta
test_sweep_herdr_live_jcode_secondmate_is_not_respawned
test_sweep_herdr_dead_jcode_secondmate_still_self_heals

echo "# all fm-secondmate-liveness tests passed"
