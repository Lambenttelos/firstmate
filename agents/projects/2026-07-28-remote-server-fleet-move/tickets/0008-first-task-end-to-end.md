# Run one task end to end on the server while the fleet stays local

Type: `wayfinder:task`. Status: open. Blocked by: Lay out the fleet share on the SSD cache pool; Build the fleet container image; Establish mosh access over OpenVPN; Stand up the Paseo daemon with direct VPN access; Place source credentials on the server.

## Question

Does a single task run cleanly on the server, with nothing migrated and the local fleet still working normally?

## Why this shape

This is the stage one gate, and its value is that it risks nothing.
The local fleet is untouched, so a failure here costs a rebuild of the server side and no work.

## Resolved when

One task spawns on the server, writes its status, wakes the watcher, is supervised through to completion, and tears down cleanly.
Any one of those failing fails the gate.
