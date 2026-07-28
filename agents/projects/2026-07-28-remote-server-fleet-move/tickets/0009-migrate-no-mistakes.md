# Migrate no-mistakes with its live state

Type: `wayfinder:task`. Status: open. Blocked by: Run one task end to end on the server while the fleet stays local.

## Question

How does the no-mistakes service move to the server without losing or corrupting its live state?

## Context

`~/.no-mistakes/` is 885 MB and is a second service in its own right.
It has a running daemon with a pid file and a socket, a bare repository store, its own worktrees, a `servers/` directory, and `state.sqlite` at 6.6 MB with an active write-ahead log.
The whole validation pipeline depends on it, so if it does not come up on the server, every delivery path stops on day one.

This is the riskiest single step in the migration, because it is the only one moving live database state rather than files that can be recloned.

## Resolved when

The daemon runs on the server, its state is intact rather than reinitialised, and one validation run completes against it.
The laptop copy is kept untouched until that has happened.
