# quota-axi decide

Label: wayfinder:task (AFK)
Phase: 1
Blocked by: 01-quota-axi-shared-cache.md, 04-quota-axi-registry-policy.md

## Question

Build the pure `decide` command: registry + policy + observed windows in, decision JSON out, zero side effects.

- Phase 1 scope: one harness (jcode), one provider (Claude), mixed plan accounts. No cross-provider moves and no model mapping - rotation within the Claude pool never changes the model. The precedence and model-map hooks stay in the design (ADR 0031) for phase 2.
- Tier fallback across mixed Claude plans: fixed-cost subscription accounts before any metered API account.
- Exhaustion: min_reserve floor crossing per window, captain_reserve on flagged accounts, recorded tripwire state ("exhausted until T").
- Unknown-data rule: missing/stale telemetry means unknown, usable only when no known-good account remains, never a reason to switch away from a working account.
- Decision JSON names, per target session (or all-sessions scope): account and the reason chain (which floors/tiers fired).
- Acceptance: fixture-driven tests cover tier fallback across plans, reserve floors, captain reserve, unknown-data, and termination when everything is exhausted (decide returns "hold" rather than looping).
