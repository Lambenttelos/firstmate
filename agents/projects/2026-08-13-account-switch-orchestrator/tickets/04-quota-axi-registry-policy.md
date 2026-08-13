# quota-axi account registry and policy

Label: wayfinder:grilling (HITL)
Phase: 1
Blocked by: none

## Question

Pin down the exact schemas for the two captain-editable files quota-axi owns, then build them with `validate` and hot-reload.

- Account registry: per account - provider, label, plan (informational), cost class fixed/metered, priority tier, harness eligibility, binding global/per-session, credential-store pointer, optional captain_reserve. Never credentials.
- Policy file: ordered tiers of account pools, per-window min_reserve floors, priming gates. Design the schema so the phase 2 model map (per-provider equivalents plus a required default model per provider) slots in without breaking changes, but do not build the model map in phase 1.
- Phase 1 registry content: Claude accounts only (mixed plans - Pro, Max, Team seats), jcode harness eligibility only. The schema stays provider-general; only the shipped content is Claude/jcode.
- Decide the file format, location, and versioning; write the `validate` subcommand (schema check, referenced accounts exist); last valid policy is always retained as the mechanical fallback.
- Acceptance: a captain (or external agent) can edit either file, `validate` catches every malformed case with an actionable error, and a bad edit never removes the last valid policy.
