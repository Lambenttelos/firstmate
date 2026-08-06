# Treehouse worktree pools

Firstmate acquires every ship and scout worktree from Treehouse.
This document records what was measured about how Treehouse chooses a pool, why that choice let fleet work land in a clone firstmate does not own, and what firstmate now does about it.
It is an evidence document: every claim below is followed by the command that produced it.

Measured 2026-07-25 against `treehouse v2.0.0` on macOS (Darwin 24.6.0).

## The pool key is the origin URL, not the clone

Treehouse places a pool at `<root>/.treehouse/<repo-basename>-<hash>/<slot>/<repo-basename>`, where `<hash>` is the first six hex characters of the SHA-256 of the clone's `origin` remote URL, and `<root>` defaults to `$HOME`.

Every pool on the captain's machine matched that derivation exactly:

```
$ printf '%s' "git@bitbucket.org:dashnow/hyfin-server.git" | shasum -a 256 | cut -c1-6
77b2ea      # ~/.treehouse/hyfin-server-77b2ea
$ printf '%s' "git@bitbucket.org:dashnow/hyfin.git" | shasum -a 256 | cut -c1-6
847492      # ~/.treehouse/hyfin-847492
$ printf '%s' "https://github.com/kunchenguid/no-mistakes.git" | shasum -a 256 | cut -c1-6
2ccc85      # ~/.treehouse/no-mistakes-2ccc85
$ printf '%s' "git@github.com:yjuyjuy/firstmate.git" | shasum -a 256 | cut -c1-6
468eb4      # ~/.treehouse/firstmate-468eb4
```

Because the key is the remote and not the clone, **every clone of one remote on the machine shares one pool**, and `treehouse get` hands out whichever slot is free without regard to which clone created it.
A pool slot is a git worktree of the clone that created it, and that binding is fixed at slot creation.

The consequence was live on the captain's machine.
One pool held slots belonging to three different clones of the same Bitbucket repo:

```
$ for p in ~/.treehouse/hyfin-server-77b2ea/*/hyfin-server; do
    printf '%-4s %s\n' "$(basename "$(dirname "$p")")" "$(git -C "$p" rev-parse --git-common-dir)"
  done
2    /Users/cyuan/workspace/work/firstmate/projects/hyfin-server/.git
...
10   /Users/cyuan/workspace/work/firstmate/projects/hyfin-server/.git
11   /Users/cyuan/workspace/work/hyfin-server/.git
...
16   /Users/cyuan/workspace/work/hyfin-server/.git
7    /Users/cyuan/.treehouse/firstmate-7bab20/3/firstmate/projects/hyfin-server/.git
```

Slots 2 through 10 belong to the fleet clone, slots 11 through 16 to the captain's own checkout, and slot 7 to a secondmate home's clone.
A crewmate handed a slot of the wrong clone commits into an object store the home that dispatched it cannot see, and every repo-scoped tool it runs, no-mistakes included, resolves that foreign clone.

## `TREEHOUSE_DIR` is an output, not a setting

`TREEHOUSE_DIR` appears in the binary's strings and is tempting to read as a root override.
It is not: Treehouse *exports* it into the subshell it opens, naming the acquired worktree.
Setting it has no effect on pool resolution.

```
$ TREEHOUSE_DIR=/tmp/th-probe2/dirA treehouse get --lease --lease-holder probeA
/Users/cyuan/.treehouse/repo-ffdd40/1/repo      # still the default $HOME root
```

Inside an acquired worktree, the variable names that worktree:

```
$ env | grep TREEHOUSE
TREEHOUSE_DIR=/Users/cyuan/.treehouse/firstmate-468eb4/2/firstmate
```

## `treehouse.toml` is the only per-clone control

`treehouse init` writes a config at the clone's repo root whose `root` key relocates the pool.
Its own comment reads: "Worktree root directory (relative to repo root or absolute path). Worktrees are placed under {root}/.treehouse/. Default: $HOME".

An absolute `root` works, and a file carrying only `root` is accepted:

```
$ cat treehouse.toml
root = "/tmp/th-final/home"
$ treehouse get --lease --lease-holder final
/tmp/th-final/home/.treehouse/demo-7b2fef/1/demo
$ git -C /tmp/th-final/home/.treehouse/demo-7b2fef/1/demo rev-parse --git-common-dir
/private/tmp/th-final/home/projects/demo/.git
```

The acquired worktree belongs to the clone that owns the config, which is the property firstmate needs.

## What firstmate does

`bin/fm-treehouse-pin.sh` writes a `treehouse.toml` into each of this home's project clones setting `root` to the home's own physical path, so the clone's pool becomes `$FM_HOME/.treehouse/...`.
A firstmate home holds at most one clone per remote, so a home-scoped root yields a per-clone pool.
The captain's own checkouts are never touched and keep using the default `$HOME` pool.

The pin is applied from the two paths `AGENTS.md` section 1 already names as project-write exceptions:

- `bin/fm-fleet-sync.sh` converges the pin for every clone on every sync, so existing clones self-heal at session start and a home that moves re-pins itself.
- `bin/fm-home-seed.sh` pins each secondmate clone as it is created or adopted, and fails the seed if the pin cannot be applied.

The pin refuses any directory that is not a direct child of this home's projects directory, refuses a `treehouse.toml` the project itself tracks, preserves any other key in an untracked one, and adds itself to the clone's `.git/info/exclude` so it never shows as dirty and never rides along in a commit.

