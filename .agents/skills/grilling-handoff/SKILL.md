---
name: grilling-handoff
description: Own the full round trip of a grilling session - firstmate prepares a captain-driven griller session and later intakes its finished result. Use when the captain invokes /grilling-handoff, wants to stress-test a design before building and hand it to a separate griller, or hands back a finished grilling session for firstmate to take in.
user-invocable: true
metadata:
  internal: true
---

# grilling-handoff

A grilling session stress-tests a fuzzy design before anyone builds it.
Firstmate does not run the grilling; the captain drives a separate griller agent by hand.
This skill owns both ends of that handoff so nothing leaks between them: the session's own identity (a session that goes out and never comes back stays visible), the ADR number the session will produce (two concurrent sessions can never claim the same number), and the handback (findings arrive as a document firstmate intakes into real queue items, not as re-explained conversation).

Firstmate spawns and owns the griller pane itself, in this fleet's default harness, and the captain switches into that pane to drive the grilling by hand.
The pane is hands-off: firstmate creates it but never supervises, steers, nudges, turn-end-pokes, or otherwise injects into it, because a grilling is the captain's live interview and any firstmate injection would corrupt it.
This is enforced structurally by spawning with `--unsupervised`, which records `supervise=off` in the task's runtime record and drops the pane from every supervision path (see the spawn step below).

The brief is the contract and the handback document is the deliverable.

This skill has two entry points, selected by the first argument:

- `/grilling-handoff prepare <ticket(s) or description>` - firstmate writes the brief and hands the captain the paths.
- `/grilling-handoff intake <slug>` - firstmate takes a finished session back.

If the captain's phrasing does not name an entry point, infer it: a request to stress-test or set up a grilling is `prepare`; a pasted handback line or "the grilling is done" is `intake`.

## Prepare

Given one or more tickets or a described chunk of work that needs grilling.

1. **Pick the slug and date.**
   The slug is lowercase letters, digits, and dashes; it becomes the session directory name, the spawned griller's task id `grill-<slug>`, and the tracking item id `grill-<slug>`, so choose it once and reuse it everywhere.
   The date is today in `YYYY-MM-DD`.
   One session may cover a **cluster** of related tickets under a single slug when they share context - grilling coupled tickets separately wastes the captain's time re-explaining that shared context.
   Genuinely independent work gets separate slugs and separate sessions.

2. **Resolve the product repo and scan its ADR numbers.**
   Resolve the project the grilling targets exactly as ordinary intake does (section 7).
   Read that project's clone under `projects/<name>` and locate its ADR directory - commonly `docs/adr`, otherwise `docs/decisions` or `agents/adr`.
   Find the highest existing ADR number (the leading zero-padded integer of each ADR filename).
   That highest number is the scan max you pass in the next step.
   Reading the clone is allowed; this step writes nothing into the product repo.

3. **Reserve the ADR number and create the session directory.**
   Run:

   ```
   bin/fm-grill-reserve.sh --slug <slug> --date <YYYY-MM-DD> --project <name> --adr-scan-max <highest-existing>
   ```

   It allocates the next free number as `max(scan max, highest already reserved in the ledger) + 1`, records the claim in the firstmate-private ledger at `data/grilling/adr-reservations.md` under a lock so two concurrent sessions cannot claim one number, and creates `data/grilling/<date>-<slug>/`.
   The ledger is fleet-wide across every product repo, not per-repository, so the number reflects the highest reserved anywhere plus one; a repo that has never had an ADR can therefore receive a first number well above `0001`, which is correct and collision-free, not a bug.
   It prints `adr=`, `session_dir=`, and `slug=`; keep those values.
   It is idempotent per slug, so a retried prepare is safe.
   **Firstmate must not create the placeholder ADR file itself** - section 1 forbids firstmate writing into a project for any reason, including a stub.
   The griller creates the actual ADR file in the product repo and commits it.
   Because a human could still take the number through their own PR in the meantime, the brief tells the griller to re-check the number at commit time and report it if it moved.

4. **Write the brief** to `<session_dir>/brief.md` using the template below, filling every element.

