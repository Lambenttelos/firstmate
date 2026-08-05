# jcode primary-harness async wake adapter (verification record)

This document records the empirical verification that jcode DOES expose a reliable model-wakeable primitive across an idle turn, and that firstmate's watcher and away-mode reader arms can therefore use the same asynchronous arm-and-wake-on-completion contract that claude and grok use.
It supersedes the "async wake cannot be verified from inside a single turn" limitation recorded in [`jcode-primary-supervision.md`](jcode-primary-supervision.md), which is why that earlier record fell back to the bounded foreground checkpoint alone.
It is a backend-verification record: dates, versions, exact commands, and exact output, per the firstmate-coding-guidelines rule.

## The gap this closes

`bin/fm-watch-arm.sh` and `bin/fm-afk-inbox-arm.sh` are both armed as "the harness's own tracked background task", and on claude and grok the background task's completion is what re-drives the model after the turn ends.
The earlier jcode record observed only the DEFAULT background-task delivery (`notify: true`, `wake: false`) and concluded that jcode could not satisfy the arm-and-wake-on-exit contract, so it routed jcode to the bounded foreground checkpoint.
The foreground checkpoint is correct for normal supervision (the model holds a foreground wait and never idles), but it does nothing for the away-mode case, where the model's turn genuinely ends and the away-mode inbox reader (`bin/fm-afk-inbox-arm.sh`) is a background task whose completion must wake an otherwise idle session.
A background task that completes with `wake: false` posts a passive notification that never re-drives the idle model, so away-mode escalations were delivered by the reader and then never read.

Live evidence of the bug (2026-08-05): the away-mode inbox reader was armed as a tracked background task at 15:28, delivered its escalations and exited at 15:31 with `wake: false`, and the idle session was never woken. The captain caught this non-wake three or more times.

## Environment

- Date: 2026-08-05.
- jcode version: `v0.64.2-dev (0d5cd9f, dirty)` (from `jcode --version`).
- Running as firstmate's own primary harness inside a jcode session (env markers `JCODE_ACTIVE_PROVIDER`, `JCODE_RUNTIME_PROVIDER`, `JCODE_NON_INTERACTIVE`, `JCODE_SOCKET`, `JCODE_SCRATCH_DIR` present).
- jcode tool surface relevant here: `Bash` with `run_in_background`, and the `bg` tool family (`status`, `wait`, `output`, `tail`, `subscribe`, `delivery`, `watch`).

## Finding 1: `bg` delivery accepts `wake: true` and persists it durably

A background task launched with the default delivery carries `notify: true` and `wake: false`.
Calling the `bg` tool's `subscribe` (or `delivery`) action on that task id with `wake: true` was accepted and flipped the durable delivery, verified on task `8356406dwn`:

```
Updated background task delivery for 8356406dwn.
Status: completed
Notify: true
Wake: true
```

The persisted status JSON records the change durably in the event history:

```json
{
  "task_id": "063457ynbj",
  "status": "completed",
  "notify": true,
  "wake": true,
  "event_history": [
    { "kind": "delivery_updated", "timestamp": "2026-08-05T16:07:46.800965650+00:00", "message": "notify=true, wake=true", "status": "running" },
    { "kind": "completed", "timestamp": "2026-08-05T16:08:23.469222070+00:00", "status": "completed", "exit_code": 0 }
  ]
}
```

The delivery flag can only be set from the model's `bg` tool call: the shell-side `jcode debug` control plane is gated (`Error: Debug control is disabled. Set JCODE_DEBUG_CONTROL=1 ...`), and `Bash` `run_in_background` exposes no wake parameter at launch.
So arming a jcode wake is inherently two model actions: launch the background task, then set `wake: true` on its task id.

## Finding 2: a `wake: true` background task re-drives an idle model across a turn boundary (the decisive positive)

This is the exact test the earlier record said could not be run from inside a single turn. It cannot be run inside ONE turn, but it CAN be run ACROSS turns: arm the wake, end the turn idle, and observe whether the next turn begins spontaneously from the background-task completion rather than from an external steer.

Probe (a background `Bash run_in_background` task, armed with `bg subscribe wake:true`):

```
sleep 40
echo "signal: cross-turn wake probe finished ..."
```

Timeline, task `063457ynbj`:

