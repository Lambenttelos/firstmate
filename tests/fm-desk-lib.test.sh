#!/usr/bin/env bash
# Unit tests for bin/fm-desk-lib.sh, the captain's-desk data layer.
#
# These drive desk_project directly (the executable interface of the sourced
# lib) through synthetic seams: FM_DESK_SNAPSHOT_BIN for the fleet projection and
# FM_DESK_MERGEQ_BIN for the
# merge queue. They assert the emitted fm-desk.v1 view model, never the lib's
# source bytes: populated rows, empty->empty, bad snapshot->gap, away->away,
# DESK_TERMS translation applied, and the DESK_MAX bound applied.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

LIB="$ROOT/bin/fm-desk-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-desk-lib)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state"

# A populated synthetic projection. The `doing` field carries an internal term
# ("crewmate") so the translation assertion has something to rewrite.
SNAP_BIN="$TMP_ROOT/snap.sh"
cat > "$SNAP_BIN" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{
  "schema": "fm-bearings.v1",
  "home": "test/home",
  "in_flight": [
    { "id": "ship-alpha", "kind": "ship", "state": "working", "doing": "guiding the crewmate" },
    { "id": "ship-beta", "kind": "ship", "state": "blocked", "doing": "waiting on a decision" }
  ],
  "secondmates": [
    { "id": "research-secondmate", "state": "idle", "doing": "nothing queued", "freshness": "fresh" }
  ],
  "decisions_open": [
    { "id": "decide-refund-contract", "key": "k", "verb": "captain-hold", "summary": "keep the refund throw", "owner": "ship-alpha" }
  ],
  "landed": [
    { "id": "ticket-fixed-index", "what": "add a compound index on Order", "artifact": "-" }
  ],
  "gates": [
    { "id": "queued-cleanup", "title": "remove the dead code path", "blocked_by": "-", "reason": "waiting on capacity" }
  ]
}
JSON
SH
chmod +x "$SNAP_BIN"

MQ_BIN="$TMP_ROOT/mq.sh"
cat > "$MQ_BIN" <<'SH'
#!/usr/bin/env bash
printf 'branch-one\t/repos/x\tfm/branch-one\tabc123\tdev\thttps://example.test/compare/one\n'
SH
chmod +x "$MQ_BIN"

# Default quota seam: a claude provider with NO usable window, so every test that
# does not care about usage gets a deterministic "no usage line, no gap" result
# instead of shelling out to the real quota-axi on the test box. The ITEM 4 tests
# override FM_DESK_QUOTA_BIN with their own stubs.
Q_NONE="$TMP_ROOT/quota-none.sh"
cat > "$Q_NONE" <<'SH'
#!/usr/bin/env bash
echo '{ "schemaVersion": 3, "providers": [ { "provider": "claude", "windows": [] } ] }'
SH
chmod +x "$Q_NONE"
export FM_DESK_QUOTA_BIN="$Q_NONE"

# Default cswap seam: reports no accounts, so every test that does not care about
# the account block gets a deterministic "no accounts, no gap" result instead of
# shelling out to a real cswap on the test box. The account tests override
# FM_DESK_CSWAP_BIN with their own stubs. A default empty jcode auth keeps those
# tests off the real ~/.jcode/auth.json too.
CSWAP_NONE="$TMP_ROOT/cswap-none.sh"
cat > "$CSWAP_NONE" <<'SH'
#!/usr/bin/env bash
echo '{ "schemaVersion": 1, "activeAccountNumber": null, "accounts": [] }'
SH
chmod +x "$CSWAP_NONE"
export FM_DESK_CSWAP_BIN="$CSWAP_NONE"
JCODE_NONE="$TMP_ROOT/jcode-auth-absent.json"
export FM_DESK_JCODE_AUTH="$JCODE_NONE"

# Default jcode-usage seam: a binary that FAILS, plus a per-test cache path under
# TMP. WHY: account usage + the header usage line now come from `jcode usage
# --json` through a desk-owned disk cache. Without these seams a test would shell
# out to the REAL jcode (3 live Anthropic calls) and write the real state dir. A
# failing default binary + an absent default cache means every test that does not
# care about usage deterministically gets "no usage, no crash". The usage tests
# override FM_DESK_JCODE_USAGE_BIN + FM_DESK_JCODE_USAGE_CACHE with their own.
JCODE_USAGE_NONE="$TMP_ROOT/jcode-usage-none.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$JCODE_USAGE_NONE"
chmod +x "$JCODE_USAGE_NONE"
export FM_DESK_JCODE_USAGE_BIN="$JCODE_USAGE_NONE"
export FM_DESK_JCODE_USAGE_CACHE="$TMP_ROOT/jcode-usage-absent.json"

# Default token-cost seam: a report binary that emits a VALID but empty coster
# blob (no billed activity), plus a per-test cache path under TMP. WHY: the
# token-cost panel (burn/cache-hit/heaviest/per-ticket) shells out to the coster
# (bin/fm-token-report.sh) + rollup through a desk-owned disk cache. Without these
# seams a test would run the REAL coster (a full jcode session-store scan) and
# write the real state dir - breaking the "reads only, no writes under state/"
# guarantee. An empty-but-valid report deterministically yields the honest "no
# billed activity yet" panel (never a spurious gap in a populated model), and the
# TMP cache keeps the panel's one owned write off the seeded home. The rollup half
# is absent (a nonexistent bin), so per-ticket cost reads "not available". The
# token-cost tests override FM_DESK_TOKEN_REPORT_BIN / FM_DESK_TICKET_ROLLUP_BIN /
# FM_DESK_TOKEN_COST_CACHE with their own.
TOKEN_COST_EMPTY="$TMP_ROOT/token-cost-empty.sh"
cat > "$TOKEN_COST_EMPTY" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"price_source":"test","price_cached_at":"2026-01-01T00:00:00Z",
 "totals":{"cost_if_api":null,"cost_if_api_billed":null,"cost_if_api_covered":null,
   "sessions":0,"token_input":0,"token_cache_read":0,"token_cache_write":0,"unknown_model_tokens":0},
 "rows":[]}
JSON
SH
chmod +x "$TOKEN_COST_EMPTY"
export FM_DESK_TOKEN_REPORT_BIN="$TOKEN_COST_EMPTY"
export FM_DESK_TICKET_ROLLUP_BIN="$TMP_ROOT/token-cost-rollup-absent.sh"
export FM_DESK_TOKEN_COST_CACHE="$TMP_ROOT/token-cost-absent.json"

# run_project <home> [extra env=val ...] -> emits the fm-desk.v1 JSON.
run_project() {
  local home=$1; shift
  # shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
  env FM_HOME="$home" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
    FM_DESK_NOW="2026-01-01 00:00:00 UTC" "$@" \
    bash -c '. "$1"; desk_project' _ "$LIB"
}

# --- schema + populated rows ------------------------------------------------
model=$(run_project "$HOME_DIR")
printf '%s' "$model" | jq -e . >/dev/null 2>&1 || fail "desk_project must emit valid JSON"
schema=$(printf '%s' "$model" | jq -r '.schema')
[ "$schema" = "fm-desk.v1" ] || fail "schema must be fm-desk.v1 (got '$schema')"
pass "desk_project emits a valid fm-desk.v1 document"

# --- status bullet CLASS + redundant kind-prefix strip (model concern) ------
# The status->bullet class map and the "ship:/scout:" prefix strip are the lib's
# job (both boards paint the glyph). Assert the class per section and that a
# leading kind label is stripped from the headline while the kind field stays.
KIND_SNAP="$TMP_ROOT/kind.sh"
cat > "$KIND_SNAP" <<'JSONSH'
#!/usr/bin/env bash
cat <<'JSON'
{
  "schema": "fm-bearings.v1",
  "in_flight": [
    { "id": "a", "kind": "ship", "state": "working", "doing": "ship: editing the path" },
    { "id": "b", "kind": "ship", "state": "blocked", "doing": "scout: stuck here" }
  ],
  "secondmates": [ { "id": "sm", "state": "active_child_work", "doing": "ship+nm: building", "freshness": "fresh" } ],
  "decisions_open": [ { "id": "d", "verb": "needs-decision", "summary": "answer this" } ],
  "landed": [ { "id": "l", "what": "ship: shipped the fix", "artifact": "-" } ],
  "gates": [ { "id": "g", "title": "scout: queued item", "blocked_by": "-", "reason": "-" } ]
}
JSON
JSONSH
chmod +x "$KIND_SNAP"
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
kmodel=$(env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$KIND_SNAP" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB")
# Bullet class per section (the vocabulary: blocked/waiting/running/done/idle).
b_under_blocked=$(printf '%s' "$kmodel" | jq -r '.sections.under_way.rows[] | select(.id=="b") | .bullet')
b_under_running=$(printf '%s' "$kmodel" | jq -r '.sections.under_way.rows[] | select(.id=="a") | .bullet')
b_call=$(printf '%s' "$kmodel" | jq -r '.sections.captains_call.rows[0].bullet')
b_landed=$(printf '%s' "$kmodel" | jq -r '.sections.landed.rows[0].bullet')
b_charted=$(printf '%s' "$kmodel" | jq -r '.sections.charted.rows[0].bullet')
b_second=$(printf '%s' "$kmodel" | jq -r '.sections.secondmates.rows[0].bullet')
b_merge=$(printf '%s' "$kmodel" | jq -r '.sections.merge.rows[0].bullet')
[ "$b_under_blocked" = blocked ] || fail "a blocked worker maps to the blocked bullet (got '$b_under_blocked')"
[ "$b_under_running" = running ] || fail "a working worker maps to the running bullet (got '$b_under_running')"
[ "$b_call" = waiting ] || fail "an open decision maps to the waiting bullet (got '$b_call')"
[ "$b_landed" = "done" ] || fail "a landed row maps to the done bullet (got '$b_landed')"
[ "$b_charted" = idle ] || fail "a queued gate maps to the idle bullet (got '$b_charted')"
[ "$b_second" = running ] || fail "an active second mate maps to the running bullet (got '$b_second')"
[ "$b_merge" = "done" ] || fail "a ready-to-merge row maps to the done bullet (got '$b_merge')"
pass "each section carries the right status bullet class"
# The redundant leading kind label is stripped from every headline; the kind
# field itself is preserved (the board may still show it as trailing meta).
d_a=$(printf '%s' "$kmodel" | jq -r '.sections.under_way.rows[] | select(.id=="a") | .doing')
k_a=$(printf '%s' "$kmodel" | jq -r '.sections.under_way.rows[] | select(.id=="a") | .kind')
[ "$d_a" = "editing the path" ] || fail "a leading 'ship:' is stripped from the headline (got '$d_a')"
[ "$k_a" = "ship" ] || fail "the kind field is preserved (got '$k_a')"
g_title=$(printf '%s' "$kmodel" | jq -r '.sections.charted.rows[0].title')
l_what=$(printf '%s' "$kmodel" | jq -r '.sections.landed.rows[0].what')
[ "$g_title" = "queued item" ] || fail "a leading 'scout:' is stripped from a gate title (got '$g_title')"
[ "$l_what" = "shipped the fix" ] || fail "a leading 'ship:' is stripped from a landed headline (got '$l_what')"
pass "redundant kind prefixes are stripped from headlines, kind field preserved"

# Populated sections carry their rows with status ok. Under Way is RANKED so the
# blocked worker (ship-beta) leads the working one (ship-alpha).
for pair in \
  "captains_call:decide-refund-contract" \
  "under_way:ship-beta" \
  "charted:queued-cleanup" \
  "landed:ticket-fixed-index" \
  "secondmates:research-secondmate"; do
  sec=${pair%%:*}; id=${pair#*:}
  st=$(printf '%s' "$model" | jq -r ".sections.$sec.status")
  [ "$st" = "ok" ] || fail "$sec status must be ok (got '$st')"
  got=$(printf '%s' "$model" | jq -r ".sections.$sec.rows[0].id")
  [ "$got" = "$id" ] || fail "$sec first row id must be $id (got '$got')"
done
# The merge section carries the branch verbatim.
murl=$(printf '%s' "$model" | jq -r '.sections.merge.rows[0].url')
[ "$murl" = "https://example.test/compare/one" ] || fail "merge url must be carried verbatim"
mcount=$(printf '%s' "$model" | jq -r '.sections.captains_call.merge_count')
[ "$mcount" = "1" ] || fail "merge_count must be 1 (got '$mcount')"
# The header summary counts the one decision and two running jobs.
summary=$(printf '%s' "$model" | jq -r '.header.summary')
assert_contains "$summary" "One thing needs your word" "header counts the open decision"
assert_contains "$summary" "2 jobs are running" "header counts running jobs"
# The machine-readable counts back the summary so both boards can read them.
cdec=$(printf '%s' "$model" | jq -r '.header.counts.decisions')
crun=$(printf '%s' "$model" | jq -r '.header.counts.running')
cblk=$(printf '%s' "$model" | jq -r '.header.counts.blocked')
[ "$cdec" = "1" ] || fail "counts.decisions must be 1 (got '$cdec')"
[ "$crun" = "2" ] || fail "counts.running must be 2 (got '$crun')"
[ "$cblk" = "1" ] || fail "counts.blocked must count the blocked worker (got '$cblk')"
pass "populated projection yields populated rows and header counts"

# --- Under Way re-homing: real state, not the trailing status word ----------
# The Under Way section must show only tasks with a live endpoint or a genuinely
# active run-step. A status line is a wake event, not current state, so the
# membership keys on fm-crew-state.sh's reconciled `.in_flight[].state` plus the
# endpoint fact (`.unhealthy_endpoints[].exists`), never on the `doing` headline.
# Drive the four shapes apart in one snapshot so no assertion can go vacuous:
#   live    a working task with a live endpoint stays a running Under Way row.
#   paused  a declared external wait stays in Under Way but reads as waiting.
#   dead    a dead-endpoint non-terminal task becomes an attention row (worker
#           gone, work preserved), never a running-looking or idle row, and its
#           raw endpoint id never leaks into the headline.
#   done    a terminal done crew-state leaves Under Way entirely; the merge
#           section is the single awaiting-merge owner, so a done task is never
#           double-listed there and never masquerades as running here.
REHOME_SNAP="$TMP_ROOT/rehome.sh"
REHOME_ARGS="$TMP_ROOT/rehome-args.txt"
cat > "$REHOME_SNAP" <<JSONSH
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$REHOME_ARGS"
cat <<'JSON'
{
  "schema": "fm-bearings.v1",
  "home": "test/home",
  "in_flight": [
    { "id": "live-task", "kind": "ship", "state": "working", "doing": "editing the fix" },
    { "id": "paused-task", "kind": "ship", "state": "paused", "doing": "awaiting an upstream release" },
    { "id": "dead-task", "kind": "ship", "state": "unknown", "doing": "backend target gone: default:w6:pCC" },
    { "id": "done-task", "kind": "ship", "state": "done", "doing": "run passed: PR merged/closed" }
  ],
  "unhealthy_endpoints": [
    { "id": "dead-task", "backend": "herdr", "target": "default:w6:pCC", "exists": false, "agent": "not_checked" },
    { "id": "done-task", "backend": "herdr", "target": "default:w6:pBZ", "exists": false, "agent": "not_checked" }
  ],
  "recorded_prs": [
    { "id": "done-task", "url": "https://example.test/pr/1" }
  ],
  "secondmates": [],
  "decisions_open": [],
  "landed": [],
  "gates": []
}
JSON
JSONSH
chmod +x "$REHOME_SNAP"
# A merge queue that carries the done task's pushed branch, so the awaiting-merge
# section is the sole owner and the Under Way drop cannot hide the task entirely.
REHOME_MQ="$TMP_ROOT/rehome-mq.sh"
cat > "$REHOME_MQ" <<'SH'
#!/usr/bin/env bash
printf 'done-task\t/repos/x\tfm/done-task\tabc123\tdev\thttps://example.test/compare/done\n'
SH
chmod +x "$REHOME_MQ"
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
rmodel=$(env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$REHOME_SNAP" FM_DESK_MERGEQ_BIN="$REHOME_MQ" \
  FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB")

under_ids=$(printf '%s' "$rmodel" | jq -r '[.sections.under_way.rows[].id] | join(",")')
# (a) done crew-state with a recorded pr: gone from Under Way, present ONCE in
# merge, never double-listed.
case ",$under_ids," in *,done-task,*) fail "a done task must leave Under Way (got '$under_ids')" ;; esac
merge_done=$(printf '%s' "$rmodel" | jq -r '[.sections.merge.rows[] | select(.id == "done-task")] | length')
[ "$merge_done" = "1" ] || fail "a done task's pushed branch must appear once in the merge section (got '$merge_done')"
pass "a done-with-pr task leaves Under Way and is owned solely by the merge section"

# (b) dead endpoint with unlanded work: an attention row, not running, not idle,
# and the raw endpoint target never leaks into the captain-facing headline.
case ",$under_ids," in *,dead-task,*) : ;; *) fail "a dead-endpoint task must stay visible as an attention row (got '$under_ids')" ;; esac
dead_state=$(printf '%s' "$rmodel" | jq -r '.sections.under_way.rows[] | select(.id=="dead-task") | .state')
dead_bullet=$(printf '%s' "$rmodel" | jq -r '.sections.under_way.rows[] | select(.id=="dead-task") | .bullet')
dead_doing=$(printf '%s' "$rmodel" | jq -r '.sections.under_way.rows[] | select(.id=="dead-task") | .doing')
[ "$dead_state" = "attention" ] || fail "a dead-endpoint task must read as attention, not '$dead_state'"
[ "$dead_bullet" = "blocked" ] || fail "an attention row must carry the blocked bullet (got '$dead_bullet')"
[ "$dead_bullet" != "idle" ] || fail "an attention row must never render idle"
case "$dead_doing" in *default:w6:pCC*|*"backend target gone"*) fail "the raw endpoint id must not leak into the headline (got '$dead_doing')" ;; esac
pass "a dead-endpoint task surfaces as an attention row with no leaked endpoint id"

