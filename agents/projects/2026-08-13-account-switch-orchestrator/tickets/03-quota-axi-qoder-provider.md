# quota-axi qoder provider

Label: wayfinder:task (AFK)
Blocked by: none

## Question

Add a qoder provider to quota-axi reporting the qoder plan's monthly credit budget (2000/6000/20000 by plan, resets at billing period end, credit packs stack) as a monthly window with percentRemaining and resetsAt.

- Investigate first whether qoder exposes credit balance via API or local IDE state.
- Blind accounts are banned (ADR 0031): this provider is the prerequisite for orchestrating qoder accounts at all.
- Acceptance: `quota-axi --provider qoder --json` reports the monthly credit window for an authenticated qoder account.
