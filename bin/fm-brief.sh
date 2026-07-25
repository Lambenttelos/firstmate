#!/usr/bin/env bash
# Scaffold a crewmate brief or persistent secondmate charter at
# data/<task-id>/brief.md under the active firstmate home.
# For ordinary tasks, the standard Setup/Rules/Definition-of-done contract is
# filled in. Firstmate then replaces the {TASK} placeholder with the task
# description, acceptance criteria, and context, and may adjust other sections
# when the task genuinely deviates (e.g. working an existing external PR instead
# of shipping a new one).
# Usage: fm-brief.sh <task-id> <repo-name> [--scout] [--herdr-lab]
#        fm-brief.sh <task-id> --secondmate {<project>...|--no-projects}
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no branch, no push, no PR) and the worktree is scratch.
#   --secondmate writes a persistent secondmate charter. The project list
#   is cloned into the secondmate home, while the natural-language scope
#   tells the main firstmate when to route work there; routine churn stays in its own home;
#   captain-relevant escalations and marked from-firstmate replies append to this
#   home's status file.
#   --no-projects writes a project-less charter for a domain whose subject is the
#   firstmate repo itself (its home is a firstmate worktree, its crews take pooled
#   worktrees of the same repo). It is mutually exclusive with a project list, and
#   omitting both still fails loudly so an accidental omission is never silent.
#   Set FM_SECONDMATE_CHARTER='<charter>' to fill the charter text.
#   Set FM_SECONDMATE_SCOPE='<scope>' to write a routing scope distinct from the charter text.
#   --herdr-lab is mandatory when the task will issue Herdr lifecycle commands.
#   It adds the hard isolation contract backed by bin/fm-herdr-lab.sh.
#   The flag must be explicit because {TASK} is filled after scaffolding and the
#   caller-supplied repo string cannot reliably identify this repo. Briefs made
#   without it carry a loud declaration so an omitted contract cannot be silent.
# For ship tasks, the definition of done is shaped by the project's delivery mode
# (data/projects.md via fm-project-mode.sh; see the project-management skill
# and AGENTS.md task lifecycle):
#   no-mistakes  implement -> /no-mistakes pipeline -> PR -> captain merge (default)
#   direct-PR    implement -> push + open PR via gh-axi (no pipeline) -> captain merge
#   direct-push  implement -> full /no-mistakes pipeline (its PR/CI steps skip; a run
#                ending "passed" with them skipped is complete) -> push validated branch
#                to origin fm/<id> and report its head. No PR, no CI wait; a run reporting
#                "missing NO_MISTAKES_BITBUCKET_EMAIL" is expected, not a blocker. The
#                configured merge authority lands the branch on the forge (e.g. Bitbucket).
#   local-only   implement on branch, stop and report "ready in branch" (no push/PR);
#                captain approves, firstmate merges to local main
# Ship briefs begin with a worktree-isolation assertion before the branch step.
# Scout tasks ignore mode - their deliverable is a report, not a merge.
# Every scaffold's status protocol distinguishes the configured
# declared-external-wait verb (FM_CLASSIFY_PAUSED_VERB, default "paused") from
# "blocked:": pause for a known external wait expected to clear on its own,
# blocked when firstmate must act.
# Ship tasks include a project-memory section so durable project-intrinsic
# learnings can be committed to AGENTS.md through the project's delivery path;
# it carries the AGENTS.md authoring bar (widely useful knowledge only, pointers
# over copied detail) and has the crewmate add the fm-ensure-agents-md.sh
# self-governance section when a touched project AGENTS.md lacks it.
# Every ship and scout scaffold also carries the fleet's shared-machine rules, so a
# freshly spawned crewmate obeys them without being steered: heavy commands go through
# bin/fm-heavy-run.sh, test parallelism is capped at VITEST_MAX_WORKERS=2, every test run
# is announced with TEST START / TEST END status lines, and a live browser reproduction
# waits for firstmate's go-ahead because at most TWO may run fleet-wide at once.
# Ship scaffolds additionally require the final report to declare whether the change was
# built test-first and whether it has end-to-end coverage.
# Every ship and scout scaffold also carries the standing captain rules that bind every
# worker, so they are structural instead of hand-pasted per dispatch: never force anything
# (push to a NEW branch when blocked, never force-push, never force-release, never delete a
# branch), understand the reason behind an instruction before acting and ask firstmate for a
# grilling session when it is unclear, plan with the wayfinder skill before changing code,
# write prose in caveman ultra style while keeping code and tool-parsed text normal, and bind
# no server to port 443 or 3000. The Mattermost-sourced rule is written as a self-guarding
# conditional on the same section rather than behind a flag, because a rule firstmate can
# forget to pass is worth nothing. The secondmate charter carries the subset that applies to a
# supervising home: never force, understand the reason, and caveman ultra prose.
# Refuses to overwrite an existing brief.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
KIND=ship
HERDR_LAB=0
NO_PROJECTS=0
POS=()
for a in "$@"; do
  case "$a" in
    --scout) KIND=scout ;;
    --secondmate) KIND=secondmate ;;
    --herdr-lab) HERDR_LAB=1 ;;
    --no-projects) NO_PROJECTS=1 ;;
    *) POS+=("$a") ;;
  esac
