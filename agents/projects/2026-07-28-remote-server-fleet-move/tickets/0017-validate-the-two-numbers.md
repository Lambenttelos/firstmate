# Validate the sixteen agent and six slot numbers under real load

Type: `wayfinder:task`. Status: open. Blocked by: Prove one unattended overnight run on the server.

## Question

Do sixteen agents and six heavy slots hold on this hardware under real work, or do they need adjusting?

## Context

The numbers were derived, not measured.
Memory arithmetic allows them with about 2 GB of headroom on 32 GB.
The doubt is CPU: six concurrent suites on twelve threads is two threads each, on a machine whose single-thread performance is about 0.65 times the laptop's.

`cap-vitest-concurrency` should land before six slots run hot, and Playwright suites should be sharded across slots rather than spawning a wide pool inside one slot.

## Resolved when

The numbers are either confirmed against observed suite wall times and host pressure, or changed, with the readings recorded either way.
