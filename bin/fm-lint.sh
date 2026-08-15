#!/usr/bin/env bash
# fm-lint.sh - the single owner of firstmate's shell-lint definition.
#
# Runs ShellCheck over firstmate's tracked shell scripts at ShellCheck's default
# severity (which reports info, warning, and error - the levels CI fails on).
# The lint command, the file set, the config, AND the pinned ShellCheck version
# live here and ONLY here, so the gates cannot drift apart: both invoke this
# script with no arguments.
#   - CI:       .github/workflows/ci.yml installs the version this script prints
#               via `--required-version`, then runs `bin/fm-lint.sh`.
#   - Pre-push: .no-mistakes.yaml `commands.lint` runs `bin/fm-lint.sh`, so the
#               no-mistakes gate runs the SAME shellcheck as CI. Without a
#               configured commands.lint, that gate step never ran this
#               deterministic shellcheck, so info-level findings were not
#               surfaced locally before CI rejected them.
#
# Version parity: CI's ShellCheck used to float with the runner image, and
# ShellCheck retired SC2015 in 0.11.0, so an older CI ShellCheck rejected an
# SC2015 that a newer local one no longer emits. This script pins one exact
# version (REQUIRED_SHELLCHECK) and asserts the resolved `shellcheck` matches it,
# so CI and local run the identical rule set. This is not a CI relaxation: it
# adopts one upstream release consistently; the only difference from the old
# floating CI is dropping the upstream-retired, false-positive-prone SC2015.
# No severity downgrade and no blanket exclude of checks - every still-supported
# finding at default severity is enforced.
# The local == CI parity contract is asserted by tests/fm-lint.test.sh.
#
# Follow-mode parity (-x): the canonical run lints every file in ONE ShellCheck
# invocation, so ShellCheck resolves each `# shellcheck source=` directive
# against the other files in that same input set and suppresses SC1091 for them.
# This speed rework lints files INDIVIDUALLY (for caching and parallelism), where
# those co-inputs are gone. Passing `-x` makes ShellCheck follow the same
# `source=` directives from the filesystem instead, which reproduces the batch
# verdict EXACTLY: measured over the whole tree, `shellcheck --norc -x <file>`
# per file yields byte-identical findings to the old `shellcheck --norc <all>`.
# Without `-x`, per-file linting emits thousands of spurious SC1091 the batch
# run never did. `-x` is therefore a parity requirement here, not a relaxation:
# it changes nothing about which findings are enforced, only restores the
# cross-file source resolution the single-batch invocation gave for free.
#
# Speed: the full canonical set is hundreds of files and a serial ShellCheck over
# all of them cost ~12 minutes on every no-mistakes run - a fleet-wide tax. Two
# safe optimizations cut that to seconds on an unchanged tree without changing
# the verdict:
#   1. Content-hash cache. ShellCheck is deterministic, so a file need not be
#      re-linted while neither it NOR anything that affects its verdict has
#      changed. Because `-x` lets a sourced library's content change a file's
#      verdict (a syntax error in a sourced lib surfaces as SC1094 in the file
#      that sources it, and a symbol defined two levels deep is visible), a
#      per-file key over the file's own bytes alone would be UNSOUND. So each
#      file's cache key folds in three things: the lint context (cache format,
#      resolved ShellCheck version, and the exact flags) AND a fingerprint of
#      the file's own transitive `# shellcheck source=` closure - the file plus
#      every library it sources, directly or indirectly. A changed or new file
#      misses on its own bytes; editing a library re-lints exactly the files
#      whose closure contains it (its actual dependents), not the whole tree; a
#      version or flag change changes every key and invalidates the whole cache.
#      A file with findings is NEVER cached, so it re-lints (and re-reports)
#      until fixed. The cache lives under .no-mistakes/lint-cache (gitignored).
#      An unavailable hash tool or an unwritable cache degrades to a full lint,
#      never to skipping a file.
#   2. Parallelism. The files that DO need linting run concurrently across cores
#      via a portable `xargs -P` fan-out (no GNU parallel required), each file
#      still linted independently with the identical `--norc -x` invocation, so
#      the combined pass/fail verdict is identical to the old serial full run.
#      The fan-out width is sized to the host's cores but CLAMPED to at most 4
#      concurrent ShellCheck processes, so a many-core box never spawns dozens of
#      linters that starve interactive and test work.
#
# HOST GENTLENESS. Three controls keep a lint sweep from ever freezing the host,
# the failure mode that appears when several no-mistakes runs lint at once:
#   - Low priority. Every ShellCheck process runs behind `nice -n 15` (when nice
#     is present; omitted, not fatal, when it is not), so lint always yields CPU
#     to interactive and test work.
#   - Concurrency cap. The `-P` fan-out is capped at 4 (see optimization 2).
#   - Fleet admission. A FULL-TREE sweep (no file arguments) is a HEAVY run like
#     a suite or a build, so it routes through the one host-global heavy-run queue
#     (bin/fm-heavy-run.sh), capping how many full-tree sweeps run at once across
#     ALL homes. An explicit single/some-file call (`fm-lint.sh <path>...`) is
#     cheap and stays UN-gated. When the sweep is already running inside a
#     heavy-run slot (fm-heavy-run exports FM_HEAVY_RUN_ACTIVE), it does NOT
#     re-admit - that would deadlock against the very lease it holds - and runs
#     inline. A heavy-run admission refusal degrades to an ungated inline sweep
#     (still nice-throttled and core-capped) rather than failing the lint.
#     N/A here: the captain's related request to nice rustc/cargo does not apply
#     to this pure-bash repo, which launches no Rust toolchain.
#
# Usage:
#   fm-lint.sh                    lint the canonical file set (what both gates run)
#   fm-lint.sh <path>...          lint only the given paths with the same config
#                                  (developer convenience; the gates never pass args)
#   fm-lint.sh --required-version print the pinned ShellCheck version and exit
#                                  (CI reads this to install the exact same one)
#   fm-lint.sh --no-cache <...>   bypass the content-hash cache for this run
#                                  (developer/debug convenience; forces a full lint)
#
# Exit status is ShellCheck's own verdict on a lint run: zero when no file
# reports a finding, non-zero when any file does, exactly matching the old
# serial full-tree behavior. A version mismatch or a missing ShellCheck fails
# before linting with a distinct message.
set -eu