done
ID=${POS[0]}

if [ "$KIND" = secondmate ] && [ "$HERDR_LAB" -eq 1 ]; then
  echo "error: --herdr-lab applies only to crewmate ship or scout briefs" >&2
  exit 1
fi

if [ "$NO_PROJECTS" -eq 1 ] && [ "$KIND" != secondmate ]; then
  echo "error: --no-projects applies only to --secondmate charters" >&2
  exit 1
fi

BRIEF="$DATA/$ID/brief.md"
[ -e "$BRIEF" ] && { echo "error: $BRIEF already exists" >&2; exit 1; }
mkdir -p "$DATA/$ID"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

STATUS_FILE=$(shell_quote "$STATE/$ID.status")

# Standing captain rules. These bind every worker, so they are generated here
# rather than pasted onto each brief by hand: a rule that lives only in
# firstmate memory never reaches a worker whose brief predates it.
# Both blocks use quoted heredocs and reach the brief only through variable
# expansion, which is not re-parsed, so their contents are literal.
# Rule 3's `wayfinder` skill is installed at the user level
# (~/.claude/skills/wayfinder), not tracked in this repo, so it resolves for
# every worker spawned on this machine and a repo-presence check is the wrong test.
CAPTAIN_RULES=$(cat <<'EOF'
# Standing captain rules

These bind you for the whole task. They are not optional and they outrank convenience.

1. **Never force anything.** Never force-push, never force a release, and never delete a
   branch - branch deletion is the captain decision alone. If a push is rejected or a branch
   is otherwise blocked, push to a NEW branch instead and report the new branch name, so
   nothing that exists can be lost.
2. **Understand the WHY before acting.** Never work the wording of this brief mechanically.
   If the reason behind an instruction is not clear enough to act on, STOP and ask firstmate
   for a grilling session. Asking is far cheaper than a wrong implementation and is never
   treated as a failure.
3. **Plan before you change code.** Invoke the `wayfinder` skill to plan the work first.
4. **Write EPHEMERAL prose in caveman ultra style.** Ephemeral prose means status lines and
   the reports or replies you send back to firstmate: drop articles, filler, hedging, and
   pleasantries; fragments are fine; state each fact once. DURABLE documents stay in normal
   English: the scout report at `data/<id>/report.md`, any project `AGENTS.md` or
   `CLAUDE.md`, ADRs, files under `docs/`, code, code comments, commit messages, PR titles
   and bodies, and anything a tool or CI parses. The style exists to cut chat noise, not to
   make the permanent record harder to read - durable documents are read cold months later
   by people and agents with no context. Also drop the style for security warnings,
   irreversible-action confirmations, and any multi-step sequence where dropping
   conjunctions would make the order ambiguous. Never invent abbreviations and never
   abbreviate identifiers, API names, CLI commands, or error strings.
5. **Never bind port 443 or 3000.** Those ports are reserved for the servers the captain
   runs personally. Any server you start runs on a non-default port.
6. **If this task came from a Mattermost thread**, your FIRST action is to re-read the full
   thread; never trust the queue-time summary in this brief. If the reported bug turns out to
   be already fixed, verify that and ADD the missing end-to-end coverage rather than closing
   the task as done.
EOF
)

