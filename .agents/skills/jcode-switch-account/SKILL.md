---
name: jcode-switch-account
description: Rotate the whole fleet's active Claude sub-account across every live jcode worker by wrapping bin/fm-switch-account.sh. Use when the captain invokes /jcode-switch-account, says "switch the fleet account", "switch to claude-1"/"switch to claude-2", "rotate the claude account", "change which claude account the workers use", or names an account by email (e.g. "switch to cyuan" / "dev1").
user-invocable: true
metadata:
  internal: true
---

# jcode-switch-account

Wrap `bin/fm-switch-account.sh`; never reimplement its mechanics.
The script owns everything: it sends jcode's per-session `/account claude switch <label>` into every live worker pane, validates the label against `auth.json`, and refuses to garble a half-typed composer.
This skill only drives that script and reports the outcome.

## Procedure

1. Run `bin/fm-switch-account.sh --status` first to show the active account and the known labels.
2. Resolve the requested label.
   - A bare label like `claude-1` or `claude-2` is used directly.
   - A captain phrasing by person or email (e.g. "cyuan", "dev1") maps to its label via the email shown in the `--status` output.
   - Ask one concise question only if the target is genuinely ambiguous.
3. Run `bin/fm-switch-account.sh <label>` to broadcast the switch to every live worker.
4. Confirm the switch landed by reading the per-pane tails the script prints for the live workers.
5. Report to the captain in plain outcome language which account the fleet is now on.

## Safety

See the `bin/fm-switch-account.sh` header for the full contract.
It rotates a reversible account label only: no `auth.json` edit, no server restart, no project-code change.
It skips any pane with genuine pending human input or a dead/unknown composer.
