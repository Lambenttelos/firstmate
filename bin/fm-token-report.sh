#!/usr/bin/env bash
# fm-token-report.sh - token usage and cost reporting for jcode sessions.
#
# PR-T2 of the token-usage-visibility design of record
# (data/design-token-usage-visibility/report.md, sections "CLI design:
# bin/fm-token-report.sh" and "PR-T2"). Ships usable per-session, per-period,
# and time-bucketed cost visibility immediately, JOIN-FREE: there is no
# per-ticket rollup here (that is PR-T4, gated on the spawn session-id ledger).
#
# Read-only. Reads the jcode session store ($JCODE_SESSIONS_DIR, default
# ~/.jcode/sessions), derives cost through bin/fm-token-lib.sh, and writes
# nothing.
#
# ONE-OWNER-PER-CONTRACT (the reason for the architecture below): every dollar
# figure is produced by bin/fm-token-lib.sh, never by a formula in this file.
# Cost is linear in token counts for a fixed model, so this script:
#   1. aggregates RAW token sums per (time-bucket, model, provider, route) in
#      ONE bulk python pass over the store (fast: sub-second per thousand
#      sessions, versus a per-session shell call that spawns five subprocesses),
#   2. costs each aggregated group through the lib's fm_token_cost (the count of
#      lib calls is bounded by buckets x models, not by session count), and
#   3. SUMS those lib-produced costs per display group (pure addition, not
#      costing) to render.
# So the number is identical to what fm_token_sum_session/fm_token_cost render
# anywhere else, and --session routes straight through fm_token_sum_session for
# exact PR-T1 parity.
#
# Captain decisions bound into this tool (data/design-token-usage-visibility/
# decisions-d1-d2-d5.md, resolved 2026-08-17):
#   D1 cached-output = N/A: no cached-output field exists, none is emitted, no
#      fabricated zero. cache_creation_input_tokens is the cache-WRITE signal and
#      is counted (handled in the lib).
#   D2 price source = jcode's cached models.dev feed, authoritative for billing;
#      every output annotates price_source + price_cached_at (from the lib).
#   D5 time-bucket default = whole session by created_at, so a long session's
#      tokens land WHOLE in its START bucket; --precise buckets per assistant
#      message by messages[].timestamp for exact hourly. Day/week/month buckets
#      barely differ between the two; the difference only bites at --by hour.
#
# Standing captain constraints honored here:
#   - a real token count with no price is UNKNOWN (dollars withheld), never a
#     fake $0 (the lib returns an empty cost; this script carries those tokens in
#     a SEPARATE unknown-model bucket and never folds them into a dollar total);
#   - un-priced / ad-hoc / mock / test model sessions land in that same labeled
#     unknown bucket, never force-fit to a price;
#   - PR-T1 per-session math is exact, so nothing here is an ESTIMATE; the
#     cost_if_api_estimate=false key rides through unchanged for the downstream
#     estimate callers (PR-T4) that reuse it.
#   - this tool only READS the store and the price snapshot; it changes nothing
#     any producer records.
#
# All bucketing and the --period window are UTC, because the store's timestamps
# are UTC (ISO-8601 with a trailing Z). "sessions=" counts sessions with billed
# token activity in the bucket; a zero-token session contributes no cost and is
# not counted. Under --precise a session whose messages span buckets is counted
# once per bucket it actually contributed tokens to.
#
# Usage:
#   fm-token-report.sh --session <session_id>            one session: token
#                                                        totals + cost-if-API +
#                                                        subscription-covered flag
#   fm-token-report.sh --period <range>                  fleet rollup over a range
#   fm-token-report.sh --period <range> --by <unit>      time-bucketed trend,
#                                                        unit = hour|day|week|month
#   fm-token-report.sh --period <range> --by-model       group by model
#   fm-token-report.sh --period <range> --by-provider    group by provider
#   fm-token-report.sh ... --json                        stable machine output
#   fm-token-report.sh ... --precise                     per-message time
#                                                        bucketing (D5 option b)
#   fm-token-report.sh --help                            print this header
#
# --period <range> forms: all | today | Nd (e.g. 7d) | YYYY-MM-DD |
#   YYYY-MM-DD..YYYY-MM-DD (both ends inclusive by whole day).
# --by <time-unit> composes with --by-model / --by-provider (e.g.
#   --period 7d --by day --by-model = daily cost per model).
#
# Deliberately NOT implemented here (PR-T4, kept out so PR-T2 stays join-free):
# a <task-id> per-ticket rollup, --by-ticket, and --retro. The session ledger
# (data/token-sessions.tsv) join rides in PR-T4.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-token-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-token-lib.sh"