# The supervising subset for a persistent secondmate home. A secondmate delegates
# implementation to its own crewmates, whose briefs carry the full set, so the
# planning, port, and Mattermost rules do not apply to the charter itself.
CAPTAIN_RULES_SECONDMATE=$(cat <<'EOF'
# Standing captain rules

These bind you and every crewmate you dispatch.

1. **Never force anything.** Never force-push, never force a release, and never delete a
   branch - branch deletion is the captain decision alone. When a push is blocked, push to a
   NEW branch and report it, so nothing that exists can be lost.
2. **Understand the WHY before acting.** Never work routed instructions mechanically. When
   the reason behind a request is not clear enough to act on, STOP and ask the main firstmate
   for a grilling session. Asking is never treated as a failure.
3. **Write EPHEMERAL prose in caveman ultra style.** Ephemeral prose means status lines and
   the reports or replies you send back to the main firstmate: drop articles, filler,
   hedging, and pleasantries; state each fact once. DURABLE documents stay in normal
   English: the scout report at `data/<id>/report.md`, any project `AGENTS.md` or
   `CLAUDE.md`, ADRs, files under `docs/`, code, code comments, commit messages, PR titles
   and bodies, and anything a tool or CI parses. The style exists to cut chat noise, not to
   make the permanent record harder to read - durable documents are read cold months later
   by people and agents with no context. Also drop the style for security warnings,
   irreversible-action confirmations, and any multi-step sequence where dropping
   conjunctions would make the order ambiguous. Never invent abbreviations and never
   abbreviate identifiers, API names, CLI commands, or error strings.
EOF
)

if [ "$KIND" = secondmate ]; then
SECONDMATE_PROJECTS=""
idx=1
while [ "$idx" -lt "${#POS[@]}" ]; do
  SECONDMATE_PROJECTS="${SECONDMATE_PROJECTS}${SECONDMATE_PROJECTS:+ }${POS[$idx]}"
  idx=$((idx + 1))
done
if [ "$NO_PROJECTS" -eq 1 ]; then
  [ -z "$SECONDMATE_PROJECTS" ] || { echo "error: --no-projects cannot be combined with a project list" >&2; exit 1; }
else
  [ -n "$SECONDMATE_PROJECTS" ] || { echo "error: --secondmate requires at least one project, or --no-projects for a project-less home" >&2; exit 1; }
fi
SECONDMATE_CHARTER=${FM_SECONDMATE_CHARTER:-"{TASK}"}
SECONDMATE_SCOPE=${FM_SECONDMATE_SCOPE:-${FM_SECONDMATE_CHARTER:-"{TASK}"}}
if [ "$NO_PROJECTS" -eq 1 ]; then
  PROJECT_CLONES_BODY="None. This is a project-less domain: its subject is the firstmate repo this home lives in, so it needs no separate clones under \`projects/\`; its crews take pooled worktrees of that firstmate repo."
  PROJECT_CLONES_NOTE="This domain has no separate project clones: its subject is the firstmate repo this home lives in, and its crews take pooled worktrees of that repo."
else
  PROJECT_CLONES_BODY=$(printf '%s\n' "$SECONDMATE_PROJECTS" | tr ' ' '\n' | sed 's/^/- /')
  PROJECT_CLONES_NOTE="The projects above are local clones for work you supervise; they are not an exclusive ownership claim."
fi
cat > "$BRIEF" <<EOF
You are a persistent second mate managed by the main firstmate. Work on your own; do not wait for a human.

# Charter
$SECONDMATE_CHARTER

# Routing scope
$SECONDMATE_SCOPE

# Project clones
$PROJECT_CLONES_BODY

