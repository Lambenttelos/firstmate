---
name: end-session
description: Close a firstmate session down cleanly in one pass - file durable knowledge, record the session, then offer a session report, leaving every live worker running unless the captain explicitly asks to stand the fleet down. Use when the captain invokes /endsession or says they are done for the session (e.g. "end the session", "close the session down", "shut the fleet down for the day"). Not for going away temporarily (that is /afk) and not for a knowledge sweep alone (that is /stow).
user-invocable: true
metadata:
  internal: true
---

# end-session

Close this session down so nothing durable is lost and nothing unsafe is destroyed.
A session that simply stops leaves knowledge only in conversation and no record that the session happened at all.
This skill removes both, and by default leaves every live worker running so work continues across the session close.

Closing a session is a bookkeeping event, not a teardown.
The captain ends their own supervising session; the fleet's workers keep working.
Standing the fleet down is a separate, destructive action taken only on the captain's explicit word (see "Optional stand-down" below), never as a side effect of `/endsession`.

## Why the order is fixed

Run the steps in exactly this order; each one exists because of the step after it.

1. **Stow first.**
   Closing the session destroys the conversation, and an optional stand-down destroys the standing-down workers' worktrees and volatile state.
   Anything learned but not yet written to disk is only recoverable while the conversation still exists, so the knowledge sweep must finish first.
2. **Record second.**
   The record states what was live at close.
   If the captain also asked to stand the fleet down, that runs before the record so the record can state which workers refused to stand down.
3. **Ask last.**
   The report is a courtesy, not part of closing the session, and it costs tokens the captain may not want spent.
   The session must already be closed and recorded whether the captain says yes or no.

## Procedure

### 1. Stow

Load the `stow` skill and run its full sweep.
Do not reimplement or abbreviate it: it owns the knowledge-routing and inspect-then-update rules.
If stow reports something it could not capture yet, tell the captain and ask whether to close down anyway before continuing.

### 2. Record the session

Run `bin/fm-end-session.sh record --model <model name> --effort <effort level>`, supplying this session's own model and effort - they are not discoverable from durable state, and the script records `unrecorded` if you omit them.

This tears nothing down.
It counts what is live, appends one line of session history, and reports:

- **Workers left running.** Every ordinary worker keeps running across the close. That is intended, not a failure: the captain's supervising session is ending, but the work is not.
- **Registered secondmates left running.** They are persistent, and retiring one is a separate captain decision (`secondmate-provisioning`).

### Optional stand-down (explicit request only)

Only when the captain explicitly asks to stand the fleet down (for example `/endsession --standdown`, "shut the fleet down", "tear everything down for the day"), run `bin/fm-end-session.sh standdown --model <model name> --effort <effort level>` in place of step 2.
It stands every ordinary worker down through the ordinary cleanup path and never forces anything, then appends the same session record.
Two results matter to you:

- **A refusal is a stop-and-report result.** It means that worker still holds work that is neither pushed nor landed. Never re-run it with `--force`, never stash, commit, or discard on the worker's behalf, and never work around it to make the command "succeed". Relay the refusal to the captain by worker name with what is holding it, and leave that worker running.
- **Registered secondmates are left running on purpose** even under a stand-down. They are persistent, and retiring one is a separate captain decision (`secondmate-provisioning`). Say they are still up rather than reporting them as a failure.

### 3. Confirm the record

The `record` or `standdown` command appends one line of session history to `data/session-stats.log`.
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