usage() {
  sed -n '2,84p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  echo "fm-token-report: $1" >&2
  exit "${2:-2}"
}

# --- argument parse ----------------------------------------------------------

MODE=""
SESSION_ID=""
PERIOD=""
BY_TIME=""
BY_DIM=""
JSON=0
PRECISE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --session)
      [ $# -ge 2 ] || die "--session needs a session id"
      [ -z "$MODE" ] || die "choose one of --session or --period, not both"
      MODE=session; SESSION_ID=$2; shift 2 ;;
    --session=*)
      [ -z "$MODE" ] || die "choose one of --session or --period, not both"
      MODE=session; SESSION_ID=${1#--session=}; shift ;;
    --period)
      [ $# -ge 2 ] || die "--period needs a range (all, today, Nd, a date, or date..date)"
      [ -z "$MODE" ] || die "choose one of --session or --period, not both"
      MODE=period; PERIOD=$2; shift 2 ;;
    --period=*)
      [ -z "$MODE" ] || die "choose one of --session or --period, not both"
      MODE=period; PERIOD=${1#--period=}; shift ;;
    --by)
      [ $# -ge 2 ] || die "--by needs a time unit (hour, day, week, or month)"
      BY_TIME=$2; shift 2 ;;
    --by=*)
      BY_TIME=${1#--by=}; shift ;;
    --by-model)
      [ -z "$BY_DIM" ] || die "choose one of --by-model or --by-provider, not both"
      BY_DIM=model; shift ;;
    --by-provider)
      [ -z "$BY_DIM" ] || die "choose one of --by-model or --by-provider, not both"
      BY_DIM=provider; shift ;;
    --json) JSON=1; shift ;;
    --precise) PRECISE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) die "unknown option '$1' (try --help)" ;;
    *) die "unexpected argument '$1' (try --help)" ;;
  esac
done

[ -n "$MODE" ] || die "nothing to report: pass --session <id> or --period <range> (try --help)"

case "$BY_TIME" in
  ""|hour|day|week|month) : ;;
  *) die "--by time unit must be hour, day, week, or month (got '$BY_TIME')" ;;
esac

if [ "$MODE" = session ]; then
  [ -z "$BY_TIME" ] && [ -z "$BY_DIM" ] && [ "$PRECISE" -eq 0 ] \
    || die "--by, --by-model, --by-provider, and --precise apply to --period, not --session"
fi

SESSIONS_DIR=${JCODE_SESSIONS_DIR:-$HOME/.jcode/sessions}
PRICE_FILE=$(fm_token_prices_path)
PRICE_SOURCE=$(fm_token_prices_field price_source "$PRICE_FILE" 2>/dev/null || true)
PRICE_CACHED=$(fm_token_prices_field cached_at "$PRICE_FILE" 2>/dev/null || true)

command -v python3 >/dev/null 2>&1 || die "python3 is required to parse the jcode session store" 3

# --- session mode ------------------------------------------------------------

resolve_session_path() {
  local want=$1 dir=$2
  FM_TR_SID="$want" FM_TR_DIR="$dir" python3 - <<'PY'
import glob, json, os, sys

want = os.environ["FM_TR_SID"]
sdir = os.environ["FM_TR_DIR"]
# A direct file path is accepted as-is so a caller can point at one file.
if os.path.isfile(want):
    sys.stdout.write(want)
    sys.exit(0)
for path in sorted(glob.glob(os.path.join(sdir, "session_*.json"))):
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        continue
    if data.get("id") == want:
        sys.stdout.write(path)
        sys.exit(0)
sys.exit(1)
PY
}

