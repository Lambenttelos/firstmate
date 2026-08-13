# 0031: Account-switch orchestration lives in quota-axi with fenced mutation

Date: 2026-08-13
Status: accepted

## Context

The fleet runs work across multiple providers (Claude subscription accounts, OpenAI plans, opencode go, qoder), multiple harnesses (jcode, claude), and multiple cost classes (fixed monthly subscriptions vs metered API).
Each subscription account has independent usage windows (a five-hour session window, a weekly window, and for some providers a monthly window or credit budget), each with its own reset clock.
The only existing switching mechanism is `bin/fm-switch-account.sh`, a firstmate-internal broadcast that types `/account claude switch <label>` into every live worker pane: Claude-only, all-or-nothing, coupled to firstmate's pane knowledge.

The captain wants a strategy-driven orchestrator that maximises utilisation of fixed-cost accounts before touching metered ones, supports whatever strategy the user wants, works cross-provider and cross-harness, and never wedges waiting on an agent when out of capacity.

Facts established during design (research record: `data/grilling/2026-08-13-account-switch-orchestrator/limits-research.md` in the firstmate home):

- Anthropic publishes only plan multipliers ("5x more usage than Pro"), never absolute limits, and never a session-vs-weekly split. The captain's Team-seat (1.25x/6.25x) and Max-20x-weekly-is-10x numbers are unconfirmed by any primary source.
- Anthropic's support docs state session limits reset five hours after being reached; no monthly cap exists on any Claude plan; peak-hour throttling was removed for Pro/Max in May 2026.
- OpenAI confirms Codex plan limits exist (weekly-cap language) but publishes no numbers or mechanism.
- opencode go publishes dollar-value windows ($12/5h, $30/week, $60/month, per-model caps). qoder publishes monthly credits only (2000/6000/20000 by plan).
- quota-axi already reports live observed per-window `percentUsed`/`resetsAt`/pace for claude, codex, cursor, copilot, grok, kimi - but not opencode or qoder, and it fetches fresh on every invocation.
- jcode caches Anthropic usage in-memory per process (300s TTL, 900s backoff on 429), so N live sessions poll independently; this multiplied polling is the likely cause of the observed constant 429s on the usage endpoint.
- jcode's `auth.json` does not affect running sessions, and the live server locks it: store-flipping cannot switch a live jcode session. The claude harness store (claude-swap) is server-side and global; live claude sessions adopt a switch near-instantly.

## Decision

Expand **quota-axi** into the account orchestrator rather than creating a new tool, with mutation fenced in one clearly-named switch subcommand.

1. **Ownership**: quota-axi owns the account registry (captain-editable; per account: provider, plan as information only, cost class fixed/metered, priority tier, harness eligibility, binding global/per-session, credential-store pointer, optional captain reserve), the shared usage cache, telemetry for every provider (opencode and qoder providers are a prerequisite build), and a pure `decide` command that evaluates the policy against observed state and emits a decision JSON. The only mutating verb is a single fenced switch subcommand that applies a decision. Nothing in the tool depends on firstmate; firstmate is one caller among any.
2. **Observation-driven limits**: no plan-multiplier arithmetic anywhere. Providers with telemetry use observed `percentRemaining` and `resetsAt`. Providers with published static windows (opencode, qoder) get declared windows tracked by the new quota-axi providers. Blind accounts are not allowed: a provider without telemetry support is not eligible for orchestration until quota-axi supports it. No peak/off-peak modeling; observed data absorbs demand variance.
3. **Mechanical strategy, layered authorship**: the strategy is a declarative policy file (ordered tiers of account pools, per-window `min_reserve` floors, captain reserves, and a model map with one required default model per provider). The decider applies a fixed precedence: harness fit first, account rotation within the harness second, cross-provider moves last, fixed-cost accounts before metered API. Complex strategies are authored by external agents or humans rewriting the policy file; quota-axi only validates and hot-reloads it. The last valid policy is always present, so the fallback path is mechanical and guaranteed to terminate.
4. **Exhaustion and telemetry failure**: an account is exhausted on a reserve-floor crossing (predictive) or a live limit error (tripwire, authoritative). Usage reads flow through a shared on-disk single-flight cache with TTL, Retry-After honoring, and backoff; 429s serve the cache and age-degrade trust; data past the stale ceiling demotes the account to unknown, which is usable only when no known-good account remains and is never a reason to switch away from a working account.
5. **Actuation**: jcode grows a control surface (list live sessions with provider/account/model; atomic per-session and all-sessions account+model switch through the live server) - the critical-path dependency, since store flips cannot reach live sessions. The claude harness switches via its global server-side store with accepted near-instant adoption and no restarts, actuated by shelling out to claude-swap as the store's single owner - quota-axi never writes that store natively, so the credential store keeps exactly one writer. Switches never interrupt running work. jcode's own usage fetcher converges on the shared cache so the host makes about one usage fetch per provider-account per TTL regardless of session count. `bin/fm-switch-account.sh` survives only as firstmate's interim fallback until the control surface ships, then is superseded.
6. **Priming**: fixed-cost accounts are kept primed - auth verified and telemetry fresh - by preferring to route real work to them and by a minimal synthetic ping otherwise, strategy-gated. Priming is not claimed to advance reset clocks; the support-documented reset semantics do not support that claim.

## Consequences

- quota-axi changes trust profile: from a read-only reporter to a tool with one mutating subcommand. The fence (single clearly-named verb; everything else side-effect-free) is the mitigation and must be preserved in review.
- The jcode control surface is the critical path for per-session switching; until it lands, only global claude switching and firstmate's legacy pane broadcast work.
- Strategies are testable offline: `decide` is pure, so fixture state plus a candidate policy can be validated before arming.
- Unconfirmed plan numbers (Team multipliers, Max 20x weekly) are irrelevant to the build because nothing consumes multipliers.
- A session whose model has no mapping for the target provider falls to that provider's required default model rather than being stranded or guessing.
- Every decision is explainable from its inputs (registry, policy, observed windows) and the decision JSON is the audit record.

## Alternatives considered

- **Standalone `accounts-axi` CLI**: cleanest separation (quota-axi stays untouchable-safe), but a second tool to install and version plus a cross-tool JSON contract, while quota-axi already owns the data the decider reads. Rejected in favor of the fenced-mutation middle path.
- **jcode built-in orchestrator**: jcode owns the multi-account store and sessions, but cannot cover the claude harness. Rejected.
- **Firstmate-internal orchestrator**: couples the tool to firstmate's pane model and home layout; the captain explicitly wants no firstmate dependency. Rejected.
- **Store-flip actuation for jcode**: `auth.json` is locked by the live server and does not affect running sessions. Rejected on verified mechanics.
- **Plan-multiplier limit model**: the numbers are unpublished and partly unconfirmable, while live observed windows are available. Rejected.
- **Agent-in-the-hot-path strategies**: consulting an agent per decision cannot guarantee termination when out of capacity. Rejected in favor of agents as policy-file authors.
