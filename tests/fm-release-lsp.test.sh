#!/usr/bin/env bash
# tests/fm-release-lsp.test.sh - contract tests for bin/fm-release-lsp.sh, the
# helper that reclaims a PARKED or DEAD lane's language server without touching
# the agent process or the worktree.
#
# The whole reason this script exists is the never-touch-a-live-lane guard, so
# these tests pin exactly that, plus the properties that keep the reclaim safe to
# run over and over:
#
#   - a PARKED lane's language server is released                (eligible)
#   - a DEAD lane's language server is released                  (eligible)
#   - a LIVE lane's language server is preserved                 (never)
#   - a BRIEFLY-WAITING lane's server is preserved               (never)
#   - a lane whose state cannot be resolved is preserved         (conservative)
#   - the agent process is NEVER in the kill set                 (structural)
#   - a re-run is idempotent / a no-op                           (safe re-run)
#   - fm-memory-report REFUSING or WARNING aborts with no kills  (trust ownership)
#
# Everything is injected: the memory-report JSON (FM_RELEASE_LSP_MEMJSON), the
# crew-state verdict (FM_RELEASE_LSP_STATE_BIN), the endpoint verdict
# (FM_RELEASE_LSP_ENDPOINT_BIN), and the kill itself (FM_RELEASE_LSP_KILL_LOG, so
# the exact pid set is verified with no real process). No assertion depends on
# what is running on the host executing the suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REL="$ROOT/bin/fm-release-lsp.sh"

assert_present "$REL" "bin/fm-release-lsp.sh is missing"
[ -x "$REL" ] || fail "bin/fm-release-lsp.sh must be executable"

TMPROOT=$(fm_test_tmproot fm-release-lsp)
HOME_DIR="$TMPROOT/home"
mkdir -p "$HOME_DIR/state"

# Four ordinary crews with distinct states, plus a secondmate that must be
# ignored entirely. Each has a language server pid in the injected memory JSON.
for id in parked dead live briefly; do
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$TMPROOT/wt/$id" \
    "harness=claude" \
    "kind=ship" \
    "mode=direct-PR"
done
fm_write_secondmate_meta "$HOME_DIR/state/second.meta" "$TMPROOT/wt/second"

# The injected memory-report JSON. Each process is one line, exactly the shape
# bin/fm-memory-report.sh --json emits. Language-server pids are 4-digit; agent
# pids 5-digit, so a kill-log assertion can tell them apart at a glance.
#   parked  lsp 4001 / agent 50001
#   dead    lsp 4002 / agent 50002
#   live    lsp 4003 / agent 50003
#   briefly lsp 4004 / agent 50004
#   second  lsp 4005 (secondmate - must be ignored even if it had one)
MEMJSON="$TMPROOT/mem.json"
write_memjson() {  # <attribution_warning-or-null>
  local warn=$1
  {
    printf '{\n'
    printf '  "kind": "memory-report",\n'
    printf '  "attribution_warning": %s,\n' "$warn"
    printf '  "processes": [\n'
    printf '    {"pid":4001,"ppid":1,"footprint_kb":1048576,"owner_kind":"task","owner":"parked","kind":"lsp","command":"tsserver"},\n'
    printf '    {"pid":50001,"ppid":900,"footprint_kb":300000,"owner_kind":"task","owner":"parked","kind":"agent","command":"claude"},\n'
    printf '    {"pid":4002,"ppid":1,"footprint_kb":1048576,"owner_kind":"task","owner":"dead","kind":"lsp","command":"tsserver"},\n'
    printf '    {"pid":50002,"ppid":900,"footprint_kb":300000,"owner_kind":"task","owner":"dead","kind":"agent","command":"claude"},\n'
    printf '    {"pid":4003,"ppid":1,"footprint_kb":1048576,"owner_kind":"task","owner":"live","kind":"lsp","command":"tsserver"},\n'
    printf '    {"pid":50003,"ppid":900,"footprint_kb":300000,"owner_kind":"task","owner":"live","kind":"agent","command":"claude"},\n'
    printf '    {"pid":4004,"ppid":1,"footprint_kb":1048576,"owner_kind":"task","owner":"briefly","kind":"lsp","command":"tsserver"},\n'
    printf '    {"pid":50004,"ppid":900,"footprint_kb":300000,"owner_kind":"task","owner":"briefly","kind":"agent","command":"claude"},\n'
    printf '    {"pid":4005,"ppid":1,"footprint_kb":1048576,"owner_kind":"secondmate","owner":"second","kind":"lsp","command":"tsserver"}\n'
    printf '  ]\n'
    printf '}\n'
  } > "$MEMJSON"
}

