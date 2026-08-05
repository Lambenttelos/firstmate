# External liveness watchdog

The external liveness watchdog (`bin/fm-liveness-watchdog.sh`) re-wakes the firstmate primary and records a durable escalation when the primary dies with work in flight.
It is opt-in, inert until a home creates `config/liveness-watchdog`.

## Why it exists

The hosted firstmate primary runs its supervision watcher (`bin/fm-watch.sh`, kept armed by the session or `bin/fm-present-daemon.sh`) as a child of its own agent process.
When the primary dies for any reason - an idle-runtime sweep, a daemon crash, a deliberate restart, a reverted pin - that watcher dies with it in the same stroke.
Nothing then observes the fleet, and nothing can wake the session, because the one process that would have woken it is gone too.
Self-recovery is structurally impossible until a human attaches.

On 2026-07-29 this left the fleet silent for 3 hours 41 minutes overnight while the captain slept: the stock idle sweep collected the primary at 04:23, tree-killed its watcher, and recovery came only when the captain attached from their phone at 08:04.
The full incident is `data/scout-overnight-turnover-while-captain-asleep/report.md`.
The specific idle-sweep cause is closed on the patched runtime, but the structural gap - a primary death takes its own supervisor with it - remains for every other death cause.
This watchdog closes that structural gap.

## What it does

The watchdog runs a small loop OUTSIDE the agent process tree, so whatever kills the primary cannot reach it.
On each cycle it reads durable on-disk state that survives the primary's death:

- `state/*.meta` - one file per task in flight (written at spawn, removed at teardown).
- `state/.last-watcher-beat` - the watcher's liveness beacon, touched every poll cycle. When the watcher dies with the primary, this beacon freezes.

It triggers when work is recorded as under way but no watcher has beaten within the grace window (`FM_GUARD_GRACE`, default 900s, the same threshold `bin/fm-guard.sh` uses in-session).
On a trigger it does two things:

1. **Auto-resume: re-wake the primary's own supervisor pane.**
   The supervisor pane is the herdr pane firstmate itself runs in.
   It is recorded durably at session start into `state/.supervisor-target`, because the detached watchdog loop inherits none of the primary's herdr environment and cannot resolve the pane itself.
   The watchdog reads that pane's agent liveness (`fm_backend_agent_alive`, which for jcode-on-herdr corroborates a no-agent pane by reading its composer row) and acts:
   - a live-but-idle client gets a gentle Enter nudge to re-drive its turn;
   - a confidently dead-shell husk gets a configured relaunch command run in the pane, but only if the captain provided one (`config/liveness-resume`);
   - a dead shell with no relaunch command, or a home with no recorded supervisor pane, gets a clean escalation and no pane action.
   Resume is capped and rate-limited per down-episode (`FM_LIVENESS_MAX_RESUMES`, default 3): after the cap it stops re-nudging and just escalates, because a resume loop against a genuinely broken primary is worse than silence.

