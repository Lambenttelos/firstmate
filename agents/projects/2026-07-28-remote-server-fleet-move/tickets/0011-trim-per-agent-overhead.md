# Trim per-agent overhead for a headless fleet

Type: `wayfinder:task`. Status: open. Blocked by: Move firstmate itself and the first clones.

## Question

What per-agent overhead is worth carrying on a headless server, and what should simply be switched off?

## Context

`ccstatusline` was measured at 18 to 38 percent of a core per agent.
On a headless box it renders a status bar nobody is looking at.
At sixteen agents that is multiple cores of pure waste on a machine whose single-thread performance is already the weaker half of the trade.

## Resolved when

Per-agent overhead is measured on the server, anything decorative is disabled in the container, and the before and after numbers are recorded.
