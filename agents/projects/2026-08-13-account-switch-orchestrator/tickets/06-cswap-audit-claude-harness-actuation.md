# claude harness actuation via claude-swap

Label: wayfinder:task (AFK)
Phase: 2
Blocked by: 09-quota-axi-switch.md

## Question

Add the claude harness to the fenced switch subcommand, actuating through claude-swap as the credential store's single owner.

- Decision (2026-08-13): depend on claude-swap rather than writing the store natively - the store must have exactly one writer, and cswap already encodes working switch mechanics including near-instant live-session adoption. quota-axi shells out to it and never touches the store directly.
- Verify first (folded-in audit): cswap is scriptable non-interactively (clean exit codes, machine-readable status), and whether it calls the Anthropic usage endpoint on its own - if so, at what cadence, and converge it on the shared cache. Also inventory any other fleet tool polling usage.
- Switch semantics: global binding - one switch flips every live claude session (near-instant adoption, no restarts); the decider already treats claude-harness accounts as one block.
- Fail closed with an actionable message when cswap is missing or not scriptable; revisit native store writing only if cswap lacks a non-interactive mode or goes unmaintained.
- Acceptance: switch applies a claude-harness decision through cswap, live claude sessions adopt without restart, and a missing cswap produces a clear refusal rather than a partial switch.
