---
name: end-session
description: Close a firstmate session down cleanly in one pass - file durable knowledge, stand every live worker down safely, record the session, then offer a session report. Use when the captain invokes /endsession or says they are done for the session (e.g. "end the session", "close the session down", "shut the fleet down for the day"). Not for going away temporarily (that is /afk) and not for a knowledge sweep alone (that is /stow).
user-invocable: true
metadata:
  internal: true
---

# end-session

Close this session down so nothing durable is lost and nothing unsafe is destroyed.
A session that simply stops leaves knowledge only in conversation, workers holding memory with no supervisor, and no record that the session happened at all.
This skill removes all three in a fixed order.

## Why the order is fixed

Run the steps in exactly this order; each one exists because of the step after it.

1. **Stow first.**
   Standing workers down destroys their worktrees and volatile state, and closing the session destroys the conversation.
   Anything learned but not yet written to disk is only recoverable while both still exist, so the knowledge sweep must finish before anything is torn down.
2. **Stand down second.**
   Only after knowledge is on disk is it safe to release workers.
3. **Record third.**
   The record has to state what actually happened, including which workers refused to stand down, so it is written after the stand-down, not before.
4. **Ask last.**
   The report is a courtesy, not part of closing the session, and it costs tokens the captain may not want spent.
   The session must already be closed and recorded whether the captain says yes or no.

## Procedure

### 1. Stow

Load the `stow` skill and run its full sweep.
Do not reimplement or abbreviate it: it owns the knowledge-routing and inspect-then-update rules.
If stow reports something it could not capture yet, tell the captain and ask whether to close down anyway before continuing.

### 2. Stand the fleet down

Run `bin/fm-end-session.sh standdown --model <model name> --effort <effort level>`, supplying this session's own model and effort - they are not discoverable from durable state, and the script records `unrecorded` if you omit them.

The script tears each worker down through the ordinary cleanup path and never forces anything.
Two results matter to you:

- **A refusal is a stop-and-report result.** It means that worker still holds work that is neither pushed nor landed. Never re-run it with `--force`, never stash, commit, or discard on the worker's behalf, and never work around it to make the command "succeed". Relay the refusal to the captain by worker name with what is holding it, and leave that worker running.
- **Registered secondmates are left running on purpose.** They are persistent, and retiring one is a separate captain decision (`secondmate-provisioning`). Say they are still up rather than reporting them as a failure.

### 3. Confirm the record

The same command appends one line of session history to `data/session-stats.log`.
It is append-only: never rewrite, prune, or reorder it.

### 4. Ask about the report

Ask the captain plainly whether they want a session report, in one line, and stop there.
If they decline, the session is closed - stats are already written, and there is nothing further to do.
If they accept, run `bin/fm-end-session.sh report` and relay it.

The report answers one question: was this session worth what it cost, and how much of it ran unattended.
That is why time in away mode, the model name, and the effort level are all required - together they say how expensive each turn was and how much of the session the captain was not watching.
Add the concrete outcomes of the session (work landed, PRs opened, findings delivered) on top of the recorded numbers.

**Be honest about away-mode time.**
Only an away stretch still open at close is durably recorded (`state/.afk` holds the epoch second away mode was entered).
A stretch that already ended leaves no duration behind, so the report says it is not recorded.
Never estimate or reconstruct a number to fill the field.
Making cumulative away time recoverable would require away-mode entry and exit to append a durable stretch ledger; propose that as work rather than papering over the gap.

## Captain-facing wording

Report the outcome, not the mechanics (`AGENTS.md` section 9).
Say "cleaned up", "still running", "work not yet saved anywhere but its own copy" - not teardown, worktree, meta, or refusal codes.
