Mode: jcode foreground checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`, or with `bin/fm-wake-brief.sh` to get that same drain plus each woken task's status tail, current state, metadata, one host reading, and an endpoint sweep in one call.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. First cycle: run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.
4. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint.
5. If the command prints `checkpoint:` or exits 124 with no wake, drain queued wakes anyway, process any queued user message now visible to jcode, then start the next checkpoint.
6. Benign tick close (only with `FM_WATCH_ABSORB_TICK=1`, off by default): if the command prints a `tick:` line, that is proof of life for an absorbed wake, not an actionable wake and not a failure; reply with the single literal word `tick`, start the next checkpoint, and never run watcher repair.
   See [`watcher-continuity.md`](../watcher-continuity.md) for the mechanism.
7. Never run `bin/fm-watch-arm.sh` as jcode's normal supervision command, and never use a plain jcode `Bash run_in_background` task to hold the watcher.
   A jcode background task is passive-notify (`notify: true`, `wake: false`): it does not wake an idle model on process exit, so it cannot be trusted to re-drive supervision after the turn ends.
8. Failure or missing cycle only: drain queued wakes, inspect the failure, then start a fresh foreground checkpoint.

jcode's default background task posts a passive notification and does not wake the model on exit, so background-task completion is not a reliable watcher wake.
The bounded foreground checkpoint returns control regularly, so user messages and queued wakes are handled without relying on background-completion wake semantics.
See [`../jcode-primary-supervision.md`](../jcode-primary-supervision.md) for the verification record (jcode server 0.64.2, 2026-08-03).