# The single source of the pinned ShellCheck version. Bump here and CI follows
# automatically via `--required-version`; the test suite reads it the same way.
REQUIRED_SHELLCHECK=0.11.0

# Cache-format generation. Bump this to invalidate every cached pass when the
# cache mechanics themselves change (independent of the ShellCheck version).
# FM_LINT_CACHE_FORMAT_OVERRIDE is a test/ops seam: it forces a different cache
# generation (an ops-side wholesale invalidation, and the behavioral proxy the
# test suite uses for the version-bump invalidation path). The gates never set
# it, so both resolve the one canonical generation.
LINT_CACHE_FORMAT=${FM_LINT_CACHE_FORMAT_OVERRIDE:-1}

# The exact ShellCheck flags every lint uses. Named once here so the cache-key
# context and the actual invocation cannot drift apart. `-x` is required for
# per-file parity with the old single-batch run (see the header).
LINT_FLAGS=(--norc -x)

# Every ShellCheck process runs behind a low-priority prefix so lint always
# yields CPU to interactive and test work and can never freeze the host, even
# when several sweeps and suites contend at once. `nice -n 15` is used when
# available and simply omitted when it is not (the lint still runs, just at
# normal priority), so the tool being absent never fails a lint. Named once here
# and consumed by both the per-file worker and, indirectly, every fan-out child.
LINT_NICE=()
if command -v nice >/dev/null 2>&1; then
  LINT_NICE=(nice -n 15)
