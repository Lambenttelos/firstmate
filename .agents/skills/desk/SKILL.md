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

0. **Write the judgment file (the analysis layer for sections 1, 2, 11, and 12).**
   Before building, publish one small bounded synthesis pass to `state/desk-judgment.json` so the builder can enrich four sections a read-only script cannot synthesize.
   Write it atomically (a temp file in `state/` then `mv`) so the builder never reads a half-written file.
   The **header of `bin/fm-desk-refresh.sh` (the `JUDGMENT LAYER` block) is the single owner of this file's schema and behavior** - read it and follow it; do not restate it here.
   In short:
   - `schema` must be `1` and `written_at` a fresh unix epoch; the builder only reads a file written within the last 900 seconds, so write it immediately before step 1.
   - `decisions` and `blockers` ENRICH the script's own cards BY TASK `id` (the script still decides which items appear); `questions` and `transcript` are the FALLBACK source for sections 11 and 12, used when the durable transcript feed (step 0b) is empty.
   - Synthesize from context this session already holds (recent captain/firstmate turns, the open decisions and live blockers, recent questions) - no new reads.
   - Everything you write must already be in the captain's vocabulary; the builder still escapes and translates defensively.
   If you skip this step the desk still renders correctly: every section degrades to its mechanical or gap form, and the page shows a "no fresh analysis" stamp. The judgment layer only ever ADDS.

0b. **Publish recent turns to the durable transcript feed (sections 11 and 12).**
   Alongside the judgment write, append this session's recent captain-facing turns and recent questions to the durable feed with `bin/fm-desk-transcript.sh`.
   This feed is the PRIMARY source for sections 11 and 12; the judgment file's `questions`/`transcript` arrays are only the fallback when the feed is empty.
   `bin/fm-desk-transcript.sh` is the single owner and only writer of the feed - read its `--help` for the record shape and the bound; do not restate them here.
   In short:
   - A captain-facing turn: `bin/fm-desk-transcript.sh turn captain "<turn text>"` or `... turn firstmate "<turn text>"`; add `--unread` on a turn the captain has not read yet (it carries the orange rail in section 12).
   - A question and its short answer: `bin/fm-desk-transcript.sh question "<question firstmate asked>" "<captain's short answer, or omit for none>"`.
   - Append only a bounded set of recent turns from context this session already holds (a few dozen at most); the feed self-caps and trims the oldest, so this stays cheap.
   - This is a build-time write only, exactly like the judgment file: do NOT create a standing background writer or a new supervised process (the desk's "no standing agent" decision stands).
   If you skip this step the desk still renders: sections 11 and 12 fall back to the judgment file, and then to the gap note.

1. **Build the desk.**
   ```sh
   FM_HOME="$FM_HOME" bin/fm-desk-refresh.sh
   ```
   It renders the spec-shaped hyfin-dark page to the stable path `.lavish/captain-desk.html` (the SAME file every refresh, so an already-open browser tab only needs a reload).
   It is slow by design (~2 minutes): the fleet-projection source (`fm-bearings-snapshot.sh`, which reads live current-state for every agent) is the one source that takes real time, and it self-degrades any source that exceeds its internal 120s bound rather than failing the page.
   Run it as a background task and wait for exit 0 rather than blocking a foreground turn.
   `bin/fm-desk-refresh.sh --path` prints the output path without building.
   The page's Captain's Call panel renders the projection's `decisions_open` in blocking-first order plus the merge-queue count, so the desk and the `/bearings` dated report lead with the same calls.

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

- The desk and the `/bearings` dated report draw every fleet fact from the SAME `fm-bearings-snapshot.sh` projection; the builder header is the single owner of that source contract. There is no second gather path, so the two surfaces cannot disagree.
- The `/bearings` skill refreshes and republishes the desk after it writes its dated report, so the page is current even on days the captain only asked for /bearings. This skill builds the same page on a direct `/desk` request.
- Resolve `FM_HOME` to this home explicitly so every child source reads the same home the desk resolved (`bin/fm-desk-refresh.sh` exports it to its children, but pass it in so the build itself resolves the right home).
- The desk is deliberately not on any schedule and never wired into the watcher as a poll. It is built fresh when the captain asks. Separately, once a desk exists, `bin/fm-desk-event.sh` rebuilds that same file in place on a task-lifecycle event (spawn, done, PR recorded, teardown) so an already-open page stays current without the captain re-running `/desk`; that trigger owns the mechanism and is a no-op when no desk has been built. It only ever rebuilds the file, never re-serves.
- If a source was unavailable, the page still renders with that section marked as a gap - report the gap, do not fail the desk.
- To serve a second Lavish artifact (e.g. the backlog view) alongside the desk, use a DIFFERENT port so the two LAN forwards do not fight over 8899 (the `/backlog` skill uses 8898).
