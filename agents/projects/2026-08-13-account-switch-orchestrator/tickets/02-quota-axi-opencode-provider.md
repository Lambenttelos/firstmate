# quota-axi opencode provider

Label: wayfinder:task (AFK)
Blocked by: none

## Question

Add an opencode provider to quota-axi reporting the opencode go plan's published dollar-value windows ($12/5h, $30/week, $60/month, per-model caps such as $15/month for capped models) as usage windows with percentRemaining and resetsAt.

- Investigate first whether opencode exposes a usage/balance API or local state the provider can read; declared static windows plus observed spend if readable, declared-only if not.
- Blind accounts are banned (ADR 0031): this provider is the prerequisite for orchestrating opencode accounts at all.
- Acceptance: `quota-axi --provider opencode --json` reports the three windows for an authenticated opencode go account.
