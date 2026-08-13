# cswap usage-call audit

Label: wayfinder:research (AFK)
Blocked by: none

## Question

Determine whether cswap/claude-swap (and any other local tool) calls the Anthropic usage endpoint, at what cadence, and whether it must converge on the shared cache.

- Inspect the cswap binary/source and any timer or status display it runs.
- Also inventory any other fleet tool polling usage (desk builders, dashboards).
- Answer feeds the 429 budget: the host target is one fetch per provider-account per TTL total.
