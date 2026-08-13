---
name: backlog
description: Build and LAN-publish an interactive hyfin-dark backlog view of this home's full task queue, with client-side filter/sort and an optional bulk-dispatch button. Use when the captain invokes /backlog or asks to "see the backlog", "publish the backlog", "put the backlog on a page", a backlog view, a task board, or "the queue as a page". Wraps the existing data/build-backlog-html.py builder and data/serve-lavish-lan.sh publisher on the captain's stable backlog port, reads ticket text straight into the page (never into firstmate's context), then polls Lavish in the background per the captain's standing order.
user-invocable: true
metadata:
  internal: true
---

# backlog

Build the backlog view and publish it to the LAN, every time, using the scripts that already own the work.
This skill exists because the pipeline is a builder plus a publisher plus a standing poll convention, and without a skill firstmate forgets the scripts and either dumps the whole backlog into context or hand-rolls a worse page.
Do not reimplement it: `data/build-backlog-html.py` owns the build and `data/serve-lavish-lan.sh` owns the LAN publish.

The backlog view is a self-contained interactive page with client-side filter and sort over every open ticket, plus an optional "dispatch selected" button.
The builder reads the full untruncated ticket text from tasks-axi straight into the HTML file and prints ONLY a one-line count summary, so firstmate publishes the whole backlog without pulling ticket bodies into its own context.

## Standing captain rules (from data/captain.md)

- Build all reports and views in the hyfin **DARK** theme, use Lavish, publish to LAN. Never a light theme.
- Always LAN-published, never public: the publisher NEVER runs `lavish-axi share` / ht-ml.app (standing order 2026-08-02).
- Always build fresh, never a partial edit.
- Always poll Lavish in the **background**, never foreground/blocking.

## Steps

1. **Build the backlog HTML.**
   ```sh
   FM_HOME="$FM_HOME" data/build-backlog-html.py --out .lavish/backlog-afk.html --home "$FM_HOME"
   ```
   It reads `tasks-axi show --full` for every open ticket and writes a self-contained page to `.lavish/backlog-afk.html`.
   It is fast (a few seconds) and prints only a one-line summary such as `backlog html: 40 open items -> ... [ready 27, running 2, need-captain 4, blocked 1, parked 6]`.
   The ticket text never reaches stdout, so this is safe to run without spending context on the backlog.

2. **Publish to the LAN on the backlog port (8898, NOT the desk's 8899).**
   ```sh
   FM_HOME="$FM_HOME" data/serve-lavish-lan.sh .lavish/backlog-afk.html 8898 "$FM_HOME/state/ui-dispatch-queue.tsv"
   ```
   Port 8898 keeps the backlog view from fighting the desk's 8899, so both can be served at once.
   The third argument wires the page's "dispatch selected" button: a POST from the page appends requested ticket ids to that TSV as a dispatch REQUEST (never a blind auto-spawn).
   It prints the LAN session URL with an end-to-end 200 verification - relay that full URL to the captain.
   Omit the third argument for a read-only view with no dispatch button.

3. **Poll Lavish in the background** (captain standing order - never foreground/blocking):
   ```sh
   lavish-axi poll .lavish/backlog-afk.html
   ```
   Arm this as a background task with a wake callback, like the watcher arm.
   Never run it in the foreground and never nohup-detach it.

4. **Report to the captain** in plain outcomes: the full backlog-view URL, the open-item count summary, and that it is live on the LAN.

## Bulk-dispatch requests from the page

When the captain uses the page's "dispatch selected" button, the requests land in `state/ui-dispatch-queue.tsv`.
Drain them with:
```sh
FM_HOME="$FM_HOME" data/ui-dispatch-drain.sh
```
It prints the pending ticket ids and clears the queue.
A UI dispatch request is a REQUEST, not a blind spawn: dispatch each one through the normal task lifecycle with a proper brief and the usual money-path and duplicate-dispatch safety gates.

## Notes

- Resolve `FM_HOME` to this home explicitly so the builder and publisher read the same home.
- This is read-only over the backlog; building or publishing the view never mutates task state, tears down, or merges.
- The backlog view and the captain desk (`/desk`) are separate artifacts on separate ports (8898 vs 8899); serving one never disturbs the other.
