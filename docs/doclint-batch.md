# Batched document+lint recovery pass

The batched document+lint pass is firstmate's cheap recovery half for the per-lane
`document,lint` skip.
Small or doc-irrelevant lanes run `no-mistakes axi run --skip document,lint` to save
the ~5.3 agent-hours that document and lint historically spent to earn only ~5 fixes
across 138 changes (`data/learnings.md` anchor `no-mistakes-cost-model`).
Skipping per-lane is correct, but the skipped lanes then get no doc or lint at all, so
drift and lint rot accumulate silently on a repo's `dev`.
This pass runs document and lint once over the accumulated merged changes when a repo's
batch is big enough.

The design of record is [`data/batch-doclint-pass/report.md`](../data/batch-doclint-pass/report.md).
[`bin/fm-doclint-batch-lib.sh`](../bin/fm-doclint-batch-lib.sh) owns the format,
arithmetic, and marker-ref discipline; [`bin/fm-doclint-batch.sh`](../bin/fm-doclint-batch.sh)
is the CLI.

## Why it reuses the merge-queue shape

The pass deliberately mirrors the [merge queue](merge-queue.md): a durable per-repo
record, automatic surfacing from the hourly session-review pass, and an on-demand
worker dispatched only when a batch has accumulated.
No standing worker exists, because an idle worker costs the memory slot that is the
binding limit on this host, and no new cadence loop exists, because the existing
watcher slow-poll already runs the hourly review.

## The marker ref

`refs/fm/doclint-base/<repo>` is a durable per-repo ref, kept in the local clone, that
records the `dev` commit the last pass covered.
It tracks provenance only ("`dev` was doc/lint-clean as of this sha") and drives the
threshold count.
It does **not** drive no-mistakes' validation base: no-mistakes has no per-run base
flag and re-derives its base per repo from the remote, so the pass cannot point
no-mistakes at "the last N merged commits" (see the report's "Key constraints").

The marker advances fast-forward only.
`fm_doclint_marker_advance` uses `git update-ref` with an explicit old value, which is a
compare-and-swap, never a force, and it refuses a backward or divergent move without
writing.
It never passes `--force` and never deletes the ref, so a wrong call can only be
refused, never lose the recorded base (standing captain rule C1).

## The threshold

A pass is ready for a repo when whichever fires first:

- `FM_DOCLINT_LANE_THRESHOLD` (default 8) landed ship lanes on the repo's `dev` since
  the last pass, or
- `FM_DOCLINT_DAY_CEILING` (default 14) days since the last pass with at least one
  landed lane.

Zero lanes never fires, however old, so an already-clean repo never triggers.
The lane count reads `data/completions.tsv` (the append-only completion ledger owned by
[`bin/fm-completions-lib.sh`](../bin/fm-completions-lib.sh)), counting every landed
`ship` lane for the repo whose closed-date is after the marker commit's date.
There is no ledger schema change: the pass counts every landed ship since the last
pass, and document and lint no-op on lanes that already ran them.
When no marker exists yet, every ship lane for the repo counts and the drift clock ages
from the oldest such lane.

## Commands

- `fm-doclint-batch.sh status [<repo>]` reads the marker ref and the ledger and prints,
  per repo, `<repo>: <N> lanes since <sha> (<days>d), threshold met=yes/no`.
  Cheap and read-only.
  With no repo it walks every registered repo that has a local clone.
- `fm-doclint-batch.sh ready` prints only the threshold-met repos, one status line each,
  and nothing when none.
  The hourly session-review pass calls this and turns each line into one actionable
  finding.
- `fm-doclint-batch.sh brief <repo>` emits the scoped ship brief firstmate dispatches on
  demand: cut `fm/doclint-<repo>-<date>` off `origin/dev`, run
  `no-mistakes axi run --skip review,test,rebase` (document and lint only, the exact
  inverse of the per-lane skip), land via the repo's normal delivery, then advance the
  marker ref.
  review and test already ran on each landed branch, so re-running them is pure waste;
  document and lint inspect the merged code and fix in place, so a fresh branch off
  current `dev` is sufficient and needs no base manipulation.
- `fm-doclint-batch.sh marker-read <repo>` and `marker-advance <repo> <sha>` are the
  fail-closed marker helpers.

## Trigger and reporting

The hourly session-review pass ([`bin/fm-session-review.sh`](../bin/fm-session-review.sh))
evaluates `ready` on its existing slow poll and surfaces each threshold-met repo as one
`session-review`-style finding with the exact dispatch command in the full report.
Firstmate then dispatches one scoped pass lane per repo on demand, the same way it
dispatches a merge worker.
The lane reports `done: doclint pass landed <sha>, K fixes` or `done: doclint pass
clean, no fixes`, and the marker advances either way.
A clean pass with no fixes is a valid, successful outcome.
