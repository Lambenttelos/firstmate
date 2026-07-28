# Stand up the laptop as a second independent home

Type: `wayfinder:task`. Status: open. Blocked by: Design the cross-host test-execution pool.

## Question

How does the laptop run a small independent fleet of its own, with its own records and its own delivery paths, that borrows heavy-run slots from the pool?

## Context

The chosen shape is two independent homes, each supervising only its own work.
The alternative, one firstmate reaching across the network into laptop workers, is the exact split ADR 0021 rejects and is not to be reintroduced here.

The cost is that the captain routes work between two homes by hand.
That cost is accepted; what is not yet worked out is how routing is expressed so nothing is dropped or duplicated.

## Resolved when

The laptop home exists, runs work, borrows a remote slot for a heavy run, and the routing convention between the two homes is written down.
