---
name: afk-review
description: >-
  Agent-only procedure for firstmate's standing two-hourly away-mode review round.
  Load only when a scheduled self-wake asks firstmate to run the next independent review-and-improve pass over away mode (`/afk`), and on nothing else.
  It is not a way to review away mode on request, not a response to an away-mode bug report, and not part of ordinary `/afk` entry, exit, or supervision.
user-invocable: false
metadata:
  internal: true
---

# afk-review

This skill owns one standing project: an ongoing, independent review-and-improve pass over firstmate's away-mode feature, dispatched on a two-hourly schedule.
It replaces the procedure that used to live inline in a session-only scheduled prompt.
The schedule triggers it; this file is the whole procedure.

Away mode is the captain's only notification channel while they are away, so a round is a normal fleet dispatch with an unusually strong "do no harm to the live feature" constraint.
The live daemon, the live outbox, the live reader, and every `state/` file in the primary checkout are off limits to both firstmate and the dispatched worker.

Run the steps in order and stop at the first one that says stop.

## 1. Re-entrancy: never run two rounds at once

Before anything else, check whether a review lane is already live in this home:

```sh
ls "$FM_HOME"/state/improve-afk*.meta 2>/dev/null
```

If any such task exists, do NOT start a second round.
Two concurrent reviewers of the same feature burn a slot twice and produce branches that conflict with each other.
Instead read that lane's current state with `bin/fm-crew-state.sh <id>`, steer it with `bin/fm-send.sh` if it is stuck, escalate it if it is blocked on a captain decision, and stop this round.

## 2. Host-headroom guard: skip rather than queue

Take one reading with `bin/fm-resource-check.sh`.
If the host is degraded or worse AND the active-agent count already meets or exceeds the recommended ceiling in that same reading, skip this round entirely and say so in one line.

Do not queue a round up behind a loaded machine.
This fleet is memory-bound, and a heavy lane waiting on a full host is how it starts thrashing.
A skipped round costs nothing: the next one is two hours away.

## 3. Dispatch profile: size the round to the fleet

Count ACTIVE crewmate lanes in this home from `state/*.meta`, excluding any whose `kind=secondmate`.
Persistent secondmates are supervision capacity, not work capacity, so counting them would make a nearly idle fleet look busy.

- Fewer than 2 active lanes is QUIET: dispatch at model `fable`, effort `medium`.
- Two or more active lanes is NORMAL: dispatch at model `opus`, effort `medium`.

State which branch you took and the count behind it, both in the round-memory record and in anything you report.

## 4. Round memory: tell the new lane what is already settled

The durable record of past rounds is `data/afk-review-rounds.md` in this home.
It lives in `data/` because that is this repo's home for durable private fleet records, it is per-home like away mode itself, and a record kept anywhere in conversation would evaporate at the next session - which is the exact failure this skill exists to end.

Read it before dispatch and append to it after.
One short entry per round: the date, the task id, the profile branch taken and why, what the round landed, what it explicitly rejected, and any open design question.
Create it lazily on the first round; its absence just means no round has run yet.

Feed that record into the brief so the new lane does not re-review settled ground or re-litigate a closed finding.

## 5. Brief and dispatch

Each round gets a fresh task id: `improve-afk-round-<N>`, taking the next N from the round-memory record.

Scaffold with `bin/fm-brief.sh improve-afk-round-<N> firstmate`, then replace `{TASK}` with the round's task text.
Reuse the reasoning shape of the previous round's brief - `data/improve-afk-round-2/brief.md` is the reference copy - which carries what a reviewer of this feature actually needs:

- The promise away mode makes: while the captain is gone, nothing captain-relevant is lost and nothing routine wastes a turn.
- Silent loss is the enemy; bounded delay is acceptable.
- This home is the hard case: the captain's session runs outside tmux permanently, so paneless pull delivery is the primary path and must never be "fixed" by proposing a move into tmux.
- The scope surface: the `/afk` skill, the `bin/fm-afk-*` scripts and libs, `bin/fm-supervise-daemon.sh`, the away-mode uses of the classification and operational-input libs, the away-mode docs, and their colocated tests.
- The hands-off constraint on the live away-mode session in the primary checkout.
- The instruction to load `firstmate-coding-guidelines`, because this is all shared tracked material.
- The prior-round summary from step 4.

Then dispatch with `bin/fm-spawn.sh improve-afk-round-<N> <firstmate-repo-worktree> --model <fable|opus> --effort medium`, using the profile from step 3.

## 6. Delivery: firstmate-repo fast lane

Rounds run on the firstmate-repo fast lane, which the generated brief already states: skip the no-mistakes pipeline, take ONE review gate rather than a review loop, and self-merge into local `main` with `git merge --no-ff` when green.
No PR, no captain wait.
Anything destructive, irreversible, or security-sensitive still stops and escalates.

## 7. Quiet by default

Report to the captain only a captain-relevant finding, a blocked lane, or a skipped round and its one-line reason.
A round that found nothing is not news, and neither is a round that merely started.
Record it in the round memory and stay silent.
