#!/usr/bin/env bash
# Static regression tests for the captain-facing plain-English translation
# contract owned by AGENTS.md section 9.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGENTS="$ROOT/AGENTS.md"
BOOTSTRAP="$ROOT/.agents/skills/bootstrap-diagnostics/SKILL.md"
AFK="$ROOT/.agents/skills/afk/SKILL.md"
DECISION="$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md"
RECOVERY="$ROOT/.agents/skills/stuck-crewmate-recovery/SKILL.md"
HARNESS="$ROOT/.agents/skills/harness-adapters/SKILL.md"
CODEXAPP="$ROOT/.agents/skills/firstmate-codexapp/SKILL.md"
FMX="$ROOT/.agents/skills/fmx-respond/SKILL.md"
UPDATE="$ROOT/.agents/skills/updatefirstmate/SKILL.md"
AHOY="$ROOT/.agents/skills/ahoy/SKILL.md"
README="$ROOT/README.md"

section_9() {
  awk '
    /^## 9\. Escalation and captain etiquette$/ { found = 1 }
    found && /^## 10\. / { exit }
    found { print }
  ' "$AGENTS"
}

test_section_9_owns_positive_translation_contract() {
  local contract
  contract=$(section_9)
  assert_contains "$contract" "Every captain-facing message must translate internal state into the project outcome, consequence, and next decision." \
    "section 9 does not own the positive captain-facing translation contract"
  assert_contains "$contract" "Use the captain's nouns:" \
    "section 9 does not require captain-owned nouns"
  assert_contains "$contract" "When evidence uses an internal label, rewrite it before sending:" \
    "section 9 does not own the rewrite mapping list"
  pass "section 9 owns the positive captain-facing translation contract"
}

test_scout_remains_allowed_house_vocabulary() {
  local contract
  contract=$(section_9)
  assert_contains "$contract" "Scout and second mate are accepted Firstmate nautical house vocabulary and do not need translation" \
    "section 9 does not preserve scout as allowed Firstmate vocabulary"
  assert_not_contains "$contract" "scout -> investigation" \
    "section 9 must not map scout to investigation"
  assert_not_contains "$contract" "scout, ship" \
    "section 9 must not add scout to the internal-vocabulary ban"
  assert_not_contains "$contract" "secondmate -> domain supervisor" \
    "section 9 must not map secondmate to domain supervisor"
  pass "scout remains allowed in private captain chat"
}

test_compressed_safety_labels_have_plain_renderings() {
  local contract
  contract=$(section_9)
  for phrase in \
    "fail-closed" \
    "fails closed" \
    "fail-open" \
    "fails open" \
    "fail loudly"; do
    assert_contains "$contract" "$phrase" "section 9 does not cover compressed safety label '$phrase'"
  done
  assert_contains "$contract" "stops safely when something goes wrong" \
    "fail-closed behavior lacks a concrete plain rendering"
  assert_contains "$contract" "refuses rather than proceeding" \
    "fail-closed behavior lacks refusal wording"
  assert_contains "$contract" "steps aside and lets work continue when the check cannot complete" \
    "fail-open behavior lacks a concrete plain rendering"
  pass "compressed safety labels require concrete plain renderings"
}

test_mapping_list_covers_high_risk_internal_families() {
  local contract
  contract=$(section_9)
  for phrase in \
    "worktree, checkout, primary checkout, or local-main -> local copy" \
    "teardown -> cleanup" \
    "wake, watcher, heartbeat, stale, signal, or check -> notification" \
    "hold, gate, ask-user, needs-decision, blocked, or paused -> the concrete decision" \
    "done, failed, fix-review, checks-passed, cancelled, validation step, or pipeline state -> the concrete result" \
    "brief -> instructions" \
    "crewmate -> worker" \
    "harness, backend, runtime, or adapter -> worker runtime or tool" \
    "status file, metadata, state, task id, or raw path -> durable record"; do
    assert_contains "$contract" "$phrase" "section 9 mapping list is missing '$phrase'"
  done
  pass "section 9 maps high-risk internal vocabulary families"
}