5. **File the captain-gated tracking item** so a session that went out and did not come back stays visible instead of vanishing:

   ```
   tasks-axi hold grill-<slug> --reason "grilling session out: <slug> (<project>), handback <session_dir>/handback.md" --kind captain
   ```

6. **Spawn the griller pane yourself, hands-off.**
   Firstmate creates the pane through the normal spawn path in this fleet's default harness - the same harness firstmate's ordinary crew resolve to, through the normal harness and dispatch selection, never a hardcoded adapter or model.
   Spawn it with `--unsupervised` so the pane records `supervise=off` and is dropped from every supervision path (no turn-end poke, no stall or wedge watch, no steer): the pane is the captain's live interview and firstmate must never touch it.

   `bin/fm-spawn.sh` delivers the task's own brief at `data/<task-id>/brief.md` to the launched agent, so write the griller's initial instruction there (a short pointer to the real grilling brief), then spawn with task id `grill-<slug>`:

   ```
   mkdir -p data/grill-<slug>
   printf '%s\n' 'Run /grill-with-docs <session_dir>/brief.md and follow that brief to drive this grilling session.' > data/grill-<slug>/brief.md
   bin/fm-spawn.sh grill-<slug> projects/<name> --unsupervised
   ```

   The spawn allocates an isolated disposable worktree of firstmate's own clone `projects/<name>` exactly like any crewmate lane, so the grilling never touches firstmate's primary checkout.
   The pointer names the durable griller brief written in step 4 (`<session_dir>/brief.md`); the griller reads that brief and drives the interview through the `/grill-with-docs` skill.
   The griller runs whatever harness the fleet default resolves to; do not carry an alternate launch command.

7. **Report to the captain** the reserved ADR number, the project, the pane to switch into (the spawn prints `window=<target>` - relay that target), and the reminder that the captain drives the grilling by hand and then tells firstmate to take over.
   Include the one-line prompt the captain pastes back to firstmate when the grilling is done (from the "Prompt back to firstmate" section below).

### Brief template

Write the brief in normal prose (it is a document a griller agent reads, not captain chat).
Fill every placeholder.

```markdown
# Grilling session: <slug>

## Task

<what needs grilling: the ticket(s) or the described chunk of work, with enough context that the griller understands the design space. For a cluster, state each ticket and why they are coupled.>

## Acceptance criteria

<what a successfully grilled design looks like - the decisions that must be resolved before anyone builds.>

## Origin

<STATE THIS EXPLICITLY - it decides what happens after grilling, and the griller cannot infer it:>

- **wayfinder-map** - a map already exists; the handback document is the destination. The griller stops at the handback.
- **firstmate-task** - no map exists yet. After grilling, the griller invokes the `wayfinder` skill to process the grilling result into a map and tickets, written to `agents/projects/<date>-<slug>/` in the product repo.

You also have permission to conclude **"no map needed, this is one small ticket"** if the grilling shows the work is that small. Record that outcome in the handback (see its template).

## Where you work

- Product repo: <name>. Firstmate spawned this pane and it launched in an isolated disposable worktree of firstmate's own clone of the product repo, allocated for this grilling task, distinct from firstmate's primary checkout. Work here; do not reach outside this worktree.
- Grilling skill: use `/grill-with-docs`; it runs the interview and creates the decision records (ADRs) and a glossary as it goes, which fits the reserved ADR number this session already holds. If the origin is firstmate-task, use `/wayfinder` afterwards to produce the map and tickets.
- This is the captain's interview: the captain drives it in this pane by hand. Firstmate created this pane but does NOT supervise it and will not steer, nudge, or interrupt you.

## ADR

- Reserved number: <NNNN>.
- The ADR lives in the product repo's ADR directory (e.g. `docs/adr/<NNNN>-<slug>.md`). Create the file yourself and commit it - firstmate did NOT create a stub.
- **Re-check the number at commit time**: if a human took `<NNNN>` through their own PR meanwhile, pick the next free number, use it, and report the number you actually used in the handback.

## Handback

Write your result to this absolute path (under firstmate's home, NOT the product repo):

    <session_dir>/handback.md

Use the handback template your firstmate gave the session (below). Commit and push every deliverable - the ADR, and (for a firstmate-task origin) the map and tickets - before you fill the handback.

## Prompt back to firstmate

When done, hand your captain this one line to paste into firstmate:

    grilling-handoff intake: slug=<slug> handback=<session_dir>/handback.md
```

