---
name: desk
description: Build and LAN-publish the captain's live fleet desk, a single reloadable hyfin-dark page rendering this home's current fleet state in the captain's own vocabulary. Use when the captain invokes /desk or asks for "the desk", "my desk", "refresh the desk", a status desk, a dashboard, or "put the fleet status on a page". Wraps the existing bin/fm-desk-refresh.sh builder and data/serve-desk.sh LAN publisher so the desk is always built to spec and served on the captain's stable bookmark port, then polls Lavish in the background per the captain's standing order.
user-invocable: true
metadata:
  internal: true
---

# desk

Build the captain's desk and publish it to the LAN, every time, using the scripts that already own the work.
This skill exists because the desk pipeline is two scripts plus a standing poll convention, and without a skill firstmate forgets to use them and hand-rolls a worse page.
Do not reimplement the desk: `bin/fm-desk-refresh.sh` owns the build and `data/serve-desk.sh` owns the LAN publish.

The desk is a single reloadable page rendering this home's current fleet state in the captain's own vocabulary (`data/captain-desk-spec.md` owns the structure).
It is read-only over fleet state, never wakes anyone, and is built fresh on request - never partially edited.

## Standing captain rules (from data/captain.md)

- Always the hyfin front-end **DARK** theme (`bin/fm-desk-refresh.sh` already renders it: #eb760f accent, dark surfaces, Inter). Never a light theme.
- Always LAN-published, never public: the publisher NEVER runs `lavish-axi share` / ht-ml.app (standing order 2026-08-02).
- Always build fresh, never a partial edit.
- Always poll Lavish in the **background**, never foreground/blocking.

## Steps

1. **Build the desk.**
   ```sh
   FM_HOME="$FM_HOME" bin/fm-desk-refresh.sh
   ```
   It renders the spec-shaped hyfin-dark page to the stable path `.lavish/captain-desk.html` (the SAME file every refresh, so an already-open browser tab only needs a reload).
   It is slow by design (~2 minutes): the fleet-projection source (`fm-bearings-snapshot.sh`, which reads live current-state for every agent) is the one source that takes real time, and it self-degrades any source that exceeds its internal 120s bound rather than failing the page.
   Run it as a background task and wait for exit 0 rather than blocking a foreground turn.
   `bin/fm-desk-refresh.sh --path` prints the output path without building.

2. **Publish to the LAN.**
   ```sh
   FM_HOME="$FM_HOME" data/serve-desk.sh
   ```
   Defaults to the captain's stable bookmark port 8899, so the captain's existing bookmark stays valid.
   It stops any stale Lavish server, restarts it with the correct LAN allowlist, bridges the LAN port, and verifies an end-to-end 200.
   It prints `desk_url: http://<lan-ip>:8899/session/<id>` with `verify_http: 200` - relay that full URL to the captain.

3. **Poll Lavish in the background** (captain standing order - never foreground/blocking):
   ```sh
   lavish-axi poll .lavish/captain-desk.html
   ```
   Arm this as a background task with a wake callback, exactly like the watcher arm.
   Never run it in the foreground and never nohup-detach it.

4. **Report to the captain** in plain outcomes: the full desk URL and that it is live on the LAN.

## Notes

- Resolve `FM_HOME` to this home explicitly so every child source reads the same home the desk resolved (`bin/fm-desk-refresh.sh` exports it to its children, but pass it in so the build itself resolves the right home).
- The desk is deliberately not on any schedule and not wired into the watcher; it is built when the captain asks.
- If a source was unavailable, the page still renders with that section marked as a gap - report the gap, do not fail the desk.
- To serve a second Lavish artifact (e.g. the backlog view) alongside the desk, use a DIFFERENT port so the two LAN forwards do not fight over 8899 (the `/backlog` skill uses 8898).
