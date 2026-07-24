Mode: OpenCode TUI plugin background wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. First cycle: let `.opencode/plugins/fm-primary-watch-arm.js` arm supervision after the OpenCode session goes idle.
3. The plugin listens for `session.idle`, spawns `bin/fm-watch-arm.sh --restart` without awaiting it in the idle handler, and owns every later successor launch.
4. After an actionable child close, the plugin rechecks session-lock ownership and verifies one singleton successor before it calls `client.session.promptAsync`; its bounded fallback is defined in `docs/watcher-continuity.md`.
5. Ordinary wake: do not ask the model to re-arm because continuity is plugin-owned.
6. Benign tick close (only with `FM_WATCH_ABSORB_TICK=1`, off by default): a delivered `tick:` line is proof of life for an absorbed wake, not an actionable wake and not a failure; reply with the single literal word `tick`, leave continuity to the plugin, and never run watcher repair.
   See [`watcher-continuity.md`](../watcher-continuity.md) for the mechanism.
7. An unexpected child close enters bounded exponential retry, and an exhausted retry or lost session lock is surfaced as a watcher failure instead of disappearing.
8. Failure or missing cycle only: if the plugin reports a watcher failure, drain queued wakes, inspect the failure text, and use `bin/fm-watch-arm.sh` manually only as a short recovery probe.
9. Never use shell `&` for watcher supervision.
   The arm mechanism above is plugin-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`.opencode/plugins/fm-primary-pretool-check.js`, `bin/fm-arm-pretool-check.sh`).
10. Do not rely on this plugin in headless `opencode run`; firstmate primary supervision targets persistent OpenCode TUI sessions.

OpenCode's persistent TUI plugin runtime is the wake mechanism.
The plugin applies in the main primary checkout and a secondmate's own home, and stays silent only in child crewmate and scout worktrees.

Continuity verification on 2026-07-17 used OpenCode 1.17.18 in a dedicated tmux socket with an isolated project and `FM_HOME` while retaining the existing managed authentication.
An actionable child close was followed by a ledger-linked successor before prompt handling, the model issued no watcher-arm command, and the turn-end guard did not fire.
Command: `FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh`.
Observed output: `ok - OpenCode 1.17.18 live E2E auto-started one successor before prompt handling without a model re-arm`.