# (c) a declared paused task stays in Under Way but reads as waiting, not idle.
case ",$under_ids," in *,paused-task,*) : ;; *) fail "a paused task must stay in Under Way (got '$under_ids')" ;; esac
paused_bullet=$(printf '%s' "$rmodel" | jq -r '.sections.under_way.rows[] | select(.id=="paused-task") | .bullet')
[ "$paused_bullet" = "waiting" ] || fail "a paused task must read as waiting, not '$paused_bullet'"
[ "$paused_bullet" != "idle" ] || fail "a paused task must never render idle"
pass "a declared paused task reads as waiting in Under Way"

# The live task is untouched, and the header counts follow the re-homed rows: the
# departed done task never counts, and the attention row counts as blocked (needs
# attention), never as running. The live and paused tasks are both still in flight
# (paused is a deliberate wait, not a finished job), so running counts both.
live_bullet=$(printf '%s' "$rmodel" | jq -r '.sections.under_way.rows[] | select(.id=="live-task") | .bullet')
[ "$live_bullet" = "running" ] || fail "a live working task must stay a running row (got '$live_bullet')"
r_run=$(printf '%s' "$rmodel" | jq -r '.header.counts.running')
r_blk=$(printf '%s' "$rmodel" | jq -r '.header.counts.blocked')
[ "$r_run" = "2" ] || fail "header running must count the live and paused tasks, never the departed done or the attention row (got '$r_run')"
[ "$r_blk" = "1" ] || fail "header blocked must count the attention row (got '$r_blk')"
pass "header counts follow the re-homed rows, not the trailing status word"

# The dead set must be complete: the snapshot caps unhealthy_endpoints by default
# (FM_BEARINGS_UNHEALTHY), so a dead worker past that cap would keep its raw
# headline as an idle row. The desk asks for the uncapped list.
grep -qx -- '--all-unhealthy' "$REHOME_ARGS" \
  || fail "the desk must read the uncapped unhealthy list (--all-unhealthy) so no dead worker is missed (got: $(tr '\n' ' ' < "$REHOME_ARGS"))"
pass "the desk reads the uncapped unhealthy list so the dead set is complete"

# A projection with no in_flight field at all must degrade to an empty Under Way,
# never blank the whole projection (which would downgrade every section to a gap).
NOFLIGHT_SNAP="$TMP_ROOT/noflight.sh"
cat > "$NOFLIGHT_SNAP" <<'JSONSH'
#!/usr/bin/env bash
cat <<'JSON'
{
  "schema": "fm-bearings.v1",
  "home": "test/home",
  "decisions_open": [
    { "id": "still-here", "kind": "ship", "verb": "needs-decision", "summary": "pick a name", "since": "2025-12-31 23:00:00 UTC", "priority": 0 }
  ],
  "landed": [], "gates": [], "secondmates": []
}
JSON
JSONSH
chmod +x "$NOFLIGHT_SNAP"
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
nfmodel=$(env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$NOFLIGHT_SNAP" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB")
nf_under=$(printf '%s' "$nfmodel" | jq -r '.sections.under_way.status')
[ "$nf_under" = "empty" ] || fail "a projection without in_flight must read as an empty Under Way, not '$nf_under'"
nf_call=$(printf '%s' "$nfmodel" | jq -r '.sections.captains_call.status')
[ "$nf_call" = "ok" ] || fail "the other sections must still render when in_flight is absent (captains_call status '$nf_call')"
nf_run=$(printf '%s' "$nfmodel" | jq -r '.header.counts.running')
[ "$nf_run" = "0" ] || fail "running must be 0 when in_flight is absent (got '$nf_run')"
pass "a projection without in_flight degrades to an empty Under Way, not a whole-page gap"

# --- Captain's Call ordering: blocking (priority 0) first, then oldest-first ---
# A work-blocking decision (priority 0) must lead the Captain's Call ahead of
# review-when-convenient holds, and within a band the oldest (earliest since)
# leads. The desk consumes the snapshot decisions_open, so drive an unordered
# fixture and assert the rendered model order. An urgent needs-decision still
# sorts ahead of a captain-hold, so keep every fixture row a captain-hold to test
# the priority/since bands in isolation.
CALL_SNAP="$TMP_ROOT/call-order.sh"
cat > "$CALL_SNAP" <<'JSONSH'
#!/usr/bin/env bash
cat <<'JSON'
{
  "schema": "fm-bearings.v1",
  "in_flight": [],
  "secondmates": [],
  "decisions_open": [
    { "id": "conv-old", "key": "a", "verb": "captain-hold", "summary": "convenience old", "owner": "(main)", "priority": null, "since": "2026-07-01" },
    { "id": "block-new", "key": "b", "verb": "captain-hold", "summary": "BLOCKING new", "owner": "(main)", "priority": "0", "since": "2026-08-20" },
    { "id": "conv-mid", "key": "c", "verb": "captain-hold", "summary": "convenience mid", "owner": "(main)", "priority": null, "since": "2026-07-15" },
    { "id": "block-old", "key": "d", "verb": "captain-hold", "summary": "BLOCKING old", "owner": "(main)", "priority": "0", "since": "2026-06-01" }
  ],
  "landed": [],
  "gates": []
}
JSON
JSONSH
chmod +x "$CALL_SNAP"
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
call_model=$(env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$CALL_SNAP" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB")
call_order=$(printf '%s' "$call_model" | jq -r '[.sections.captains_call.rows[].id] | join(",")')
[ "$call_order" = "block-old,block-new,conv-old,conv-mid" ] \
  || fail "Captain's Call must order blocking-first then oldest-first (got '$call_order')"
pass "Captain's Call orders blocking holds first, oldest-first within each band"


# --- DESK_TERMS translation applied -----------------------------------------
# "crewmate" in the projection must be rewritten to "worker" in the model, and
# ids must stay verbatim (never translated). ship-alpha carries the term and,
# after ranking (blocked-first), sits behind ship-beta, so read it by id.
doing=$(printf '%s' "$model" | jq -r '.sections.under_way.rows[] | select(.id == "ship-alpha") | .doing')
assert_contains "$doing" "worker" "DESK_TERMS rewrites crewmate to worker"
assert_not_contains "$doing" "crewmate" "the internal term does not survive"
pass "DESK_TERMS translation is applied to text fields"

# --- DEFECT 1: desk_plain translates prose but never a literal command -------
# The unanchored gsub rewrote command text: `no-mistakes --skip pr,ci` became
# `validation --skip pr,ci`, trading a copy-pastable command for a friendlier
# word. The captain's writing profile forbids exactly that (exactness beats a
# plain word). desk_plain must protect a literal a human might copy - a command
# glued to a flag, a backticked span, a path/branch token - while still
# translating plain prose.
d1_cmd=$(printf '%s' 'validated (no-mistakes --skip pr,ci)' \
  | bash -c '. "$1"; desk_plain' _ "$LIB")
[ "$d1_cmd" = 'validated (no-mistakes --skip pr,ci)' ] \
  || fail "the literal command must survive desk_plain verbatim (got '$d1_cmd')"
d1_prose=$(printf '%s' 'the no-mistakes run passed' \
  | bash -c '. "$1"; desk_plain' _ "$LIB")
[ "$d1_prose" = 'the validation run passed' ] \
  || fail "plain prose must still translate no-mistakes to validation (got '$d1_prose')"
# shellcheck disable=SC2016
d1_tick=$(printf '%s' 'run `no-mistakes` now' \
  | bash -c '. "$1"; desk_plain' _ "$LIB")
# shellcheck disable=SC2016
[ "$d1_tick" = 'run `no-mistakes` now' ] \
  || fail "a backticked span must survive verbatim (got '$d1_tick')"
d1_branch=$(printf '%s' 'on fm/no-mistakes-thing branch' \
  | bash -c '. "$1"; desk_plain' _ "$LIB")
[ "$d1_branch" = 'on fm/no-mistakes-thing branch' ] \
  || fail "a branch/path token must survive verbatim (got '$d1_branch')"
pass "DEFECT 1: desk_plain protects literal commands while translating prose"

# --- ITEM 4: header usage line from the jcode plane -------------------------
# The captain's session usage rides in the MODEL header so BOTH boards render it
# and the crate stays file-driven. The source is `jcode usage --json` (the plane
# the fleet runs on), read through a desk-owned disk cache. A stub jcode binary +
# a fresh per-test cache path let us assert the compact 5h+7d line for the ACTIVE
# account (the ✦-marked provider), the GAP-on-failure path, and the no-window
# path. FM_DESK_JCODE_USAGE_BIN + FM_DESK_JCODE_USAGE_CACHE are the seams.
JU_OK="$TMP_ROOT/jcode-usage-ok.sh"
cat > "$JU_OK" <<'SH'
#!/usr/bin/env bash
# The ACTIVE account carries the ✦ marker in provider_name; a second account has
# no marker (must never be read for the header line). Each carries the two named
# limits plus a "Last used" extra.
cat <<'JSON'
{ "providers": [
  { "provider_name": "Anthropic - claude-panda (r***e@gmail.com) ✦",
    "limits": [ { "name": "5-hour window", "usage_percent": 12, "resets_at": "2026-01-01T03:00:00+00:00" },
                { "name": "7-day window", "usage_percent": 60, "resets_at": "2026-01-03T00:00:00+00:00" },
                { "name": "7-day Fable window", "usage_percent": 0, "resets_at": null } ],
    "extra_info": [ ["Last used", "just now"] ], "error": null },
  { "provider_name": "Anthropic - claude-fox (r***e@crew.test)",
    "limits": [ { "name": "5-hour window", "usage_percent": 99, "resets_at": null } ],
    "extra_info": [ ["Last used", "3h ago"] ], "error": null } ] }