### Why the pool root is the home, and not something else

Three alternatives were considered and rejected.

Making the fleet clone and the captain's own checkout a single copy would remove the collision by removing one of the clones, but it puts firstmate's teardown, fleet-sync and merge paths on the captain's live working checkout, with their own branch state and uncommitted work.
It also fixes only this pair: two firstmate homes cloning the same remote still collide, which is the case the clone-identity assertion was originally written for.
The pin fixes both.

Giving the fleet clone a textually different `origin` URL would land it in a different pool, since the key is the URL string.
Deliberately skewing a remote to steer a hash is fragile, surprising to anyone reading the remote, and undone by any later `git remote set-url`.

`root = "./"` would put each pool inside its own clone, needing no path interpolation and never going stale.
It was rejected because it places live task worktrees under `projects/`, which `AGENTS.md` describes as clones firstmate reads and does not otherwise write, and because a `git clean -xdf` in the primary clone would then delete every open task worktree.

The chosen root leaves one known tradeoff: for the main home, `$FM_HOME` is the firstmate repo itself, so the pools sit inside its working tree.
`.treehouse/` is gitignored, so git and every tool that honours ignore rules skip it; an ad-hoc filesystem scan of the firstmate repo would still descend into it.

## Migration

Pinning a clone whose tasks already hold slots in the old shared pool is safe.
`treehouse return --force <absolute-path>` locates the pool that actually contains the path rather than the one the current config names, so teardown of a task allocated before the pin still succeeds and still releases the lease.

Measured by pinning a clone to a new root while an old-pool lease was held, then returning the old path from the re-pinned clone:

```
$ treehouse return --force /Users/cyuan/.treehouse/repo-418d41/1/repo
🌳 Worktree returned to pool.
exit=0
$ cat ~/.treehouse/repo-418d41/treehouse-state.json
{ "worktrees": [ { "name": "1", "path": ".../repo-418d41/1/repo",
                   "created_at": "..." } ] }     # the "leased" flag is gone
```

No migration step is required, and nothing in the old pool needs to be moved or deleted.
Existing worktrees keep working until their tasks are torn down normally.

## The isolation assertion this interacts with

`bin/fm-spawn.sh` refuses a launch whose worktree does not belong to the project's own clone.
That check is *relative*: it compares the allocated worktree against the project it was given, so it proves only that the two agree.
It cannot detect that the project itself is the wrong clone.

`resolve_project_dir_arg` rewrites only a `projects/<name>` argument and passes every other string through verbatim, so a spawn given another checkout of the same repo opens its pane there, `treehouse get` allocates a slot of that same foreign clone, and both sides of the comparison then name it.
The launch proceeded.
This was not hypothetical: pool slots 11, 12 and 14 were created after the clone comparison shipped on 2026-07-23 and carried firstmate branches (`fm/fix-charge-time-fee-config-reads`, `fm/fix-cc-daily-billing-deposit-exclusion`, `fm/batch-merge-hyfin-server-2026-07-25`) in the captain's object store.

`bin/fm-spawn.sh` now also applies an *absolute* test before the relative one: a ship or scout project must be a direct child of this home's projects directory, which is what the registry model already means by a registered project.
`tests/fm-spawn-foreign-clone.test.sh` covers the bypass directly, including a self-consistent foreign clone, a path that climbs out of the projects directory, and a subdirectory standing in for a clone.

## Separately-leased extra worktrees

Most tasks use exactly one worktree, the primary one `bin/fm-spawn.sh` records as `worktree=` in `state/<id>.meta`.
Some lanes need a SECOND isolated checkout beyond that primary one.
The canonical case is full-stack product work: a `hyfin-server` lane that also needs a paired `hyfin` backend checkout to stand up a live local stack.
Each such checkout is a treehouse worktree leased from that clone's own (home-pinned) pool, and every leased worktree occupies a pool slot until it is returned.

The failure this closes: `bin/fm-teardown.sh` returned only the primary worktree, and a separately-leased second worktree was never recorded anywhere teardown could see, so its lease was never returned.
Those orphaned leases accumulate until the pool hits `max_trees` and new spawns can no longer get a worktree.

The fix is durable recording at lease time.
`bin/fm-lease-extra-worktree.sh <task-id> <clone-dir>` leases the worktree AND appends one line to the task's meta in the same step, so a leased slot can never exist without a record teardown reads:

```
extra_worktree=<clone-abs-path>\t<worktree-abs-path>
```

The clone path is recorded alongside the worktree because teardown returns the worktree by running `treehouse return` from that clone, matching how the primary worktree is returned from its project.
There may be more than one such line; teardown reads every `extra_worktree=` line, not just the last.

`bin/fm-teardown.sh` returns every recorded extra worktree to its pool alongside the primary, through the same guarded `treehouse return` path (never a raw `rm`, never `--force`).
Each extra worktree gets exactly the same unlanded-work protection as the primary: teardown refuses the whole operation before destroying anything if any extra worktree holds uncommitted or unpushed-and-unlanded work, and `--force` discards it the same way it discards an unlanded primary.
`tests/fm-teardown.test.sh` covers both-return, single-worktree-unchanged, unlanded-refusal, and forced-discard.

## Maintaining this file

Record measured facts here, with the command and its real output, not assumptions.
When Treehouse's version changes, re-measure the pool-key derivation and the migration behaviour before relying on either.
