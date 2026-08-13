# quota-axi account registry and policy

Label: wayfinder:grilling (HITL)
Blocked by: none

## Question

Pin down the exact schemas for the two captain-editable files quota-axi owns, then build them with `validate` and hot-reload.

- Account registry: per account - provider, label, plan (informational), cost class fixed/metered, priority tier, harness eligibility, binding global/per-session, credential-store pointer, optional captain_reserve. Never credentials.
- Policy file: ordered tiers of account pools, per-window min_reserve floors, model map with one required default model per provider, priming gates.
- Decide the file format, location, and versioning; write the `validate` subcommand (schema check, referenced accounts exist, every provider in tiers has a default model); last valid policy is always retained as the mechanical fallback.
- Acceptance: a captain (or external agent) can edit either file, `validate` catches every malformed case with an actionable error, and a bad edit never removes the last valid policy.
