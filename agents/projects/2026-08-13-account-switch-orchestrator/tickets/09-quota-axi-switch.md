# quota-axi fenced switch subcommand

Label: wayfinder:task (AFK)
Phase: 1
Blocked by: 05-jcode-control-surface.md, 07-quota-axi-decide.md

## Question

Build the single mutating verb that applies a decision JSON to live jcode sessions via the control surface (per-session and all-sessions).

- Phase 1 scope: jcode harness only, Claude account switches only (no model changes, no claude-swap actuation - that is phase 2).
- The fence: this is quota-axi's only mutating subcommand; everything else stays side-effect-free, preserved in review.
- Applies a decision produced by `decide` (or an explicit captain instruction in the same shape); records what it did and why durably; per-target success/failure output.
- Failure of one target never aborts the rest; a failed target is reported and retryable.
- Acceptance: end-to-end fixture run - decide emits a decision, switch applies it to one live jcode session and to all sessions, status reflects the new reality, work is never interrupted.