fi

# The hard ceiling on concurrent ShellCheck processes. Parallelism is sized to
# the host's cores below but clamped to this cap, so a many-core machine never
# fans out into dozens of concurrent linters that starve everything else.
LINT_MAX_JOBS=4

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# --- worker mode ------------------------------------------------------------
# Re-entrant per-file worker driven by the xargs fan-out below. Each invocation
# lints exactly one file, honoring the content-hash cache, and writes any
# findings to a per-file output slot so the parent aggregates a deterministic,
# order-stable verdict and report. It always exits 0: failure is signaled by a
# non-empty output slot, so xargs never aborts the fan-out mid-sweep.
# Contract via environment (set by the parent): FM_LINT_OUTDIR, FM_LINT_CACHE_DIR
# (empty = caching disabled), FM_LINT_SALT (lint-context prefix), FM_LINT_HASH_CMD
# (empty = no hasher).

# fm_lint_source_closure <file>: print, one per line, the file plus every file
# it transitively pulls in via `# shellcheck source=` directives (deduped). This
# is the exact set whose content can change the file's `-x` verdict, so hashing
# it yields a sound, minimal cache key: a library edit invalidates only its real
# dependents. Unresolvable and special (/dev/null) targets contribute nothing,
# matching ShellCheck's own follow behavior.
fm_lint_source_closure() {
  local start=$1
  local -a stack=("$start")
  local seen=$'\n'
  local cur t dep
  while [ "${#stack[@]}" -gt 0 ]; do
    cur=${stack[-1]}
    unset 'stack[-1]'
    case "$seen" in
      *$'\n'"$cur"$'\n'*) continue ;;
    esac
    seen+="$cur"$'\n'
    [ -r "$cur" ] || continue
    printf '%s\n' "$cur"
    # Follow each source= target named in this file, resolved relative to the
    # repo root (the directory this script cd'd into), matching how the batch
    # run resolved them.
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      case "$t" in
        /dev/null) continue ;;
      esac
      if [ -r "$t" ]; then
        dep="$t"
      elif [ -r "$ROOT/$t" ]; then
        dep="$ROOT/$t"
      else
        continue
      fi
      stack+=("$dep")
    done < <(sed -n 's/.*shellcheck source=\([^ ]*\).*/\1/p' -- "$cur")
  done
}