test_verbatim_internal_evidence_is_rejected_from_chat() {
  local contract
  contract=$(section_9)
  assert_contains "$contract" "Never relay worker reports, status lines, tool output, validation-state labels, or decision records verbatim into captain chat." \
    "section 9 does not reject verbatim internal evidence in captain chat"
  assert_contains "$contract" "A report may retain internal terms alongside the verbatim evidence allowed by the caveman ultra prose rule below" \
    "section 9 does not preserve report precision for every report"
  assert_not_contains "$contract" "Private evidence reports may retain" \
    "section 9 still limits report precision to private reports"
  assert_contains "$contract" "the captain-facing chat summary that points to the report still follows this translation rule" \
    "section 9 does not keep chat summaries plain English"
  pass "captain chat rejects verbatim internal evidence while reports stay precise"
}

test_outward_facing_skill_points_reference_section_9_owner() {
  assert_grep "using \`AGENTS.md\` section 9's captain-facing translation contract" "$BOOTSTRAP" \
    "bootstrap diagnostics do not reference section 9 at captain handoff"
  assert_grep "Acknowledge** in \`AGENTS.md\` section 9 language" "$AFK" \
    "afk acknowledgement does not reference section 9"
  assert_grep "Captain, away mode is active; I will batch routine updates" "$AFK" \
    "afk acknowledgement lacks a local plain-English example"
  assert_grep "as decisions from Bearings' Captain's Call section under \`AGENTS.md\` section 9" "$DECISION" \
    "decision relay does not reference section 9"
  assert_grep "using \`AGENTS.md\` section 9; do not mention metadata, harness, window, or worktree" "$RECOVERY" \
    "stuck-worker failure does not reference section 9"
  assert_grep "under \`AGENTS.md\` section 9 that the requested worker runtime is not verified yet" "$HARNESS" \
    "runtime fallback does not reference section 9"
  assert_grep "use firstmate's own verified runtime for current work" "$HARNESS" \
    "runtime fallback does not require the current-work fallback"
  assert_grep "Do not pause current work for that future-verification choice, and never launch an unverified adapter." "$HARNESS" \
    "runtime fallback permits waiting on future verification or launching an unverified adapter"
  assert_grep "translate status prefixes and return-channel evidence through \`AGENTS.md\` section 9" "$CODEXAPP" \
    "Codex Desktop result reporting does not reference section 9"
  assert_grep "It supplements \`AGENTS.md\` section 9; apply both, and this public-channel rule wins wherever it is stricter." "$FMX" \
    "X reply safety does not state that it supplements section 9"
  assert_grep "under \`AGENTS.md\` section 9 without firstmate's internal vocabulary" "$UPDATE" \
    "Firstmate update reporting does not reference section 9"
  pass "outward-facing skill handoffs point to the section 9 owner"
}

