---
name: overnight-queue-prep
description: Prepare a clean, reality-checked overnight work queue before the captain switches to away mode, so the fleet works productively unattended. Use when the captain wants to line up overnight or unattended work, "prep the overnight queue", "queue up work for tonight", "find and unblock tickets so you can work while I'm away", or asks to get the backlog ready before going afk. It reconciles the backlog against reality first, finds and unblocks genuinely-ready work, categorizes and right-sizes a non-conflicting batch to the host, and stages it. It does NOT enter away mode itself (that is /afk) and never merges, tears down, or unblocks captain-gated decisions on its own.
user-invocable: true
metadata:
  internal: true
---

# overnight-queue-prep

Prepare a clean, reality-checked queue of work the fleet can run unattended overnight, then hand off to `/afk`.
The point is that a walk-away stretch is only as productive as the queue it starts with: stale tickets waste worker turns, conflicting work collides, and captain-gated items stall with nobody to decide.
This skill produces a batch that is real, non-conflicting, sized to the host, and dispatchable without a captain in the loop.

This skill does NOT enter away mode. That is `/afk`, run separately once the queue is staged.
This skill never merges a PR, tears down unlanded work, deletes a branch, or unblocks a captain-gated decision on its own. Those keep their normal authority.

## Why the ordering matters

Run the phases in order. The single biggest failure mode is queuing work that is already done, because the backlog drifts from reality every session (work lands via autoland but no ticket flips to done; decision holds outlive their decision when the fix ships under a different name; scout reports go stale; umbrella/placeholder tickets never close). So reconcile BEFORE you select, or the overnight fleet burns hours re-doing landed work.

## Phase 1 - Reconcile the backlog against reality (do this first)

Never trust ticket prose. Check each candidate against the actual current state of dev and existing reports.

1. Enumerate the backlog: `tasks-axi list --state queued` and `tasks-axi list --state held`.
2. For a small backlog, reconcile inline. For a large one (dozens of tickets), dispatch a READ-ONLY reconciliation scout rather than burning firstmate context: brief it to read every ticket, check product work against `origin/dev` (fetch first, grep the log and inspect the actual code/docs/ADR/test for the distinctive symbol), check tooling work against the fork's merged PRs, check scouts for an existing covering report, and emit a per-ticket verdict report (DONE-close / STALE-close / KEEP-dispatchable / KEEP-blocked / KEEP-captain-gated) with concrete evidence for every close verdict. Bias to KEEP under uncertainty: a false DONE loses real work, a false KEEP just stays queued.
3. Review the verdicts and apply the closes yourself with `tasks-axi done <id>` (never let the scout mutate state). Do not blind-close; a close needs cited evidence (a commit, a PR, a covering report path).

This is also where the recurring drift gets surfaced to the captain as a root-cause, not just cleaned up once.

## Phase 2 - Find and unblock genuinely-ready work

1. `tasks-axi ready` lists what is dispatchable now (dependencies and time gates clear).
2. Inspect held tickets' hold reasons (`tasks-axi show <id>`). Release ONLY holds whose reason is a soft queue-management defer that overnight headroom satisfies (e.g. "dispatch when cap headroom + higher-priority work drained"). 
3. Leave held, and never auto-release: captain-gated decisions (`kind=captain`), placeholder/stub guards, anything needing supervised git surgery, anything needing a host/credential/login the fleet does not have, and anything the captain parked. Unblocking any of these overnight is out of scope.

## Phase 3 - Categorize and right-size the batch

Select a batch that can run unattended without a captain decision and without colliding.

- **Autonomous-safe overnight:** scouts (read-only, produce a report), narrowly-scoped single-file ships, doc/cleanup tasks, and ships on repos we own with autoland. These never need a mid-run decision.
- **Exclude:** anything whose definition of done includes a captain approval, a needs-decision finding likely mid-run, or a destructive/irreversible/security-sensitive step.
- **Serialize collision-prone work:** multiple ships touching the same repo subsystem, and especially multiple firstmate-repo ships touching shared tracked material (`bin/`, `AGENTS.md`, skills) - run those one at a time so they do not clobber each other. Independent scouts and product ships on different repos run in parallel.
- **Right-size to the host:** read `bin/fm-resource-check.sh` for the current recommended ceiling of active agents and let the host reading plus supervision judgment set the parallelism, not a fixed number. Confirm the worker count with the captain.

## Phase 4 - Confirm, then stage

1. Present the proposed batch to the captain: the tickets, why each is overnight-safe, the parallel-vs-serial plan, and the worker count. Get explicit confirmation of the count and any held-ticket releases before staging.
2. Ensure each selected ticket is queued and dispatchable (dependencies recorded, blockers cleared). Record serialization intent as durable dependencies (`tasks-axi block <later> --by <earlier>`) so the overnight driver honors it rather than relying on live judgment that will not be present.
3. Do NOT spawn the whole batch here unless the captain wants work started now. The normal dispatch-and-supervise lifecycle (and, once away, the away-mode driver) pulls ready work as slots free. Staging means the queue is correct and ordered, so unattended dispatch does the right thing.

## Phase 5 - Hand off to away mode

Tell the captain the queue is staged and summarize it (count of overnight-safe tickets, parallel/serial shape, worker ceiling). Then stop.
Entering away mode is a separate, explicit step: load `/afk` only when the captain gives the away instruction.
Away mode never expands approval authority, so a captain-gated item that surfaces overnight still waits for the captain - staging correctly in Phase 3 is what keeps the fleet busy instead of stalled.

## Guardrails

- Read-mostly on project state: this skill reads clones and reports, and never writes to a project worktree.
- The only state it mutates is the firstmate backlog (closing verified-done tickets, releasing soft-deferred holds, recording serialization dependencies) and only after captain-confirmed selection.
- Every DONE/STALE close needs cited evidence. No evidence means keep it queued.
- Worker count and any held-ticket release are captain-confirmed, not assumed.
