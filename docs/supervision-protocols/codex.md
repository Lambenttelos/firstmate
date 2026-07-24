Mode: Codex foreground checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`, or with `bin/fm-wake-brief.sh` to get that same drain plus each woken task's status tail, current state, metadata, one host reading, and an endpoint sweep in one call.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. First cycle: run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.
4. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint.
5. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued user message now visible to Codex, then start the next checkpoint.
6. Benign tick close (only with `FM_WATCH_ABSORB_TICK=1`, off by default): if the command prints a `tick:` line, that is proof of life for an absorbed wake, not an actionable wake and not a failure; reply with the single literal word `tick`, start the next checkpoint, and never run watcher repair.
   See [`watcher-continuity.md`](../watcher-continuity.md) for the mechanism.
7. Never use shell `&` or Codex background tasks for firstmate watcher supervision.
8. Do not run `bin/fm-watch-arm.sh` as Codex's normal supervision command.
   If it is ever shelled anyway, a backgrounded, piped, or bundled anti-pattern is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.codex/hooks.json`.
9. Failure or missing cycle only: drain queued wakes, inspect the failure, then start a fresh foreground checkpoint.

Codex cannot reason while a foreground tool call is running.
The bounded checkpoint returns control regularly so user messages and queued wakes can be handled without relying on background-task wake semantics.
