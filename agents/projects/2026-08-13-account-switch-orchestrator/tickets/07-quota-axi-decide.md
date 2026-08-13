# quota-axi decide

Label: wayfinder:task (AFK)
Blocked by: 01-quota-axi-shared-cache.md, 02-quota-axi-opencode-provider.md, 03-quota-axi-qoder-provider.md, 04-quota-axi-registry-policy.md

## Question

Build the pure `decide` command: registry + policy + observed windows in, decision JSON out, zero side effects.

- Fixed precedence: harness fit first, account rotation within harness second, cross-provider last; fixed-cost tiers before metered.
- Exhaustion: min_reserve floor crossing, captain_reserve on flagged accounts, recorded tripwire state ("exhausted until T").
- Unknown-data rule: missing/stale telemetry means unknown, usable only when no known-good account remains, never a reason to switch away from a working account.
- Model mapping: per-provider equivalent from the model map, else the provider's required default model.
- Global-binding awareness: claude-harness accounts move as one block.
- Decision JSON names, per target session (or all-sessions/global scope): account, model, harness, and the reason chain (which floors/tiers fired).
- Acceptance: fixture-driven tests cover tier fallback, reserve floors, captain reserve, unknown-data, global block switch, model default fallback, and termination when everything is exhausted (decide returns "hold" rather than looping).