assert_no_skill_duplicates() {
  local marker="$1" message="$2"
  local duplicates file
  duplicates=""
  for file in "$ROOT"/.agents/skills/*/SKILL.md; do
    [ -e "$file" ] || continue
    if grep -Fq "$marker" "$file"; then
      duplicates="$duplicates $file"
    fi
  done
  [ -z "$duplicates" ] || fail "$message:$duplicates"
}

test_section_9_owner_is_not_duplicated_into_skills() {
  assert_no_skill_duplicates "When evidence uses an internal label, rewrite it before sending:" \
    "skills duplicated section 9's mapping owner"
  pass "skills cross-reference section 9 instead of duplicating the mapping list"
}

# The caveman ultra prose rule used to live only in one home's private captain
# preferences, so it bound by memory and every live worker had to be hand-steered.
# Section 9 is now its structural owner, next to the translation contract it must
# never override.
test_section_9_owns_the_caveman_ultra_prose_rule() {
  local contract
  contract=$(section_9)
  assert_contains "$contract" "**Write in caveman ultra prose.**" \
    "section 9 does not own the caveman ultra prose rule"
  assert_contains "$contract" "It binds captain-facing chat, escalations, captain-facing summaries, and reports, including scout reports, per-task reports, and session or status reports." \
    "section 9 does not bind reports to the compression rule"
  assert_contains "$contract" "never relaxes section 8's quiet-when-idle contract" \
    "section 9 lets compression relax the quiet-when-idle contract"
  assert_contains "$contract" "a compressed message that leaks internal vocabulary is still a violation" \
    "section 9 lets compression override the translation contract"
  assert_contains "$contract" "Inside any report, private or captain-facing, exact identifiers, paths, commands, status lines, and error strings stay verbatim" \
    "section 9 does not grant the verbatim-evidence carve-out to any report"
  pass "section 9 owns the caveman ultra prose rule for chat and reports"
}

# The exceptions must be stated where the rule is stated, so an agent that reads
# only this paragraph never compresses text a tool, a forge, or a human safety
# decision depends on.
test_caveman_rule_states_its_exceptions_in_place() {
  local contract phrase
  contract=$(section_9)
  for phrase in \
    "commit messages" \
    "PR titles and bodies" \
    "anything a tool, forge, or CI parses" \
    "security warnings" \
    "irreversible-action confirmations" \
    "dropping conjunctions makes the order ambiguous" \
    "Never invent abbreviations"; do
    assert_contains "$contract" "$phrase" \
      "section 9's caveman rule lost its \"$phrase\" exception"
  done
  pass "the caveman rule states its exceptions next to the rule"
}

# One owner: skills must point at section 9 rather than carry a second copy of
# the rule that will drift the moment only one is edited.
test_caveman_rule_is_not_duplicated_into_skills() {
  assert_no_skill_duplicates "**Write in caveman ultra prose.**" \
    "skills duplicated section 9's caveman ultra prose owner"
  pass "skills do not duplicate the caveman ultra prose owner"
}

test_ahoy_is_an_internal_user_invocable_skill() {
  assert_present "$AHOY" "ahoy skill is missing"
  assert_grep 'name: ahoy' "$AHOY" "ahoy skill metadata has the wrong name"
  assert_grep 'user-invocable: true' "$AHOY" "ahoy skill is not user-invocable"
  assert_grep '  internal: true' "$AHOY" "ahoy skill is not internal"
  [ ! -e "$ROOT/skills/ahoy" ] || fail "ahoy must not exist in the public installer-facing skills directory"
  pass "ahoy is internal, user-invocable, and absent from public skills"
}

test_ahoy_readme_uses_cross_harness_convention() {
  assert_grep 'Claude and grok use the slash form shown here; codex uses the same names with `$`' "$README" \
    "README lost the cross-harness slash and dollar convention"
  assert_grep '| `/ahoy`' "$README" "README built-in skills table does not list /ahoy"
  pass "README lists ahoy under the shared cross-harness invocation convention"
}

test_ahoy_owns_only_the_visible_session_recap() {
  assert_grep '[`../bearings/SKILL.md`](../bearings/SKILL.md)' "$AHOY" \
    "first-message fallback does not delegate to Bearings by relative pointer"
  assert_grep 'If no prior real captain message exists' "$AHOY" \
    "ahoy does not limit Bearings fallback to the first real captain message"
  assert_grep 'A captain boundary is an ordinary user-role message unless it matches one of the narrow operational exclusions below.' "$AHOY" \
    "ahoy lacks an explicit captain-authored boundary rule"
  assert_grep 'Exclude messages that begin with the current U+2063 `FIRSTMATE_OP:` injection prefix.' "$AHOY" \
    "ahoy does not exclude current marked operational injections"
  assert_grep 'Exclude legacy bare-marker away-mode injections only when U+2063 is immediately followed by `Supervisor escalate (`.' "$AHOY" \
    "ahoy does not narrowly exclude the legacy away-mode injection shape"
  assert_grep 'Exclude the exact legacy unmarked session-start payload ``Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.``' "$AHOY" \
    "ahoy does not exclude the legacy unmarked session-start payload"
  assert_grep 'quotes or embeds a current operational message after ordinary captain text' "$AHOY" \
    "ahoy lacks quoted-current near-miss protection"
  assert_grep 'Apply the current exclusion only when U+2063 `FIRSTMATE_OP:` begins at the first character of the whole message' "$AHOY" \
    "ahoy does not pin the current-prefix whole-message boundary"
  assert_grep 'contains ASCII `FIRSTMATE_OP:` without a leading U+2063' "$AHOY" \
    "ahoy lacks ASCII-only near-miss protection"
  assert_grep 'Apply the legacy startup exclusion as a literal whole-message match: ``Captain quote: Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.`` is a captain boundary.' "$AHOY" \
    "ahoy does not pin the altered-startup behavioral near miss"
  assert_grep 'System, developer, tool, watcher, guard, away-mode, and other injected operational messages are not captain messages.' "$AHOY" \
    "ahoy incorrectly treats synthetic operational messages as captain messages"
  assert_grep 'The normal recap branch is session-history-only.' "$AHOY" \
    "later ahoy invocation is not explicitly session-history-only"
  assert_grep 'Do not call Bearings, shell commands, fleet snapshots, status readers, GitHub or browser APIs, tools, or file reads or writes.' "$AHOY" \
    "normal recap does not prohibit fresh fleet, file, and tool reads"
  assert_grep 'do not guess current live state beyond the last visible event' "$AHOY" \
    "normal recap may falsely claim a live snapshot"
  assert_grep 'If context compaction makes the prior boundary unavailable' "$AHOY" \
    "ahoy does not disclose an unavailable compacted boundary"
  assert_grep 'summarize only visibly supported events' "$AHOY" \
    "compacted fallback may invent unsupported events"
  assert_no_grep 'fm-bearings-snapshot.sh' "$AHOY" \
    "ahoy copied Bearings gathering mechanics instead of referencing its owner"
  assert_no_grep "Captain's Call" "$AHOY" \
    "ahoy copied Bearings response contract instead of referencing its owner"
  pass "ahoy delegates first-message fallback and keeps later recaps visible-session-only"
}

test_ahoy_user_role_injections_share_one_marker() {
  local daemon grok_guard opencode_guard opencode_watch pi_guard pi_watch owner sessionstart spawn
  daemon=$(cat "$ROOT/bin/fm-supervise-daemon.sh")
  grok_guard=$(cat "$ROOT/bin/fm-turnend-guard-grok.sh")
  opencode_guard=$(cat "$ROOT/.opencode/plugins/fm-primary-turnend-guard.js")
  opencode_watch=$(cat "$ROOT/.opencode/plugins/fm-primary-watch-arm.js")
  pi_guard=$(cat "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts")
  pi_watch=$(cat "$ROOT/.pi/extensions/fm-primary-pi-watch.ts")
  owner=$(cat "$ROOT/bin/fm-operational-input.sh")
  sessionstart=$(cat "$ROOT/bin/fm-sessionstart-nudge.sh")
  spawn=$(cat "$ROOT/bin/fm-spawn.sh")

  assert_contains "$owner" 'FM_OPERATIONAL_PREFIX="${FM_OPERATIONAL_MARK}FIRSTMATE_OP: "' \
    "canonical owner lost the landed Ahoy prefix"
  assert_contains "$sessionstart" 'fm_operational_input_encode session-start' \
    "session-start does not use the canonical typed constructor"
  assert_contains "$daemon" 'fm_operational_input_encode away-supervisor' \
    "away-mode does not use the canonical typed constructor"
  assert_contains "$grok_guard" 'fm_operational_input_encode turn-end-guard' \
    "Grok guard does not use the canonical typed constructor"
  assert_contains "$opencode_guard" 'encodeFirstmateOperationalInput(' \
    "OpenCode guard does not use the cross-language constructor"
  assert_contains "$opencode_guard" '"turn-end-guard"' \
    "OpenCode guard does not retain its exact current kind"
  assert_contains "$opencode_watch" 'encodeFirstmateOperationalInput(paths.root, "watcher"' \
    "OpenCode watcher does not retain its exact current kind"
  assert_contains "$pi_guard" 'encodeFirstmateOperationalInput(' \
    "Pi guard does not use the cross-language constructor"
  assert_contains "$pi_guard" '"turn-end-guard"' \
    "Pi guard does not retain its exact current kind"
  assert_contains "$pi_watch" '"watcher"' \
    "Pi watcher does not retain its exact current kind"
  assert_contains "$spawn" 'encode launch-brief' \
    "cross-harness launches do not use the canonical launch-instruction kind"
  for producer in "$daemon" "$grok_guard" "$opencode_guard" "$opencode_watch" "$pi_guard" "$pi_watch" "$sessionstart" "$spawn"; do
    assert_not_contains "$producer" 'FIRSTMATE_OP: ' \
      "a current producer copied the canonical marker grammar"
  done
  pass "ahoy: one canonical owner constructs typed operational input for every Firstmate-controlled user-role producer"
}

test_section_9_owns_positive_translation_contract
test_scout_remains_allowed_house_vocabulary
test_compressed_safety_labels_have_plain_renderings
test_mapping_list_covers_high_risk_internal_families
test_verbatim_internal_evidence_is_rejected_from_chat
test_outward_facing_skill_points_reference_section_9_owner
test_section_9_owner_is_not_duplicated_into_skills
test_section_9_owns_the_caveman_ultra_prose_rule
test_caveman_rule_states_its_exceptions_in_place
test_caveman_rule_is_not_duplicated_into_skills
test_ahoy_is_an_internal_user_invocable_skill
test_ahoy_readme_uses_cross_harness_convention
test_ahoy_owns_only_the_visible_session_recap
test_ahoy_user_role_injections_share_one_marker
