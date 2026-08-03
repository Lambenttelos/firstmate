# jcode primary-harness supervision (verification record)

This document records the empirical verification that promoted jcode out of `bin/fm-supervision-instructions.sh`'s `unknown` fallback and into a named supervision protocol.
It is a backend-verification record: dates, versions, exact commands, and exact output, per the firstmate-coding-guidelines rule.

The verified conclusion is that jcode's primary watcher supervision is the **codex-shaped bounded foreground checkpoint** (`bin/fm-watch-checkpoint.sh`), not a claude/grok-shaped background-notify arm.
jcode background tasks default to a passive notification that does not wake an idle model, so the async `bin/fm-watch-arm.sh` arm-and-wake contract is not satisfied.
The bounded foreground wait is fully verified and reuses the existing codex checkpoint infrastructure with no new supervision code.

## The arm-and-wake contract being tested

`bin/fm-watch-arm.sh` is safe only on a harness with a tracked background mechanism that SURVIVES the tool call and NOTIFIES the model on process exit (its header states this explicitly).
Claude and grok satisfy it: a tracked background task runs `bin/fm-watch-arm.sh`, and background-task completion wakes the model with the watcher's reason line even after the turn ends.
Codex does not: it cannot reason while a foreground tool call runs and does not have a verified background-completion wake, so it uses a bounded foreground checkpoint (`bin/fm-watch-checkpoint.sh`) that returns control regularly.
The question for jcode was which shape it matches.

## Environment

- Date: 2026-08-03.
- jcode version: `v0.64.2-dev (0d5cd9f, dirty)` (from `jcode --version`).
- Running as firstmate's own primary harness inside a jcode session (env markers `JCODE_ACTIVE_PROVIDER`, `JCODE_RUNTIME_PROVIDER`, `JCODE_NON_INTERACTIVE`, `JCODE_SOCKET`, `JCODE_SCRATCH_DIR` present).
- jcode tool surface relevant here: `Bash` with `run_in_background`, and the `bg` tool family (`status`, `wait`, `output`, `tail`, `subscribe`, `delivery`, `watch`).

## Finding 1: a background task survives the tool call and captures its reason line

Command (jcode `Bash` tool, `run_in_background: true`):

```
echo "start-marker $(date -u +%H:%M:%S)"; ( sleep 6; echo "signal: synthetic wake reason line" )
```

jcode acknowledged the launch, assigning `Task ID: 646250xeab`, an output file under `/tmp/jcode-bg-tasks/`, and printing `You will be notified when the task completes.`
A later `bg` `wait` returned the completed record with the full captured output:

```
Status: completed
Exit code: 0
Notify: true
Wake: false
Output preview:
start-marker 14:34:06
signal: synthetic wake reason line
--- Command finished with exit code: 0 ---
```

So a background process does survive the call boundary and its stdout (the synthetic `signal:` reason line) is captured intact.
This is a synthetic stand-in for `bin/fm-watch.sh`, which blocks then prints one reason line and exits.

## Finding 2: background tasks are passive-notify, not wake-on-exit (the decisive negative)

Every background task launched carried `notify: true` and `wake: false` by default.
The persisted status JSON for task `812516ytsk` (a 25-second synthetic watcher) shows the durable fields verbatim:

```json
{
  "task_id": "812516ytsk",
  "status": "completed",
  "exit_code": 0,
  "duration_secs": 25.009451848,
  "owner_pid": 766,
  "detached": false,
  "notify": true,
  "wake": false,
  ...
}
```

`wake: false` means completion posts a passive notification but does not interrupt or wake an idle model.
`detached: false` means the task is tied to the owner session rather than surviving independently.
This is the opposite of the claude/grok background-notify contract, where the tracked background task's completion reliably re-drives the model after the turn ends.
Whether a passive `notify` reliably re-drives an idle jcode model across a completed turn cannot be verified from inside a single turn (the observer cannot end its own turn, idle, and then confirm the wake within the same transcript), and `wake: false` is a real correctness risk.
Per the task's correctness-over-promotion constraint, an unverified async wake must not be claimed.

## Finding 3: `bg wait` is a reliable bounded foreground wait that returns the reason line

The `bg` tool's `wait` action, called on a still-running task, blocks in the foreground until the process exits, then returns its output.
Verified against task `812516ytsk` (a 25-second synthetic watcher): `bg wait` with `max_wait_seconds: 40` was issued about 4 seconds into the run and blocked for ~20 seconds of real wall time until the task exited, then returned:

```
Background task finished.
Status: completed
Exit code: 0
Duration: 25.01s
Output preview:
wait-test-start 14:36:52
signal: wait-test reason line
--- Command finished with exit code: 0 ---
```

The `[tool timing]` on that call recorded `duration=20s`, confirming the foreground block was real, not an immediate return.
This is exactly the codex bounded-foreground-checkpoint shape: the model holds a foreground wait that returns control on the watcher's actionable wake (or a bound).

## Finding 4: `bin/fm-watch-checkpoint.sh` runs unchanged on jcode

The existing codex checkpoint wrapper was run in a throwaway `FM_HOME`, never touching real supervision:

```
FM_HOME="$JCODE_SCRATCH_DIR/fmjc-checkpoint-verify-<pid>" \
  bin/fm-watch-checkpoint.sh --seconds 4
```

Exact output:

```
checkpoint: no actionable wake within 4s
checkpoint exit code: 124
```

The quiet-checkpoint path (`exit 124`, `checkpoint: no actionable wake within <n>s`) works on jcode identically to codex.
The actionable-wake pass-through and the `watcher: already running` guard are shared `bin/fm-watch.sh` behavior already verified for codex; jcode reuses the same wrapper with no jcode-specific code.

A separate check confirmed jcode's foreground `Bash` tool tolerates a long blocking command (a 20-second `sleep` completed inside a 200-second tool timeout), so the codex default `FM_CODEX_WATCH_CHECKPOINT:-180` checkpoint length is safe on jcode.

## Conclusion and consequences

jcode's verified primary watcher protocol is the bounded foreground checkpoint `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`, identical in shape to codex.
The model takes one checkpoint, handles any actionable wake it returns, then takes the next checkpoint while supervision is required.
Do NOT use `bin/fm-watch-arm.sh` as jcode's normal supervision command: a jcode background task is passive-notify (`wake: false`) and does not satisfy the arm-and-wake-on-exit contract.

This closes the "primary harness: unknown" gap: `bin/fm-supervision-instructions.sh` now maps `jcode` to `docs/supervision-protocols/jcode.md` and emits a jcode-specific repair line, so session start on jcode prints `primary harness: jcode`.

### Not yet built for a jcode primary (unchanged, still open)

The turn-end guard and the PreToolUse arm seatbelt for a jcode PRIMARY are still unbuilt, because jcode's `[hooks]` are read by the shared background server, not the spawned client, so a spawn cannot arm them (see the jcode section of the harness-adapters skill).
The bounded foreground checkpoint does not depend on either hook: it returns control on its own bound rather than relying on a background-completion wake, so jcode primary supervision is safe without them.
Building those hooks would need a captain decision about writing the shared jcode server config, and is out of scope for this verification.
