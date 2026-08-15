# priming loop

Label: wayfinder:task (AFK)
Phase: 2
Blocked by: 09-quota-axi-switch.md

## Question

Build the strategy-gated priming pass keeping fixed-cost accounts primed: auth verified and telemetry fresh.

- Prefer routing real work (a decide preference for under-used fixed-cost accounts); minimal synthetic ping only when no real work is available and the policy's priming gate is on.
- Sharpen here (from map fog): the cheapest safe synthetic call per provider, and its cadence (about once per 5h window).
- Honest rationale per ADR 0031: priming verifies auth and freshens telemetry; it is not claimed to advance reset clocks.
- Acceptance: with priming on, every fixed-cost account shows fresh telemetry and verified auth within one window cycle; with priming off, no synthetic traffic at all.
