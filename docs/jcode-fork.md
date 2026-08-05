# jcode fork registration

This document registers the fleet-owned jcode fork and records the preserved local patch.
It mirrors the herdr fork-release-and-repin pattern: the fork becomes the canonical source for FUTURE jcode builds and installs, while the currently running binary is left untouched.
Swapping the live binary is a separate, coordinated, quiet-window step, and this document only describes that step, it does not perform it.

jcode (github.com/1jehuang/jcode) is firstmate's own primary harness and a supported crewmate and secondmate target (see `.agents/skills/harness-adapters/SKILL.md`).
Unlike herdr, firstmate has no pinned installer script for jcode: `bin/fm-spawn.sh` launches a bare `jcode --no-update` from `PATH`, and the binary is produced by jcode's own self-dev build and self-update machinery, not by a firstmate `bin/fm-install-*.sh` script.
The registration surface is therefore this document plus the source-tree remote and the harness-adapters pointer, not a SHA-pinned release asset.

## Canonical fork

- Fork: `yjuyjuy/jcode` (public, default branch `master`).
- Upstream: `1jehuang/jcode`.
- The fork is the fleet-owned source of truth for future jcode builds and installs.
  New builds are cut from the fork, not from a floating upstream checkout.

The self-dev build tree at `/root/.jcode/source/jcode` already has both remotes registered:

```
fork    https://github.com/yjuyjuy/jcode.git (fetch/push)
origin  https://github.com/1jehuang/jcode.git (fetch/push)
```

At the time of this registration:

- `fork/master` was at `0d5cd9f6ca21cad4f2cf9330e442a393f9d55947`, which already carries upstream PR #1 (`feat(tools): add agent-callable compact_context tool`).
- `fork/master` was 164 commits behind `origin/master` (upstream `1jehuang/jcode`).
  Catching the fork up to upstream is deliberately out of scope for this task, which repins future installs only.

## Preserved local patch

The running binary reports `v0.64.2-dev (0d5cd9f, dirty)` and was built on 2026-08-01 with a dirty working tree (build source fingerprint `034bb8ff718d`, recorded in `/root/.jcode/builds/manifest.json`).
The dirty delta is a single local commit that was later committed on top of `0d5cd9f` in the self-dev build tree:

- Commit: `1f75b85417a2f7f9b3d785f731b895fc609e7d3e`
- Title: `feat(tui): show active account label in header model line`
- Scope: `crates/jcode-tui/src/tui/ui_header.rs`, +30 lines.
- What it changes: adds an `active_account_suffix` helper and renders a ` · <account>` suffix on the TUI header model line when the active provider has more than one account configured (Claude or OpenAI).
  Single-account setups are unaffected, so the header stays uncluttered in the common case.

This commit was the only local work ahead of `fork/master` and was not present on the fork.
It is now preserved on the fork so a future rebuild cannot clobber it:

- Branch: `yjuyjuy/jcode` `fm/preserve-local-dirty-patch-0d5cd9f` -> `1f75b85417a2f7f9b3d785f731b895fc609e7d3e`.

Merging that branch into `fork/master` is a captain decision and is intentionally not done here.

## Live-swap runbook (NOT EXECUTED)

The live `jcode` binary is the harness running the entire fleet, including firstmate itself.
Its shared background server serves every jcode session on the machine, so rebuilding over it or restarting the server tears down every live worker.
Do not run any of the steps below as part of registration.
Run them only in a coordinated quiet window with no live crewmates and explicit captain approval.

The live binary is resolved through a symlink chain:

```
/root/.local/bin/jcode -> /root/.jcode/builds/current/jcode -> /root/.jcode/builds/versions/<version>/jcode
```

Quiet-window swap procedure:

1. Confirm the fleet is idle: no live crewmates or secondmates, and the captain has approved the swap window.
2. In the build tree `/root/.jcode/source/jcode`, decide the target commit on the fork.
   To keep the preserved patch, first merge `fm/preserve-local-dirty-patch-0d5cd9f` into `fork/master` (captain decision), then check out that commit.
   To also catch up to upstream, merge `origin/master` into the fork first, resolve conflicts, and re-verify the preserved patch still applies.
3. Build a clean, non-dirty binary from that committed source using jcode's own build path (for example `scripts/dev_cargo.sh build --profile selfdev -p jcode --bin jcode`, or the release build in `scripts/install_release.sh`).
   A clean tree yields a non-dirty version label, which is the signal that no uncommitted delta rode along.
4. Publish the new build into `/root/.jcode/builds/versions/<new-version>/jcode` and repoint `/root/.jcode/builds/current/jcode` to it, following jcode's own build-publish mechanics rather than hand-editing the symlink where a managed command exists.
5. Restart or reload the shared server so live sessions pick up the new binary.
   This is the destructive step that drops every live session, which is why it is quiet-window only.
6. Verify: a fresh `jcode --version` reports the new, non-dirty version, and a spawned session's TUI header shows the ` · <account>` suffix when multiple accounts are configured, confirming the preserved patch survived.

Until that window runs, the fleet keeps running the existing `0d5cd9f-dirty` binary and new spawns resolve the same `jcode` on `PATH`.

## Maintaining this file

Keep this file to the fork identity, the preserved-patch record, and the unexecuted swap runbook.
Update the preserved-patch section if the local delta changes, and update the fork-distance facts only when they are re-measured.
Record exact commit hashes, branch names, and paths as evidence.
