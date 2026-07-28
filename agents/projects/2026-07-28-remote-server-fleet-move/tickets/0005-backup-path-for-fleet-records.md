# Decide the backup path for irreplaceable fleet records

Type: `wayfinder:grilling`. Status: open. Blocked by: Lay out the fleet share on the SSD cache pool.

## Question

Where do the irreplaceable fleet records get backed up to, how often, and who verifies a restore actually works?

## Why this is a real decision

The cache pool is deliberately not parity-protected, because parity on scratch data is waste.
But not all of the fleet home is scratch.
`data/` holds the backlog, the captured learnings, and captain preferences, and none of it exists on any remote.
`~/.no-mistakes/` holds live SQLite state for the validation pipeline.
Today those sit on a laptop that is presumably backed up by other means; after the move they sit on a single unprotected SSD.

This decision was surfaced by the cache-pool choice and was not settled during the grilling session.

## Resolved when

A backup target, a cadence, and a restore check are written down, and one restore has actually been performed rather than assumed.
