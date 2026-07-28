# Design the cross-host test-execution pool

Type: `wayfinder:grilling`. Status: open. Blocked by: Prove one unattended overnight run on the server.

## Question

How does a heavy-run slot become addressable from a machine that does not own it, so a laptop worker can borrow a server slot and a second server can join the pool?

## Context

This revives the transport half of the earlier remote heavy-run executor design: push the worktree head, run remotely, stream output back, return the real exit code, and degrade rather than wedge.
What changes is the ledger.
Today it is a host-global file; a pool spanning machines needs a network service instead.

The eventual direction is several firstmates across a development team sharing that capacity, which argues for the service shape rather than a shared file even in the first version.

## Resolved when

The pool's admission model, its failure behaviour, and its ledger shape are decided, with the earlier executor design explicitly reconciled rather than quietly reinvented.
