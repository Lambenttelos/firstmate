# firstmate integration

Label: wayfinder:task (AFK)
Blocked by: 09-quota-axi-switch.md

## Question

Reduce firstmate to a caller: fm-dispatch-select consults `decide` at spawn time so a worker is never dispatched onto an exhausted or wrong-harness account; the watcher calls decide+switch on tripwire wakes; fm-switch-account.sh is superseded (kept only as documented fallback until confidence, then removed).

- Also sharpen (from map fog): the per-harness tripwire error catalog - which limit errors the watcher recognizes, per provider, and how they are recorded as "exhausted until T".
- Firstmate-repo changes fall under firstmate-coding-guidelines and route to the firstmate-dev secondmate.
- Acceptance: a spawn during Claude exhaustion lands on the next tier automatically; a live limit error triggers a switch without captain intervention; fm-switch-account.sh path no longer needed in the routine flow.
