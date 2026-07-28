# Move firstmate itself and the first clones

Type: `wayfinder:task`. Status: open. Blocked by: Run one task end to end on the server while the fleet stays local; Migrate no-mistakes with its live state.

## Question

What exactly moves in the first migration wave, and what stops new local work from starting once it has?

## Context

This is where the degraded window opens.
Firstmate itself, no-mistakes, and two or three clones move.
Local work already in flight finishes and lands rather than being migrated, and no new local spawns are allowed.
`data/` and `state/` are copied; `.treehouse/` pools and `node_modules` are rebuilt on the server rather than moved.

## Resolved when

Firstmate answers on the server, the first clones are usable there, no unlanded work was moved, and the captain has a single place they talk to.