JSON
SH
chmod +x "$JU_OK"
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
usage_model=$(env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_JCODE_USAGE_BIN="$JU_OK" FM_DESK_JCODE_USAGE_CACHE="$TMP_ROOT/ju-ok-cache.json" \
  FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB")
uline=$(printf '%s' "$usage_model" | jq -r '.header.usage.line')
# One compact line: percent used + terse reset, for both the 5h session and 7d week.
assert_contains "$uline" "session 12%" "usage line shows the 5h session percent"
assert_contains "$uline" "week 60%" "usage line shows the 7d week percent"
assert_contains "$uline" "resets 3h" "usage line shows a terse session reset (3h)"
assert_contains "$uline" "resets 2d" "usage line shows a terse week reset (2d)"
# The active-account line is read, NOT the 99% inactive one.
assert_not_contains "$uline" "99%" "the header line reads the active account, not an inactive one"
# The structured figures ride along for a future surface.
usp=$(printf '%s' "$usage_model" | jq -r '.header.usage.session.percent_used')
[ "$usp" = "12" ] || fail "usage.session.percent_used must be 12 (got '$usp')"
# It must NOT dump the whole structure: no Fable/last-used leaks into the header line.
assert_not_contains "$uline" "Fable" "the usage line never dumps other windows"
pass "ITEM 4: jcode usage folds into one compact 5h+7d header line for the active account"

# GAP on failure: a jcode-usage binary that fails AND no readable cache is a gap
# line, never a crash, and the model carries no usage.
JU_FAIL="$TMP_ROOT/jcode-usage-fail.sh"
printf '#!/usr/bin/env bash\nexit 3\n' > "$JU_FAIL"; chmod +x "$JU_FAIL"
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
fail_model=$(env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_JCODE_USAGE_BIN="$JU_FAIL" FM_DESK_JCODE_USAGE_CACHE="$TMP_ROOT/ju-fail-cache.json" \
  FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB")
fusage=$(printf '%s' "$fail_model" | jq -r '.header.usage')
[ "$fusage" = "null" ] || fail "a failing jcode usage must leave header.usage null (got '$fusage')"
fgaps=$(printf '%s' "$fail_model" | jq -r '.gaps | join("\n")')
assert_contains "$fgaps" "Claude session usage could not be read" "a failing jcode usage adds a gap line"
pass "ITEM 4: a failing jcode usage is a gap line, not a crash, with no usage in the model"

# No usable window (the active account carries no limits): no line AND no gap -
# nothing to show. The cache is readable, so it is NOT a gap.
JU_EMPTY="$TMP_ROOT/jcode-usage-empty.sh"
cat > "$JU_EMPTY" <<'SH'
#!/usr/bin/env bash
echo '{ "providers": [ { "provider_name": "Anthropic - claude-panda (r***e@gmail.com) ✦", "limits": [], "extra_info": [], "error": null } ] }'
SH
chmod +x "$JU_EMPTY"
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
empty_model=$(env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_JCODE_USAGE_BIN="$JU_EMPTY" FM_DESK_JCODE_USAGE_CACHE="$TMP_ROOT/ju-empty-cache.json" \
  FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB")
eusage=$(printf '%s' "$empty_model" | jq -r '.header.usage')
[ "$eusage" = "null" ] || fail "no usable window must leave header.usage null (got '$eusage')"
egaps=$(printf '%s' "$empty_model" | jq -r '.gaps | join("\n")')
assert_not_contains "$egaps" "Claude session usage" "no usable window is not a gap"
pass "ITEM 4: no usable window yields no usage line and no gap"

# --- Claude accounts (all three) + which store uses which --------------------
# The captain asked to see ALL managed accounts on the board, mark which
# credential store points at which, and switch the global account. The MODEL
# gathers the ROSTER from `cswap list --json` (all accounts; quota-axi cannot)
# plus the jcode auth store (~/.jcode/auth.json). The USAGE numbers + last-used
# come from `jcode usage --json` (matched by email), NOT cswap. Three stubs make
# it deterministic; a stub jcode auth file lets us assert the store markers.
CSWAP_OK="$TMP_ROOT/cswap-ok.sh"
cat > "$CSWAP_OK" <<'SH'
#!/usr/bin/env bash
# schemaVersion 1: three accounts, #3 active in the Claude Code store, #2 held out
# of rotation (disabled:true is the REAL JSON signal, not text parsing). cswap is
# now the ROSTER source only - its own .usage is deliberately absent to prove the
# numbers come from the jcode plane, never from cswap.
cat <<'JSON'
{ "schemaVersion": 1, "activeAccountNumber": 3, "accounts": [
  { "number": 1, "email": "sampledev@crew.test", "active": false },
  { "number": 2, "email": "crew@example.net", "active": false, "disabled": true },
  { "number": 3, "email": "sample.person@gmail.com", "active": true } ] }
JSON
SH
chmod +x "$CSWAP_OK"
# jcode usage: the per-account 5h/7d numbers + last-used, keyed by the animal
# alias in provider_name (resolved to email through auth.json). Account 1
# (claude-fox) is the ✦ active one. The numbers match what the assertions below
# expect, and are deliberately DIFFERENT from any cswap .usage to prove the
# source switch. Account 2 (claude-otter) is rate-limited (error + empty limits).
JU_ACCT="$TMP_ROOT/jcode-usage-acct.sh"
cat > "$JU_ACCT" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{ "providers": [
  { "provider_name": "Anthropic - claude-fox (r***e@crew.test) ✦",
    "limits": [ { "name": "5-hour window", "usage_percent": 100.0, "resets_at": "2026-01-01T05:00:00+00:00" },
                { "name": "7-day window", "usage_percent": 78.0, "resets_at": "2026-01-01T21:00:00+00:00" } ],
    "extra_info": [ ["Last used", "just now"] ], "error": null },
  { "provider_name": "Anthropic - claude-otter (r***n@example.net)",
    "limits": [], "extra_info": [ ["Last used", "2d ago"] ],
    "error": "Usage API error (429 Too Many Requests)" },
  { "provider_name": "Anthropic - claude-panda (r***e@gmail.com)",
    "limits": [ { "name": "5-hour window", "usage_percent": 20.0, "resets_at": "2026-01-01T05:00:00+00:00" },
                { "name": "7-day window", "usage_percent": 4.0, "resets_at": "2026-01-07T21:00:00+00:00" } ],
    "extra_info": [ ["Last used", "5m ago"] ], "error": null } ] }
JSON
SH
chmod +x "$JU_ACCT"
# jcode auth: active account is claude-fox (sampledev@crew.test), so the jcode
# plane points at a DIFFERENT account than the Claude Code plane (account 3).
JCODE_AUTH="$TMP_ROOT/jcode-auth.json"
cat > "$JCODE_AUTH" <<'JSON'
{ "active_anthropic_account": "claude-fox",
  "anthropic_accounts": [
    { "label": "claude-otter", "email": "crew@example.net" },
    { "label": "claude-fox", "email": "sampledev@crew.test" },
    { "label": "claude-panda", "email": "sample.person@gmail.com" } ] }
JSON
# acct_env: the shared seam for the account tests below. The jcode-usage source is
# the OK stub with a fresh per-test cache.
acct_env() {
  env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
    FM_DESK_CSWAP_BIN="$CSWAP_OK" FM_DESK_JCODE_AUTH="$JCODE_AUTH" \
    FM_DESK_JCODE_USAGE_BIN="$JU_ACCT" FM_DESK_JCODE_USAGE_CACHE="$TMP_ROOT/ju-acct-cache-$1.json" \
    FM_DESK_NOW="2026-01-01 00:00:00 UTC" "${@:2}"
}
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
acct_model=$(acct_env main bash -c '. "$1"; desk_project' _ "$LIB")
# All three accounts appear (quota-axi could only show one).
alen=$(printf '%s' "$acct_model" | jq -r '.header.accounts.accounts | length')
[ "$alen" = "3" ] || fail "all three accounts must appear (got '$alen')"
# The store markers are HONEST and per-store: Claude Code marks account 3 (active
# number), jcode marks account 1 (its active email), and they legitimately differ.
cc_mark=$(printf '%s' "$acct_model" | jq -r '.header.accounts.accounts[] | select(.number==3) | .claude_code_marked')
jc_mark=$(printf '%s' "$acct_model" | jq -r '.header.accounts.accounts[] | select(.number==1) | .jcode_active')
[ "$cc_mark" = "true" ] || fail "the Claude Code active account (3) must be marked"
[ "$jc_mark" = "true" ] || fail "the jcode active account (1) must be marked"
# The two planes point at DIFFERENT accounts here, and both are shown.
line3=$(printf '%s' "$acct_model" | jq -r '.header.accounts.lines[] | select(startswith("3 "))')
line1=$(printf '%s' "$acct_model" | jq -r '.header.accounts.lines[] | select(startswith("1 "))')
assert_contains "$line3" "<- cc" "account 3 line marks the Claude Code store"
assert_contains "$line1" "jcode" "account 1 line marks the jcode store"
# The disabled flag comes ONLY from the JSON disabled:true, never text parsing.
line2=$(printf '%s' "$acct_model" | jq -r '.header.accounts.lines[] | select(startswith("2 "))')
assert_contains "$line2" "(disabled)" "account 2 shows disabled from the JSON flag"
d1=$(printf '%s' "$acct_model" | jq -r '.header.accounts.accounts[] | select(.number==1) | .disabled')
[ "$d1" = "false" ] || fail "an account with no disabled flag must not be marked disabled"
# The honesty caption is present and never asserts a live-session claim.
cap=$(printf '%s' "$acct_model" | jq -r '.header.accounts.caption')
assert_contains "$cap" "a running session may differ" "the caption states the honesty caveat"
# No secret ever leaks into the account block.
blob=$(printf '%s' "$acct_model" | jq -c '.header.accounts')
assert_not_contains "$blob" "organizationUuid" "no organizationUuid in the account block"
assert_not_contains "$blob" "refresh" "no refresh token in the account block"
pass "accounts: all three shown, honest per-store markers, JSON-only disabled, no secrets"

# CHANGE 1: each line shows its jcode animal alias from auth.json (per-email map),
# terse and inline (label then email), and it is also a structured field. Account
# 1 is claude-fox, account 3 is claude-panda; a missing label degrades silently.
# The line carries the animal alias WHOLE - "claude-fox", the account's real name
# in jcode's own auth.json and the name fm-claude-switch resolves by - never an
# abbreviation of it. A row too wide for its pane drops the label outright rather
# than painting a name the account does not have.
assert_contains "$line1" "1 claude-fox sampledev@crew.test" "account 1 line shows its jcode animal alias"
assert_contains "$line3" "3 claude-panda sample.person@gmail.com" "account 3 line shows its jcode animal alias"
lbl1=$(printf '%s' "$acct_model" | jq -r '.header.accounts.accounts[] | select(.number==1) | .jcode_label')
[ "$lbl1" = "claude-fox" ] || fail "account 1 must carry jcode_label claude-fox (got '$lbl1')"
lbl3=$(printf '%s' "$acct_model" | jq -r '.header.accounts.accounts[] | select(.number==3) | .jcode_label')
[ "$lbl3" = "claude-panda" ] || fail "account 3 must carry jcode_label claude-panda (got '$lbl3')"
# The email is shown ONCE per line (label plus email, never a duplicated email).
e1count=$(printf '%s' "$line1" | grep -o 'sampledev@crew.test' | wc -l)
[ "$e1count" = "1" ] || fail "account 1 email must appear exactly once (got '$e1count')"
pass "accounts: each line carries its jcode animal alias, terse, one representation"

# CHANGE 2: the 5h and 7d percents are classed INDEPENDENTLY (same thresholds as
# MR !35), each token carrying its ascii shape glyph for the NO_COLOR reader.
# Account 1: 5h 100% -> blocked, 7d 78% -> waiting. Account 3: 5h 20% + / 7d 4% +.
f1=$(printf '%s' "$acct_model" | jq -r '.header.accounts.accounts[] | select(.number==1) | .five_hour_class')
s1=$(printf '%s' "$acct_model" | jq -r '.header.accounts.accounts[] | select(.number==1) | .seven_day_class')
[ "$f1" = "blocked" ] || fail "account 1 5h (100%) must class blocked (got '$f1')"
[ "$s1" = "waiting" ] || fail "account 1 7d (78%) must class waiting (got '$s1')"
f3=$(printf '%s' "$acct_model" | jq -r '.header.accounts.accounts[] | select(.number==3) | .five_hour_class')
[ "$f3" = "done" ] || fail "account 3 5h (20%) must class done (got '$f3')"
# The parallel per-window token arrays carry the class glyph baked in.
ft1=$(printf '%s' "$acct_model" | jq -r '.header.accounts.five_hour_tokens[0]')
st1=$(printf '%s' "$acct_model" | jq -r '.header.accounts.seven_day_tokens[0]')
assert_contains "$ft1" "5h 100%x" "account 1 5h token carries the spent 'x' ascii glyph"
assert_contains "$st1" "7d 78%?" "account 1 7d token carries the tight '?' ascii glyph"
# Both windows carry their own terse reset, so the 5h reset is no longer discarded.
# Account 1: 5h resets_at 05:00 from now 00:00 = 5h; 7d resets_at 21:00 = 21h.
r5_1=$(printf '%s' "$acct_model" | jq -r '.header.accounts.accounts[] | select(.number==1) | .five_hour_resets_in')
r7_1=$(printf '%s' "$acct_model" | jq -r '.header.accounts.accounts[] | select(.number==1) | .seven_day_resets_in')
[ "$r5_1" = "5h" ] || fail "account 1 5h reset must be 5h (got '$r5_1')"
[ "$r7_1" = "21h" ] || fail "account 1 7d reset must be 21h (got '$r7_1')"
assert_contains "$line1" "5h 100%x (5h)" "account 1 line renders the 5h reset beside its 5h token"
assert_contains "$line1" "7d 78%? (21h)" "account 1 line still renders the 7d reset beside its 7d token"
# LEGIBILITY (a hard constraint): the captain reads these lines over SSH, where the
# board falls back to 80 columns and clips the overflow with an ellipsis. The whole
# composition is pinned here - identifiers, both windows with their resets, store
# marker - so no token silently reappears on the line and pushes it into the clip.
# The on-line "used <x>" text is what was traded away to pay for the 5h reset.
exp1="1 claude-fox sampledev@crew.test  5h 100%x (5h) · 7d 78%? (21h)  <- jcode"
[ "$line1" = "$exp1" ] || fail "account 1 line composition drifted:
  want: $exp1
  got:  $line1"
# The invariant behind it: NO composed account line exceeds the lib's own column
# budget, so no board ever receives a line its clip would cut mid-word. Width is
# counted the way the boards count it - a UTF-8 continuation byte continues the
# current column - so the ambient locale cannot change the answer.
vwidth() { local LC_ALL=C _s=$1 _b; _b=${_s//[$'\x80'-$'\xbf']/}; printf '%d' "${#_b}"; }
# The budget is stated ONCE, in the lib, and read from there - never repeated as a
# number here. The Rust board mirrors it for its own tests, so the two are
# reconciled right here: a budget that moved in one renderer and not the other is
# exactly the duplicate-logic drift this file keeps closing.
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
ACCT_COLS=$(bash -c '. "$1"; printf "%s" "$DESK_ACCOUNT_COLS"' _ "$LIB")
case "$ACCT_COLS" in ''|*[!0-9]*) fail "the lib must state DESK_ACCOUNT_COLS (got '$ACCT_COLS')" ;; esac
rust_cols=$(sed -n 's/^pub const ACCOUNT_LINE_COLS: usize = \([0-9][0-9]*\);.*/\1/p' "$ROOT/desk/src/render.rs")
[ "$rust_cols" = "$ACCT_COLS" ] \
  || fail "desk/src/render.rs ACCOUNT_LINE_COLS ($rust_cols) must mirror the lib's DESK_ACCOUNT_COLS ($ACCT_COLS)"
while IFS= read -r _al; do
  _aw=$(vwidth "$_al")
  [ "$_aw" -le "$ACCT_COLS" ] || fail "account line must fit the $ACCT_COLS-column budget (got $_aw): $_al"
done < <(printf '%s' "$acct_model" | jq -r '.header.accounts.lines[]')
unset _al _aw
# A disabled account reads idle for both windows, never a false green.
f2=$(printf '%s' "$acct_model" | jq -r '.header.accounts.accounts[] | select(.number==2) | .five_hour_class')
[ "$f2" = "idle" ] || fail "disabled account 2 5h must class idle (got '$f2')"
pass "accounts: 5h and 7d classed independently, each with a NO_COLOR ascii carrier"

# A reset instant that has ALREADY PASSED is omitted, never painted as "(0m)" - a
# statement that the window resets right now, which is simply false for a window
# that has already rolled over. This is the steady state of an inherited reading:
# a 429/errored provider keeps the prior limits with their ORIGINAL resets_at, so
# the instant recedes into the past while the percent keeps painting. Same fixture,
# read from a "now" past BOTH of account 1's reset instants (05:00 and 21:00 on
# 2026-01-01): the percents still paint, the resets simply drop.
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
past_model=$(env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_CSWAP_BIN="$CSWAP_OK" FM_DESK_JCODE_AUTH="$JCODE_AUTH" \
  FM_DESK_JCODE_USAGE_BIN="$JU_ACCT" FM_DESK_JCODE_USAGE_CACHE="$TMP_ROOT/ju-acct-cache-past.json" \
  FM_DESK_NOW="2026-01-02 00:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB")
past_line1=$(printf '%s' "$past_model" | jq -r '.header.accounts.lines[] | select(startswith("1 "))')
assert_contains "$past_line1" "5h 100%x" "a passed-reset account still paints its 5h percent"
assert_contains "$past_line1" "7d 78%?" "a passed-reset account still paints its 7d percent"
assert_not_contains "$past_line1" "(0m)" "a reset instant already in the past paints no '(0m)'"
pr5=$(printf '%s' "$past_model" | jq -r '.header.accounts.accounts[] | select(.number==1) | .five_hour_resets_in')
pr7=$(printf '%s' "$past_model" | jq -r '.header.accounts.accounts[] | select(.number==1) | .seven_day_resets_in')
[ "$pr5" = "null" ] || fail "a 5h reset already in the past must carry no reset (got '$pr5')"
[ "$pr7" = "null" ] || fail "a 7d reset already in the past must carry no reset (got '$pr7')"
# A still-FUTURE reset in the same paint is untouched, so the suppression is not a
# blanket drop: account 3's 7d resets at 2026-01-07T21:00, still ahead of this
# "now", and reads "5d" - while its own already-passed 5h reset is dropped.
past_line3=$(printf '%s' "$past_model" | jq -r '.header.accounts.lines[] | select(startswith("3 "))')
assert_contains "$past_line3" "7d 4%+ (5d)" "a still-future reset is unchanged by the suppression"
assert_contains "$past_line3" "5h 20%+ ·" "the same line drops only the reset whose instant has passed"
pass "accounts: a reset instant already in the past is dropped, never painted '(0m)'"

# --- the fit ladder terminates INSIDE the budget, for every input -------------
# A disabled account still RECEIVES its jcode reading (the disabled branch only
# overrides the window CLASSES, after the tokens are built), so the widest row the
# block can produce is a disabled account carrying the longest real email, both
# windows spent, both resets at their widest single-unit form, the routine
# "(Nm old)" staleness token, and BOTH store markers resolving to it. Every rung
# of the ladder fires on that row, and what it emits must be inside the budget
# with nothing cut mid-word.
#
# The cache is written DIRECTLY with a per-provider fetched_at 90 seconds behind
# the render time: the blob itself is fresh (so no re-fetch, and the stub binary is
# never consulted) while the provider's own reading is past the 60s age floor -
# the routine half of every TTL cycle, which is what paints "(1m old)".
PATHO_CSWAP="$TMP_ROOT/cswap-patho.sh"
cat > "$PATHO_CSWAP" <<'SH'
#!/usr/bin/env bash
echo '{ "schemaVersion": 1, "activeAccountNumber": 2, "accounts": [
  { "number": 2, "email": "sample.person@gmail.com", "active": true, "disabled": true } ] }'
SH
chmod +x "$PATHO_CSWAP"
PATHO_AUTH="$TMP_ROOT/jcode-auth-patho.json"
cat > "$PATHO_AUTH" <<'JSON'
{ "active_anthropic_account": "claude-otter",
  "anthropic_accounts": [ { "label": "claude-otter", "email": "sample.person@gmail.com" } ] }
JSON
PATHO_CACHE="$TMP_ROOT/ju-patho-cache.json"
patho_now=$(date -d "2026-01-01 00:00:00 UTC" +%s)
cat > "$PATHO_CACHE" <<JSON
{ "fetched_at": $patho_now, "providers": [
  { "provider_name": "Anthropic - claude-otter (r***e@gmail.com) \u2726",
    "fetched_at": $((patho_now - 90)),
    "limits": [ { "name": "5-hour window", "usage_percent": 100.0, "resets_at": "2026-01-01T00:59:00+00:00" },
                { "name": "7-day window", "usage_percent": 100.0, "resets_at": "2026-01-01T23:00:00+00:00" } ],
    "extra_info": [ ["Last used", "just now"] ], "error": null } ] }
JSON
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
patho_model=$(env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_CSWAP_BIN="$PATHO_CSWAP" FM_DESK_JCODE_AUTH="$PATHO_AUTH" \
  FM_DESK_JCODE_USAGE_BIN="$TMP_ROOT/no-such-jcode" FM_DESK_JCODE_USAGE_CACHE="$PATHO_CACHE" \
  FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB")
patho_line=$(printf '%s' "$patho_model" | jq -r '.header.accounts.lines[0]')
patho_w=$(vwidth "$patho_line")
[ "$patho_w" -le "$ACCT_COLS" ] \
  || fail "the widest disabled row must fit $ACCT_COLS columns (got $patho_w): $patho_line"
# What the captain decides on is never what gives way.
assert_contains "$patho_line" "5h 100%. (59m)" "the spent 5h window keeps its reset through the ladder"
assert_contains "$patho_line" "7d 100%. (23h)" "the spent 7d window keeps its reset through the ladder"
assert_contains "$patho_line" "(1m old)" "the staleness token is never the thing dropped"
assert_contains "$patho_line" "sample.person@gmail.com" "the email still names the account"
# What did give way went WHOLE - the ladder drops decorations, it does not cut.
assert_not_contains "$patho_line" "(disable" "the disabled suffix is dropped whole, never cut mid-word"
assert_not_contains "$patho_line" "claude-otter" "the label is dropped whole on a row that cannot hold it"
assert_not_contains "$patho_line" "<-" "the store marker is dropped whole"
assert_not_contains "$patho_line" "…" "the lib emits no ellipsis of its own"
# The structured flags stay authoritative for whatever a board wants to mark.
pd=$(printf '%s' "$patho_model" | jq -r '.header.accounts.accounts[0].disabled')
[ "$pd" = "true" ] || fail "the disabled flag must stay true in the model (got '$pd')"

# The TERMINAL rung: input no arrangement of decorations can fit - an email that
# blows the budget on its own - is STILL emitted within budget. The lib never hands
# a board an over-wide line and trusts the board's clip to be the correctness
# boundary; that clip is a visual backstop, not the invariant.
LONG_CSWAP="$TMP_ROOT/cswap-long.sh"
cat > "$LONG_CSWAP" <<'SH'
#!/usr/bin/env bash
echo '{ "schemaVersion": 1, "activeAccountNumber": 1, "accounts": [
  { "number": 1, "active": true,
    "email": "an.extremely.long.mailbox.name.that.cannot.fit@a-very-long-domain.example.test" } ] }'
SH
chmod +x "$LONG_CSWAP"
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
long_model=$(env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_CSWAP_BIN="$LONG_CSWAP" FM_DESK_JCODE_AUTH="$JCODE_AUTH" \
  FM_DESK_JCODE_USAGE_BIN="$TMP_ROOT/no-such-jcode" FM_DESK_JCODE_USAGE_CACHE="$TMP_ROOT/ju-long-cache.json" \
  FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB")
long_line=$(printf '%s' "$long_model" | jq -r '.header.accounts.lines[0]')
long_w=$(vwidth "$long_line")
[ "$long_w" -le "$ACCT_COLS" ] \
  || fail "an unfittable email must still be clamped to $ACCT_COLS columns (got $long_w): $long_line"
# The clamp cuts on a CHARACTER boundary, so a multibyte glyph is kept whole or
# dropped whole - never split into a mojibake half byte.
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
clamped=$(bash -c '. "$1"; _desk_clamp "abc·defghij" 4; printf "%s" "$_DESK_CLAMPED"' _ "$LIB")
[ "$clamped" = "abc·" ] || fail "the clamp must cut on a character boundary (got '$clamped')"
cw=$(vwidth "$clamped")
[ "$cw" = "4" ] || fail "the clamp must answer in visible columns, not bytes (got $cw)"
pass "accounts: the fit ladder lands every row inside the budget, dropping whole decorations"

# GAP on failure: a cswap that errors is a gap line, never a crash, and the model
# carries no accounts.
CSWAP_FAIL="$TMP_ROOT/cswap-fail.sh"
printf '#!/usr/bin/env bash\nexit 3\n' > "$CSWAP_FAIL"; chmod +x "$CSWAP_FAIL"
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
afail_model=$(env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_CSWAP_BIN="$CSWAP_FAIL" FM_DESK_JCODE_AUTH="$JCODE_AUTH" FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB")
aacc=$(printf '%s' "$afail_model" | jq -r '.header.accounts')
[ "$aacc" = "null" ] || fail "a failing cswap must leave header.accounts null (got '$aacc')"
agaps=$(printf '%s' "$afail_model" | jq -r '.gaps | join("\n")')
assert_contains "$agaps" "Claude accounts could not be read" "a failing cswap adds a gap line"
pass "accounts: a failing cswap is a gap line, not a crash, with no accounts in the model"

# No accounts (an empty cswap): no block AND no gap - nothing to show.
CSWAP_EMPTY="$TMP_ROOT/cswap-empty.sh"
cat > "$CSWAP_EMPTY" <<'SH'
#!/usr/bin/env bash
echo '{ "schemaVersion": 1, "activeAccountNumber": null, "accounts": [] }'
SH
chmod +x "$CSWAP_EMPTY"
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
aempty_model=$(env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_CSWAP_BIN="$CSWAP_EMPTY" FM_DESK_JCODE_AUTH="$JCODE_AUTH" FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB")
eacc=$(printf '%s' "$aempty_model" | jq -r '.header.accounts')
[ "$eacc" = "null" ] || fail "no accounts must leave header.accounts null (got '$eacc')"
eagaps=$(printf '%s' "$aempty_model" | jq -r '.gaps | join("\n")')
assert_not_contains "$eagaps" "Claude accounts could not be read" "no accounts is not a gap"
pass "accounts: an empty cswap yields no account block and no gap"

# --- jcode-plane usage: source switch, throttle, staleness, last-used --------
# The whole point of the change: usage numbers come from `jcode usage --json`
# (the plane the fleet runs on), matched by email, throttled behind a desk-owned
# disk cache. cswap owns roster + switch only.

# SOURCE SWITCH: the per-account numbers are the jcode ones (100/78 for account 1,
# 20/4 for account 3), NOT cswap's - the cswap stub above deliberately carries NO
# .usage, so a number appearing at all proves it came from the jcode plane.
p1=$(printf '%s' "$acct_model" | jq -r '.header.accounts.accounts[] | select(.number==1) | .five_hour_pct')
p3=$(printf '%s' "$acct_model" | jq -r '.header.accounts.accounts[] | select(.number==3) | .seven_day_pct')
[ "$p1" = "100" ] || fail "account 1 5h must be the jcode 100 (got '$p1')"
[ "$p3" = "4" ] || fail "account 3 7d must be the jcode 4 (got '$p3')"
# LAST-USED rides from the jcode extra_info, the real "what is using this account".
# It is a STRUCTURED field only - the rendered line spends its 80-column budget on
# the identifiers and both windows with their resets, so no "used <x>" text.
lu1=$(printf '%s' "$acct_model" | jq -r '.header.accounts.accounts[] | select(.number==1) | .last_used')
[ "$lu1" = "just now" ] || fail "account 1 last_used must be the jcode 'just now' (got '$lu1')"
assert_not_contains "$line1" "used just now" "account 1 line spends no width on the last-used text"
# A rate-limited jcode account (empty limits + a "Last used" extra) shows NO number
# rather than a stale one, yet KEEPS its structured last-used: account 2 is claude-otter with a
# 429 error and no limits. This guards the U+001F field split: a tab collapses the
# empty 5h/7d/reset fields and shifts "Last used" into the 5h slot, painting a
# garbled "5h 22d ago%" token; the unit separator keeps every empty field in place.
a2() { printf '%s' "$acct_model" | jq -r ".header.accounts.accounts[] | select(.number==2) | $1"; }
p2=$(a2 .five_hour_pct); [ "$p2" = "null" ] || fail "account 2 must show no 5h number (got '$p2')"
s2p=$(a2 .seven_day_pct); [ "$s2p" = "null" ] || fail "account 2 must show no 7d number (got '$s2p')"
ft2=$(a2 .five_hour_token); [ "$ft2" = "null" ] || fail "account 2 must carry no 5h token (got '$ft2')"
st2=$(a2 .seven_day_token); [ "$st2" = "null" ] || fail "account 2 must carry no 7d token (got '$st2')"
lu2=$(a2 .last_used); [ "$lu2" = "2d ago" ] || fail "account 2 last_used must be the jcode '2d ago' (got '$lu2')"
assert_not_contains "$line2" "used 2d ago" "account 2 line spends no width on the last-used text"
assert_not_contains "$line2" "22d ago" "account 2 line has no garbled shifted token"
assert_not_contains "$line2" "5h " "account 2 line carries no 5h metric token"
pass "jcode source: per-account usage + last-used come from the jcode plane, not cswap"

# THROTTLE (the captain's hard acceptance criterion): 10 rapid model regenerations
# within the TTL (default 120s) trigger AT MOST 1 `jcode usage` fetch. The counting
# stub appends one line per invocation; a shared fresh cache across all 10 regens
# means only the first cold read fetches, the rest reuse the disk cache.
JU_COUNT_LOG="$TMP_ROOT/ju-fetch-count.log"
JU_COUNT="$TMP_ROOT/jcode-usage-count.sh"
cat > "$JU_COUNT" <<SH
#!/usr/bin/env bash
echo fetch >> "$JU_COUNT_LOG"
cat <<'JSON'
{ "providers": [ { "provider_name": "Anthropic - claude-panda (r***e@gmail.com) ✦", "limits": [ { "name": "5-hour window", "usage_percent": 10, "resets_at": null } ], "extra_info": [ ["Last used", "just now"] ], "error": null } ] }
JSON
SH
chmod +x "$JU_COUNT"
: > "$JU_COUNT_LOG"
THROTTLE_CACHE="$TMP_ROOT/ju-throttle-cache.json"
rm -f "$THROTTLE_CACHE"
i=0
while [ "$i" -lt 10 ]; do
  # shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
  env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
    FM_DESK_JCODE_USAGE_BIN="$JU_COUNT" FM_DESK_JCODE_USAGE_CACHE="$THROTTLE_CACHE" \
    bash -c '. "$1"; desk_project' _ "$LIB" >/dev/null 2>&1
  i=$((i + 1))
done
fetches=$(wc -l < "$JU_COUNT_LOG" | tr -d ' ')
[ "$fetches" -le 1 ] || fail "10 regens must trigger AT MOST 1 jcode-usage fetch (got $fetches)"
[ "$fetches" -eq 1 ] || fail "10 regens must trigger EXACTLY 1 fetch on a cold cache (got $fetches)"
pass "throttle: 10 model regens trigger at most 1 jcode-usage fetch ($fetches)"

# THROTTLE FLOOR RESPECTED: a cache younger than the TTL is reused with NO fetch,
# even on the very next regen. Reuse the warm cache from the throttle run above.
: > "$JU_COUNT_LOG"
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_JCODE_USAGE_BIN="$JU_COUNT" FM_DESK_JCODE_USAGE_CACHE="$THROTTLE_CACHE" \
  bash -c '. "$1"; desk_project' _ "$LIB" >/dev/null 2>&1
warm_fetches=$(wc -l < "$JU_COUNT_LOG" | tr -d ' ')
[ "$warm_fetches" -eq 0 ] || fail "a fresh cache must trigger NO fetch (got $warm_fetches)"
pass "throttle: a cache younger than the TTL is reused with no fetch"

# RE-FETCH ABOVE THE FLOOR: a cache older than the TTL DOES re-fetch. Force the
# cache mtime old, then one regen must fetch exactly once.
: > "$JU_COUNT_LOG"
touch -d '2020-01-01 00:00:00' "$THROTTLE_CACHE" 2>/dev/null \
  || touch -t 202001010000 "$THROTTLE_CACHE"
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_JCODE_USAGE_BIN="$JU_COUNT" FM_DESK_JCODE_USAGE_CACHE="$THROTTLE_CACHE" \
  bash -c '. "$1"; desk_project' _ "$LIB" >/dev/null 2>&1
stale_fetches=$(wc -l < "$JU_COUNT_LOG" | tr -d ' ')
[ "$stale_fetches" -eq 1 ] || fail "a cache older than the TTL must re-fetch once (got $stale_fetches)"
pass "throttle: a cache older than the TTL re-fetches"

# STALE-CACHE AGE SURFACED: a stale-but-readable cache is USED (a known-age number
# beats a gap), and its age is surfaced so it is never painted as live. Seed a
# readable cache, force an old mtime, then read with a FAILING binary so no fetch
# refreshes it. The age token appears on the line and as a structured field.
STALE_CACHE="$TMP_ROOT/ju-stale-cache.json"
cat > "$STALE_CACHE" <<'JSON'
{ "providers": [
  { "provider_name": "Anthropic - claude-panda (r***e@gmail.com) ✦",
    "limits": [ { "name": "5-hour window", "usage_percent": 100, "resets_at": null } ],
    "extra_info": [ ["Last used", "6m ago"] ], "error": null } ],
  "fetched_at": 1735689600 }
JSON
touch -d '2020-01-01 00:00:00' "$STALE_CACHE" 2>/dev/null \
  || touch -t 202001010000 "$STALE_CACHE"
STALE_AUTH="$TMP_ROOT/jcode-auth-stale.json"
cat > "$STALE_AUTH" <<'JSON'
{ "active_anthropic_account": "claude-panda",
  "anthropic_accounts": [ { "label": "claude-panda", "email": "sample.person@gmail.com" } ] }
JSON
STALE_CSWAP="$TMP_ROOT/cswap-stale.sh"
cat > "$STALE_CSWAP" <<'SH'
#!/usr/bin/env bash
echo '{ "schemaVersion": 1, "activeAccountNumber": 1, "accounts": [ { "number": 1, "email": "sample.person@gmail.com", "active": true } ] }'
SH
chmod +x "$STALE_CSWAP"
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
stale_model=$(env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_CSWAP_BIN="$STALE_CSWAP" FM_DESK_JCODE_AUTH="$STALE_AUTH" \
  FM_DESK_JCODE_USAGE_BIN="$JU_FAIL" FM_DESK_JCODE_USAGE_CACHE="$STALE_CACHE" \
  bash -c '. "$1"; desk_project' _ "$LIB")
# The stale number is still shown (used, not dropped), and its age is surfaced.
sp1=$(printf '%s' "$stale_model" | jq -r '.header.accounts.accounts[0].five_hour_pct')
[ "$sp1" = "100" ] || fail "a stale-but-readable cache must still show its number (got '$sp1')"
sage=$(printf '%s' "$stale_model" | jq -r '.header.accounts.accounts[0].data_age')
assert_contains "$sage" "old" "a stale account reading surfaces its age as a data_age token"
sline=$(printf '%s' "$stale_model" | jq -r '.header.accounts.lines[0]')
assert_contains "$sline" "old" "a stale account line surfaces its age inline"
# The header usage line surfaces the same age.
suline=$(printf '%s' "$stale_model" | jq -r '.header.usage.line')
assert_contains "$suline" "old" "the header usage line surfaces the stale age"
suage=$(printf '%s' "$stale_model" | jq -r '.header.usage.age')
assert_contains "$suage" "old" "the header usage carries a structured age token"
pass "staleness: a stale-but-readable cache is used and its age is surfaced, never hidden"

# FRESH READING carries NO age token (a tight line stays clean). Use the OK stub
# with a fresh cache: the age is 0, well under the TTL, so no token appears.
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
fresh_model=$(acct_env fresh bash -c '. "$1"; desk_project' _ "$LIB")
fage=$(printf '%s' "$fresh_model" | jq -r '.header.accounts.accounts[0].data_age')
[ "$fage" = "null" ] || fail "a fresh reading must carry no age token (got '$fage')"
fuage=$(printf '%s' "$fresh_model" | jq -r '.header.usage.age')
[ "$fuage" = "null" ] || fail "a fresh header usage must carry no age token (got '$fuage')"
pass "staleness: a fresh reading carries no age token"

# AGE FLOOR: the exact bug MR !43 shipped. The cache REFRESHES at the TTL, so a
# reading is almost always under the TTL; gating the "(Nm old)" token on the TTL
# meant it NEVER fired and a stale-but-under-TTL number posed as live. A reading
# BETWEEN the age floor and the TTL must now carry the token. Seed a cache whose
# fetched_at is 90s before FM_DESK_NOW (floor 60 <= 90 < TTL 120). The file mtime
# is real-now (after the injected NOW), so its mtime age clamps to 0 and the
# honest fetched_at age of 90s wins. A FAILING binary proves no fetch resets it.
NOW_EPOCH=$(date -d "2026-01-01 00:00:00 UTC" +%s)
FLOORED_CACHE="$TMP_ROOT/ju-floored-cache.json"
cat > "$FLOORED_CACHE" <<JSON
{ "providers": [
  { "provider_name": "Anthropic - claude-panda (r***e@gmail.com) \u2726",
    "limits": [ { "name": "5-hour window", "usage_percent": 35, "resets_at": null } ],
    "extra_info": [ ["Last used", "just now"] ], "error": null } ],
  "fetched_at": $((NOW_EPOCH - 90)) }
JSON
FLOORED_AUTH="$TMP_ROOT/jcode-auth-floored.json"
cat > "$FLOORED_AUTH" <<'JSON'
{ "active_anthropic_account": "claude-panda",
  "anthropic_accounts": [ { "label": "claude-panda", "email": "sample.person@gmail.com" } ] }
JSON
FLOORED_CSWAP="$TMP_ROOT/cswap-floored.sh"
cat > "$FLOORED_CSWAP" <<'SH'
#!/usr/bin/env bash
echo '{ "schemaVersion": 1, "activeAccountNumber": 1, "accounts": [ { "number": 1, "email": "sample.person@gmail.com", "active": true } ] }'
SH
chmod +x "$FLOORED_CSWAP"
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
floored_model=$(env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_CSWAP_BIN="$FLOORED_CSWAP" FM_DESK_JCODE_AUTH="$FLOORED_AUTH" \
  FM_DESK_JCODE_USAGE_BIN="$JU_FAIL" FM_DESK_JCODE_USAGE_CACHE="$FLOORED_CACHE" \
  FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB")
# The number is still live-looking (35%), but the age token now warns it is 1m old.
fp1=$(printf '%s' "$floored_model" | jq -r '.header.accounts.accounts[0].five_hour_pct')
[ "$fp1" = "35" ] || fail "the floored reading must still show its number (got '$fp1')"
fdage=$(printf '%s' "$floored_model" | jq -r '.header.accounts.accounts[0].data_age')
assert_contains "$fdage" "old" "a reading between the floor and TTL now carries a data_age token"
assert_contains "$fdage" "1m" "the floored age token reads 1m old (90s)"
fdline=$(printf '%s' "$floored_model" | jq -r '.header.accounts.lines[0]')
assert_contains "$fdline" "old" "the floored account line surfaces its age inline"
fduage=$(printf '%s' "$floored_model" | jq -r '.header.usage.age')
assert_contains "$fduage" "old" "the header usage line surfaces the floored age (both gate sites)"
pass "age floor: a reading between the floor and the TTL now carries a (Nm old) token"

# BELOW THE FLOOR stays clean: the same seam at 30s (under floor 60) shows NO
# token, so a genuinely live line stays uncluttered.
UNDERFLOOR_CACHE="$TMP_ROOT/ju-underfloor-cache.json"
cat > "$UNDERFLOOR_CACHE" <<JSON
{ "providers": [
  { "provider_name": "Anthropic - claude-panda (r***e@gmail.com) \u2726",
    "limits": [ { "name": "5-hour window", "usage_percent": 35, "resets_at": null } ],
    "extra_info": [ ["Last used", "just now"] ], "error": null } ],
  "fetched_at": $((NOW_EPOCH - 30)) }
JSON
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
underfloor_model=$(env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_CSWAP_BIN="$FLOORED_CSWAP" FM_DESK_JCODE_AUTH="$FLOORED_AUTH" \
  FM_DESK_JCODE_USAGE_BIN="$JU_FAIL" FM_DESK_JCODE_USAGE_CACHE="$UNDERFLOOR_CACHE" \
  FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB")
ufage=$(printf '%s' "$underfloor_model" | jq -r '.header.accounts.accounts[0].data_age')
[ "$ufage" = "null" ] || fail "a reading under the floor (30s) must carry no age token (got '$ufage')"
ufuage=$(printf '%s' "$underfloor_model" | jq -r '.header.usage.age')
[ "$ufuage" = "null" ] || fail "the header usage under the floor must carry no age token (got '$ufuage')"
pass "age floor: a reading under the floor (30s) stays clean, no age token"

# AGE FLOOR IS TUNABLE: raising the floor above the reading age hides the token,
# proving FM_DESK_JCODE_USAGE_AGE_FLOOR gates the marker (not a hardcoded 60).
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
raised_model=$(env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_CSWAP_BIN="$FLOORED_CSWAP" FM_DESK_JCODE_AUTH="$FLOORED_AUTH" \
  FM_DESK_JCODE_USAGE_BIN="$JU_FAIL" FM_DESK_JCODE_USAGE_CACHE="$FLOORED_CACHE" \
  FM_DESK_JCODE_USAGE_AGE_FLOOR=100 FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB")
rdage=$(printf '%s' "$raised_model" | jq -r '.header.accounts.accounts[0].data_age')
[ "$rdage" = "null" ] || fail "a 90s reading under a raised floor (100) must carry no token (got '$rdage')"
pass "age floor: FM_DESK_JCODE_USAGE_AGE_FLOOR tunes the marker gate"

# --- last-known-good inheritance when a provider's usage fetch errors ---------
# The captain-observed bug: the ACTIVE account under load 429s, jcode yields EMPTY
# limits for it, and the desk painted NO number instead of the last-known-good one
# it had a moment ago. The fix: on cache write, a provider with error/empty limits
# INHERITS the prior cache's values for those fields plus their ORIGINAL fetched_at,
# and the age-token mechanism paints the inherited number AS stale, never as live.
# This exercises the REAL desk_jcode_usage_cached write path (not a hand-seeded
# blob): a first fetch seeds a good reading, then a second fetch of the SAME cache
# returns a 429 (empty limits) for that account and a good reading for a sibling.

LKG_AUTH="$TMP_ROOT/jcode-auth-lkg.json"
cat > "$LKG_AUTH" <<'JSON'
{ "active_anthropic_account": "claude-fox",
  "anthropic_accounts": [
    { "label": "claude-fox", "email": "sampledev@crew.test" },
    { "label": "claude-panda", "email": "sample.person@gmail.com" } ] }
JSON
LKG_CSWAP="$TMP_ROOT/cswap-lkg.sh"
cat > "$LKG_CSWAP" <<'SH'
#!/usr/bin/env bash
echo '{ "schemaVersion": 1, "activeAccountNumber": 1, "accounts": [
  { "number": 1, "email": "sampledev@crew.test", "active": true },
  { "number": 2, "email": "sample.person@gmail.com", "active": false } ] }'
SH
chmod +x "$LKG_CSWAP"

# GOOD stub: both accounts carry real windows. claude-fox is the ✦ active one.
LKG_GOOD="$TMP_ROOT/jcode-usage-lkg-good.sh"
cat > "$LKG_GOOD" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{ "providers": [
  { "provider_name": "Anthropic - claude-fox (r***e@crew.test) ✦",
    "limits": [ { "name": "5-hour window", "usage_percent": 33, "resets_at": "2026-06-01T11:58:00+00:00" },
                { "name": "7-day window", "usage_percent": 90, "resets_at": "2026-06-01T11:59:00+00:00" } ],
    "extra_info": [ ["Last used", "just now"] ], "error": null },
  { "provider_name": "Anthropic - claude-panda (r***e@gmail.com)",
    "limits": [ { "name": "5-hour window", "usage_percent": 10, "resets_at": null },
                { "name": "7-day window", "usage_percent": 5, "resets_at": null } ],
    "extra_info": [ ["Last used", "5m ago"] ], "error": null } ] }
JSON
SH
chmod +x "$LKG_GOOD"
# 429 stub: the ACTIVE account (claude-fox) errors with EMPTY limits; the sibling
# (claude-panda) returns a fresh good reading. Exactly the captain's scenario.
LKG_429="$TMP_ROOT/jcode-usage-lkg-429.sh"
cat > "$LKG_429" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{ "providers": [
  { "provider_name": "Anthropic - claude-fox (r***e@crew.test) ✦",
    "limits": [], "extra_info": [ ["Last used", "just now"] ],
    "error": "Usage API error (429 Too Many Requests)" },
  { "provider_name": "Anthropic - claude-panda (r***e@gmail.com)",
    "limits": [ { "name": "5-hour window", "usage_percent": 12, "resets_at": null },
                { "name": "7-day window", "usage_percent": 6, "resets_at": null } ],
    "extra_info": [ ["Last used", "1m ago"] ], "error": null } ] }
JSON
SH
chmod +x "$LKG_429"

LKG_CACHE="$TMP_ROOT/ju-lkg-cache.json"
rm -f "$LKG_CACHE"
lkg_env() {
  env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
    FM_DESK_CSWAP_BIN="$LKG_CSWAP" FM_DESK_JCODE_AUTH="$LKG_AUTH" \
    FM_DESK_JCODE_USAGE_CACHE="$LKG_CACHE" "$@"
}
# Step 1: seed the cache with the GOOD reading, at a time 200s before the second
# fetch, so the inherited reading will be genuinely stale (>= floor 60) at read.
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
lkg_env FM_DESK_JCODE_USAGE_BIN="$LKG_GOOD" FM_DESK_NOW="2026-06-01 11:56:40 UTC" \
  bash -c '. "$1"; desk_jcode_usage_cached >/dev/null' _ "$LIB"
# Force the cache mtime old so the second call re-fetches (past the TTL).
touch -d '2020-01-01 00:00:00' "$LKG_CACHE" 2>/dev/null || touch -t 202001010000 "$LKG_CACHE"
# Step 2: re-fetch with the 429 stub; the active account inherits its prior values.
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
lkg_model=$(lkg_env FM_DESK_JCODE_USAGE_BIN="$LKG_429" FM_DESK_NOW="2026-06-01 12:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB")

# The active (errored) account keeps its OLD 33/90 values, now age-tokened as stale.
lkg_active() { printf '%s' "$lkg_model" | jq -r ".header.accounts.accounts[] | select(.number==1) | $1"; }
a5=$(lkg_active .five_hour_pct); [ "$a5" = "33" ] || fail "errored active account must inherit its OLD 5h 33 (got '$a5')"
a7=$(lkg_active .seven_day_pct); [ "$a7" = "90" ] || fail "errored active account must inherit its OLD 7d 90 (got '$a7')"
adage=$(lkg_active .data_age); assert_contains "$adage" "old" "the inherited reading is painted AS stale with an age token"
assert_contains "$adage" "3m" "the inherited age reflects the ORIGINAL fetch time (200s ~ 3m old)"
lkg_line1=$(printf '%s' "$lkg_model" | jq -r '.header.accounts.lines[] | select(startswith("1 "))')
assert_contains "$lkg_line1" "33%" "the errored active account line still shows its last-known 5h number"
assert_contains "$lkg_line1" "old" "the errored active account line surfaces the staleness inline, not blank"
# The header usage line (also the active account) shows the inherited stale number.
lkg_uline=$(printf '%s' "$lkg_model" | jq -r '.header.usage.line')
assert_contains "$lkg_uline" "session 33%" "the header usage line keeps the inherited 5h number"
assert_contains "$lkg_uline" "old" "the header usage line paints the inherited number AS stale"
# The inherited reading keeps its ORIGINAL resets_at, so by read time (12:00) both
# instants (11:58 and 11:59) have PASSED. The header omits the reset rather than
# rendering "(resets 0m)", which would affirm that a window that has in fact
# already rolled over resets right now - beside the very number the captain picks
# an account by. The "(3m old)" token is what discloses the staleness honestly.
assert_not_contains "$lkg_uline" "resets 0m" "a passed header reset paints no '(resets 0m)'"
assert_not_contains "$lkg_uline" "(resets" "a passed header reset is omitted whole, not rounded down"
usr=$(printf '%s' "$lkg_model" | jq -r '.header.usage.session.resets_in')
uwr=$(printf '%s' "$lkg_model" | jq -r '.header.usage.week.resets_in')
[ "$usr" = "" ] || fail "a passed session reset must carry no structured reset (got '$usr')"
[ "$uwr" = "" ] || fail "a passed week reset must carry no structured reset (got '$uwr')"
# The per-account line for the SAME reading agrees: one rule, both renderers, one
# shared reset helper - this is what a private copy per renderer used to break.
assert_not_contains "$lkg_line1" "(0m)" "the per-account line agrees: no '(0m)' for a passed reset"
# The sibling account got a FRESH reading this fetch: its NEW 12/6 numbers, no token.
lkg_sib() { printf '%s' "$lkg_model" | jq -r ".header.accounts.accounts[] | select(.number==2) | $1"; }
s5=$(lkg_sib .five_hour_pct); [ "$s5" = "12" ] || fail "the fresh sibling must show its NEW 5h 12, not an inherited value (got '$s5')"
sdage=$(lkg_sib .data_age); [ "$sdage" = "null" ] || fail "a freshly-fetched sibling must carry NO age token (got '$sdage')"
pass "last-known-good: an errored active account keeps its old windows painted AS stale, a fresh sibling stays clean"

# NO PRIOR READING -> still nothing (never a fabricated value). A cold cache whose
# very first fetch 429s the active account has no last-known-good to inherit, so
# that account must show no number at all - the fix must not invent one.
COLD_CACHE="$TMP_ROOT/ju-lkg-cold-cache.json"
rm -f "$COLD_CACHE"
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
cold_model=$(env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_CSWAP_BIN="$LKG_CSWAP" FM_DESK_JCODE_AUTH="$LKG_AUTH" \
  FM_DESK_JCODE_USAGE_CACHE="$COLD_CACHE" \
  FM_DESK_JCODE_USAGE_BIN="$LKG_429" FM_DESK_NOW="2026-06-01 12:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB")
cold_active() { printf '%s' "$cold_model" | jq -r ".header.accounts.accounts[] | select(.number==1) | $1"; }
c5=$(cold_active .five_hour_pct); [ "$c5" = "null" ] || fail "an errored account with NO prior reading must show no 5h number (got '$c5')"
c7=$(cold_active .seven_day_pct); [ "$c7" = "null" ] || fail "an errored account with NO prior reading must show no 7d number (got '$c7')"
cdage=$(cold_active .data_age); [ "$cdage" = "null" ] || fail "an account with no reading must carry no age token (got '$cdage')"
cold_line1=$(printf '%s' "$cold_model" | jq -r '.header.accounts.lines[] | select(startswith("1 "))')
assert_not_contains "$cold_line1" "%" "an errored account with no prior reading paints no percentage at all"
# But its last-used still rides through (the errored provider carried it).
cu=$(cold_active .last_used); [ "$cu" = "just now" ] || fail "the errored account keeps its jcode last-used even with no windows (got '$cu')"
pass "last-known-good: an errored account with NO prior reading shows nothing, never a fabricated number"

# --- DESK_MAX bound applied -------------------------------------------------
# A projection with more decisions than DESK_MAX must be truncated to DESK_MAX.
MANY_SNAP="$TMP_ROOT/many.sh"
cat > "$MANY_SNAP" <<'SH'
#!/usr/bin/env bash
jq -n '{
  schema: "fm-bearings.v1",
  in_flight: [], secondmates: [], landed: [], gates: [],
  decisions_open: [ range(0;10) | { id: ("d-\(.)"), summary: ("decision \(.)"), key: "k", verb: "v", owner: "o" } ]
}'
SH
chmod +x "$MANY_SNAP"
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
many_model=$(env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$MANY_SNAP" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_MAX=3 FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB")
n=$(printf '%s' "$many_model" | jq -r '.sections.captains_call.rows | length')
[ "$n" = "3" ] || fail "DESK_MAX=3 must bound decisions to 3 rows (got '$n')"
# The header total is the TRUE count, never the DESK_MAX-bounded working set: the
# ranked rows are bounded to 3 but full_total is the honest 10, so a section
# header can never disagree with the summary's source-list count.
ft=$(printf '%s' "$many_model" | jq -r '.sections.captains_call.full_total')
[ "$ft" = "10" ] || fail "full_total must be the true decision count, not the DESK_MAX-bounded 3 (got '$ft')"
pass "DESK_MAX bounds an unbounded list; full_total stays the true total"

# --- ranking: urgent decisions first, ready gates before blocked -------------
# A projection whose urgent (needs-decision) row is NOT first must still surface
# it first, and a gate with no blocker must rank above a blocked one.
RANK_SNAP="$TMP_ROOT/rank.sh"
cat > "$RANK_SNAP" <<'SH'
#!/usr/bin/env bash
jq -n '{
  schema: "fm-bearings.v1",
  in_flight: [], secondmates: [], landed: [],
  decisions_open: [
    { id: "d-hold", verb: "captain-hold", summary: "a standing hold" },
    { id: "d-urgent", verb: "needs-decision", summary: "answer me now" }
  ],
  gates: [
    { id: "g-blocked", title: "blocked one", blocked_by: "other", reason: "waiting" },
    { id: "g-ready", title: "ready one", blocked_by: "-", reason: "-" }
  ]
}'
SH
chmod +x "$RANK_SNAP"
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
rank_model=$(env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$RANK_SNAP" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB" 2>/dev/null)
first_dec=$(printf '%s' "$rank_model" | jq -r '.sections.captains_call.rows[0].id')
[ "$first_dec" = "d-urgent" ] || fail "an urgent decision must rank first (got '$first_dec')"
first_gate=$(printf '%s' "$rank_model" | jq -r '.sections.charted.rows[0].id')
[ "$first_gate" = "g-ready" ] || fail "a ready gate must rank above a blocked one (got '$first_gate')"
pass "ranking surfaces urgent decisions and ready gates first"

# --- main-inventory: the synthetic fleet-integrity gate never reaches the desk -
# fm-bearings-snapshot.sh prepends a "(main-inventory)" gate row whenever a
# main-home backlog<->task check fails. That is firstmate's own signal, not
# captain-facing queued work, and its wording is internal jargon. The desk must
# drop it from the charted section AND the header queued count, while real gates
# survive.
MI_SNAP="$TMP_ROOT/main-inventory.sh"
cat > "$MI_SNAP" <<'SH'
#!/usr/bin/env bash
jq -n '{
  schema: "fm-bearings.v1",
  in_flight: [], secondmates: [], landed: [], decisions_open: [],
  gates: [
    { id: "(main-inventory)", title: "in-flight backlog item has no child metadata",
      blocked_by: "-", reason: "main inventory" },
    { id: "real-gate", title: "a real queued item", blocked_by: "-", reason: "-" }
  ]
}'
SH
chmod +x "$MI_SNAP"
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
mi_model=$(env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$MI_SNAP" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB" 2>/dev/null)
mi_ids=$(printf '%s' "$mi_model" | jq -r '[.sections.charted.rows[].id] | join(",")')
case ",$mi_ids," in
  *",(main-inventory),"*) fail "the synthetic (main-inventory) gate leaked into the charted section" ;;
esac
[ "$mi_ids" = "real-gate" ] || fail "a real gate must survive suppression (got '$mi_ids')"
mi_total=$(printf '%s' "$mi_model" | jq -r '.sections.charted.full_total')
[ "$mi_total" = 1 ] || fail "the header count must exclude the synthetic gate (got '$mi_total')"
pass "the synthetic (main-inventory) gate is suppressed from the desk"

# --- collapse: DESK_CAP holds a tail behind a named +N more count -----------
# With more rows than DESK_CAP, a section reports total/shown/more and a hint;
# with cap 0 it shows everything and holds nothing back.
# shellcheck disable=SC2016
cap_model=$(env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$MANY_SNAP" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_MAX=20 FM_DESK_CAP=4 FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB")
total=$(printf '%s' "$cap_model" | jq -r '.sections.captains_call.total')
shown=$(printf '%s' "$cap_model" | jq -r '.sections.captains_call.shown')
more=$(printf '%s' "$cap_model" | jq -r '.sections.captains_call.more')
rown=$(printf '%s' "$cap_model" | jq -r '.sections.captains_call.rows | length')
hint=$(printf '%s' "$cap_model" | jq -r '.sections.captains_call.more_hint')
[ "$total" = "10" ] || fail "total must be the full ranked count (got '$total')"
[ "$shown" = "4" ] || fail "DESK_CAP=4 must show 4 (got '$shown')"
[ "$more" = "6" ] || fail "more must be total-shown=6 (got '$more')"
[ "$rown" = "10" ] || fail "rows array keeps every ranked row so a board can reveal them (got '$rown')"
assert_contains "$hint" "6 more" "the collapse hint names the held-back count"
# cap 0 = no collapse.
# shellcheck disable=SC2016
full_model=$(env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$MANY_SNAP" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_MAX=20 FM_DESK_CAP=0 FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB")
full_more=$(printf '%s' "$full_model" | jq -r '.sections.captains_call.more')
full_shown=$(printf '%s' "$full_model" | jq -r '.sections.captains_call.shown')
[ "$full_more" = "0" ] || fail "cap 0 must hold nothing back (got more='$full_more')"
[ "$full_shown" = "10" ] || fail "cap 0 must show every row (got shown='$full_shown')"
pass "DESK_CAP collapses a tail behind a named count; cap 0 shows all"

# --- empty projection -> empty status ---------------------------------------
EMPTY_SNAP="$TMP_ROOT/empty.sh"
cat > "$EMPTY_SNAP" <<'SH'
#!/usr/bin/env bash
echo '{"schema":"fm-bearings.v1","in_flight":[],"secondmates":[],"decisions_open":[],"landed":[],"gates":[]}'
SH
chmod +x "$EMPTY_SNAP"
EMPTY_MQ="$TMP_ROOT/emptymq.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$EMPTY_MQ"; chmod +x "$EMPTY_MQ"
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
empty_model=$(env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$EMPTY_SNAP" FM_DESK_MERGEQ_BIN="$EMPTY_MQ" \
  FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB")
for sec in captains_call under_way charted landed secondmates; do
  st=$(printf '%s' "$empty_model" | jq -r ".sections.$sec.status")
  [ "$st" = "empty" ] || fail "$sec must be empty for an empty projection (got '$st')"
done
pass "empty projection yields empty section status"

# --- bad snapshot -> gap status ---------------------------------------------
BAD_SNAP="$TMP_ROOT/bad.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BAD_SNAP"; chmod +x "$BAD_SNAP"
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
bad_model=$(env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$BAD_SNAP" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB")
for sec in captains_call under_way charted landed secondmates; do
  st=$(printf '%s' "$bad_model" | jq -r ".sections.$sec.status")
  [ "$st" = "gap" ] || fail "$sec must be gap for an unreadable projection (got '$st')"
done
gap=$(printf '%s' "$bad_model" | jq -r '.sections.under_way.gap')
[ -n "$gap" ] && [ "$gap" != "null" ] || fail "a gap section must carry its sentence"
# The whole-page gaps array records the read failure.
gapcount=$(printf '%s' "$bad_model" | jq -r '.gaps | length')
[ "$gapcount" -ge 1 ] || fail "an unreadable projection records a page-level gap"
pass "unreadable projection yields gap section status and a page gap"

# --- away mode -> away status -----------------------------------------------
# A snapshot that honors the away-return guard: while .afk exists it refuses.
AWAY_HOME="$TMP_ROOT/awayhome"
mkdir -p "$AWAY_HOME/state"
: > "$AWAY_HOME/state/.afk"
AWAY_SNAP="$TMP_ROOT/awaysnap.sh"
cat > "$AWAY_SNAP" <<'SH'
#!/usr/bin/env bash
[ -e "$FM_HOME/state/.afk" ] && { echo "away" >&2; exit 3; }
echo '{"schema":"fm-bearings.v1","in_flight":[],"secondmates":[],"decisions_open":[],"landed":[],"gates":[]}'
SH
chmod +x "$AWAY_SNAP"
# shellcheck disable=SC2016 # $1 must expand in the child bash, not the outer shell.
away_model=$(env FM_HOME="$AWAY_HOME" FM_DESK_SNAPSHOT_BIN="$AWAY_SNAP" FM_DESK_MERGEQ_BIN="$EMPTY_MQ" \
  FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB")
away=$(printf '%s' "$away_model" | jq -r '.away')
[ "$away" = "true" ] || fail "away flag must be true when .afk is present"
for sec in captains_call under_way charted landed secondmates; do
  st=$(printf '%s' "$away_model" | jq -r ".sections.$sec.status")
  [ "$st" = "away" ] || fail "$sec must be away for an away-mode projection (got '$st')"
done
away_gap=$(printf '%s' "$away_model" | jq -r '.sections.under_way.gap')
assert_contains "$away_gap" "away mode is active" "away sections attribute the gap to away mode"
away_summary=$(printf '%s' "$away_model" | jq -r '.header.summary')
assert_contains "$away_summary" "You are marked away" "header notes away status"
pass "away mode yields away section status and away header"

# --- never writes: the lib reads, it must not touch state/ ------------------
WAKE_HOME="$TMP_ROOT/wakehome"
mkdir -p "$WAKE_HOME/state"
printf 'working: seed\n' > "$WAKE_HOME/state/ship-alpha.status"
before=$(find "$WAKE_HOME/state" -mindepth 1 | sort)
run_project "$WAKE_HOME" >/dev/null 2>&1 || fail "desk_project must succeed against a seeded home"
after=$(find "$WAKE_HOME/state" -mindepth 1 | sort)
[ "$before" = "$after" ] || fail "desk_project must not create or remove anything under state/"
pass "desk_project reads only: no writes under state/"

# --- desk_fit: budget a built model to a PHYSICAL-line budget ---------------
# desk_fit is the ONE owner of per-row and per-chrome line cost. Drive it
# directly (the sourced lib's executable interface) on a model built from a busy
# snapshot, and assert the shaping fields both boards read: render (a section
# dropped whole when nothing fits, header included), shown (fewer rows on a
# shorter budget - no floor inversion), and that the always-shown sections
# render even with no rows. This pins the line budget so an overflow regression
# is caught without a machine-specific live-fleet render.
# fit_shown <budget> <section>: build the busy model then fit it, echo
# "<render> <shown>" for a section. desk_fit budgets on physical lines only
# (width is enforced by the TUI's clip_frame at paint time), so no width arg.
FIT_SNAP="$TMP_ROOT/fitsnap.sh"
cat > "$FIT_SNAP" <<'SH'
#!/usr/bin/env bash
jq -n '{
  schema:"fm-bearings.v1", in_flight:[], secondmates:[],
  decisions_open:[ range(0;10) | {id:("d-\(.)"), summary:("a decision question number \(.) with enough text to matter"), key:"k", verb:"captain-hold", owner:"o"} ],
  landed:[ range(0;6) | {id:("l-\(.)"), what:("landed change number \(.)"), artifact:("data/l-\(.)/report.md")} ],
  gates:[ range(0;6) | {id:("g-\(.)"), title:("queued item \(.)"), blocked_by:"-", reason:"waiting"} ]
}'
SH
chmod +x "$FIT_SNAP"
fit_shown() {  # <budget> <section>
  # shellcheck disable=SC2016
  env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$FIT_SNAP" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
    FM_DESK_MAX=20 FM_DESK_NOW="2026-01-01 00:00:00 UTC" FM_DESK_BUDGET="$1" \
    bash -c '. "$1"; m=$(desk_project); f=$(desk_fit "$m");
             printf "%s %s" "$(printf "%s" "$f" | jq -r "if (.sections.'"$2"' | has(\"render\")) then .sections.'"$2"'.render else true end")" \
                            "$(printf "%s" "$f" | jq -r ".sections.'"$2"'.shown")"' _ "$LIB"
}
# A generous budget shows more rows than a tight one. Captain's Call is now a
# counts-only section (see below), so this floor-inversion property is pinned on
# a section that still lists rows (charted / queued next).
big=$(fit_shown 60 charted); big_shown=${big#* }
small=$(fit_shown 24 charted); small_shown=${small#* }
[ "$big_shown" -gt "$small_shown" ] || fail "a larger line budget must show more rows (big=$big_shown small=$small_shown) - floor inversion"
pass "desk_fit shows more rows on a larger line budget than a smaller one ($big_shown > $small_shown)"

# Captain's Call is COUNTS ONLY: the TUI paints its total in the header plus a
# single pointer line, never any decision rows. desk_fit must therefore never
# seat a captain's-call row, on any budget, while the section still renders.
cc_big=$(fit_shown 60 captains_call); cc_big_shown=${cc_big#* }; cc_big_render=${cc_big% *}
cc_small=$(fit_shown 12 captains_call); cc_small_shown=${cc_small#* }
[ "$cc_big_shown" = "0" ] && [ "$cc_small_shown" = "0" ] || fail "captain's call is counts-only: shown must be 0 on any budget (big=$cc_big_shown small=$cc_small_shown)"
[ "$cc_big_render" = "true" ] || fail "counts-only captain's call must still render (got render=$cc_big_render)"
pass "desk_fit keeps Captain's Call counts-only: no rows seated on any budget"

# The always-shown decisions section renders even when the budget is tiny.
tiny=$(fit_shown 12 captains_call); tiny_render=${tiny% *}
[ "$tiny_render" = "true" ] || fail "the acted-on decisions section must always render (got render=$tiny_render)"
pass "desk_fit always renders the acted-on decisions section"

# A low-priority section (landed) is dropped WHOLE (render:false) when the
# budget cannot seat any of its rows after the higher sections take their share.
landed_tiny=$(fit_shown 14 landed); landed_render=${landed_tiny% *}
[ "$landed_render" = "false" ] || fail "an unfittable low-priority section must be dropped whole (got render=$landed_render)"
pass "desk_fit drops an unfittable low-priority section whole (header included)"

# --- generated_at: a machine-readable build stamp on the model --------------
# WP-1 adds a top-level generated_at distinct from .now. It is pinned by
# FM_DESK_NOW in tests so the document is stable.
gen=$(printf '%s' "$model" | jq -r '.generated_at')
[ -n "$gen" ] && [ "$gen" != "null" ] || fail "model must carry a generated_at stamp (got '$gen')"
pass "model carries a generated_at build stamp"

# --- desk_persist_model: atomic cache write to a valid model ----------------
# The persist step is the ONE writer of the tier-1 cache. It must write a valid
# fm-desk.v1 document to FM_DESK_MODEL_OUT, carrying generated_at, and leave no
# temp file behind (the atomic temp+rename completed).
OUT_MODEL="$TMP_ROOT/desk-model.json"
# shellcheck disable=SC2016 # $1/$2 expand in the child bash, not the outer shell.
env FM_HOME="$HOME_DIR" FM_DESK_SNAPSHOT_BIN="$SNAP_BIN" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_NOW="2026-01-01 00:00:00 UTC" FM_DESK_MODEL_OUT="$OUT_MODEL" \
  bash -c '. "$1"; desk_persist_model' _ "$LIB" || fail "desk_persist_model must succeed"
[ -f "$OUT_MODEL" ] || fail "desk_persist_model must write the cache file"
printf '' # ensure the file parses as a full fm-desk.v1 document
jq -e '.schema == "fm-desk.v1" and (.generated_at != null)' "$OUT_MODEL" >/dev/null 2>&1 \
  || fail "the persisted cache must be a valid fm-desk.v1 document with generated_at"
# No temp file left behind in the output directory (atomic rename completed).
leftover=$(find "$TMP_ROOT" -maxdepth 1 -name '.desk-model.json.tmp.*' 2>/dev/null)
[ -z "$leftover" ] || fail "desk_persist_model must leave no temp file behind (found: $leftover)"
pass "desk_persist_model atomically writes a valid model cache with generated_at"

# A pre-built model handed to desk_persist_model is written verbatim (no second
# projection), so a board that already built the model persists that exact one.
# shellcheck disable=SC2016
env FM_HOME="$HOME_DIR" FM_DESK_MODEL_OUT="$TMP_ROOT/passed.json" \
  bash -c '. "$1"; desk_persist_model "$2"' _ "$LIB" \
  '{"schema":"fm-desk.v1","generated_at":"stamp","sentinel":42}' \
  || fail "desk_persist_model must accept a pre-built model"
sentinel=$(jq -r '.sentinel' "$TMP_ROOT/passed.json" 2>/dev/null)
[ "$sentinel" = "42" ] || fail "a pre-built model must be persisted verbatim (got sentinel '$sentinel')"
pass "desk_persist_model persists a pre-built model verbatim without reprojecting"

# A malformed pre-built model must be refused, leaving any prior good cache
# untouched, so a bad render can never replace a good model with garbage.
GOOD="$TMP_ROOT/guarded.json"
printf '{"schema":"fm-desk.v1","good":true}\n' > "$GOOD"
# shellcheck disable=SC2016
env FM_HOME="$HOME_DIR" FM_DESK_MODEL_OUT="$GOOD" \
  bash -c '. "$1"; desk_persist_model "not json {{{"' _ "$LIB" \
  && fail "desk_persist_model must reject a malformed model" || true
jq -e '.good == true' "$GOOD" >/dev/null 2>&1 \
  || fail "a rejected persist must leave the prior good cache untouched"
pass "desk_persist_model rejects a malformed model and preserves the prior cache"

# --- secondmate usage: context_tokens + idle_seconds from session files ------
# WP-1 extends each secondmates row with live session-derived fields so the
# MODEL owns the schema. Build a fake sessions dir + secondmates.md and assert
# the model folds real numbers in by working_dir, and that a registered mate
# with no session shows an explicit unknown (never hidden, never a crash).
USAGE_HOME="$TMP_ROOT/usagehome"
mkdir -p "$USAGE_HOME/state" "$USAGE_HOME/data"
SM_HOME_A="$USAGE_HOME/sm-a"
SM_HOME_B="$USAGE_HOME/sm-b"
SM_HOME_C="$USAGE_HOME/sm-c"
cat > "$USAGE_HOME/data/secondmates.md" <<EOF
- sm-alpha - alpha mate (home: $SM_HOME_A; scope: x; projects: ; added 2026-01-01)
- sm-beta - beta mate with no session (home: $SM_HOME_B; scope: y; projects: ; added 2026-01-01)
- sm-gamma - gamma mate mid-startup (home: $SM_HOME_C; scope: z; projects: ; added 2026-01-01)
EOF
SESS="$TMP_ROOT/sessions"
mkdir -p "$SESS"
# One session for sm-alpha with a last token_usage (369 = 300+50+19) and an
# activity timestamp; an older session for the same home to prove newest wins.
cat > "$SESS/session_alpha_new.json" <<EOF
{"id":"session_alpha_new","working_dir":"$SM_HOME_A",
 "last_active_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z",
 "messages":[
   {"token_usage":{"input_tokens":10,"output_tokens":1,"cache_read_input_tokens":5}},
   {"token_usage":{"input_tokens":50,"output_tokens":19,"cache_read_input_tokens":300}}
 ]}
EOF
cat > "$SESS/session_alpha_old.json" <<EOF
{"id":"session_alpha_old","working_dir":"$SM_HOME_A",
 "last_active_at":"2025-01-01T00:00:00Z","updated_at":"2025-01-01T00:00:00Z",
 "messages":[{"token_usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":1}}]}
EOF
# Pin file mtimes to each session's updated_at so activity ordering is stable and
# not driven by the incidental wall-clock mtime of just-written fixtures.
touch -d "2026-01-01T00:00:00Z" "$SESS/session_alpha_new.json"
touch -d "2025-01-01T00:00:00Z" "$SESS/session_alpha_old.json"
# A freshly-started session for sm-gamma: it matches the home and carries a real
# session id, but its newest messages have NO token_usage yet. Context must
# degrade to unknown while session_id stays the real id.
cat > "$SESS/session_gamma.json" <<EOF
{"id":"session_gamma","working_dir":"$SM_HOME_C",
 "last_active_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z",
 "messages":[{"role":"user"},{"role":"assistant"}]}
EOF
# A snapshot whose secondmates rollup carries both registered mates.
USAGE_SNAP="$TMP_ROOT/usagesnap.sh"
cat > "$USAGE_SNAP" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{
  "schema": "fm-bearings.v1",
  "in_flight": [], "decisions_open": [], "landed": [], "gates": [],
  "secondmates": [
    { "id": "sm-alpha", "state": "idle", "doing": "nothing", "freshness": "fresh" },
    { "id": "sm-beta", "state": "idle", "doing": "nothing", "freshness": "fresh" },
    { "id": "sm-gamma", "state": "idle", "doing": "nothing", "freshness": "fresh" }
  ]
}
JSON
SH
chmod +x "$USAGE_SNAP"
# shellcheck disable=SC2016
usage_model=$(env FM_HOME="$USAGE_HOME" FM_DESK_SNAPSHOT_BIN="$USAGE_SNAP" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_SESSIONS_DIR="$SESS" FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB")
a_ctx=$(printf '%s' "$usage_model" | jq -r '.sections.secondmates.rows[] | select(.id=="sm-alpha") | .context_tokens')
a_src=$(printf '%s' "$usage_model" | jq -r '.sections.secondmates.rows[] | select(.id=="sm-alpha") | .context_source')
a_idle=$(printf '%s' "$usage_model" | jq -r '.sections.secondmates.rows[] | select(.id=="sm-alpha") | .idle_seconds')
[ "$a_ctx" = "369" ] || fail "sm-alpha context_tokens must sum the newest session's last token_usage (got '$a_ctx')"
[ "$a_src" = "session" ] || fail "sm-alpha context_source must be session (got '$a_src')"
[ "$a_idle" != "null" ] && [ -n "$a_idle" ] || fail "sm-alpha must carry an idle_seconds value (got '$a_idle')"
# sm-beta has no session file: it must still appear, with an explicit unknown.
b_present=$(printf '%s' "$usage_model" | jq -r '[.sections.secondmates.rows[] | select(.id=="sm-beta")] | length')
b_ctx=$(printf '%s' "$usage_model" | jq -r '.sections.secondmates.rows[] | select(.id=="sm-beta") | .context_tokens')
b_src=$(printf '%s' "$usage_model" | jq -r '.sections.secondmates.rows[] | select(.id=="sm-beta") | .context_source')
[ "$b_present" = "1" ] || fail "a secondmate with no session must never be hidden (got count '$b_present')"
[ "$b_ctx" = "null" ] || fail "a sessionless secondmate must have null context_tokens (got '$b_ctx')"
[ "$b_src" = "unknown" ] || fail "a sessionless secondmate must be marked unknown (got '$b_src')"
# sm-gamma matches a real session with no token_usage: context is unknown, but
# the session_id must survive.
g_ctx=$(printf '%s' "$usage_model" | jq -r '.sections.secondmates.rows[] | select(.id=="sm-gamma") | .context_tokens')
g_src=$(printf '%s' "$usage_model" | jq -r '.sections.secondmates.rows[] | select(.id=="sm-gamma") | .context_source')
g_sid=$(printf '%s' "$usage_model" | jq -r '.sections.secondmates.rows[] | select(.id=="sm-gamma") | .session_id')
g_idle=$(printf '%s' "$usage_model" | jq -r '.sections.secondmates.rows[] | select(.id=="sm-gamma") | .idle_seconds')
[ "$g_ctx" = "null" ] || fail "a tokenless session must yield null context_tokens (got '$g_ctx')"
[ "$g_src" = "unknown" ] || fail "a tokenless session must mark context_source unknown (got '$g_src')"
[ "$g_sid" = "session_gamma" ] || fail "a tokenless session must keep its real session_id (got '$g_sid')"
[ "$g_idle" != "null" ] && [ -n "$g_idle" ] || fail "sm-gamma must still carry idle_seconds from its timestamp (got '$g_idle')"
pass "secondmates rows carry session-derived context/idle, newest wins, missing->unknown, tokenless keeps session_id"

# --- regression: idle_seconds tracks REAL activity, not session-start ---------
# last_active_at is frozen at session start, so an actively-working agent whose
# session was opened hours ago has an OLD last_active_at but a RECENT updated_at
# (and file mtime). idle_seconds must be derived from max(updated_at, mtime) so
# a busy worker reports SMALL idle, not the whole-session age. This is the
# assertion that would have caught the WP-1 false-stuck bug.
IDLE_HOME="$TMP_ROOT/idlehome"
mkdir -p "$IDLE_HOME/state" "$IDLE_HOME/data"
SM_HOME_W="$IDLE_HOME/sm-w"
cat > "$IDLE_HOME/data/secondmates.md" <<EOF
- sm-worker - working mate (home: $SM_HOME_W; scope: x; projects: ; added 2026-01-01)
EOF
IDLE_SESS="$TMP_ROOT/idlesessions"
mkdir -p "$IDLE_SESS"
# Session opened 3 hours before "now" (last_active_at frozen at start) but
# updated_at only 30s ago: an actively-working agent.
cat > "$IDLE_SESS/session_worker.json" <<EOF
{"id":"session_worker","working_dir":"$SM_HOME_W",
 "last_active_at":"2025-12-31T21:00:00Z","updated_at":"2025-12-31T23:59:30Z",
 "messages":[{"token_usage":{"input_tokens":10,"output_tokens":1,"cache_read_input_tokens":5}}]}
EOF
# Pin the file mtime to updated_at so this asserts the updated_at path cleanly,
# not an incidental wall-clock mtime. (max(updated_at, mtime) with both ~30s ago.)
touch -d "2025-12-31T23:59:30Z" "$IDLE_SESS/session_worker.json"
IDLE_SNAP="$TMP_ROOT/idlesnap.sh"
cat > "$IDLE_SNAP" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{
  "schema": "fm-bearings.v1",
  "in_flight": [], "decisions_open": [], "landed": [], "gates": [],
  "secondmates": [
    { "id": "sm-worker", "state": "running", "doing": "working", "freshness": "fresh" }
  ]
}
JSON
SH
chmod +x "$IDLE_SNAP"
# shellcheck disable=SC2016
idle_model=$(env FM_HOME="$IDLE_HOME" FM_DESK_SNAPSHOT_BIN="$IDLE_SNAP" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_SESSIONS_DIR="$IDLE_SESS" FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB")
w_idle=$(printf '%s' "$idle_model" | jq -r '.sections.secondmates.rows[] | select(.id=="sm-worker") | .idle_seconds')
# now = 2026-01-01T00:00:00Z. updated_at is 30s before now, last_active_at is 3h
# (10800s) before now. A last_active_at-derived idle would be ~10800; a real
# activity-derived idle is ~30. Assert it followed updated_at, not session start.
[ "$w_idle" != "null" ] && [ -n "$w_idle" ] || fail "sm-worker must carry idle_seconds (got '$w_idle')"
[ "$w_idle" -le 60 ] || fail "idle_seconds must follow updated_at (~30s), not frozen last_active_at (~10800s); got '$w_idle'"
pass "idle_seconds tracks real activity (updated_at/mtime), not frozen session-start last_active_at"

# --- WP-6 DEFECT A: an unresolved secondmate state renders a PLAIN status, never
# the raw internal diagnostic. The bearings `doing` for a mate whose structured
# home snapshot could not be read carries an internal string
# ("structured home state invalid: ...", "snapshot timed out", "in-flight backlog
# item ..."). That must NEVER reach the captain-facing secondmates row.
DIAG_HOME="$TMP_ROOT/diaghome"
mkdir -p "$DIAG_HOME/state" "$DIAG_HOME/data"
SM_HOME_D="$DIAG_HOME/sm-d"
mkdir -p "$SM_HOME_D/state"
cat > "$DIAG_HOME/data/secondmates.md" <<EOF
- sm-diag - diag mate (home: $SM_HOME_D; scope: x; projects: ; added 2026-01-01)
EOF
DIAG_SNAP="$TMP_ROOT/diagsnap.sh"
cat > "$DIAG_SNAP" <<SH
#!/usr/bin/env bash
cat <<'JSON'
{
  "schema": "fm-bearings.v1",
  "in_flight": [], "decisions_open": [], "landed": [], "gates": [],
  "secondmates": [
    { "id": "sm-diag", "state": "unknown",
      "doing": "structured home state invalid: live child state has no in-flight backlog item: x=working",
      "freshness": "historical-event" }
  ]
}
JSON
SH
chmod +x "$DIAG_SNAP"
# shellcheck disable=SC2016
diag_model=$(env FM_HOME="$DIAG_HOME" FM_DESK_SNAPSHOT_BIN="$DIAG_SNAP" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
  FM_DESK_SESSIONS_DIR="$TMP_ROOT/nosessions" FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
  bash -c '. "$1"; desk_project' _ "$LIB")
# The ENTIRE secondmates section must not contain any internal diagnostic string.
diag_sec=$(printf '%s' "$diag_model" | jq -c '.sections.secondmates')
assert_not_contains "$diag_sec" "structured home state" "the raw diagnostic must never reach the secondmates section"
assert_not_contains "$diag_sec" "in-flight backlog" "the raw backlog diagnostic must never reach the section"
assert_not_contains "$diag_sec" "snapshot" "no snapshot-internal wording in the section"
d_doing=$(printf '%s' "$diag_model" | jq -r '.sections.secondmates.rows[] | select(.id=="sm-diag") | .doing')
case "$d_doing" in
  working|idle|unknown|"waiting on you") : ;;
  *) fail "an unresolved secondmate must show a short plain status, got '$d_doing'" ;;
esac
pass "WP-6 DEFECT A: an unresolved secondmate renders a plain status, never the raw diagnostic"

# --- token-cost / efficiency panel: empty, thin-ledger, populated, money() ----
# The burn/cache/heaviest half comes from the coster (FM_DESK_TOKEN_REPORT_BIN)
# and the cost-per-landed-ticket half from the rollup (FM_DESK_TICKET_ROLLUP_BIN);
# the model combines them so BOTH boards paint identical text. These drive
# desk_project through those two seams (never the real coster) and assert the
# EMITTED header.token_cost - the branch selection, the if-API/covered split, and
# the money() rounding boundaries. Each case uses its own fresh TMP cache path so
# a warm blob from one never leaks into the next.

# A populated burn report shared by the thin-ledger and populated cases: a real
# $4.9k spend (if-API $4.9k / billed $2.5k / covered $2.4k), a 98% cache-hit ratio
# (980 cache reads vs 20 fresh input tokens), and two engines given OUT of rank
# order so the heaviest sort has work to do.
TC_REPORT_FULL="$TMP_ROOT/tc-report-full.sh"
cat > "$TC_REPORT_FULL" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{ "price_source": "test", "price_cached_at": "2026-01-01T00:00:00Z",
  "totals": { "cost_if_api": 4900, "cost_if_api_billed": 2500, "cost_if_api_covered": 2400,
    "sessions": 128, "token_input": 20, "token_cache_read": 980, "token_cache_write": 0,
    "unknown_model_tokens": 0 },
  "rows": [
    { "dimension": "claude-sonnet", "cost_if_api": 1900, "cost_if_api_billed": 1000, "cost_if_api_covered": 900, "sessions": 48 },
    { "dimension": "claude-opus", "cost_if_api": 3000, "cost_if_api_billed": 1500, "cost_if_api_covered": 1500, "sessions": 80 }
  ] }
JSON
SH
chmod +x "$TC_REPORT_FULL"

# (a) EMPTY store: the default empty-but-valid report + an absent rollup render the
# honest "no billed activity yet" glance line, a LIVE panel (never a gap), and a
# per-ticket detail that reads "not available" (the rollup half is absent here).
tc_empty=$(run_project "$HOME_DIR" \
  FM_DESK_TOKEN_REPORT_BIN="$TOKEN_COST_EMPTY" \
  FM_DESK_TICKET_ROLLUP_BIN="$TMP_ROOT/tc-rollup-absent.sh" \
  FM_DESK_TOKEN_COST_CACHE="$TMP_ROOT/tc-empty-cache.json")
tce_line=$(printf '%s' "$tc_empty" | jq -r '.header.token_cost.line')
[ "$tce_line" = "no billed activity yet" ] || fail "an empty store must glance 'no billed activity yet' (got '$tce_line')"
tce_null=$(printf '%s' "$tc_empty" | jq -r '.header.token_cost == null')
[ "$tce_null" = "false" ] || fail "an empty store is NOT a gap: header.token_cost must be present"
tce_gaps=$(printf '%s' "$tc_empty" | jq -r '.gaps | join("\n")')
assert_not_contains "$tce_gaps" "spend panel is unavailable" "an empty store is not a token-cost gap"
tce_detail=$(printf '%s' "$tc_empty" | jq -r '.header.token_cost.detail | join("\n")')
assert_contains "$tce_detail" "not available on this home yet" "an absent rollup reads not-available, never a fabricated number"
pass "token-cost (empty): honest 'no billed activity yet', live panel, absent rollup not-available"

# (b) THIN LEDGER: a populated report but a rollup where EVERY landed ticket is
# unattributable (correct-by-design until spawns accrue). The burn half still
# renders; the cost-per-ticket detail reads honestly as thin/unattributable and
# NEVER as $0 and NEVER as a broken/empty panel - the captain-facing invariant.
TC_ROLLUP_THIN="$TMP_ROOT/tc-rollup-thin.sh"
cat > "$TC_ROLLUP_THIN" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{ "totals": { "tickets": 513, "unattributable_tickets": 513, "sessions": 0,
    "cost_if_api": null, "cost_if_api_billed": null, "cost_if_api_covered": null },
  "tickets": [
    { "ticket": "fm-1", "repo": "firstmate", "close_date": "2026-08-01", "unattributable": true, "cost_if_api": null, "cost_if_api_covered": null }
  ] }
JSON
SH
chmod +x "$TC_ROLLUP_THIN"
tc_thin=$(run_project "$HOME_DIR" \
  FM_DESK_TOKEN_REPORT_BIN="$TC_REPORT_FULL" \
  FM_DESK_TICKET_ROLLUP_BIN="$TC_ROLLUP_THIN" \
  FM_DESK_TOKEN_COST_CACHE="$TMP_ROOT/tc-thin-cache.json")
tct_line=$(printf '%s' "$tc_thin" | jq -r '.header.token_cost.line')
assert_contains "$tct_line" "if-API \$4.9k" "the burn half still renders on a thin ledger"
assert_contains "$tct_line" "cache 98%" "the cache-hit ratio still renders on a thin ledger"
tct_detail=$(printf '%s' "$tc_thin" | jq -r '.header.token_cost.detail | join("\n")')
assert_contains "$tct_detail" "thin ledger" "a thin ledger renders honestly as thin"
assert_contains "$tct_detail" "513 landed tickets are unattributable" "the thin-ledger detail counts the unattributable tickets"
assert_contains "$tct_detail" "not \$0 and not an error" "the thin ledger states it is not \$0 and not an error"
assert_not_contains "$tct_detail" "attributed spend" "a thin ledger never renders an attributed-spend (would-be \$0) figure"
pass "token-cost (thin ledger): burn renders, per-ticket honest thin/unattributable, never \$0 or broken"

# (c) POPULATED ledger: attributable per-ticket spend renders with cost_if_api and
# covered as SEPARATE labeled figures (captain ruling: never summed). The attributed
# count, the two separate figures, and the ranked costliest-tickets list all render.
TC_ROLLUP_FULL="$TMP_ROOT/tc-rollup-full.sh"
cat > "$TC_ROLLUP_FULL" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{ "totals": { "tickets": 10, "unattributable_tickets": 3, "sessions": 40,
    "cost_if_api": 251, "cost_if_api_billed": 130, "cost_if_api_covered": 120 },
  "tickets": [
    { "ticket": "fm-102", "repo": "firstmate", "close_date": "2026-08-02", "unattributable": false, "cost_if_api": 110, "cost_if_api_covered": 45 },
    { "ticket": "fm-101", "repo": "firstmate", "close_date": "2026-08-01", "unattributable": false, "cost_if_api": 140, "cost_if_api_covered": 60 },
    { "ticket": "fm-999", "repo": "firstmate", "close_date": "2026-07-01", "unattributable": true, "cost_if_api": null, "cost_if_api_covered": null }
  ] }
JSON
SH
chmod +x "$TC_ROLLUP_FULL"
tc_full=$(run_project "$HOME_DIR" \
  FM_DESK_TOKEN_REPORT_BIN="$TC_REPORT_FULL" \
  FM_DESK_TICKET_ROLLUP_BIN="$TC_ROLLUP_FULL" \
  FM_DESK_TOKEN_COST_CACHE="$TMP_ROOT/tc-full-cache.json")
tcf_detail=$(printf '%s' "$tc_full" | jq -r '.header.token_cost.detail | join("\n")')
assert_contains "$tcf_detail" "7 of 10 landed tickets attributed" "the populated per-ticket detail counts attributed tickets"
assert_contains "$tcf_detail" "3 unattributable" "the populated per-ticket detail counts the unattributable remainder"
# if-API and covered stay SEPARATE figures, never one summed total (251 + 120 = 371).
assert_contains "$tcf_detail" "attributed spend: if-API \$251 / covered \$120" "attributed spend keeps if-API and covered separate"
assert_not_contains "$tcf_detail" "\$371" "the if-API and covered figures are never summed"
# The costliest attributable tickets list, ranked by if-API, each with both figures.
assert_contains "$tcf_detail" "fm-101  if-API \$140 / covered \$60" "the costliest ticket shows both figures separately"
tcf_top0=$(printf '%s' "$tc_full" | jq -r '.header.token_cost.per_ticket.top[0].ticket')
[ "$tcf_top0" = "fm-101" ] || fail "the costliest attributable ticket (fm-101, \$140) must rank first (got '$tcf_top0')"
# The heaviest engines are ranked by if-API cost, opus ($3k) ahead of sonnet ($1.9k).
tcf_heavy0=$(printf '%s' "$tc_full" | jq -r '.header.token_cost.heaviest[0].name')
[ "$tcf_heavy0" = "claude-opus" ] || fail "the heaviest engine (claude-opus, \$3k) must rank first (got '$tcf_heavy0')"
pass "token-cost (populated): attributed count + separate if-API/covered figures + ranked heaviest/tickets"

# (d) money() rounding boundaries in one report: >=1000 -> \$Nk, >=100 -> whole
# dollars, <100 -> cents, null -> n/a. The burn split carries one figure in each of
# the first three bands; a heaviest engine carries a null covered figure so the n/a
# path (an unpriced figure, never a fabricated $0) renders too.
TC_REPORT_MONEY="$TMP_ROOT/tc-report-money.sh"
cat > "$TC_REPORT_MONEY" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{ "price_source": "test", "price_cached_at": "2026-01-01T00:00:00Z",
  "totals": { "cost_if_api": 4900, "cost_if_api_billed": 340, "cost_if_api_covered": 4.25,
    "sessions": 5, "token_input": 0, "token_cache_read": 0, "token_cache_write": 0,
    "unknown_model_tokens": 0 },
  "rows": [
    { "dimension": "claude-opus", "cost_if_api": 1234, "cost_if_api_billed": 600, "cost_if_api_covered": null, "sessions": 3 }
  ] }
JSON
SH
chmod +x "$TC_REPORT_MONEY"
tc_money=$(run_project "$HOME_DIR" \
  FM_DESK_TOKEN_REPORT_BIN="$TC_REPORT_MONEY" \
  FM_DESK_TICKET_ROLLUP_BIN="$TMP_ROOT/tc-rollup-absent.sh" \
  FM_DESK_TOKEN_COST_CACHE="$TMP_ROOT/tc-money-cache.json")
tcm_line=$(printf '%s' "$tc_money" | jq -r '.header.token_cost.line')
assert_contains "$tcm_line" "if-API \$4.9k" "money() renders >=1000 as \$Nk (4900 -> \$4.9k)"
assert_contains "$tcm_line" "billed \$340" "money() renders >=100 as whole dollars (340 -> \$340)"
assert_contains "$tcm_line" "covered \$4.25" "money() renders <100 with cents (4.25 -> \$4.25)"
tcm_detail=$(printf '%s' "$tc_money" | jq -r '.header.token_cost.detail | join("\n")')
assert_contains "$tcm_detail" "if-API \$1.2k" "money() rounds 1234 to \$1.2k in the heaviest list"
assert_contains "$tcm_detail" "covered n/a" "money() renders a null figure as n/a, never a fabricated \$0"
pass "token-cost (money): \$Nk / whole-dollar / cents / n/a rounding boundaries"

# --- WP-6 running count + working/unknown/idle on the LIVE per-crew basis ------
# These three defects share one root cause and one fix: a secondmate is "running"
# when it has a LIVE working child crew - a child task whose endpoint is ALIVE and
# whose current turn is BUSY - NOT when the trailing word of its status LOG happens
# to read working. A crew mid-work between status appends (one that appended
# paused:/done: earlier and resumed, or never appended since it started) carries a
# stale last word while genuinely building, so the log word is the wrong signal.
# desk_secondmate_child_activity reads each child's authoritative busy verdict the
# same way bin/fm-crew-state.sh does (fm_busy_classify_live over the real endpoint
# + the gen-checked busy record). We exercise that end to end over REAL tmux
# endpoints and REAL busy records, with the status LOG words deliberately DIVERGENT
# from the live truth so a regression to the trailing-token heuristic fails here.
if ! command -v tmux >/dev/null 2>&1; then
  echo "skip: tmux not found (WP-6 live-basis running-count tests need a real endpoint)"
else
  BUSY_EV="$ROOT/bin/fm-busy-event.sh"
  REAL_TMUX=$(command -v tmux)
  DESK_SOCKET="fm-desk-live-$$"
  DESK_SESSION=desklive
  SHIM_DIR="$TMP_ROOT/tmuxshim"
  mkdir -p "$SHIM_DIR"
  cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$DESK_SOCKET" "\$@"
SH
  chmod +x "$SHIM_DIR/tmux"
  desk_tmux() { "$REAL_TMUX" -L "$DESK_SOCKET" "$@"; }
  desk_tmux_cleanup() { "$REAL_TMUX" -L "$DESK_SOCKET" kill-server >/dev/null 2>&1 || true; }
  trap desk_tmux_cleanup EXIT
  desk_tmux new-session -d -s "$DESK_SESSION" -n idlewin \
    || fail "could not start the private tmux server for the live-basis tests"
  # A live window whose pane runs a real long-lived process (the endpoint is
  # genuinely alive). Returns the tmux target (session:window).
  SLEEP_BIN=$(command -v sleep)
  live_window() {  # <name>
    desk_tmux new-window -d -t "$DESK_SESSION:" -n "$1" -- "$SLEEP_BIN" 900 \
      || fail "could not create live window $1"
    printf '%s:%s' "$DESK_SESSION" "$1"
  }
  # Write a child task's meta (tmux backend) + arm a busy record with the given
  # live state, all under <home>/state, so fm_busy_classify_live reads it exactly
  # as the watcher would. <busy_state> is busy|idle (idle proves an alive-but-idle
  # endpoint is NOT counted).
  child_task() {  # <home> <id> <target> <busy_state>
    local home=$1 id=$2 target=$3 bstate=$4
    mkdir -p "$home/state"
    cat > "$home/state/$id.meta" <<META
backend=tmux
window=$target
harness=claude
kind=ship
META
    "$BUSY_EV" arm "$home/state" "$id" >/dev/null 2>&1 \
      || fail "could not arm busy record for $id"
    "$BUSY_EV" apply "$home/state" "$id" "$bstate" --current-gen \
      --source claude-hook --event turn >/dev/null 2>&1 \
      || fail "could not apply $bstate busy record for $id"
  }

  BUSY_HOME="$TMP_ROOT/busyhome"
  mkdir -p "$BUSY_HOME/state" "$BUSY_HOME/data"
  SM_HOME_BUSY="$BUSY_HOME/sm-busy"
  SM_HOME_QUIET="$BUSY_HOME/sm-quiet"
  mkdir -p "$SM_HOME_BUSY/state" "$SM_HOME_QUIET/state"
  cat > "$BUSY_HOME/data/secondmates.md" <<EOF
- sm-busy - busy builder mate (home: $SM_HOME_BUSY; scope: x; projects: ; added 2026-01-01)
- sm-quiet - quiet mate (home: $SM_HOME_QUIET; scope: y; projects: ; added 2026-01-01)
EOF
  # Two crews with LIVE endpoints + busy records in the busy mate's tree. Their
  # status LOGS say paused:/done: (stale) - the OLD trailing-token count would see
  # 0 here, which is the exact defect. One crew has a live-but-IDLE record (alive
  # endpoint, settled turn) and must NOT count. The quiet mate has only a torn-down
  # crew (no endpoint) and must count 0.
  b1=$(live_window busy1); child_task "$SM_HOME_BUSY" crew-1 "$b1" busy
  b2=$(live_window busy2); child_task "$SM_HOME_BUSY" crew-2 "$b2" busy
  b3=$(live_window busy3); child_task "$SM_HOME_BUSY" crew-3 "$b3" idle
  printf 'paused: awaiting captain review\n' > "$SM_HOME_BUSY/state/crew-1.status"
  printf 'done: shipped the parser\n' > "$SM_HOME_BUSY/state/crew-2.status"
  printf 'working: still poking\n' > "$SM_HOME_BUSY/state/crew-3.status"
  # Quiet mate: a torn-down crew whose meta no longer resolves an endpoint (no
  # window) plus a working log word. With no resolvable endpoint the live verdict
  # is unknown, never busy, so this counts 0 despite the working log word. (A
  # genuinely dead endpoint yields the same not-counted result on the herdr
  # backend the desk actually runs on, where the liveness probe reports it gone;
  # tmux 3.6's display-message cannot represent a dead session cleanly, so the
  # portable regression uses the deterministic no-endpoint path instead.)
  mkdir -p "$SM_HOME_QUIET/state"
  cat > "$SM_HOME_QUIET/state/crew-x.meta" <<META
backend=tmux
harness=claude
kind=ship
META
  printf 'working: building forever\n' > "$SM_HOME_QUIET/state/crew-x.status"
  BUSY_SNAP="$TMP_ROOT/busysnap.sh"
  cat > "$BUSY_SNAP" <<SH
#!/usr/bin/env bash
cat <<'JSON'
{
  "schema": "fm-bearings.v1",
  "in_flight": [], "decisions_open": [], "landed": [], "gates": [],
  "secondmates": [
    { "id": "sm-busy", "state": "unknown", "doing": "snapshot timed out", "freshness": "historical-event" },
    { "id": "sm-quiet", "state": "no_active_work", "doing": "No active child work", "freshness": "fresh" }
  ]
}
JSON
SH
  chmod +x "$BUSY_SNAP"
  # shellcheck disable=SC2016
  busy_model=$(env PATH="$SHIM_DIR:$PATH" FM_HOME="$BUSY_HOME" FM_DESK_SNAPSHOT_BIN="$BUSY_SNAP" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
    FM_DESK_SESSIONS_DIR="$TMP_ROOT/nosessions" FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
    bash -c '. "$1"; desk_project' _ "$LIB")
  # DEFECT 1: the header counts the 2 live-busy crews, not the idle or dead ones,
  # and never the stale log words.
  busy_running=$(printf '%s' "$busy_model" | jq -r '.header.counts.running')
  [ "$busy_running" = "2" ] || fail "running must count only the 2 live-busy child crews (not idle/dead), got '$busy_running'"
  busy_summary=$(printf '%s' "$busy_model" | jq -r '.header.summary')
  assert_not_contains "$busy_summary" "Nothing is running" "the summary must not say Nothing is running while live crews build"
  assert_contains "$busy_summary" "2 jobs are running" "the summary reflects the live child-tree work"
  busy_cr=$(printf '%s' "$busy_model" | jq -r '.sections.secondmates.rows[] | select(.id=="sm-busy") | .child_running')
  [ "$busy_cr" = "2" ] || fail "the busy mate row must carry child_running=2 (got '$busy_cr')"
  # DEFECT 2: a mate with live building crews reads working, NEVER unknown, and
  # stays diagnostic-free.
  busy_doing=$(printf '%s' "$busy_model" | jq -r '.sections.secondmates.rows[] | select(.id=="sm-busy") | .doing')
  [ "$busy_doing" = "working" ] || fail "a mate with live building crews must render working, got '$busy_doing'"
  [ "$busy_doing" != "unknown" ] || fail "an actively-building mate must never render unknown"
  quiet_doing=$(printf '%s' "$busy_model" | jq -r '.sections.secondmates.rows[] | select(.id=="sm-quiet") | .doing')
  [ "$quiet_doing" = "idle" ] || fail "a mate with no live crews must render idle despite a working log word, got '$quiet_doing'"
  pass "WP-6 DEFECT 1/2: running count + working state key on live per-crew state, not the status log word"

  # --- FEATURE 2: the busy mate's live child TASKS surface in Under Way ---------
  # The captain wants "what are we actively working on" answered in one place. The
  # two fs-verified building crews in sm-busy's tree (crew-1, crew-2) must each
  # appear as an Under Way row tagged "[sm-busy]", so the actual tasks show, not
  # just an aggregate mate. crew-3 is a live-but-idle crew and must NOT appear.
  uw_ids=$(printf '%s' "$busy_model" | jq -r '[.sections.under_way.rows[].id] | sort | join(",")')
  assert_contains "$uw_ids" "[sm-busy] crew-1" "the busy mate's first live child must show in Under Way (got '$uw_ids')"
  assert_contains "$uw_ids" "[sm-busy] crew-2" "the busy mate's second live child must show in Under Way (got '$uw_ids')"
  assert_not_contains "$uw_ids" "crew-3" "an idle child must never surface as under-way work (got '$uw_ids')"
  # The tagged child leads with a running bullet and a terse verb, never a raw
  # status string (DEFECT A: a child status can be an internal diagnostic).
  child_bullet=$(printf '%s' "$busy_model" | jq -r '.sections.under_way.rows[] | select(.id=="[sm-busy] crew-1") | .bullet')
  child_doing=$(printf '%s' "$busy_model" | jq -r '.sections.under_way.rows[] | select(.id=="[sm-busy] crew-1") | .doing')
  [ "$child_bullet" = running ] || fail "a live child row must lead with the running bullet (got '$child_bullet')"
  [ "$child_doing" = building ] || fail "a ship child row shows the terse 'building' verb (got '$child_doing')"
  # No double-count: the aggregate 'sm-busy' mate row is GONE from Under Way (its
  # children replaced it), and the header total for Under Way equals the child
  # count (2), matching the running count. The board never lists a mate AND its
  # children as separate under-way work.
  assert_not_contains "$uw_ids" "sm-busy," "the mate aggregate must not linger beside its child rows (got '$uw_ids')"
  uw_total=$(printf '%s' "$busy_model" | jq -r '.sections.under_way.full_total')
  [ "$uw_total" = "2" ] || fail "Under Way header count must equal the 2 live child tasks, no double-count (got '$uw_total')"
  # Folding children over an empty in_flight base must flip the section to ok, or
  # both boards fold it away (status empty) and the tagged rows never paint.
  uw_status=$(printf '%s' "$busy_model" | jq -r '.sections.under_way.status')
  [ "$uw_status" = "ok" ] || fail "Under Way with folded child rows must render (status ok, got '$uw_status')"
  pass "FEATURE 2: live secondmate child tasks fold into Under Way with an owner tag and an honest count"

  # --- DEFECT 2 (separate path): the MAIN home's OWN live crew and the header ---
  # MR !30 fixed the secondmate child-tree count only. This is the other path: the
  # header running count keyed on `.in_flight[].state`, which is fm-crew-state.sh's
  # run-step-authoritative verdict, unioned with desk_main_live_running_ids (the
  # same live basis) so a live crew the projection does not carry as a running row
  # still counts - never double-counting a task the base filter already counted.
  # The header must AGREE with the re-homed Under Way section: a task whose run
  # terminally passed reads `done`, leaves Under Way, and is counted as neither
  # running nor blocked even while its pane keeps working on follow-up (a merged
  # task on follow-up work, a green PR building the next commit). A header claiming
  # one job runs over a section saying nothing is under way is the confusion the
  # re-homing removes, so the live union must not resurrect the departed task.
  D2_HOME="$TMP_ROOT/d2home"
  mkdir -p "$D2_HOME/state" "$D2_HOME/data"
  : > "$D2_HOME/data/secondmates.md"
  # A main-home ship task with a LIVE-busy endpoint. Its status log says done:.
  d2w=$(live_window d2live); child_task "$D2_HOME" ship-live "$d2w" busy
  printf 'done: merged; re-verifying delivery\n' > "$D2_HOME/state/ship-live.status"
  # The bearings projection reports that same task as state=done (crew-state's
  # verdict): a departed row, whatever the pane is doing.
  D2_SNAP="$TMP_ROOT/d2snap.sh"
  cat > "$D2_SNAP" <<SH
#!/usr/bin/env bash
cat <<'JSON'
{
  "schema": "fm-bearings.v1",
  "in_flight": [ { "id": "ship-live", "kind": "ship", "state": "done", "doing": "merged; re-verifying" } ],
  "decisions_open": [], "landed": [], "gates": [], "secondmates": []
}
JSON
SH
  chmod +x "$D2_SNAP"
  # shellcheck disable=SC2016
  d2_model=$(env PATH="$SHIM_DIR:$PATH" FM_HOME="$D2_HOME" FM_DESK_SNAPSHOT_BIN="$D2_SNAP" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
    FM_DESK_SESSIONS_DIR="$TMP_ROOT/nosessions" FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
    bash -c '. "$1"; desk_project' _ "$LIB")
  d2_running=$(printf '%s' "$d2_model" | jq -r '.header.counts.running')
  [ "$d2_running" = "0" ] || fail "a done crew-state must not count as running even with a live pane, got '$d2_running'"
  d2_blocked=$(printf '%s' "$d2_model" | jq -r '.header.counts.blocked')
  [ "$d2_blocked" = "0" ] || fail "a departed done task counts as neither running nor blocked, got blocked '$d2_blocked'"
  d2_summary=$(printf '%s' "$d2_model" | jq -r '.header.summary')
  assert_contains "$d2_summary" "Nothing is running" "the summary must agree with the section: a departed done task is not a running job"
  d2_under=$(printf '%s' "$d2_model" | jq -r '[.sections.under_way.rows[].id] | join(",")')
  case ",$d2_under," in *,ship-live,*) fail "a done crew-state must leave Under Way even while its pane is live (got '$d2_under')" ;; esac
  # The live basis is still consulted for the same task: a genuinely working
  # (non-done) live task IS counted, exactly once - the base filter counts it and
  # the live union must not add it a second time.
  D2B_SNAP="$TMP_ROOT/d2bsnap.sh"
  cat > "$D2B_SNAP" <<SH
#!/usr/bin/env bash
cat <<'JSON'
{
  "schema": "fm-bearings.v1",
  "in_flight": [ { "id": "ship-live", "kind": "ship", "state": "working", "doing": "building" } ],
  "decisions_open": [], "landed": [], "gates": [], "secondmates": []
}
JSON
SH
  chmod +x "$D2B_SNAP"
  # shellcheck disable=SC2016
  d2b_model=$(env PATH="$SHIM_DIR:$PATH" FM_HOME="$D2_HOME" FM_DESK_SNAPSHOT_BIN="$D2B_SNAP" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
    FM_DESK_SESSIONS_DIR="$TMP_ROOT/nosessions" FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
    bash -c '. "$1"; desk_project' _ "$LIB")
  d2b_running=$(printf '%s' "$d2b_model" | jq -r '.header.counts.running')
  [ "$d2b_running" = "1" ] || fail "a working live task must count exactly once (base filter, no live-union double-count), got '$d2b_running'"
  d2b_summary=$(printf '%s' "$d2b_model" | jq -r '.header.summary')
  assert_contains "$d2b_summary" "One job is running" "the summary counts the working live main-home job"
  d2b_under=$(printf '%s' "$d2b_model" | jq -r '[.sections.under_way.rows[].id] | join(",")')
  case ",$d2b_under," in *,ship-live,*) : ;; *) fail "a working live task must be an Under Way row (got '$d2b_under')" ;; esac
  pass "DEFECT 2: the header running count agrees with Under Way - a working live crew counts once, a departed done crew counts as neither"

  # --- DEFECT 3: a working mate must NOT render a large idle figure. A long-lived
  # session freezes its session-JSON updated_at + mtime while the agent works, so
  # idle_seconds reads hours; the row must suppress that and show "working". A
  # genuinely idle mate still shows its terse idle figure.
  IDLE3_HOME="$TMP_ROOT/idle3home"
  mkdir -p "$IDLE3_HOME/state" "$IDLE3_HOME/data"
  SM_HOME_WORK="$IDLE3_HOME/sm-work"
  SM_HOME_REST="$IDLE3_HOME/sm-rest"
  mkdir -p "$SM_HOME_WORK/state" "$SM_HOME_REST/state"
  cat > "$IDLE3_HOME/data/secondmates.md" <<EOF
- sm-work - working mate (home: $SM_HOME_WORK; scope: x; projects: ; added 2026-01-01)
- sm-rest - resting mate (home: $SM_HOME_REST; scope: y; projects: ; added 2026-01-01)
EOF
  # sm-work: a live-busy crew, but its own mate status file (and any session) is
  # ancient - the frozen-session-JSON shape. idle would read hours if not suppressed.
  w1=$(live_window work1); child_task "$SM_HOME_WORK" crew-1 "$w1" busy
  # Ancient session so the raw idle figure is large.
  IDLE3_SESS="$TMP_ROOT/idle3sessions"
  mkdir -p "$IDLE3_SESS"
  cat > "$IDLE3_SESS/session_work.json" <<EOF
{"id":"session_work","working_dir":"$SM_HOME_WORK",
 "last_active_at":"2025-12-31T17:00:00Z","updated_at":"2025-12-31T17:00:00Z",
 "messages":[{"token_usage":{"input_tokens":10,"output_tokens":1}}]}
EOF
  touch -d "2025-12-31T17:00:00Z" "$IDLE3_SESS/session_work.json"
  # An ancient mate status file too, so no fresh mtime accidentally rescues idle.
  printf 'paused: long ago\n' > "$IDLE3_HOME/state/sm-work.status"
  touch -d "2025-12-31T17:00:00Z" "$IDLE3_HOME/state/sm-work.status"
  # sm-rest: genuinely idle (no live crew), ancient session -> keeps a real idle figure.
  cat > "$IDLE3_SESS/session_rest.json" <<EOF
{"id":"session_rest","working_dir":"$SM_HOME_REST",
 "last_active_at":"2025-12-31T20:00:00Z","updated_at":"2025-12-31T20:00:00Z",
 "messages":[{"token_usage":{"input_tokens":10,"output_tokens":1}}]}
EOF
  touch -d "2025-12-31T20:00:00Z" "$IDLE3_SESS/session_rest.json"
  IDLE3_SNAP="$TMP_ROOT/idle3snap.sh"
  cat > "$IDLE3_SNAP" <<SH
#!/usr/bin/env bash
cat <<'JSON'
{
  "schema": "fm-bearings.v1",
  "in_flight": [], "decisions_open": [], "landed": [], "gates": [],
  "secondmates": [
    { "id": "sm-work", "state": "unknown", "doing": "snapshot timed out", "freshness": "historical-event" },
    { "id": "sm-rest", "state": "no_active_work", "doing": "No active child work", "freshness": "fresh" }
  ]
}
JSON
SH
  chmod +x "$IDLE3_SNAP"
  # shellcheck disable=SC2016
  idle3_model=$(env PATH="$SHIM_DIR:$PATH" FM_HOME="$IDLE3_HOME" FM_DESK_SNAPSHOT_BIN="$IDLE3_SNAP" FM_DESK_MERGEQ_BIN="$MQ_BIN" \
    FM_DESK_SESSIONS_DIR="$IDLE3_SESS" FM_DESK_NOW="2026-01-01 00:00:00 UTC" \
    bash -c '. "$1"; desk_project' _ "$LIB")
  work_doing=$(printf '%s' "$idle3_model" | jq -r '.sections.secondmates.rows[] | select(.id=="sm-work") | .doing')
  work_fresh=$(printf '%s' "$idle3_model" | jq -r '.sections.secondmates.rows[] | select(.id=="sm-work") | .freshness')
  [ "$work_doing" = "working" ] || fail "sm-work must read working (live crew), got '$work_doing'"
  assert_not_contains "$work_fresh" "idle " "a working mate must not show a stale idle figure (got '$work_fresh')"
  assert_contains "$work_fresh" "working" "a working mate shows working in place of the idle figure (got '$work_fresh')"
  rest_fresh=$(printf '%s' "$idle3_model" | jq -r '.sections.secondmates.rows[] | select(.id=="sm-rest") | .freshness')
  assert_contains "$rest_fresh" "idle " "a genuinely idle mate keeps its terse idle figure (got '$rest_fresh')"
  pass "WP-6 DEFECT 3: a working mate suppresses the frozen-session idle figure; an idle mate keeps it"

  desk_tmux_cleanup
  trap - EXIT
fi

echo "# all fm-desk-lib tests passed"
