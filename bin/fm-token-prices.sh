#!/usr/bin/env bash
# fm-token-prices.sh - the single owner of firstmate's token-price snapshot.
#
# One owned file carries the per-model USD-per-Mtok price tables the coster
# (bin/fm-token-lib.sh) multiplies token usage against. Prices are NEVER
# hand-maintained, per the one-owner-per-contract rule: `--refresh` copies
# EVERY provider table out of jcode's live cached models.dev feed (the exact
# numbers jcode itself bills against, not only providers.anthropic) into the
# owned snapshot, and stamps a header that makes every price traceable from
# the file alone:
#   price_source            where the prices came from ("jcode-models-dev-cache")
#   cached_at_unix_secs     the SOURCE feed's own cache timestamp (epoch seconds)
#   cached_at               the same timestamp as ISO-8601 UTC
#   written_at_unix_secs    this snapshot's own written-at timestamp
#   written_at              the same as ISO-8601 UTC
#   providers               every provider table from the feed, kept in jcode's
#                           exact shape (provider -> model_id ->
#                           input/output/cache_read/cache_write _usd_per_mtok)
#                           so the refresh is a straight copy
#   prices                  the merged flat map: model ids present in EXACTLY
#                           ONE provider table. A model id that appears in two
#                           or more provider tables is ambiguous and is EXCLUDED
#                           here on purpose: the lib must fail loudly on it, not
#                           guess which provider's price applies. The coster
#                           looks a model up by its session provider first and
#                           falls back to this unambiguous flat map only.
#
# Why snapshot rather than read the jcode cache live: the cache is jcode's
# private file (a different domain; it may move or clear), while firstmate owns
# a stable, auditable, testable copy and `--refresh` is the one deliberate sync
# point. A wrong price stays traceable to its source and date from the file
# alone, which is the captain constraint this header serves.
#
# Snapshot location: $FM_TOKEN_PRICES when set, else <repo-root>/config/
# token-prices.json. source cache: $FM_TOKEN_PRICES_SOURCE when set, else
# $HOME/.jcode/cache/models_dev_pricing.json. Both default paths live here and
# in the lib header; the file is tracked shared material under config/ (the
# data/ tree is captain-private and gitignored as a whole, so the tracked,
# seedable snapshot lives in config/ per the design's stated alternative).
#
# Usage:
#   fm-token-prices.sh --refresh   re-snapshot from the jcode cache and write
#   fm-token-prices.sh             print the current snapshot (or a clear
#                                  "not yet refreshed" message, never a guess)
#   fm-token-prices.sh --help      print this header
#
# Failure modes (fail-closed, never a guessed price): a missing or unreadable
# source cache exits non-zero with a clear message and writes nothing; a source
# cache with no providers table does the same; a bare call with no snapshot yet
# exits non-zero telling the caller to run --refresh.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SNAPSHOT="${FM_TOKEN_PRICES:-$FM_ROOT/config/token-prices.json}"
SOURCE="${FM_TOKEN_PRICES_SOURCE:-$HOME/.jcode/cache/models_dev_pricing.json}"

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

refresh() {
  command -v python3 >/dev/null 2>&1 \
    || { echo "fm-token-prices: --refresh needs python3 (not found on PATH)" >&2; return 1; }
  FM_TOK_SOURCE="$SOURCE" FM_TOK_SNAPSHOT="$SNAPSHOT" python3 - <<'PY'
import json, os, sys, time
from datetime import datetime, timezone

source = os.environ["FM_TOK_SOURCE"]
snapshot = os.environ["FM_TOK_SNAPSHOT"]


def epoch_iso(secs):
    return datetime.fromtimestamp(secs, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


try:
    with open(source) as fh:
        feed = json.load(fh)
except OSError as exc:
    print("fm-token-prices: --refresh source cache not found: %s (%s)" % (source, exc), file=sys.stderr)
    sys.exit(3)
except ValueError as exc:
    print("fm-token-prices: --refresh source cache is not valid JSON: %s (%s)" % (source, exc), file=sys.stderr)
    sys.exit(3)

providers = feed.get("providers") or {}
if not isinstance(providers, dict) or not providers:
    print("fm-token-prices: --refresh source cache has no providers table: %s" % source, file=sys.stderr)
    sys.exit(3)

# Flat merged map = model ids present in EXACTLY ONE provider table. A model id
# in two or more tables is ambiguous (the same name bills differently per
# provider), so it is left OUT of the flat map and the lib fails loudly on it
# instead of guessing; provider-scoped lookups still cost it exactly.
counts = {}
for table in providers.values():
    if not isinstance(table, dict):
        continue
    for model_id in table:
        counts[model_id] = counts.get(model_id, 0) + 1
flat = {}
for model_id, n in counts.items():
    if n != 1:
        continue
    for table in providers.values():
        if isinstance(table, dict) and model_id in table:
            flat[model_id] = table[model_id]
            break

raw_cached = feed.get("cached_at_unix_secs")
cached_at = epoch_iso(raw_cached) if isinstance(raw_cached, (int, float)) else None
now = int(time.time())
out = {
    "price_source": "jcode-models-dev-cache",
    "cached_at_unix_secs": raw_cached,
    "cached_at": cached_at,
    "written_at_unix_secs": now,
    "written_at": epoch_iso(now),
    "providers": providers,
    "prices": flat,
}

os.makedirs(os.path.dirname(snapshot) or ".", exist_ok=True)
tmp = "%s.tmp%s" % (snapshot, os.getpid())
try:
    with open(tmp, "w") as fh:
        json.dump(out, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, snapshot)
except OSError as exc:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    print("fm-token-prices: --refresh could not write snapshot: %s (%s)" % (snapshot, exc), file=sys.stderr)
    sys.exit(3)

print("fm-token-prices: snapshot written: %s (%d providers, %d models, %d unambiguous in flat map, cached_at %s)" % (
    snapshot, len(providers), sum(len(t) for t in providers.values() if isinstance(t, dict)), len(flat), cached_at or "unknown"))
PY
}

case "${1:-}" in
  --refresh)
    refresh
    ;;
  -h|--help)
    usage
    ;;
  "")
    if [ -f "$SNAPSHOT" ]; then
      cat "$SNAPSHOT"
    else
      echo "fm-token-prices: not yet refreshed - no snapshot at $SNAPSHOT; run 'bin/fm-token-prices.sh --refresh' to create it (never invents prices)." >&2
      exit 4
    fi
    ;;
  *)
    echo "fm-token-prices: unknown argument '$1' (use --refresh, --help, or no argument)" >&2
    usage >&2
    exit 2
    ;;
esac
