# firstmate integration

Label: wayfinder:task (AFK)
Phase: 1
Blocked by: 09-quota-axi-switch.md

## Question

Reduce firstmate to a caller: fm-dispatch-select consults `decide` at spawn time so a jcode worker is never dispatched onto an exhausted Claude account; the watcher calls decide+switch on tripwire wakes; fm-switch-account.sh is superseded (kept only as documented fallback until confidence, then removed).

- Phase 1 scope: jcode workers on Claude accounts only.
- Also sharpen (from map fog): the jcode/Claude tripwire error catalog - which limit errors the watcher recognizes and how they are recorded as "exhausted until T".
- Firstmate-repo changes fall under firstmate-coding-guidelines and route to the firstmate-dev secondmate.
- Acceptance: a spawn during exhaustion of the preferred Claude account lands on the next account automatically; a live limit error triggers a switch without captain intervention; fm-switch-account.sh path no longer needed in the routine flow.