Include the handback template (below) inside the brief so the griller writes the exact shape intake expects.

### Handback template

The griller fills this fixed template so intake is unambiguous.
It covers both outcomes cleanly.

```markdown
# Handback: <slug>

## Session

- slug: <slug>
- date: <YYYY-MM-DD>
- origin: <wayfinder-map | firstmate-task>
- branch: <the branch you committed the ADR and any deliverables on>

## ADR

- number: <the number actually used>
- moved: <no | yes, reserved <NNNN> was taken, used <MMMM>>
- file: <path in product repo>
- committed: <commit sha or PR url>

## Outcome

<EXACTLY ONE of the two below.>

### map

- map: agents/projects/<date>-<slug>/ (committed: <sha or PR url>)
- tickets:
  - <ticket title> - blocked by: <other ticket titles, or "none">
  - <ticket title> - blocked by: ...

### single-ticket

- conclusion: no map needed, one small ticket.
- ticket title: <title>
- what to build: <end-to-end behaviour>
- acceptance: <criteria>

## Findings

<the substance the grilling surfaced: decisions locked, risks found, assumptions killed. This is what firstmate relays to the captain.>
```

## The minimal prompt back to firstmate

The griller hands the captain one short line, which the captain pastes into firstmate:

```
grilling-handoff intake: slug=<slug> handback=<absolute handback path>
```

That line carries the session slug and the handback document's absolute path - all intake needs.

## Intake

Given a slug (and usually the handback path from the prompt line above).

1. **Read the handback document** at `data/grilling/<date>-<slug>/handback.md` (resolve the date from the ledger row if only the slug is given).
   If it is absent or does not match the template, tell the captain the session has not produced a usable handback yet and stop.

2. **Relay the findings** to the captain as findings, not as "it finished": the decisions locked, risks found, and the ADR number actually used (note it if it moved from the reserved number).

3. **File the tickets the session produced as real backlog items**, handling both outcomes:
   - **map** - file each listed ticket as a backlog item and record its blocking edges exactly as the handback declares them, so the dependency graph survives.
   - **single-ticket** - file the one ticket as a single backlog item; there are no edges.

4. **Close the tracking item** from the prepare tracking-hold step:

   ```
   tasks-axi resolve grill-<slug>
   ```

   (Use the backend's resolve/close verb per section 10; the point is the captain-gated `grill-<slug>` hold no longer resurfaces.)

5. Mark the ledger row for this slug `landed` in `data/grilling/adr-reservations.md` so the ledger reflects that the session came back.

6. **Release the griller pane firstmate owns.**
   Firstmate spawned this pane, so firstmate cleans it up after a successful intake with the normal teardown path:

   ```
   bin/fm-teardown.sh grill-<slug>
   ```

   Teardown kills the recorded pane, releases its disposable worktree, and clears its runtime record.
   The grilling session directory and handback under `data/grilling/<date>-<slug>/` are the durable record and are NOT touched by this - only the live pane is released.
   The handback is the deliverable and the pane is disposable, so intake steps 1-5 already succeeded before this: even if the captain closed the pane, its runtime record persists until teardown runs (closing the pane does not remove the record), so teardown still finds it, kills the already-dead endpoint harmlessly, and releases the worktree.
   Only if teardown was already run for this slug (its record is genuinely gone) does teardown report no record for the task; that means the pane is already released, so treat it as done rather than a failed intake.
   If teardown refuses because the worktree holds genuinely unlanded work (the griller committed but did not push a deliverable), that is the ordinary unlanded-work guard: report it to the captain rather than forcing, since the intake itself is already complete.

Filing tickets is intake recording the session's produced work into the queue; it is not authorization to build.
Dispatch of that work follows the ordinary lifecycle in section 7 on the captain's word.
