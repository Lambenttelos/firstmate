# jcode session control surface

Label: wayfinder:task (AFK)
Phase: 1
Blocked by: none

## Question

Build the jcode feature that lets an external tool switch live sessions without terminal injection. Critical path: store flips cannot reach live sessions (auth.json is locked by the live server and only affects new sessions).

- List live sessions with current provider, account, and model.
- Switch a session's account, and atomically account+model together (the provider-crossing case), per-session and all-sessions.
- Report success/failure per session; a switch never interrupts a turn in flight (drain semantics - adopt on next turn).
- Shape (CLI subcommand vs control socket) is the implementer's choice; it must work headless.
- Acceptance: an external script can enumerate sessions and flip one session and all sessions between two Claude accounts, and cross-provider with a model change, while the sessions keep working.
