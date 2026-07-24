Mode: Claude background-notify supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`, or with `bin/fm-wake-brief.sh` to get that same drain plus each woken task's status tail, current state, metadata, one host reading, and an endpoint sweep in one call.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. First cycle: run `bin/fm-watch-arm.sh` as its own Claude Code background task.
4. Never bundle the arm command with other commands.
5. Never use shell `&` for watcher supervision.
   A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.claude/settings.json`.
6. Treat `watcher: started ...` and `watcher: attached ...` as proof that one live cycle exists.
   On attach, the background task follows verified identity-matched successors instead of exiting when the first cycle ends.
7. Failure or missing cycle only: treat any `watcher: FAILED ...` result as an alarm and repair it before ending the turn.
8. Ordinary wake: when the background task completes with `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, then start exactly one fresh background task before running other fleet commands to handle the wake.
   Do not invent a wake from an attach-status line alone; drain and act only on real wake records or a real watcher reason line.
9. Benign tick close (only on a home with `FM_WATCH_ABSORB_TICK=1`, off by default): when the background task completes with a `tick:` line, that is proof of life for an absorbed wake, not an actionable wake and not a failure; reply with the single literal word `tick`, re-arm one fresh background task, and never run watcher repair.
   See [`watcher-continuity.md`](../watcher-continuity.md) for the mechanism.
10. The continuity PreToolUse gate allows wake drain, watcher arm recovery, and fail-closed teardown, and refuses only other `bin/fm-*.sh` fleet commands while tasks are in flight and no identity-matched live watcher holds the home lock.
11. The existing turn-end guard remains unchanged as the final backstop and is not replaced by this command gate.
12. Recovery only: if a forced restart is genuinely needed, run `bin/fm-watch-arm.sh --restart` through the same Claude background task mechanism.
13. Do not send idle progress while the watcher is parked.

Claude Code's background task completion is the wake mechanism.
The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` is only the verified background arm wrapper.
Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.
