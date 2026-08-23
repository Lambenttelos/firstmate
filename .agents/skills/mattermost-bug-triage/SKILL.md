---
name: mattermost-bug-triage
description: >-
  Agent-only pipeline for turning a batch of chat-thread bug reports into landed fixes without spending firstmate's context on raw thread content.
  Load when the captain drops one or more Mattermost permalinks to bug threads and wants them worked, or hands over any batch of bug reports that live as chat threads rather than as written tickets.
  Do not load for an ordinary bug report the captain describes directly, for a single already-written ticket or issue, or for diagnosing a bug already in a task.
user-invocable: false
metadata:
  internal: true
---

# Chat-thread bug triage pipeline

This skill owns the three-stage pipeline that converts chat-thread bug reports into committed end-to-end specs and, where a bug still reproduces, into landed fixes.
It does not restate the task lifecycle: dispatch, briefs, supervision, delivery paths, and merge authority stay owned by `AGENTS.md` sections 7, 8, and 11.

## Hard rules

- **Firstmate never reads the threads itself.**
  Raw chat content is high-volume and low-density, so it belongs in a dedicated intake worker's context.
  Firstmate reads only the per-bug briefs that worker writes.
- **An end-to-end spec is written and committed for every bug, whether or not it reproduces.**
  A bug that no longer reproduces still yields a passing spec that pins the correct behavior against regression.
  There is no "nothing to do" outcome.
- **Reproduction is driven live through the project's end-to-end runner CLI, then persisted as a spec file in that project's suite.**
  The same spec doubles as the fixer's test-first specification and as a free regression test, so a live browser-inspection tool is not a substitute for it.
- **A worker crossing this home's context threshold is handed off to a fresh agent, never compacted.**
  Have it write a continuation document covering durable state, branch and last commit, the outstanding step with its exact verification commands, and known traps, then respawn a fresh worker on that document.
- **Specs seed their own data.**
  Identifiers a reporter supplied may be used to understand and reproduce the bug, but the committed spec must not depend on them.
- **Always reproduce against the latest state of the project's integration branch, never an older branch or a reporter's stale build.**
  Do not check out, pull, or build another branch to make a bug appear.
  If the bug does not reproduce on the latest integration branch, treat it as already fixed: stop there, do not investigate further, and tell the captain so they can close the thread.
  The captain owns all reporter communication; never ask a reporter to pull or rebuild.
- **When a bug's work lands, give the captain that bug's thread link** so they can resolve the thread too.
  Record the link durably on the work item so it survives cleanup.

## Stages

### 1. Intake - one scout worker for all threads

Spawn a single scout worker on the affected repository.
It reads every thread with `mcp__mattermost__get_thread` (the identifier after `/pl/` in a permalink is the post id) and retrieves attachments with `mcp__mattermost__get_file`.

It writes one file per distinct bug under its own task directory, each containing title, repository, reporter reference plus thread permalink, surface and flow, numbered end-user reproduction steps, concrete data (values, toggles, identifiers, environment), expected versus actual behavior, any diagnosis already present in the thread, and open questions.
It also writes an index roll-up listing each bug's slug, title, repository, surface, and a severity read.

It merges duplicate threads and splits a thread that carries more than one bug.
It never reproduces, diagnoses, or touches product code.
It writes each bug file immediately after reading that thread so raw thread content never accumulates in its context.

### 2. Reproduction - one worker per bug

Dispatch from the intake index, respecting this home's live worker cap and dispatch ladder.
Each reproduction worker:

1. Drives the flow live through the end-to-end runner CLI against the local stack, following the bug file's steps.
2. Persists that flow as a spec file in the project's end-to-end suite, seeding its own data.
3. Commits the spec on its own branch regardless of the outcome.
   Reproduced means the spec is a failing regression test capturing the bug; report it with the spec path and the observed versus expected values.
   Not reproduced on the latest integration branch means the bug is already fixed; report it with the spec path and the evidence, then stop without digging for why it once failed, trying an older branch, or chasing the reporter's environment.
4. Never fixes product code.

Reproduction workers for disjoint bugs may run in parallel.

### 3. Fix - one fresh worker per still-reproducing bug

Only bugs that stage 2 reproduced reach this stage.
A fresh worker takes the failing spec as its test-first specification, fixes the product code, turns the spec green, and delivers through the project's selected delivery path.
Fixers touching disjoint files may run in parallel.
A bug that did not reproduce skips this stage entirely; its passing spec still lands.

## Landing

Batch the resulting green branches into a single merge worker per repository rather than one per branch.
For an owned GitHub tooling fork, `bin/fm-merge-queue.sh dispatch` automates that batch (see `docs/merge-queue.md`); a product repo is never auto-merged there, so a Mattermost bug fix on hyfin or hyfin-server still lands through the captain's own merge.
Merge authority is unchanged: `AGENTS.md` section 7 still governs it.
Relay each landed bug's thread link to the captain as described in the hard rules.
