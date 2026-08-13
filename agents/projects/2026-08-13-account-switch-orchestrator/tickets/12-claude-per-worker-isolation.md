# claude per-worker account isolation investigation

Label: wayfinder:research (AFK)
Blocked by: none

## Question

Investigate whether the claude harness can support per-worker accounts (for example per-worker CLAUDE_CONFIG_DIR homes or equivalent), removing the global-binding constraint that forces claude workers to switch as one block.

- Deferred from MVP (design Q8): today claude binding is global and the decider treats claude workers as one slot.
- Deliverable: a report - feasible or not, mechanism, cost, and whether it changes the registry's binding field for claude accounts. No implementation.
