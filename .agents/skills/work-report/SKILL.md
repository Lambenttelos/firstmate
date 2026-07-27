---
name: work-report
description: Generate an engineering work-progress report for any timeframe across the fleet's repos. Use when the captain invokes /work-report or asks for a work report, weekly or monthly work report, engineering output summary, "what shipped last week/month", "what did we ship in <timeframe>", or a work-progress report for an explicit date range. Resolves a named window (last-week, this-week, last-month) or an explicit --since/--until range to concrete local-time bounds, derives three separately-methoded throughput numbers, writes a dated report under data/work-report-<window>/report.md, and optionally publishes a Lavish HTML surface.
user-invocable: true
metadata:
  internal: true
---

# work-report

Produce an engineering work-progress report for a chosen timeframe: what shipped, by area, per repo, with three separately-methoded throughput numbers.
This skill generalizes the one-off `data/weekly-fm-session-report/report.md` procedure to any window; that example report remains the reference for tone, section shape, and the accuracy rules below.
Do not delete or repurpose that example.

The report synthesis stays agent-driven.
`bin/fm-work-report-counts.sh` mechanizes only the two error-prone git counts; everything else - reading commit subjects, writing plain-language impact, categorizing repos, bucketing time - is your judgment.

## Prime accuracy rules (these are the hard-won lessons - bake them in)

1. Report **work output**, not fleet internals.
   Lead with what shipped, organized by area or theme per repo.
   Demote any fleet-reliability or supervision-plumbing notes to a short appendix, never the summary.
2. Three throughput numbers, each with its own reproducible command, **never conflated**:
   - **TOTAL COMMITS** - raw git volume, first-parent on the default branch, filtered by commit date.
   - **TICKET LANDINGS** - distinct `fm/` branches merged, with batch-merges unrolled so lanes hidden inside a batch commit are still counted.
   - **TICKETS FILED** - backlog `created` dates in-window.
   Commit count is NOT ticket throughput.
   State the exact command for each number in the report.
3. Data hygiene stays honest.
   Backlog `closed` dates are sparse and pruned on teardown, so per-day completion uses the git landing signal, not `closed`.
   Flag anything claimed but not landed (settle with `git ls-remote origin` + `git rev-list --count <ref>..<sha>`).

## Step 1 - resolve the timeframe

Accept exactly one of:
- a named window: `last-week`, `this-week`, or `last-month`;
- an explicit range: `--since <YYYY-MM-DD> --until <YYYY-MM-DD>` (since inclusive, until exclusive, both at local midnight).

Resolve it once with the helper and reuse the returned `since`/`until` for every git filter AND the backlog filter, so all three numbers share identical bounds.
Do not hardcode any specific dates.
Pick a slug for the output path from the window: the named window itself (`last-week`), or `<since>_<until>` for an explicit range.

## Step 2 - inventory the repos

Read `data/projects.md` for the current repo list and categories; do not hardcode it, it changes.
Categorize each repo as **product** or **tooling** by its registry role (product = the shipped Hyfin/Dash repos; tooling = firstmate, no-mistakes).
Each product repo is a clone under `projects/<repo>`; firstmate itself is this home's own repo root (there is no `projects/firstmate` clone), so count it against the home checkout on `main`.
Product repos default to ref `dev`; tooling repos default to `main`.

## Step 3 - derive the three numbers

Run the helper once per repo for TOTAL COMMITS and TICKET LANDINGS:

```
bin/fm-work-report-counts.sh --repo <clone-dir> --ref <dev|main> --window <window>
# or an explicit range:
bin/fm-work-report-counts.sh --repo <clone-dir> --ref <dev|main> --since <date> --until <date>
```

It emits JSON `{repo, ref, since, until, total_commits, ticket_landings}` using these exact methods (quote them in the report):

```
# TOTAL COMMITS - first-parent, commit-date
git -C <repo> log --first-parent <ref> --since=<since> --until=<until> --pretty=%h | wc -l

# TICKET LANDINGS - distinct fm/ lanes merged, batch-unrolled
git -C <repo> log <ref> --since=<since> --until=<until> --pretty=%s \
  | grep -E '^Merge|Merged' | grep -oE 'fm/[A-Za-z0-9._-]+' \
  | grep -v 'fm/batch-merge' | sort -u | wc -l
```

For **TICKETS FILED**, count `data/backlog.md` rows whose `created` date falls in the resolved `[since, until)` window (use `tasks-axi list --fields=created,closed,type,repo` or read the backlog directly), and break them down by type (ship/scout/task/captain) and by category (product/tooling/other).

Then read the in-window commit subjects on each repo (`git -C <repo> log --first-parent <ref> --since --until --pretty='%h %s'`) to write the work-by-area narrative with verbatim shas and plain-language impact.

## Step 4 - assemble the report

Write `data/work-report-<slug>/report.md` with these sections, mirroring the reference report:

1. **Executive summary** - the dominant themes, the three headline numbers each labeled with what it measures, and the highest-value fixes.
2. **Work by area** - per product repo then tooling, grouped by theme, each line `<sha> <lane-or-subject> - plain-language impact`.
3. **Throughput** - the three numbers, each with its explicit command and a per-repo table, plus a short reconciliation (COMMITS > LANDINGS > FILED is expected; they are different populations).
4. **Ticket stats** - created by type and by category (tables), and per-day completion via the git landing signal with the honesty note about `closed`.
5. **Work volume by time window** - bucket activity by local-time windows (business hours / after-hours / weekend); state the timezone offset used and any proxy caveats (e.g. human-message count as an engagement proxy, fleet-active vs human-active).
6. **Appendix: fleet reliability notes** - short, off to the side.
7. **Evidence index** - the commands and sources used.

Write the report prose caveman ultra per the fleet compression contract (terse, no articles or filler, every technical fact intact); identifiers, shas, paths, commands, and error strings stay verbatim as evidence.

## Step 5 - optional Lavish publish

If the caller wants a review surface, generate an HTML rendering of the report and run `lavish-axi <html-file>` so the captain can view and annotate it.
Name it `.lavish/work-report-<slug>-<date>.html`.

## Verification before calling it done

Confirm the three counts resolved with their commands for the chosen window, and that a spot-checked sha or two actually lands in-window.
For a large window on a memory-tight host, do not run a heavy full-history sweep; the helper's bounded `--since/--until` git reads are cheap and sufficient.
