# Map: account-switch orchestrator

Label: wayfinder:map

## Destination

quota-axi expanded into the fleet's account orchestrator: registry, all-provider telemetry through a shared cache, a pure `decide`, one fenced switch subcommand actuating live jcode sessions (via a new jcode control surface) and the global claude store, with firstmate reduced to a caller.
Design decisions are locked in ADR 0031 (`docs/adr/0031-account-switch-orchestrator.md`); this map carries the build to done.

## Notes

- Domain: firstmate shared tracked material plus two external codebases (quota-axi, jcode). Firstmate-repo work falls under `firstmate-coding-guidelines` and routes to the firstmate-dev secondmate.
- Consult `CONTEXT.md` (Account orchestration section) for canonical vocabulary and ADR 0031 before any ticket.
- Research record with fact-checked limits and citations: firstmate home `data/grilling/2026-08-13-account-switch-orchestrator/limits-research.md`.
- Tracker: local markdown, one file per ticket under `tickets/`, blocking edges as `Blocked by:` lines in each ticket body.

## Decisions so far

- [Grilling session 2026-08-13](../../../docs/adr/0031-account-switch-orchestrator.md) - full design locked: quota-axi owns orchestration with fenced mutation; observation-driven limits; declarative tier policy with external policy authors; harness-first precedence; jcode control surface for actuation; drain semantics; shared single-flight usage cache; priming as auth+telemetry freshness.

## Not yet specified

- Exact policy-file schema (field names, tier syntax, model-map syntax): sharpens inside the registry/policy ticket.
- Tripwire error catalog: the exact limit-error strings/codes per provider per harness that mark an account exhausted, and how the watcher observes them per harness.
- Synthetic ping mechanics: cheapest safe "one tiny call" per provider that opens/refreshes telemetry without burning meaningful quota.
- Decision JSON schema versioning and how callers (firstmate dispatch-select, watcher) pin to it.

## Out of scope

- Restarting live claude sessions to force account adoption: rejected; drain/near-instant adoption semantics accepted (ADR 0031).
- Peak/off-peak limit modeling: no current provider varies limits by time of day (research record, claim 9).
- A separate standalone accounts-axi tool: superseded by the quota-axi expansion decision (Q27c).
- A full per-account usage ledger for blind providers: blind accounts are banned instead; telemetry support is the prerequisite.

## Tickets

| Ticket | Blocked by |
|---|---|
| [quota-axi shared usage cache](tickets/01-quota-axi-shared-cache.md) | none |
| [quota-axi opencode provider](tickets/02-quota-axi-opencode-provider.md) | none |
| [quota-axi qoder provider](tickets/03-quota-axi-qoder-provider.md) | none |
| [quota-axi account registry and policy](tickets/04-quota-axi-registry-policy.md) | none |
| [jcode session control surface](tickets/05-jcode-control-surface.md) | none |
| [cswap usage-call audit](tickets/06-cswap-usage-audit.md) | none |
| [quota-axi decide](tickets/07-quota-axi-decide.md) | 01, 02, 03, 04 |
| [jcode converge on shared usage cache](tickets/08-jcode-shared-cache-convergence.md) | 01 |
| [quota-axi fenced switch subcommand](tickets/09-quota-axi-switch.md) | 05, 07 |
| [priming loop](tickets/10-priming-loop.md) | 09 |
| [firstmate integration](tickets/11-firstmate-integration.md) | 09 |
| [claude per-worker account isolation investigation](tickets/12-claude-per-worker-isolation.md) | none |