# The stub crew-state reader: prints "state: <token> · source: stub" for each id
# from a lookup file the test writes. An id absent from the file prints an
# unknown state line, exercising the unresolvable-state path.
STATE_BIN="$TMPROOT/state-stub.sh"
STATE_MAP="$TMPROOT/state-map"
cat > "$STATE_BIN" <<'SH'
#!/usr/bin/env bash
id=$1
line=$(grep "^$id	" "$FM_TEST_STATE_MAP" 2>/dev/null | head -1 | cut -f2)
[ -n "$line" ] || line=unknown
printf 'state: %s · source: stub · test\n' "$line"
SH
chmod +x "$STATE_BIN"

# The stub endpoint reader: prints alive|dead|unknown per id from a lookup file.
ENDPOINT_BIN="$TMPROOT/endpoint-stub.sh"
ENDPOINT_MAP="$TMPROOT/endpoint-map"
cat > "$ENDPOINT_BIN" <<'SH'
#!/usr/bin/env bash
id=$1
v=$(grep "^$id	" "$FM_TEST_ENDPOINT_MAP" 2>/dev/null | head -1 | cut -f2)
[ -n "$v" ] || v=alive
printf '%s' "$v"
SH
chmod +x "$ENDPOINT_BIN"

# The canonical fixture: parked is paused+alive, dead is alive-state-but-dead
# endpoint, live is working+alive, briefly is working+alive (a briefly-waiting
# crew reports working: lines so crew-state reads working, never paused).
setup_maps() {
  {
    printf 'parked\tpaused\n'
    printf 'dead\tunknown\n'
    printf 'live\tworking\n'
    printf 'briefly\tworking\n'
  } > "$STATE_MAP"
  {
    printf 'parked\talive\n'
    printf 'dead\tdead\n'
    printf 'live\talive\n'
    printf 'briefly\talive\n'
  } > "$ENDPOINT_MAP"
}

KILL_LOG="$TMPROOT/killed"

# run_release <args...>: run the helper against the injected fixture, recording
# killed pids to KILL_LOG rather than signalling anything.
run_release() {
  : > "$KILL_LOG"
  FM_HOME="$HOME_DIR" \
  FM_RELEASE_LSP_MEMJSON="$MEMJSON" \
  FM_RELEASE_LSP_STATE_BIN="$STATE_BIN" \
  FM_RELEASE_LSP_ENDPOINT_BIN="$ENDPOINT_BIN" \
  FM_RELEASE_LSP_KILL_LOG="$KILL_LOG" \
  FM_TEST_STATE_MAP="$STATE_MAP" \
  FM_TEST_ENDPOINT_MAP="$ENDPOINT_MAP" \
    "$REL" "$@" 2>&1
}

killed() { sort -u "$KILL_LOG" 2>/dev/null | tr '\n' ' '; }
was_killed() { grep -qx "$1" "$KILL_LOG" 2>/dev/null; }

# --- eligible lanes ---------------------------------------------------------

test_parked_lane_server_released() {
  write_memjson null; setup_maps
  run_release >/dev/null
  was_killed 4001 || fail "a PARKED lane's language server must be released (pid 4001), killed: $(killed)"
  pass "a parked lane's language server is released"
}

test_dead_lane_server_released() {
  write_memjson null; setup_maps
  run_release >/dev/null
  was_killed 4002 || fail "a DEAD lane's language server must be released (pid 4002), killed: $(killed)"
  pass "a dead lane's language server is released"
}

# --- the safety guard: never a live or briefly-waiting lane -----------------

test_live_lane_server_preserved() {
  write_memjson null; setup_maps
  run_release >/dev/null
  ! was_killed 4003 || fail "a LIVE lane's language server must NEVER be released (pid 4003), killed: $(killed)"
  pass "a live lane's language server is preserved"
}