emit_session_json() {
  # Build the session object in python so the JSON is always valid and the cost
  # is a real number or null (never a fabricated 0 for an unpriced model).
  FM_TR_SID="$1" FM_TR_MODEL="$2" FM_TR_TI="$3" FM_TR_TO="$4" FM_TR_CR="$5" \
    FM_TR_CW="$6" FM_TR_COST="$7" FM_TR_COVERED="$8" FM_TR_PS="$9" \
    FM_TR_PC="${10}" python3 - <<'PY'
import json, os, sys

cost_raw = os.environ.get("FM_TR_COST", "")
cost = None
if cost_raw != "":
    try:
        cost = round(float(cost_raw), 6)
    except ValueError:
        cost = None
obj = {
    "mode": "session",
    "session": os.environ["FM_TR_SID"],
    "model": os.environ["FM_TR_MODEL"],
    "token_input": int(os.environ["FM_TR_TI"]),
    "token_output": int(os.environ["FM_TR_TO"]),
    "token_cache_read": int(os.environ["FM_TR_CR"]),
    "token_cache_write": int(os.environ["FM_TR_CW"]),
    "cost_if_api": cost,
    "cost_if_api_estimate": False,
    "subscription_covered": os.environ["FM_TR_COVERED"] == "true",
    "price_source": os.environ.get("FM_TR_PS", "") or None,
    "price_cached_at": os.environ.get("FM_TR_PC", "") or None,
}
json.dump(obj, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
PY
}

summary_val() { # <out> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | tail -n 1
}

do_session() {
  local path out model ti to cr cw cost covered
  path=$(resolve_session_path "$SESSION_ID" "$SESSIONS_DIR") \
    || die "session not found in $SESSIONS_DIR: $SESSION_ID" 1
  # Exact PR-T1 parity: the per-session numbers come straight from the lib.
  out=$(fm_token_sum_session "$path" "$PRICE_FILE") \
    || die "could not read session $SESSION_ID ($path)" 1
  model=$(summary_val "$out" model)
  ti=$(summary_val "$out" token_input)
  to=$(summary_val "$out" token_output)
  cr=$(summary_val "$out" token_cache_read)
  cw=$(summary_val "$out" token_cache_write)
  cost=$(summary_val "$out" cost_if_api)
  covered=$(summary_val "$out" subscription_covered)

  if [ "$JSON" -eq 1 ]; then
    emit_session_json "$SESSION_ID" "$model" "$ti" "$to" "$cr" "$cw" \
      "$cost" "$covered" "$PRICE_SOURCE" "$PRICE_CACHED"
    return 0
  fi

  local covered_label price_note
  if [ "$covered" = true ]; then covered_label="covered=yes(subscription)"; else covered_label="covered=no(API)"; fi
  if [ -n "$PRICE_SOURCE" ]; then price_note="[price $PRICE_SOURCE @$PRICE_CACHED]"; else price_note="[price UNKNOWN (no snapshot)]"; fi
  printf 'session %s  model=%s  %s\n' "$SESSION_ID" "$model" "$covered_label"
  printf '  input %s  output %s  cache_read %s  cache_write %s\n' \
    "$(commafy "$ti")" "$(commafy "$to")" "$(commafy "$cr")" "$(commafy "$cw")"
  if [ -n "$cost" ]; then
    printf '  cost_if_api $%s   %s\n' "$(printf '%.2f' "$cost")" "$price_note"
  else
    printf '  cost_if_api UNKNOWN (no price for model=%s)   %s\n' "$model" "$price_note"
  fi
}

# Thousands separators for a plain integer, portable (no locale dependency).
commafy() {
  printf '%s' "$1" | sed -e ':a' -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta'
}

# --- period mode -------------------------------------------------------------

# Pass A: one bulk parse of the store. Aggregates raw token sums per
# (bucket, model, provider, route) applying the --period window and the D5
# bucketing rule. Emits a leading "@period" line then TSV rows. No costing here.
aggregate_tokens() {
  FM_TR_DIR="$SESSIONS_DIR" FM_TR_PERIOD="$PERIOD" FM_TR_BYTIME="$BY_TIME" \
    FM_TR_PRECISE="$PRECISE" python3 - <<'PY'
import calendar
import glob
import json
import os
import re
import sys
import time
from datetime import datetime, timezone

sess_dir = os.environ["FM_TR_DIR"]
period = (os.environ.get("FM_TR_PERIOD", "all") or "all").strip()
bytime = os.environ.get("FM_TR_BYTIME", "").strip()
precise = os.environ.get("FM_TR_PRECISE", "") == "1"


def to_epoch(s):
    if s is None:
        return None
    s = str(s).strip()
    if not s:
        return None
    if re.fullmatch(r"\d+(\.\d+)?", s):
        return float(s)
    m = re.fullmatch(
        r"(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?Z?", s
    )
    if not m:
        return None
    y, mo, d, h, mi, se = (int(m.group(i)) for i in range(1, 7))
    frac = ((m.group(7) or "0") + "000000")[:6]
    return calendar.timegm((y, mo, d, h, mi, se, 0, 0, 0)) + int(frac) / 1_000_000.0


def day_floor(ep):
    dt = datetime.fromtimestamp(ep, tz=timezone.utc).replace(
        hour=0, minute=0, second=0, microsecond=0
    )
    return dt.timestamp()


now = time.time()
start = end = None
if period in ("all", ""):
    start = end = None
elif period == "today":
    start = day_floor(now)
    end = now
elif re.fullmatch(r"\d+d", period):
    n = int(period[:-1])
    if n < 1:
        sys.stderr.write("fm-token-report: --period Nd needs N>=1\n")
        sys.exit(2)
    start = day_floor(now) - (n - 1) * 86400
    end = now
elif re.fullmatch(r"\d{4}-\d{2}-\d{2}", period):
    st = to_epoch(period + "T00:00:00Z")
    if st is None:
        sys.stderr.write("fm-token-report: bad --period date: %s\n" % period)
        sys.exit(2)
    start, end = st, st + 86400
elif ".." in period:
    a, b = period.split("..", 1)
    start = to_epoch(a.strip() + "T00:00:00Z")
    e = to_epoch(b.strip() + "T00:00:00Z")
    if start is None or e is None:
        sys.stderr.write("fm-token-report: bad --period range: %s\n" % period)
        sys.exit(2)
    end = e + 86400
else:
    sys.stderr.write("fm-token-report: unrecognized --period '%s'\n" % period)
    sys.exit(2)


def in_range(ep):
    if start is not None and ep < start:
        return False
    if end is not None and ep >= end:
        return False
    return True


def bucket_of(ep):
    if not bytime:
        return "all"
    dt = datetime.fromtimestamp(ep, tz=timezone.utc)
    if bytime == "hour":
        return dt.strftime("%Y-%m-%dT%H")
    if bytime == "day":
        return dt.strftime("%Y-%m-%d")
    if bytime == "week":
        return dt.strftime("%G-W%V")
    if bytime == "month":
        return dt.strftime("%Y-%m")
    sys.stderr.write("fm-token-report: bad --by time unit '%s'\n" % bytime)
    sys.exit(2)


agg = {}


def add(key, ti, to, cr, cw, sid):
    row = agg.get(key)
    if row is None:
        row = [0, 0, 0, 0, set()]
        agg[key] = row
    row[0] += ti
    row[1] += to
    row[2] += cr
    row[3] += cw
    row[4].add(sid)


for path in glob.glob(os.path.join(sess_dir, "session_*.json")):
    try:
        with open(path) as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        continue
    sid = d.get("id") or os.path.basename(path)
    model = str(d.get("model") or "unknown")
    provider = str(d.get("provider_key") or "None")
    route = str(d.get("route_api_method") or "None")
    created = to_epoch(d.get("created_at"))
    msgs = d.get("messages") or []
    if precise:
        # Per-message attribution (D5 option b): each assistant message's tokens
        # land in the bucket of its own timestamp, so a long session SPLITS.
        for m in msgs:
            if m.get("role") != "assistant":
                continue
            tu = m.get("token_usage")
            if not isinstance(tu, dict):
                continue
            ts = to_epoch(m.get("timestamp"))
            if ts is None:
                ts = created
            if ts is None or not in_range(ts):
                continue
            add(
                (bucket_of(ts), model, provider, route),
                int(tu.get("input_tokens", 0) or 0),
                int(tu.get("output_tokens", 0) or 0),
                int(tu.get("cache_read_input_tokens", 0) or 0),
                int(tu.get("cache_creation_input_tokens", 0) or 0),
                sid,
            )
    else:
        # Whole-session attribution by created_at (D5 default): every token lands
        # WHOLE in the session's START bucket.
        if created is None or not in_range(created):
            continue
        ti = to = cr = cw = 0
        for m in msgs:
            if m.get("role") != "assistant":
                continue
            tu = m.get("token_usage")
            if not isinstance(tu, dict):
                continue
            ti += int(tu.get("input_tokens", 0) or 0)
            to += int(tu.get("output_tokens", 0) or 0)
            cr += int(tu.get("cache_read_input_tokens", 0) or 0)
            cw += int(tu.get("cache_creation_input_tokens", 0) or 0)
        if ti or to or cr or cw:
            add((bucket_of(created), model, provider, route), ti, to, cr, cw, sid)


def iso(ep):
    if ep is None:
        return ""
    return datetime.fromtimestamp(ep, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


sys.stdout.write("@period\t%s\t%s\t%s\n" % (period, iso(start), iso(end)))
for (b, model, provider, route), row in agg.items():
    sys.stdout.write(
        "\t".join(
            [
                b,
                model,
                provider,
                route,
                str(len(row[4])),
                str(row[0]),
                str(row[1]),
                str(row[2]),
                str(row[3]),
            ]
        )
        + "\n"
    )
PY
}

# Pass B: render. Reads the COSTED rows from the file named by $FM_TR_COSTED
# (each carrying a lib-produced cost or an empty cost for an unpriced model) and
# only SUMS them per display group. No costing formula lives here. The rows come
# from a file rather than stdin because python's own script is fed on stdin by
# the heredoc below, so stdin is already consumed.
render_period() {
  local costed_file=$1
  FM_TR_COSTED="$costed_file" FM_TR_BYTIME="$BY_TIME" FM_TR_BYDIM="$BY_DIM" \
    FM_TR_JSON="$JSON" FM_TR_PRECISE="$PRECISE" FM_TR_PERIOD="$PERIOD" \
    FM_TR_START="$PERIOD_START" FM_TR_END="$PERIOD_END" FM_TR_PS="$PRICE_SOURCE" \
    FM_TR_PC="$PRICE_CACHED" python3 - <<'PY'
import json
import os
import sys

bytime = os.environ.get("FM_TR_BYTIME", "")
bydim = os.environ.get("FM_TR_BYDIM", "")
as_json = os.environ.get("FM_TR_JSON", "") == "1"
precise = os.environ.get("FM_TR_PRECISE", "") == "1"
period = os.environ.get("FM_TR_PERIOD", "")
start = os.environ.get("FM_TR_START", "")
end = os.environ.get("FM_TR_END", "")
price_source = os.environ.get("FM_TR_PS", "")
price_cached = os.environ.get("FM_TR_PC", "")


def blank():
    return {
        "sessions": 0,
        "cost": 0.0,
        "covered": 0.0,
        "billed": 0.0,
        "has_priced": False,
        "unk_tokens": 0,
        "unk_models": set(),
        "ti": 0,
        "to": 0,
        "cr": 0,
        "cw": 0,
    }


groups = {}
with open(os.environ["FM_TR_COSTED"]) as _fh:
    costed_lines = _fh.readlines()
for line in costed_lines:
    line = line.rstrip("\n")
    if not line:
        continue
    parts = line.split("\t")
    if len(parts) != 10:
        continue
    bucket, model, provider, covered, sessions, cost, ti, to, cr, cw = parts
    dim = model if bydim == "model" else (provider if bydim == "provider" else "")
    key = (bucket, dim)
    g = groups.get(key)
    if g is None:
        g = blank()
        groups[key] = g
    g["sessions"] += int(sessions)
    g["ti"] += int(ti)
    g["to"] += int(to)
    g["cr"] += int(cr)
    g["cw"] += int(cw)
    if cost != "":
        c = float(cost)
        g["cost"] += c
        g["has_priced"] = True
        if covered == "true":
            g["covered"] += c
        else:
            g["billed"] += c
    else:
        g["unk_tokens"] += int(ti) + int(to) + int(cr) + int(cw)
        g["unk_models"].add(model)

# Grand totals across every row (exact when not --precise; under --precise a
# session active in several buckets is counted once per bucket, so the session
# total is an activity count, noted in the label).
total = blank()
for g in groups.values():
    for k in ("sessions", "cost", "covered", "billed", "unk_tokens", "ti", "to", "cr", "cw"):
        total[k] += g[k]
    total["has_priced"] = total["has_priced"] or g["has_priced"]
    total["unk_models"] |= g["unk_models"]

# Sort: by bucket ascending (chronological for every time unit), then by cost
# descending within a bucket, then dimension name for determinism.
sorted_keys = sorted(
    groups.keys(), key=lambda k: (k[0], -groups[k]["cost"], k[1])
)


def commafy(n):
    return "{:,}".format(int(n))


def money(x):
    return "{:.2f}".format(x)


if as_json:
    rows = []
    for (bucket, dim) in sorted_keys:
        g = groups[(bucket, dim)]
        rows.append(
            {
                "bucket": bucket if bytime else None,
                "dimension": dim if bydim else None,
                "sessions": g["sessions"],
                "token_input": g["ti"],
                "token_output": g["to"],
                "token_cache_read": g["cr"],
                "token_cache_write": g["cw"],
                "cost_if_api": round(g["cost"], 6) if g["has_priced"] else None,
                "cost_if_api_covered": round(g["covered"], 6),
                "cost_if_api_billed": round(g["billed"], 6),
                "cost_if_api_estimate": False,
                "unknown_model_tokens": g["unk_tokens"],
                "unknown_models": sorted(g["unk_models"]),
            }
        )
    obj = {
        "mode": "period",
        "period": {"spec": period, "start": start or None, "end": end or None},
        "by_time": bytime or None,
        "by_dimension": bydim or None,
        "precise": precise,
        "price_source": price_source or None,
        "price_cached_at": price_cached or None,
        "rows": rows,
        "totals": {
            "sessions": total["sessions"],
            "token_input": total["ti"],
            "token_output": total["to"],
            "token_cache_read": total["cr"],
            "token_cache_write": total["cw"],
            "cost_if_api": round(total["cost"], 6) if total["has_priced"] else None,
            "cost_if_api_covered": round(total["covered"], 6),
            "cost_if_api_billed": round(total["billed"], 6),
            "cost_if_api_estimate": False,
            "unknown_model_tokens": total["unk_tokens"],
            "unknown_models": sorted(total["unk_models"]),
        },
    }
    json.dump(obj, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    sys.exit(0)

# Human (caveman, aligned).
win = period
if start or end:
    win = "%s [%s..%s]" % (period, start or "-", end or "-")
src = ("%s @%s" % (price_source, price_cached)) if price_source else "UNKNOWN (no snapshot)"
sys.stdout.write("period %s  price %s\n" % (win, src))


def render_row(label, g):
    unk_tail = ""
    if g["unk_tokens"] > 0:
        models = ",".join(sorted(g["unk_models"]))
        unk_tail = "  [unknown-model tokens %s | %s]" % (commafy(g["unk_tokens"]), models)
    if g["has_priced"]:
        return "%s  sessions=%d  cost_if_api $%s  covered $%s / api $%s%s" % (
            label,
            g["sessions"],
            money(g["cost"]),
            money(g["covered"]),
            money(g["billed"]),
            unk_tail,
        )
    # No priced tokens at all: withhold dollars, show the tokens (never $0).
    return "%s  sessions=%d  cost_if_api UNKNOWN (no price)  tokens %s%s" % (
        label,
        g["sessions"],
        commafy(g["ti"] + g["to"] + g["cr"] + g["cw"]),
        unk_tail,
    )


for (bucket, dim) in sorted_keys:
    parts = []
    if bytime:
        parts.append(bucket)
    if bydim:
        parts.append("%s=%s" % (bydim, dim))
    label = "  ".join(parts) if parts else ("period %s" % period)
    sys.stdout.write(render_row(label, groups[(bucket, dim)]) + "\n")

if len(sorted_keys) > 1:
    tlabel = "total (session count is per-bucket activity)" if precise else "total"
    sys.stdout.write(render_row(tlabel, total) + "\n")
PY
}

do_period() {
  local agg_tmp costed_tmp
  agg_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-token-report.aggXXXXXX")
  costed_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-token-report.costXXXXXX")
  trap 'rm -f "$agg_tmp" "$costed_tmp"' RETURN

  aggregate_tokens > "$agg_tmp"

  # First line is the resolved period window: "@period <spec> <start> <end>".
  # The spec field is re-derived from $PERIOD in render, so it is discarded here.
  local _tag _spec PERIOD_START PERIOD_END
  IFS=$'\t' read -r _tag _spec PERIOD_START PERIOD_END < "$agg_tmp"
  [ "$_tag" = "@period" ] || die "internal: aggregate output missing period header" 3

  # Cost each aggregated group through the lib. covered is a pure-bash lib rule
  # (memoized per provider+route pair); price presence is memoized per model so
  # an unpriced model never spawns a cost call. fm_token_cost is the ONLY place
  # a dollar figure is computed.
  local -A COVERED_CACHE=()
  local -A PRICED_CACHE=()
  local b model provider route sessions ti to cr cw cov cost pkey ckey

  # tail -n +2 drops the @period header; the loop runs in this shell so the
  # memo caches persist across rows.
  while IFS=$'\t' read -r b model provider route sessions ti to cr cw; do
    [ -n "$b" ] || continue
    pkey="$provider|$route"
    if [ -z "${COVERED_CACHE[$pkey]+x}" ]; then
      COVERED_CACHE[$pkey]=$(fm_token_subscription_covered "$provider" "$route")
    fi
    cov=${COVERED_CACHE[$pkey]}

    ckey=$model
    if [ -z "${PRICED_CACHE[$ckey]+x}" ]; then
      if fm_token_model_price "$model" "$PRICE_FILE" >/dev/null 2>&1; then
        PRICED_CACHE[$ckey]=1
      else
        PRICED_CACHE[$ckey]=0
      fi
    fi

    cost=""
    if [ "${PRICED_CACHE[$ckey]}" = 1 ]; then
      cost=$(fm_token_cost "$ti" "$to" "$cr" "$cw" "$model" "$PRICE_FILE") || cost=""
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$b" "$model" "$provider" "$cov" "$sessions" "$cost" "$ti" "$to" "$cr" "$cw"
  done < <(tail -n +2 "$agg_tmp") > "$costed_tmp"

  render_period "$costed_tmp"
}

# --- dispatch ----------------------------------------------------------------

if [ "$MODE" = session ]; then
  do_session
else
  do_period
fi
