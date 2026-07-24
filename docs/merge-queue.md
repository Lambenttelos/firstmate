# Merge queue

The merge queue is the durable, firstmate-private record of ship branches that were
**pushed to origin but not yet merged** when their disposable worktree was released.
It is the safety guard that makes release-on-pushed teardown acceptable: without it,
releasing a worktree before its branch merges would be a silent leak.

## Why it exists

On this memory-bound host an idle worker occupies a slot that queued work needs.
A finished worker whose branch is fully pushed holds nothing unique - the branch is
durable on the remote - yet it used to idle for hours solely because the branch had
not merged.
`bin/fm-teardown.sh` now releases such a worktree as soon as the branch is fully
pushed to its own origin ref (verified by a fresh fetch), independent of merge state.
The captain accepted one tradeoff: once released, a branch that later needs changes
needs a fresh worker to pick it back up.
The merge queue keeps that pending merge visible rather than silent.

## Format

`data/merge-queue.tsv`, one entry per line, tab-separated, owned by
`bin/fm-merge-queue-lib.sh`:

```
<id>	<project-path>	<branch>	<head>	<base>	<compare-url>
```

- `id` - the task id whose worktree was released.
- `project-path` - the local clone firstmate runs git against when sweeping.
- `branch` - the pushed branch name.
- `head` - the branch tip commit at release time.
- `base` - the intended merge target branch.
- `compare-url` - the captain-facing compare link.

One entry per task id; recording an id again replaces its line.
Comment lines start with `#`.
The library and `bin/fm-merge-queue.sh` own every read and write; nothing else parses
or hand-edits the file.

## Lifecycle

- **Record.** Teardown records an entry only for a released ship task (not scout,
  secondmate, or `local-only`) whose branch is fully pushed to origin AND is not
  already merged.
- **Surface.** `bin/fm-merge-queue.sh list` prints the batched set as one list of
  compare links, grouped for the captain, rather than a trickle of individual asks.
- **Clear.** `bin/fm-merge-queue.sh sweep` drops every entry whose branch is now
  merged into its base. The merged check is a fresh **content-in-base** test against
  the real base branch on origin - never a PR-state lookup - so it is correct for
  Bitbucket repos (hyfin, hyfin-server) that have no PR automation. Any inconclusive
  result (no origin, fetch failure, merge conflict) keeps the entry rather than
  clearing it on an unverifiable claim.

## Merge workers on demand, not standing

No standing merge worker exists: idle workers cost memory, the binding limit on this
host.
When a batch has accumulated for a repo AND merge authority exists (the captain's
explicit word, or a `yolo`-approved routine posture for a green branch), firstmate may
spawn one merge worker per repo per batch to land the queued branches, then tear it
down.
The queue is what makes each batch discoverable; there is no daemon and no poller.
For a repo with no PR automation (Bitbucket), the merge worker lands content into the
base branch directly, and the same content-in-base sweep clears the entries afterward.

## Never against upstream

`origin` is the fork `git@github.com:yjuyjuy/firstmate.git`.
Merge work driven from the queue targets `origin`, never an upstream we do not own.
Nothing in this path force-pushes; a branch that cannot fast-forward is re-pushed
under a new name and reported, never forced.
