# Determine whether the long session freeze follows to Linux

Type: `wayfinder:research`. Status: open. Blocked by: Move firstmate itself and the first clones.

## Question

Does the unexplained multi-hour session freeze reproduce on the server, or does the different pty stack remove it?

## Context

The 2026-07-26 stall was a whole-process freeze of the interactive session lasting 7.69 hours.
It was proven to be the agent process parked on stdin under a pty rather than anything in the host application, and it is still unfixed.
Moving to Linux changes the pty stack entirely, so it may vanish or it may follow.

Either answer is useful.
If it follows, the second way in over mosh becomes the mitigation rather than a convenience.

## Resolved when

Enough server running time has accumulated to say one way or the other, with the evidence recorded.
