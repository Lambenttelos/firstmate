# quota-axi fenced switch subcommand

Label: wayfinder:task (AFK)
Blocked by: 05-jcode-control-surface.md, 07-quota-axi-decide.md

## Question

Build the single mutating verb that applies a decision JSON: jcode sessions via the control surface (per-session and all-sessions, atomic account+model), claude harness via the global claude-swap store (live sessions adopt near-instantly, never restart).

- The fence: this is quota-axi's only mutating subcommand; everything else stays side-effect-free, preserved in review.
- Applies a decision produced by `decide` (or an explicit captain instruction in the same shape); records what it did and why durably; per-target success/failure output.
- Failure of one target never aborts the rest; a failed target is reported and retryable.
- Acceptance: end-to-end fixture run - decide emits a decision, switch applies it to a live jcode session and the claude store, status reflects the new reality.
