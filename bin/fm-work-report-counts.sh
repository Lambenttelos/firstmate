#!/usr/bin/env bash
# Emit reproducible work-report throughput counts for one repo over one time window as JSON.
#
# It resolves a named window or an explicit range to concrete local-time bounds, then reports
# two of the three throughput numbers the work-report skill needs, each by the exact method the
# skill documents:
#   total_commits   - first-parent commits on <ref>, filtered by COMMIT date (raw git volume)
#   ticket_landings - distinct fm/<lane> branch names in any merge-commit subject reachable from
#                     <ref> in-window, with fm/batch-merge-* wrappers excluded so batched lanes
#                     are still counted (unrolled)
# The third number (tickets filed) comes from the backlog and is intentionally NOT computed here;
# the skill derives it from data/backlog.md created dates using the same resolved bounds.
#
# Usage:
#   fm-work-report-counts.sh --repo <dir> [--ref <git-ref>] --window <last-week|this-week|last-month>
#   fm-work-report-counts.sh --repo <dir> [--ref <git-ref>] --since <YYYY-MM-DD> --until <YYYY-MM-DD>
#
#   --repo    path to a git clone (required)
#   --ref     git ref to count on (default: origin/dev, falling back to the current HEAD's upstream)
#   --window  named window; boundaries are local-time calendar boundaries (Mon-based weeks)
#   --since   explicit inclusive start date (local midnight)
#   --until   explicit exclusive end date (local midnight)
#
# --window and --since/--until are mutually exclusive. Dates without a time are taken at local
# 00:00:00. The resolved since/until are echoed back in the JSON so the caller filters the backlog
# on identical bounds.
#
# Output: one JSON object on stdout. Nothing else on stdout; diagnostics go to stderr.
set -u

usage() {
  sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

REPO=""
REF="origin/dev"
REF_EXPLICIT=0
WINDOW=""
SINCE=""
UNTIL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --ref) REF="${2:-}"; REF_EXPLICIT=1; shift 2 ;;
    --window) WINDOW="${2:-}"; shift 2 ;;
    --since) SINCE="${2:-}"; shift 2 ;;
    --until) UNTIL="${2:-}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done

[ -n "$REPO" ] || { echo "error: --repo is required" >&2; exit 2; }
[ -d "$REPO/.git" ] || git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "error: --repo is not a git clone: $REPO" >&2; exit 2; }

if [ -n "$WINDOW" ] && { [ -n "$SINCE" ] || [ -n "$UNTIL" ]; }; then
  echo "error: --window and --since/--until are mutually exclusive" >&2; exit 2
fi
if [ -z "$WINDOW" ] && { [ -z "$SINCE" ] || [ -z "$UNTIL" ]; }; then
  echo "error: give --window OR both --since and --until" >&2; exit 2
fi

# date_at "spec" -> emit "YYYY-MM-DD HH:MM:SS" for a GNU/BSD-portable relative or absolute spec.
# GNU accepts "-d <spec>"; BSD needs "-v" adjustments, so this handles only the specs we use.
is_gnu_date() { date --version >/dev/null 2>&1; }

# ymd_add BASE_YMD N_DAYS -> BASE plus N days (N may be negative), as YYYY-MM-DD.
ymd_add() {
  if is_gnu_date; then
    date -d "$1 +$2 days" +%Y-%m-%d
  else
    date -j -v"${2}"d -f '%Y-%m-%d' "$1" +%Y-%m-%d
  fi
}

# dow BASE_YMD -> day of week, 1=Mon .. 7=Sun.
dow() {
  if is_gnu_date; then
    date -d "$1" +%u
  else
    date -j -f '%Y-%m-%d' "$1" +%u
  fi
}

TODAY="$(date +%Y-%m-%d)"

case "$WINDOW" in
  "") : ;;  # explicit --since/--until path
  this-week)
    d="$(dow "$TODAY")"
    SINCE="$(ymd_add "$TODAY" "-$((d - 1))")"   # Monday of this week
    UNTIL="$(ymd_add "$SINCE" 7)"               # next Monday
    ;;
  last-week)
    d="$(dow "$TODAY")"
    this_mon="$(ymd_add "$TODAY" "-$((d - 1))")"
    SINCE="$(ymd_add "$this_mon" -7)"
    UNTIL="$this_mon"
    ;;
  last-month)
    first_this="${TODAY%-*}-01"                 # first day of this month
    SINCE="$(ymd_add "$first_this" -1)"         # a day in the previous month
    SINCE="${SINCE%-*}-01"                      # first day of the previous month
    UNTIL="$first_this"
    ;;
  *)
    echo "error: unknown --window '$WINDOW' (expected last-week|this-week|last-month)" >&2
    exit 2
    ;;
esac

SINCE_TS="$SINCE 00:00:00"
UNTIL_TS="$UNTIL 00:00:00"

# Fall back to the tracking upstream if the default ref is absent and the caller did not pin one.
if [ "$REF_EXPLICIT" -eq 0 ] && ! git -C "$REPO" rev-parse --verify --quiet "$REF" >/dev/null 2>&1; then
  up="$(git -C "$REPO" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
  [ -n "$up" ] && REF="$up" || REF="HEAD"
fi
git -C "$REPO" rev-parse --verify --quiet "$REF" >/dev/null 2>&1 || {
  echo "error: ref not found in $REPO: $REF" >&2; exit 2; }

total_commits="$(git -C "$REPO" log --first-parent "$REF" \
  --since="$SINCE_TS" --until="$UNTIL_TS" --pretty=%h | grep -c . || true)"

ticket_landings="$(git -C "$REPO" log "$REF" \
  --since="$SINCE_TS" --until="$UNTIL_TS" --pretty=%s \
  | grep -E '^Merge|Merged' \
  | grep -oE 'fm/[A-Za-z0-9._-]+' \
  | grep -v 'fm/batch-merge' \
  | sort -u | grep -c . || true)"

repo_name="$(basename "$REPO")"

printf '{"repo":"%s","ref":"%s","since":"%s","until":"%s","total_commits":%s,"ticket_landings":%s}\n' \
  "$repo_name" "$REF" "$SINCE" "$UNTIL" "$total_commits" "$ticket_landings"