2. **Durable local escalation - not a phone push.**
   This home has no phone-alert channel (the previous hosting runtime's phone-attach path is gone), so the alert is a durable local record, `state/.liveness-escalation`, stating what happened and whether the resume acted.
   It is surfaced two ways the captain sees on next attach: a prominent `LIVENESS_ESCALATION:` line at the top of the next session start (`bin/fm-bootstrap.sh`), and a durable `check` wake enqueued to `state/.wake-queue` so a still-live-but-recovered session also learns of it.
   The session-start line is surfaced in both read-only and full modes; a lock-holding session clears the record after surfacing it (via `bin/fm-liveness-watchdog.sh ack`), so it shows exactly once to the session that can act on it.

A quiet fleet with nothing in flight is healthy and never acts.
A fresh watcher beacon means supervision is alive and never acts.

### The wedged-but-alive secondary benefit

The trigger signal (beacon stale past grace while work is in flight) also catches a primary that is still ALIVE but whose supervision has stalled - the shape of the composer-defer wedge (`bin/fm-supervise-daemon.sh`), among others.
For a live-but-idle supervisor pane the Enter nudge is exactly the right, safe action, and the watchdog never relaunches a client it read as alive.
This watchdog does not attempt to fix that wedge (that is a separate ticket); it only re-drives the pane and records the escalation so the stall is never invisible.

## Outside-the-tree hosting

The requirement is that the watchdog cannot be killed by whatever killed the primary, so it must not be a child of the agent or its runtime.
On this Linux host there is no `launchd`, no systemd user session, and no cron, so - exactly like `bin/fm-present-daemon.sh` - the watchdog detaches with `setsid` (or a `perl` `POSIX::setsid` fallback) into its own session leader with no controlling terminal, which reparents it to init.
A tree-kill of the agent therefore cannot reach it, and a disconnecting terminal or a finished harness background task cannot reap it.

If the watchdog process itself ever dies, the next locked session start relaunches it (`bin/fm-bootstrap.sh`'s `liveness_watchdog_sweep`).
Session start is the natural relaunch point because the failure the watchdog guards against also removes its own relaunch opportunity until a fresh session exists.
That same sweep also re-records the supervisor pane and acks a surfaced escalation.

## Away-mode interlock

While `state/.afk` exists, away mode owns supervision through its own durable, session-independent daemon (`bin/fm-afk-launch.sh start-paneless`), which already hosts a watcher outside the session.
The liveness watchdog stands down under away mode so two supervisors never race a resume.
Its bootstrap sweep is a no-op under away mode for the same reason.

## Configuration

All configuration is local and gitignored.
See `docs/examples/liveness-watchdog` for a copyable starting file.

- `config/liveness-watchdog` - presence flag. The whole feature is inert without it.
- `config/liveness-resume` - OPTIONAL relaunch command, run in the supervisor pane via the backend's text-submit when the pane reads as a DEAD shell (for example a `jcode --resume <id>` line). When absent, a dead client is escalated for manual recovery but never relaunched; a live-but-idle pane still gets the Enter nudge with no config needed. Keep any secret it needs in this gitignored file, never committed.

Durable state (gitignored):

- `state/.supervisor-target` - `<backend>\t<target>` of the primary's own pane, recorded at session start by `bin/fm-liveness-watchdog.sh record`.
- `state/.liveness-escalation` - the durable escalation record, surfaced at session start and cleared by `ack`.

Tuning knobs (environment, all optional):

- `FM_GUARD_GRACE` - staleness threshold in seconds (default 900). Shared with the in-session guard so both agree on "the watcher is down".
- `FM_LIVENESS_INTERVAL` - how often the loop evaluates, in seconds (default 60). Far shorter than the grace so a real death is caught within roughly one interval past grace.
- `FM_LIVENESS_MAX_RESUMES` - maximum resume attempts within one down-episode (default 3). Once the cap is hit the watchdog stops re-nudging and escalates instead.

### Auto-resume is capped and idempotent

Resume attempts are counted per down-episode, keyed to the beacon's state so a continuous outage shares one episode and a recovered-then-restale beacon starts a fresh one.
Within an episode the watchdog resumes up to the cap, recording each attempt's outcome, then records once that the cap was reached and stops.
Recovery (a fresh beacon) ends the episode; a later outage re-arms from zero.

## Subcommands

`bin/fm-liveness-watchdog.sh --help` owns the full subcommand list. In brief:

- `record` - capture this session's supervisor pane into `state/.supervisor-target` (run at session start, from inside the primary's pane, so the herdr env is inherited).
- `start` - launch the loop detached and return; prints one status line.
- `run` - run the loop in the foreground (what `start` execs after detaching).
- `tick` - evaluate once and act; the pure decision, used by the tests.
- `status` - print running/not-running and exit 0/1.
- `stop` - signal only this home's recorded watchdog and wait for it to exit.
- `escalation` - print the durable escalation record, if any.
- `ack` - clear the durable escalation record (after it has been surfaced).

Every kill targets a pid recorded in this home's own lock, never a broad `pkill` that would match other firstmate homes on the machine.

## Test safety

Every resume routes through the backend send primitives, and the watchdog sources `bin/fm-backend.sh` lazily only when it acts.
`tests/fm-liveness-watchdog.test.sh` drives the watchdog against a FAKE `bin/fm-backend.sh` that records pane actions and reports a configurable pane liveness, so no test ever drives a real herdr pane or resumes a real agent.
The end-to-end test kills a real fake-primary process (a loop that beats the beacon like the real watcher) and observes the supervisor-pane re-wake and the durable escalation, proving the whole path from an actual process death rather than a hand-staled file.

## Verification (Linux, herdr, jcode)

Recorded 2026-08-05 on Linux (x86_64, Intel Core i7-8700K), herdr backend, jcode harness, no launchd/systemd/cron.
End-to-end proof: a detached fake primary beats `state/.last-watcher-beat` in a loop; the watchdog starts detached (reparented to init, ppid 1, its own session leader); while the primary beats the watchdog is silent; on `kill -KILL` of the fake primary the beacon freezes; within a few grace-plus-interval windows the watchdog re-wakes the recorded supervisor pane and records the escalation.

```
watchdog pid=8203, ppid=1 (reparented to init: OUTSIDE the agent tree)

### Watchdog quiet while the primary is alive (beacon fresh):
escalation: (none - correct, fleet healthy)

### KILL the fake primary (its child watcher would die with it):
primary alive? NO - dead

=== SUPERVISOR PANE RE-WOKEN (auto-resume) ===
[pane-wake] send-key Enter to default:w1:p1 (herdr)

=== DURABLE ESCALATION (surfaced at next session start; no phone push) ===
summary=primary supervision was DOWN, 1 task(s) in flight (watcher beacon 2s ago). Sent an Enter nudge to the supervisor pane (attempt 1) to re-drive its turn. Verify on waking whether the fleet recovered.

=== how the captain sees it at next session start ===
LIVENESS_ESCALATION: [2026-08-05T03:15:35+0000] primary supervision was DOWN, 1 task(s) in flight (watcher beacon 2s ago). Sent an Enter nudge to the supervisor pane (attempt 1) to re-drive its turn. Verify on waking whether the fleet recovered.
```

The full transcript and the passing `tests/fm-liveness-watchdog.test.sh` (13 assertions including the end-to-end kill) are the empirical record.