test_briefly_waiting_lane_server_preserved() {
  write_memjson null; setup_maps
  run_release >/dev/null
  # A briefly-waiting crew reports working: lines, so crew-state reads it as
  # working, not paused - it must keep its server.
  ! was_killed 4004 || fail "a briefly-waiting lane's server must be preserved (pid 4004), killed: $(killed)"
  pass "a briefly-waiting lane's language server is preserved"
}

test_uncertain_state_preserved() {
  # A lane whose endpoint is not confidently dead AND whose crew-state is not
  # paused (here: unknown/unknown) must be left alone - the conservative default.
  write_memjson null
  {
    printf 'parked\tpaused\n'
    printf 'dead\tunknown\n'
    printf 'live\tunknown\n'    # unknown state
    printf 'briefly\tworking\n'
  } > "$STATE_MAP"
  {
    printf 'parked\talive\n'
    printf 'dead\tdead\n'
    printf 'live\tunknown\n'    # unknown endpoint, NOT a confident dead
    printf 'briefly\talive\n'
  } > "$ENDPOINT_MAP"
  run_release >/dev/null
  ! was_killed 4003 || fail "an uncertain-state lane must be preserved (pid 4003), killed: $(killed)"
  pass "a lane whose state cannot be resolved keeps its server (conservative default)"
}

test_agent_process_is_never_killed() {
  write_memjson null; setup_maps
  run_release >/dev/null
  local p
  for p in 50001 50002 50003 50004; do
    ! was_killed "$p" || fail "an agent process must NEVER be killed (pid $p), killed: $(killed)"
  done
  pass "no agent process is ever in the kill set, even for eligible lanes"
}

test_secondmate_is_ignored() {
  write_memjson null; setup_maps
  run_release >/dev/null
  ! was_killed 4005 || fail "a secondmate's server must never be touched (pid 4005), killed: $(killed)"
  pass "a persistent secondmate is ignored entirely"
}

test_only_eligible_servers_killed() {
  write_memjson null; setup_maps
  run_release >/dev/null
  [ "$(killed)" = "4001 4002 " ] || fail "exactly the parked+dead servers must be killed, got: $(killed)"
  pass "exactly and only the eligible lanes' servers are released"
}

# --- idempotent / safe to re-run --------------------------------------------

test_idempotent_rerun() {
  write_memjson null; setup_maps
  # First run releases 4001 and 4002. On a real host the second run would find
  # them gone; here the memory JSON is static, so idempotence is proven by the
  # release_pid absent-path: drop the eligible lanes' servers from the JSON to
  # model "already released", and assert a clean no-op.
  run_release >/dev/null
  # Model the post-release world: the parked/dead servers are gone.
  grep -v '"pid":4001' "$MEMJSON" | grep -v '"pid":4002' > "$MEMJSON.after"
  mv "$MEMJSON.after" "$MEMJSON"
  local out
  out=$(run_release); 
  [ -z "$(killed)" ] || fail "a re-run after release must kill nothing, killed: $(killed)"
  assert_contains "$out" "nothing to release" "a re-run with the servers gone must report a no-op"
  pass "a re-run once the servers are gone is a clean no-op (idempotent)"
}

test_absent_pid_is_a_noop_not_an_error() {
  # release_pid on a pid that is already gone must be silent. Use the real kill
  # path (no KILL_LOG) against a pid guaranteed not to exist.
  write_memjson null; setup_maps
  # A high, almost-certainly-free pid for the parked lane's server.
  sed 's/"pid":4001/"pid":2147480000/' "$MEMJSON" > "$MEMJSON.x"
  mv "$MEMJSON.x" "$MEMJSON"
  local out rc
  out=$(FM_HOME="$HOME_DIR" FM_RELEASE_LSP_MEMJSON="$MEMJSON" \
        FM_RELEASE_LSP_STATE_BIN="$STATE_BIN" FM_RELEASE_LSP_ENDPOINT_BIN="$ENDPOINT_BIN" \
        FM_TEST_STATE_MAP="$STATE_MAP" FM_TEST_ENDPOINT_MAP="$ENDPOINT_MAP" \
        "$REL" 2>&1); rc=$?
  expect_code 0 "$rc" "an already-gone pid must not make the run fail"
  assert_contains "$out" "absent" "an already-gone pid must be reported absent, not released"
  pass "releasing an already-gone pid is a silent no-op, not an error"
}

