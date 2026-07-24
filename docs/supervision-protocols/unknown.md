Mode: Unknown harness fallback.

This primary harness does not have a verified watcher wake adapter.
Follow the generic supervision contract in `AGENTS.md`.
First cycle: drain queued wakes, then choose a supervision wait that the harness can actually wake from.
Ordinary wake: drain and handle the wake, then repeat that verified wait while supervision is still required.
Use `bin/fm-watch-arm.sh` only when the harness has a tracked background mechanism that survives the tool call and notifies the model on process exit.
Use a bounded foreground wait over `bin/fm-watch.sh` when that wake mechanism is not verified.
Benign tick close (only with `FM_WATCH_ABSORB_TICK=1`, off by default): a `tick:` reason line is proof of life for an absorbed wake, not an actionable wake and not a failure; reply with the single literal word `tick`, resume the same verified wait, and never run watcher repair (see [`watcher-continuity.md`](../watcher-continuity.md)).
Never use shell `&` for watcher supervision.
Failure or missing cycle only: inspect the failure and restore the same verified wait shape.

Record new verification evidence before promoting an unknown harness to a named snippet.
