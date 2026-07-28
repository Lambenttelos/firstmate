# Cut over the remaining clones, records, and scheduled work

Type: `wayfinder:task`. Status: open. Blocked by: Prove one full pipeline run green on the server and review it from the phone.

## Question

What is the checklist for moving everything that is left, and what confirms nothing was stranded?

## Context

Remaining are the other clones, the backlog, `data/`, `state/`, the scheduled self-wake jobs, X mode artefacts if enabled, and the away-mode daemon.
The same standing rules apply: nothing unlanded migrates, and pools are rebuilt rather than copied.
Once this completes the laptop holds no fleet, only a terminal and the cold rebuild path.

## Resolved when

The laptop has no live fleet work, every registered project is usable on the server, the scheduled jobs run there, and a written list records what was deliberately left behind.
