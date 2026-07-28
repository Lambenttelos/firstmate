# Move the whole firstmate home to the home server

Status: accepted, 2026-07-28.

## Context

The captain's laptop is an Apple M4 with 10 cores and 16 GB of memory, and it is the binding constraint on all fleet work.
Buying more memory is not an option because the machine is company-managed.
The practical ceiling is four to five concurrent workers while ready work routinely exceeds that by a wide margin.
The failure mode is not a shortage of cores.
It is swap thrash: the 2026-07-23 incident reached load 177 with 11.8 GB of swap in use, and exiting five idle agents alone took load back to 14 and swap to 3.9 GB.

An earlier design pass on this same capacity problem recorded a rejection.
`data/design-active-worker-admission-control/decisions.md` section 4 reads: "Rejected: moving agents remote (splits supervision fabric for 0.5 GB/agent)".
That pass landed on a narrower answer instead, which was to keep agents local and push only heavy test runs to the home server through a remote execution backend.

Firstmate supervises workers through terminal panes, per-task status files, a durable wake queue, task metadata, and shared worktree pools, all of which are ordinary files inside one `FM_HOME` on one host.
The runtime backend abstraction is small, around a dozen pane operations in `bin/backends/tmux.sh`, but nothing else in the system is host-agnostic.

## Decision

Move the entire firstmate home to the home server, rather than moving workers alone.

The server is an i7-8700K with 6 cores and 12 threads, 32 GB of DDR4, Docker, a 500 GB SSD cache pool, and an OpenVPN server already in place.

Concretely:

- Firstmate itself, every crewmate, every project clone, the worktree pools, and the no-mistakes service all live on the server.
- The whole home runs inside one long-lived container, with `FM_HOME`, `projects/`, and `.treehouse/` bind-mounted from a share on the SSD cache pool, never on the parity array and never inside the Docker vdisk.
- A Paseo daemon on the server hosts firstmate, bound to the VPN interface with a password set, so both the laptop and the phone connect directly over OpenVPN rather than through the Paseo relay.
- Mosh over OpenVPN provides a second, independent way in, for looking into crew panes and for the case where the Paseo daemon is itself the thing that broke.
- Source-side credentials (GitHub, Bitbucket, npm, the harness) move to the server.
- Deployment credentials for production do not, so agent-driven production deploys remain impossible by construction.
- The agent ceiling is 16 and the heavy-run slot count is 6.
- There is no standing local home. If the server dies as hardware rather than as a network, the recovery path is a cold rebuild of a fresh local home from origin.

## Why the earlier rejection is not being overturned

The recorded objection was correct, and it was answering a different question.

It evaluated the shape where workers move and firstmate stays local.
In that shape the supervision fabric genuinely does split: status files land on one host while the wake queue and the reconciliation logic that reads them live on another, worktree pools are remote while merge and landing paths are local, and inspecting a stuck worker crosses the network.
The prize in that shape really is only the agent memory floor, roughly 0.5 GB per agent, because the heavy runs were already leaving by another route.
That trade was bad and the rejection stands.

Moving the whole home has no split to pay for.
Inside the server it is one host, one filesystem, and one terminal multiplexer, so the supervision code is unchanged.
The prize is also different: it is not 0.5 GB per agent, it is the entire working envelope moving from 12 GB of usable memory to roughly 24 GB on a machine with no browser, editor, or desktop competing for it.

This decision therefore re-rejects the original shape a second time, and adopts a shape the original pass never evaluated.

## Considered options

- **Workers remote, firstmate local.** Rejected, for the reasons above. It was rejected again during this session when it reappeared as a way to run extra laptop workers.
- **Heavy test runs remote only, no fleet move.** This is the existing `scout-remote-heavy-run-executor` design. It is not wrong, but it addresses the memory spike while leaving the agent floor on the constrained machine, so the practical worker ceiling barely moves.
- **A container per agent on the server.** Rejected. Isolating each agent in its own filesystem fragments status files, the wake queue, worktree pools, and pane access, which is the same split, self-inflicted, in exchange for isolation nobody asked for.
- **Running the fleet bare on the unraid host.** Rejected. The host root filesystem is rebuilt from flash on each boot, so a permanent fleet home would depend on a plugin chain to survive a reboot.
- **The Windows desktop.** Previously rejected and not revisited. It adds a third environment flavour with no capacity worth the cost.

## What this actually buys, stated honestly

Roughly three times the concurrent workers, not three times the capacity.

- Usable memory roughly doubles, from about 12 GB after the laptop's operating system, browser, and editor reserve, to about 24 GB.
- Multi-core throughput is roughly at parity. An i7-8700K and an M4 are close on multi-core, so this is not a faster machine.
- Single-thread performance is about 0.65 times the laptop, so individual test suites run roughly 1.3 to 1.5 times slower, and slower still when all six heavy slots are busy on twelve threads.
- The machine stops swapping, which was the actual failure mode.

After the move, memory is no longer the binding constraint.
The constraints expected to bite next, in order, are API rate limits and token budget, the captain's supervision attention, and server CPU on suite-heavy days.

## Consequences

Knowingly accepted:

1. The server becomes a single point of failure. There is no standing local home, so a hardware failure means no fleet until a cold rebuild.
2. Company source credentials live on an unmanaged home machine. The deployment-credential carve-out narrows the blast radius but does not remove it. Whether an employer's clearance for company code on a home server extends to company credentials is a question for the employer, not a design decision.
3. Individual suites get slower even though total throughput rises.
4. The primary work surface becomes network-dependent. If the tunnel is down, the captain cannot look, although the fleet keeps working and reconnecting resumes supervision.
5. The migration has a degraded window, during which the local fleet drains while the server is only partly live.
6. The no-mistakes service moves with its live SQLite state, which is the riskiest single step in the migration.
7. Fleet data on the cache pool is not parity-protected, so `data/` needs its own backup path. It holds the backlog, learnings, and captain preferences, none of which are recoverable from a remote.

Riding along with the six-slot choice, two pieces of existing work become prerequisites rather than nice-to-haves.
`cap-vitest-concurrency` sizes vitest workers from available memory rather than core count, and it should land before six slots run hot.
Playwright suites should be sharded across slots rather than allowed to spawn a wide worker pool inside a single slot.

The `scout-remote-heavy-run-executor` design is not deleted.
Phase one does not need it, because a test run is now an ordinary local command in the same filesystem as the code.
It returns later in a generalised form, as a test-execution pool addressable from any host, so that a laptop worker can borrow a server slot and a second server can join the pool.
Because the eventual direction is several firstmates across a development team sharing that capacity, the pool should then be a network service rather than a shared file.

## Glossary

- **Fleet home**: the single `FM_HOME` directory tree that holds durable records, volatile runtime state, configuration, and project clones. Supervision is coherent precisely because these sit on one filesystem.
- **Supervision fabric**: the combination of pane access, status files, the wake queue, task metadata, and worktree pools through which firstmate observes and steers workers. It is fabric because the pieces only work as a set on one host.
- **Split fabric**: any arrangement where parts of that set live on different hosts. The cost is not latency, it is the absence of a single source of truth about what a worker is doing.
- **Cold fallback**: the recovery posture where no standing second home exists, and a local home is rebuilt from origin only if the server fails as hardware.
- **Test-execution pool**: the future capability where heavy-run slots are addressable across several machines, so any worker on any host can borrow a slot.
