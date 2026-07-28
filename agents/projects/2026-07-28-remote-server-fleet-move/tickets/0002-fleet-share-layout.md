# Lay out the fleet share on the SSD cache pool

Type: `wayfinder:task`. Status: open. Blocked by: none.

## Question

What is the concrete layout of the fleet share on the 500 GB SSD cache pool, and what enforces that it never lands on the parity array or inside the 60 GB Docker vdisk?

## Context

Measured local footprint today is 2.1 GB of clones plus 6.3 GB of worktree pools at four to five workers.
Scaled to sixteen workers this is roughly 20 to 25 GB, which is trivial against 500 GB but fatal against the 40 GB free inside the Docker vdisk.
Parity on fleet scratch data is pure cost, since every byte of it is reclonable.

## Resolved when

The share exists, its cache-only allocation is set so the mover never migrates it to the array, and a written note records where `FM_HOME`, `projects/`, and `.treehouse/` each sit.