- 16:07:46Z: armed `wake: true` on the running task.
- 16:08:12Z: the turn ended idle (a `paused:` status line was appended and no tool call was left pending).
- 16:08:23Z: the task completed (`completed_at` in the status JSON), and this session was re-driven into a new turn whose triggering content was exactly the task's completion block, carrying the probe's `signal:` line - not a firstmate steer.

The re-drive content matched the background-completion block byte-for-byte and its timestamp matched `completed_at` precisely, distinguishing it from an unrelated "incomplete todos" nudge that arrived separately about ninety seconds later.

A second probe (`184421o7cs`, 35-second sleep) armed the same way confirmed repeatability: armed `wake: true` at 16:09:48Z, completed at 16:10:19Z, and re-drove the session with its own `signal:` completion block.

## Finding 3: `JCODE_CHECKPOINT` output alone does NOT set wake

A probe that emitted `JCODE_CHECKPOINT {"message":"..."}` on stdout without a paired `bg subscribe wake:true` call completed with `wake: false` (task `3240330ye0`):

```
Progress: checkpoint wake probe - single-call arm test (reported)
Notify: true
Wake: false
Recent events:
- Checkpoint · 2026-08-05T16:12:09Z · checkpoint wake probe - single-call arm test
- Completed · 2026-08-05T16:12:12Z
```

So `JCODE_CHECKPOINT` is a progress/milestone annotation, not a standalone wake primitive. The only verified wake path is an explicit `bg` delivery set to `wake: true`.

## Finding 4: `ScheduleWakeup` create is rejected on this version

The `ScheduleWakeup` tool was tested as an alternative timed-wake primitive. Its `create` path is currently rejected with a schema error, confirming the sibling finding `jcode-schedulewakeup-schema-mismatch`:

```
Error: task is required for action=create
```

`ScheduleWakeup` is therefore not usable as a wake primitive today. The `bg` `wake: true` path is the verified mechanism.

## Finding 5: the real `bin/fm-watch-arm.sh` forks a genuine watcher on jcode

The unmodified `bin/fm-watch-arm.sh` was run in a throwaway `FM_HOME` under the task worktree (never touching real supervision), with fast cadence knobs:

```
FM_HOME=<throwaway> FM_ROOT_OVERRIDE=<repo> FM_STATE_OVERRIDE=<throwaway>/state \
  FM_POLL=2 FM_HEARTBEAT=3 FM_SIGNAL_GRACE=2 FM_ARM_CONFIRM_TIMEOUT=5 \
  timeout 10 bash bin/fm-watch-arm.sh
```

Output:

```
watcher: started pid=11247 (beacon fresh)
arm-exit=124
```

The arm forked and confirmed a live watcher exactly as it does on claude and codex, and the `timeout` killed the arm, whose trap tore the watcher child down with it (verified: pid 11247 gone, no orphan watcher on the throwaway home).
So the async arm reuses the existing watcher and arm infrastructure unchanged; only the harness-side wake wiring differs.

## Conclusion and consequences

jcode DOES have a reliable, model-wakeable primitive across an idle turn: a `Bash run_in_background` task whose delivery is set to `wake: true` via the `bg` tool re-drives the idle model with its completion block when the task exits.
This satisfies the same arm-and-wake-on-completion contract that `bin/fm-watch-arm.sh` and `bin/fm-afk-inbox-arm.sh` are built on, so jcode can use the asynchronous arm like claude and grok, instead of being limited to the bounded foreground checkpoint.

The one jcode-specific requirement is that the wake is a SEPARATE, mandatory step: immediately after launching the arm as a background task, the model must set `wake: true` on that exact task id with the `bg` tool. A forgotten wake set silently reverts to `wake: false` and leaves supervision blind, which is exactly the failure that recurred. The protocol documents this as a single paired action (launch, then arm wake) so the two steps are never separated.

The bounded foreground checkpoint (`bin/fm-watch-checkpoint.sh`) remains a correct zero-dependency fallback for normal, non-idle supervision and for any situation where the two-step async arm is not appropriate.

### Verified bound and what is inferred

The cross-turn wake is verified over the seconds-to-minutes range across a real turn boundary (turn ended, new turn re-driven by completion).
Delivery is owned by the shared jcode background server (`owner_pid` is the server, which persists across turns), not by the ending turn, so a long idle (an hours-long away-mode wait) is expected to deliver the same way; that longer bound is inferred from the server-owned delivery architecture rather than directly timed here.
Per the correctness-over-promotion constraint, the async arm is documented as verified for the cross-turn wake and the away-mode reader shape, with the checkpoint retained as the fallback.