# Operating model
You are in an isolated firstmate home. The local \`AGENTS.md\` is your job description, and your local \`data/\`, \`state/\`, \`config/\`, and \`projects/\` dirs are yours to operate.
$PROJECT_CLONES_NOTE
Delegate project work to your own crewmates with the normal firstmate lifecycle: brief, spawn, status, watcher, steer, teardown, and recovery.
Do not invent a second delegation system.
You do not generate your own work.
Act only on tasks the main firstmate routes to you.
Never start a survey, audit, or "find improvements" sweep on your own initiative; that is not your job and it is unwanted.

# Requests from the main firstmate
You are a firstmate in your own home, so an incoming message reaches you in your own chat.
You must distinguish who it is from, because the answer goes to a different place.
A request relayed to you by the main firstmate is tagged with a leading \`$FM_FROMFIRST_LABEL\` marker followed by an invisible system separator; this marker is untypable, so a human never produces it.
When a message carries that marker, do the work, then respond via the STATUS/ESCALATION path below, never only in this chat: the main firstmate does not read your chat, so a chat-only reply is lost.
Marked requests also carry a privacy-safe \`corr=<id>\` token after the marker; include that exact token in your parent status reply (or in the status pointer to a detailed doc) so the parent can correlate the answer.
Optional helper: \`bin/fm-secondmate-report.sh\` can append a correlated status line for you, but a plain \`echo\` that includes the same \`corr=<id>\` is equally valid - do not depend on the helper being present.
For a terse result, a status line is the whole answer.
For a detailed answer (an investigation, a plan, an audit), write it to a doc under your home's \`data/\` and append a status line that points to that doc - the scout-report pattern - so the main firstmate is woken and can read it.
Before treating an investigation or visual review as complete, load \`decision-hold-lifecycle\` from this home's \`.agents/skills/\` and pass its shared completion gate.
A message with NO marker is the captain typing directly into your pane: treat it as authoritative captain intervention and stay conversational exactly as you would for any captain message; do not force it onto the status path.

$CAPTAIN_RULES_SECONDMATE

# Escalation to main firstmate
Handle routine work yourself.
Report only true captain-relevant outcomes or a declared external wait by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
Use \`$PAUSED_VERB: {why}\` (distinct from \`blocked:\`) only when your domain is deliberately idling on a known external wait you expect to clear on its own; use \`blocked:\` when you are stuck and need firstmate to act.
Use this only for material phase changes, a captain decision, a real blocker, a failure, or work ready for review.
This is also how you return the answer to a marked from-firstmate request above.
Give every routed-work phase a stable key: open it with \`working [key=<work-slug>]: {material phase}\`, and use the same key on its later \`$PAUSED_VERB\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event so the earlier working phase is superseded.
When a keyed phase ends without another reportable state, append \`resolved [key=<work-slug>]: {why it is no longer active}\`.
When a decision you escalated is answered or a blocker clears and your domain resumes, append \`resolved: {how it was decided or unblocked}\` (keyed with \`[key=<slug>]\` if you opened it with one) so it is durably closed instead of resurfacing behind later unrelated events.
Routine internal supervision, heartbeats, retries, and crewmate churn stay inside your own home and must not touch that status file.

# Definition of done
You are persistent by default. Do not exit just because your queue is empty.
On startup and restart, run normal firstmate bootstrap and recovery through \`bin/fm-session-start.sh\` for your own home, but only to RECONCILE work that is already yours: in-flight crewmates, tracked backlog items, and durable watches recorded in this home.
When you have no assigned or in-flight work after that reconciliation, go idle and wait silently for the main firstmate to route you a task.
An empty queue is a healthy resting state, not a cue to invent work: never spawn a survey, audit, or any self-directed "find work" task on your own initiative.
If this charter cannot be carried out, append \`blocked: {why}\` or \`failed: {why}\` to the main status file and stop.
EOF
if [ "$SECONDMATE_CHARTER" = "{TASK}" ]; then
  echo "scaffolded: $BRIEF (secondmate charter; replace {TASK})"
else
  echo "scaffolded: $BRIEF (secondmate charter)"
fi
exit 0
fi

REPO=${POS[1]}

if [ "$HERDR_LAB" -eq 1 ]; then
HERDR_LAB_HELPER=$(shell_quote "$FM_ROOT/bin/fm-herdr-lab.sh")
# shellcheck disable=SC2016  # single quotes are deliberate: these lines are literal brief text whose backtick-wrapped $(...) and "$HERDR_LAB_SESSION" snippets must reach the reading agent verbatim, not expand at scaffold time; only the '"$VAR"' break-outs interpolate.
HERDR_SECTION=$(printf '%s\n' \
'# Herdr isolation - HARD SAFETY CONTRACT' \
'This brief was explicitly scaffolded with `--herdr-lab` because the task will drive Herdr lifecycle behavior.' \
'On Herdr 0.7.3 the API socket is not relocatable by `HERDR_CONFIG_PATH`, `XDG_CONFIG_HOME`, or `HOME`.' \
'A named non-`default` session plus a trailing `--session <name>` on every call is the only viable local isolation.' \
'' \
'1. Set `HERDR_LAB_HELPER='"$HERDR_LAB_HELPER"'` and generate the session name with `HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name '"$ID"')`.' \
'   Install `trap '\''"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"'\'' EXIT` before provisioning, then provision only with `"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"`.' \
'2. Run every task-specific non-lifecycle Herdr command through `"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" <arguments...>`.' \
'   The helper appends the required trailing `--session "$HERDR_LAB_SESSION"`; `HERDR_SESSION` alone is never accepted as isolation.' \
'3. Teardown only through `"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"`.' \
'   It re-checks refuse-default immediately before stop and again immediately before delete, and fails closed on ambiguity.' \
'4. If an experiment requires a deliberate mid-run session stop, use only `"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION"`; it performs the same immediate refuse-default check.' \
'5. Forbidden commands: direct `herdr server stop`, every other server-global operation such as `herdr server live-handoff` or reload/update operations, direct `herdr session stop`, direct `herdr session delete`, and any Herdr call scoped only by ambient or inline `HERDR_SESSION`.' \
'6. The helper records the live default session before provisioning and verifies the identical fleet state after teardown.' \
'   A missing, stopped, or changed default session is a hard tripwire failure, never a cleanup warning to ignore.' \
'' \
'Never bypass the helper, even for a read-only lifecycle probe or cleanup after failure.' \
'The captain fleet uses the running `default` session.')
else
HERDR_SECTION=$(cat <<'EOF'
# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text that replaces `{TASK}` later.
If the task will start, stop, delete, restart, profile, or otherwise drive Herdr lifecycle behavior, stop and regenerate the brief with `--herdr-lab` before dispatch.
Do not add Herdr lifecycle commands to this unguarded brief by hand.
EOF
)
fi

if [ "$KIND" = scout ]; then
cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is your laboratory - install, run, edit, and make scratch commits freely; all of it is discarded at teardown.
The report is the only thing that survives, so anything worth keeping must be in it.

# Rules
1. Never push to any remote and never open a PR.
2. Stay inside this worktree; the only files you may write outside it are the report and the status file below.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on and the needs-decision/blocked/paused/done/failed states. No step-by-step
   FYI progress lines; firstmate reads your pane for that.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset):
   firstmate then leaves your idle pane alone and rechecks it on a long cadence instead of
   treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.
   When firstmate replies or a blocker clears and you resume, append \`resolved: {how it was decided or unblocked}\` (add the same \`[key=<slug>]\` if you opened it with one) so the decision or blocker is durably closed and does not keep resurfacing.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append \`blocked: {the daemon error}\` and stop; only firstmate manages the daemon.
8. Run every heavy command - unit suites, end-to-end suites, lint sweeps, builds - through
   \`$FM_ROOT/bin/fm-heavy-run.sh --task $ID -- <command>\`. It queues the run so the whole fleet
   is not thrashing one machine, then gives you the command's real output and exit status.
   It prints a queued notice while you wait; that is normal, not a hang.
   Cap test parallelism at \`VITEST_MAX_WORKERS=2\` - never 4: vitest sizes its pool from the CPU
   count and is the fleet's dominant memory consumer.
9. Announce every test run in the status file: \`working: TEST START - {what is running, rough scale}\`
   before it, \`working: TEST END - {outcome}\` after it. Firstmate coordinates the shared machine
   from those two lines, so a silent suite is a defect.
10. At most TWO live browser reproductions may run across the whole fleet at once.
   Before you start one, append \`working: BROWSER WAIT - {what you will drive}\` and STOP until
   firstmate replies with a go-ahead - the one line in this brief you do wait on.
   Append \`working: BROWSER END - {outcome}\` the moment it finishes so the slot is released.

$CAPTAIN_RULES

# Definition of done
Write your findings to \`$DATA/$ID/report.md\`.
The report must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
Before reporting done, read and follow \`$FM_ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md\` and pass its shared completion gate for the report and any visual review.
When the report is complete, append \`done: {one-line conclusion}\` to the status file and stop.
If your findings reveal work that should ship (e.g. you reproduced a bug and the fix is clear), say so in the report; firstmate may promote this task in place, and you would then receive mode-specific ship instructions as a follow-up message.
EOF
echo "scaffolded: $BRIEF (scout; replace {TASK})"
exit 0
fi

# Ship task: shape Setup / Rule 1 / Definition of done by the project's delivery mode.
# yolo does not affect the brief (it governs firstmate's approval behaviour), so discard it.
read -r MODE _ <<EOF
$("$FM_ROOT/bin/fm-project-mode.sh" "$REPO")
EOF

case "$MODE" in
  direct-PR)
    SETUP2=""
    RULE1='1. Never push to the default branch (push only your `fm/'"$ID"'` branch). Never merge a PR.'
    DOD=$(cat <<EOF
# Definition of done
This project ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
)
    ;;
  direct-push)
    SETUP2="
2. Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`."
    RULE1='1. Never push to the default branch (push only your `fm/'"$ID"'` branch to origin). Never merge a PR.'
    DOD=$(cat <<EOF
# Definition of done
This project ships **direct-push**: the forge cannot host firstmate-opened PRs (e.g. Bitbucket), so there is no PR and no CI to wait on.
You still run the FULL /no-mistakes pipeline; its \`pr\` and \`ci\` steps not applying is expected, and a run ending \`passed\` with those steps skipped is COMPLETE - do not treat skipped PR/CI as a failure or a wait.
A run reporting \`missing NO_MISTAKES_BITBUCKET_EMAIL\` is expected and is NOT a blocker; do not append \`blocked:\` for it.

The task is complete only when committed on your branch.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate.

Before you invoke /no-mistakes, run \`$FM_ROOT/bin/fm-nm-preflight.sh\` from this worktree.
If it refuses, do NOT invoke /no-mistakes: append \`blocked: {the refusal it printed}\` and stop.
It refuses when the pipeline already has a run in flight on a different branch, because a run started here would silently attach to that one and validate that branch instead of yours - never respond to or abort that run, because its findings belong to the lane that started it.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are not yours to answer: escalate to firstmate (rule 6) and stop.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Avoid \`--yes\`: the captain, not you, owns the ask-user decisions it would silently auto-resolve.

After the pipeline reports \`passed\`, push your validated branch explicitly - a pipeline "push" only reaches the local internal gate:
  \`git push origin HEAD:fm/$ID\`
Then append \`done: pushed origin fm/$ID @ {short-sha}\` (the branch head commit) to the status file and stop. You are finished.
Do NOT wait for a PR url or checks-green - none will arrive. The configured merge authority lands the branch on the forge; firstmate verifies it on origin.
EOF
)
    ;;
  local-only)
    SETUP2=""
    RULE1="1. Never push to any remote and never open a PR. Work only on your \`fm/$ID\` branch; firstmate handles the merge into local \`main\`."
    DOD=$(cat <<EOF
# Definition of done
This project ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$ID\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done: ready in branch fm/$ID\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
)
    ;;
  *)  # no-mistakes (default)
    SETUP2="
2. Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`."
    RULE1='1. Never push to the default branch. Never merge a PR.'
    DOD=$(cat <<EOF
# Definition of done
The task is complete only when committed on your branch.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

Before you invoke /no-mistakes, run \`$FM_ROOT/bin/fm-nm-preflight.sh\` from this worktree.
If it refuses, do NOT invoke /no-mistakes: append \`blocked: {the refusal it printed}\` and stop.
It refuses a detached HEAD and a worktree that belongs to another copy of the repo.
A run in flight on a DIFFERENT branch is not a refusal: no-mistakes serializes per repo+branch, so your branch validates alongside it. The guard names that run as a warning - never respond to or abort that run, because its findings belong to the lane that started it.

Drive YOUR run by its id. \`no-mistakes axi run\` reports the run it started; from then on read it with \`no-mistakes axi status --run <id>\` and \`no-mistakes axi logs --run <id> --step <step>\`.
A bare \`axi status\` resolves repo-wide whenever your branch has no run of its own, so it can hand you a concurrent lane run as if it were yours.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are not yours to answer: escalate to firstmate (rule 6) and stop.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Avoid \`--yes\`: the captain, not you, owns the ask-user decisions it would silently auto-resolve.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished.
EOF
)
    ;;
esac

cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

$HERDR_SECTION

# Setup
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.

**Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from.
The path check is authoritative: \`git rev-parse --git-dir\` and \`git rev-parse --git-common-dir\` can help inspect the repo, but they do not prove you are outside the primary checkout.
If the top-level path is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit here - append \`blocked: launched in primary checkout, not an isolated worktree\` to the status file and stop.

1. First action: create your branch: \`git checkout -b fm/$ID\`$SETUP2

# Rules
$RULE1
2. Stay inside this worktree; modify nothing outside it.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, validation passed) and the
   needs-decision/blocked/paused/done/failed states. No step-by-step FYI progress lines;
   firstmate reads your pane for that.
   A mid-task \`working:\` line (including setup complete) is nonterminal: do not end the
   turn after it; continue the same stage until a defined \`done:\` gate under Definition of done.
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset,
   a scheduled window): firstmate then leaves your idle pane alone and rechecks it on a long
   cadence instead of treating it as a possible wedge. Use \`blocked:\` when you are stuck and need help.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions, ask-user findings),
   append \`needs-decision: {summary of options}\` and stop. Firstmate will reply with the decision.
   When firstmate replies or a blocker clears and you resume, append \`resolved: {how it was decided or unblocked}\` (add the same \`[key=<slug>]\` if you opened it with one) so the decision or blocker is durably closed and does not keep resurfacing.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append \`blocked: {the daemon error}\` and stop; only firstmate manages the daemon.
8. Run every heavy command - unit suites, end-to-end suites, lint sweeps, builds - through
   \`$FM_ROOT/bin/fm-heavy-run.sh --task $ID -- <command>\`. It queues the run so the whole fleet
   is not thrashing one machine, then gives you the command's real output and exit status.
   It prints a queued notice while you wait; that is normal, not a hang.
   Cap test parallelism at \`VITEST_MAX_WORKERS=2\` - never 4: vitest sizes its pool from the CPU
   count and is the fleet's dominant memory consumer.
9. Announce every test run in the status file: \`working: TEST START - {what is running, rough scale}\`
   before it, \`working: TEST END - {outcome}\` after it. Firstmate coordinates the shared machine
   from those two lines, so a silent suite is a defect.
10. At most TWO live browser reproductions may run across the whole fleet at once.
   Before you start one, append \`working: BROWSER WAIT - {what you will drive}\` and STOP until
   firstmate replies with a go-ahead - the one line in this brief you do wait on.
   Append \`working: BROWSER END - {outcome}\` the moment it finishes so the slot is released.

$CAPTAIN_RULES

# Project memory
If \`AGENTS.md\` or \`CLAUDE.md\` already exists, or if this task produced durable project-intrinsic knowledge, run \`$FM_ROOT/bin/fm-ensure-agents-md.sh .\` in the worktree.
Record only project knowledge useful to almost every future session.
For anything the codebase already shows, prefer a pointer to the authoritative file, command, or doc over copying the detail.
If you touch a project \`AGENTS.md\` that lacks \`## Maintaining this file\`, add that short self-governance section from \`$FM_ROOT/bin/fm-ensure-agents-md.sh\` in the same pass.
Keep it proportionate: skip \`AGENTS.md\` edits for trivial tasks that produced no durable project knowledge.

# Test coverage declaration
Your final report must state plainly whether you built this change test-first and whether it has end-to-end coverage.
A gap does not block the merge, but name the gap and its reason; the captain reviews every untested product change.

$DOD
EOF
echo "scaffolded: $BRIEF (ship, mode=$MODE; replace {TASK})"