# --- trust the ownership source ---------------------------------------------

test_refuses_on_attribution_warning() {
  write_memjson '"3 of 3 agent processes (100%) matched no record"'
  setup_maps
  local out rc
  out=$(run_release); rc=$?
  expect_code 3 "$rc" "an attribution warning must refuse (exit 3)"
  assert_contains "$out" "REFUSING" "the refusal must say so plainly"
  [ -z "$(killed)" ] || fail "a refusal must kill nothing, killed: $(killed)"
  pass "a memory-report attribution warning aborts with no kills"
}

test_refuses_when_memory_report_refuses() {
  # A memory-report that exits 3 (a broken reading) must propagate as a refusal,
  # never a guess. The FM_RELEASE_LSP_MEMREPORT seam runs a stub that refuses.
  local stub out rc
  stub="$TMPROOT/refusing-memreport.sh"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
echo "fm-memory-report: REFUSING to report" >&2
exit 3
SH
  chmod +x "$stub"
  setup_maps
  : > "$KILL_LOG"
  out=$(FM_HOME="$HOME_DIR" FM_RELEASE_LSP_MEMREPORT="$stub" \
        FM_RELEASE_LSP_STATE_BIN="$STATE_BIN" FM_RELEASE_LSP_ENDPOINT_BIN="$ENDPOINT_BIN" \
        FM_RELEASE_LSP_KILL_LOG="$KILL_LOG" \
        FM_TEST_STATE_MAP="$STATE_MAP" FM_TEST_ENDPOINT_MAP="$ENDPOINT_MAP" \
        "$REL" 2>&1); rc=$?
  expect_code 3 "$rc" "a memory-report that refuses must propagate as a refusal (exit 3)"
  assert_contains "$out" "REFUSING" "the refusal must say so plainly"
  [ -z "$(killed)" ] || fail "a refusal must kill nothing, killed: $(killed)"
  pass "a memory-report refusal aborts this helper too, with no kills"
}

test_empty_memory_report_is_an_error() {
  : > "$MEMJSON"
  setup_maps
  local rc
  run_release >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "empty memory-report output must not be treated as a clean run"
  pass "empty memory-report output is an error, not a silent no-op"
}

# --- dry run and json -------------------------------------------------------

test_dry_run_kills_nothing() {
  write_memjson null; setup_maps
  local out
  out=$(run_release --dry-run)
  [ -z "$(killed)" ] || fail "--dry-run must kill nothing, killed: $(killed)"
  assert_contains "$out" "DRY RUN" "--dry-run must announce itself"
  assert_contains "$out" "would-release" "--dry-run must show what it would release"
  pass "--dry-run reports eligible servers without killing anything"
}

test_json_reports_released_set() {
  write_memjson null; setup_maps
  local out
  out=$(run_release --json)
  assert_contains "$out" '"kind": "release-lsp"' "--json must identify itself"
  assert_contains "$out" '"pid":4001' "--json must name the parked lane's released server"
  assert_contains "$out" '"pid":4002' "--json must name the dead lane's released server"
  assert_not_contains "$out" '"pid":4003' "--json must not list a preserved live server"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' \
      || fail "--json must emit valid JSON"
  fi
  pass "--json reports exactly the released set as valid machine-readable output"
}

test_usage_and_bad_flag() {
  local out rc
  out=$("$REL" --help); rc=$?
  expect_code 0 "$rc" "--help must succeed"
  assert_contains "$out" "HARD SAFETY CONSTRAINT" "help must carry the never-touch-live contract"
  out=$("$REL" --nonsense 2>&1); rc=$?
  expect_code 64 "$rc" "an unknown flag must be a usage error"
  pass "--help prints the safety contract and an unknown flag is a usage error"
}

test_parked_lane_server_released
test_dead_lane_server_released
test_live_lane_server_preserved
test_briefly_waiting_lane_server_preserved
test_uncertain_state_preserved
test_agent_process_is_never_killed
test_secondmate_is_ignored
test_only_eligible_servers_killed
test_idempotent_rerun
test_absent_pid_is_a_noop_not_an_error
test_refuses_on_attribution_warning
test_refuses_when_memory_report_refuses
test_empty_memory_report_is_an_error
test_dry_run_kills_nothing
test_json_reports_released_set
test_usage_and_bad_flag