if [ "${1:-}" = "--lint-one" ]; then
  line=$2
  idx=${line%%$'\t'*}
  file=${line#*$'\t'}
  out="$FM_LINT_OUTDIR/$idx.out"
  # Clearing the pending sentinel proves this file was actually processed; a
  # worker that never launched leaves it, so the parent cannot miscount an
  # un-run file as a clean pass.
  rm -f -- "$FM_LINT_OUTDIR/$idx.pending"

  marker=""
  if [ -n "$FM_LINT_CACHE_DIR" ] && [ -n "$FM_LINT_HASH_CMD" ] && [ -r "$file" ]; then
    # Key = lint context, then the bytes of the file's whole transitive source
    # closure in a stable (sorted) order. A NUL-delimited salt and per-member
    # framing cannot collide with file content, so distinct inputs never share a
    # key. Any change to the file or any library it sources changes the key.
    key=$(
      {
        printf '%s\0' "$FM_LINT_SALT"
        while IFS= read -r member; do
          [ -n "$member" ] || continue
          printf '\0FILE\0%s\0' "$member"
          cat -- "$member"
        done < <(fm_lint_source_closure "$file" | sort -u)
      } | $FM_LINT_HASH_CMD | awk '{print $1}'
    )
    if [ -n "$key" ]; then
      marker="$FM_LINT_CACHE_DIR/$key"
      # Cache hit: this exact closure already passed under this exact context.
      if [ -f "$marker" ]; then
        exit 0
      fi
    fi
  fi

  rc=0
  "${LINT_NICE[@]}" shellcheck "${LINT_FLAGS[@]}" -- "$file" > "$out" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$out" ]; then
    # Clean pass: record it so an unchanged tree re-lints nothing next time.
    rm -f -- "$out"
    if [ -n "$marker" ]; then
      : > "$marker" || true
    fi
  elif [ "$rc" -ne 0 ] && [ ! -s "$out" ]; then
    # Non-zero exit with no findings text (e.g. an internal ShellCheck error):
    # surface it as a failure rather than silently passing.
    printf 'fm-lint.sh: shellcheck exited %d for %s\n' "$rc" "$file" > "$out"
  fi
  exit 0
fi

# Expose the pinned version without needing ShellCheck installed, so CI can read
# it to install the exact same build before any lint runs.
if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_SHELLCHECK"
  exit 0
fi

use_cache=1
nocache_flag=()
if [ "${1:-}" = "--no-cache" ]; then
  use_cache=0
  nocache_flag=(--no-cache)
  shift
fi

# Full-tree sweep admission. A full-tree sweep (no file arguments) is a HEAVY
# run just like a suite or a build, so route it through the fleet's one heavy-run
# queue exactly as tests are, capping how many full-tree lint sweeps run at once
# across ALL homes and never freezing the host under concurrent no-mistakes runs.
# An explicit single/some-file call (fm-lint.sh <path>...) is cheap and stays
# UN-gated. Self-deadlock guard: when this sweep is ALREADY running inside a
# heavy-run slot, fm-heavy-run has exported FM_HEAVY_RUN_ACTIVE into this process,
# so we must NOT re-admit against the very lease we hold - detect it and run
# inline instead. A heavy-run admission REFUSAL (nothing ran: exit 69/75/76,
# codes fm-lint itself never uses) degrades to an ungated inline sweep rather
# than turning a lint into a spurious failure; that sweep is still nice-throttled
# and core-capped, so it stays gentle. FM_LINT_NO_HEAVY_GATE is a test/ops seam.
if [ "$#" -eq 0 ] && [ -z "${FM_HEAVY_RUN_ACTIVE:-}" ] && [ -z "${FM_LINT_NO_HEAVY_GATE:-}" ]; then
  # FM_LINT_HEAVY_RUN is a test/ops seam for the heavy-run wrapper path; the
  # gates never set it, so both resolve the one canonical repo wrapper.
  heavy="${FM_LINT_HEAVY_RUN:-$ROOT/bin/fm-heavy-run.sh}"
  if [ -x "$heavy" ]; then
    rc=0
    "$heavy" --label "fm-lint full-tree" -- bash "${BASH_SOURCE[0]}" "${nocache_flag[@]+"${nocache_flag[@]}"}" || rc=$?
    case "$rc" in
      69|75|76)
        printf 'fm-lint.sh: heavy-run admission refused (exit %s); running an ungated sweep (still nice-throttled and core-capped).\n' \
          "$rc" >&2
        # fall through to the inline sweep below
        ;;
      *)
        exit "$rc"
        ;;
    esac
  fi
  # A non-executable heavy-run wrapper simply means an ungated sweep here.
fi

# Enforce the pin so local and CI resolve the identical rule set.
if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'fm-lint.sh: ShellCheck not found; install ShellCheck %s for CI parity.\n' \
    "$REQUIRED_SHELLCHECK" >&2
  exit 127
fi
unset SHELLCHECK_OPTS
resolved=$(shellcheck --version | awk '/^version:/ {print $2; exit}')
# Log the resolved version to stderr so both CI and local runs record it.
printf 'fm-lint.sh: ShellCheck %s (pinned %s)\n' "$resolved" "$REQUIRED_SHELLCHECK" >&2
if [ "$resolved" != "$REQUIRED_SHELLCHECK" ]; then
  printf 'fm-lint.sh: ShellCheck %s required for CI parity, found %s. Install %s.\n' \
    "$REQUIRED_SHELLCHECK" "$resolved" "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi

# Resolve the file set. Canonical file set: the ONE authoritative definition.
# Callers reference this script; they never re-spell these globs.
if [ "$#" -gt 0 ]; then
  files=("$@")
else
  files=(bin/*.sh bin/backends/*.sh tests/*.sh)
fi
[ "${#files[@]}" -gt 0 ] || exit 0

# Pick a content hasher for the cache; disable the cache if none is available
# (degrade to a full lint, never to skipping a file).
hash_cmd=""
if command -v sha256sum >/dev/null 2>&1; then
  hash_cmd="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  hash_cmd="shasum -a 256"
fi

# The cache key context prefix shared by every file: bump-safe format tag,
# resolved ShellCheck version, and the exact flags. Any change here invalidates
# every previously cached pass. The per-file part of the key (the file and its
# transitive source closure) is added by each worker.
salt="fmlint:v${LINT_CACHE_FORMAT}:sc=${resolved}:flags=${LINT_FLAGS[*]}"

cache_dir=""
if [ "$use_cache" -eq 1 ] && [ -n "$hash_cmd" ]; then
  # FM_LINT_CACHE_ROOT is a test/debug seam to isolate the cache location; the
  # gates never set it, so both resolve the one canonical repo-local cache.
  candidate="${FM_LINT_CACHE_ROOT:-$ROOT/.no-mistakes/lint-cache}"
  if mkdir -p "$candidate" 2>/dev/null && [ -w "$candidate" ]; then
    cache_dir="$candidate"
  fi
  # An uncreatable or unwritable cache leaves cache_dir empty: full lint.
fi

# Parallelism width: one worker per core, floored at 1, then clamped to the hard
# cap (LINT_MAX_JOBS) so a many-core host never runs more than that many
# ShellCheck processes at once and cannot be starved by a single lint sweep.
jobs=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
[ "$jobs" -ge 1 ] 2>/dev/null || jobs=1
[ "$jobs" -le "$LINT_MAX_JOBS" ] || jobs=$LINT_MAX_JOBS

outdir=$(mktemp -d "${TMPDIR:-/tmp}/fm-lint.XXXXXX")
trap 'rm -rf "$outdir"' EXIT

self="${BASH_SOURCE[0]}"

# Fan out: feed "index<TAB>file" lines to a bounded pool of per-file workers.
# Each worker is this same script in --lint-one mode; the context passes through
# the environment so the worker cannot drift from the parent's lint definition.
i=0
lines=""
for f in "${files[@]}"; do
  lines+="$i"$'\t'"$f"$'\n'
  # Seed a pending sentinel per file; the worker clears it once it runs, so a
  # worker that never launched is detected as an un-linted file, not a pass.
  : > "$outdir/$i.pending"
  i=$((i + 1))
done

printf '%s' "$lines" | FM_LINT_OUTDIR="$outdir" FM_LINT_CACHE_DIR="$cache_dir" \
  FM_LINT_SALT="$salt" FM_LINT_HASH_CMD="$hash_cmd" \
  xargs -r -d '\n' -P "$jobs" -I '{}' \
  bash "$self" --lint-one '{}'

# Aggregate in stable input order: emit findings, and fail iff any file did.
# A leftover pending sentinel means a worker never ran that file; treat it as a
# failure so a partial fan-out can never masquerade as a clean tree.
status=0
j=0
while [ "$j" -lt "$i" ]; do
  out="$outdir/$j.out"
  if [ -f "$outdir/$j.pending" ]; then
    printf 'fm-lint.sh: %s was not linted (worker did not run)\n' "${files[$j]}"
    status=1
  elif [ -s "$out" ]; then
    cat "$out"
    status=1
  fi
  j=$((j + 1))
done

exit "$status"
