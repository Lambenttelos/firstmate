# Context: Firstmate

Glossary of domain terms.
Terms are canonical; use them exactly as defined.

## Account orchestration

- **Account**: one authenticated identity on a provider (e.g. `claude-1`, an OpenAI login, an opencode subscription). Identified in the account registry by provider + label. Never stores credentials; points at the credential store that holds them.
- **Account registry**: the captain-editable file listing every account with its provider, plan (informational), cost class, priority tier, harness eligibility, binding, and reserves. Owned by quota-axi.
- **Cost class**: `fixed` (sunk recurring subscription cost; exhaust first) or `metered` (pay-as-you-go per-token; last mechanical fallback).
- **Binding**: whether an account selection applies `per-session` (jcode: each session can sit on a different account) or `global` (claude harness: one active account fleet-wide; switching flips every live claude session at once).
- **Usage window**: one provider-enforced limit bucket with an observed `percentRemaining` and `resetsAt` (session/5h, weekly, monthly, or model-scoped). Observation-driven via quota-axi; no plan-multiplier arithmetic.
- **Exhausted**: an account whose relevant window crossed its `min_reserve` floor (predictive) or which produced a live limit error (tripwire). Telemetry silence is never exhaustion.
- **Unknown (telemetry)**: an account whose usage data is missing or older than the stale ceiling. Usable only when no known-good account remains in tier order; never a reason to switch away from a working account.
- **Tripwire**: a real provider limit error observed on live work. Authoritative exhaustion signal regardless of telemetry health; marks the account exhausted until its estimated reset.
- **min_reserve**: per-window percent floor below which an account is exhausted for dispatch purposes.
- **Captain reserve**: an extra floor on accounts flagged as personally used by the captain, so fleet workers never drain them below it.
- **Tier**: one rung of the mechanical strategy's ordered account pools. The decider exhausts higher tiers before lower ones.
- **Precedence rule**: harness fit is decided first, account rotation within the chosen harness second, cross-provider moves last.
- **Model map**: the equivalence table giving each model's per-provider counterpart, plus one required default model per provider used when a session's model has no explicit mapping.
- **Decide / apply split**: `decide` is pure - state in, decision JSON out, no side effects. Mutation is fenced in a single clearly-named switch subcommand that applies a decision to live sessions and stores.
- **Priming**: keeping a fixed-cost account's auth verified and telemetry fresh (routing real work when available, minimal synthetic ping otherwise). Not a claim about advancing reset clocks.
- **Policy file**: the declarative mechanical strategy (tiers, reserves, model map). Any external agent or human may rewrite it; quota-axi only validates and hot-reloads it. The last valid policy is always the fallback, so the mechanical path always terminates.
- **Shared usage cache**: quota-axi's on-disk, single-flight cache of provider usage responses (payload, fetchedAt, Retry-After state) that all consumers - including jcode sessions - read through, so the whole host makes about one usage fetch per provider-account per TTL.
- **jcode control surface**: the jcode feature letting an external tool list live sessions and atomically switch a session's account and model (per-session or all-sessions) through the live server, without terminal injection.
- **Drain semantics**: switch behavior that never interrupts running work; live sessions adopt the new account at their next turn (claude adopts near-instantly via the server-side store).
