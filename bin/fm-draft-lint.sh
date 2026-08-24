#!/usr/bin/env bash
# fm-draft-lint.sh - validate a support-desk draft-replies.md against the LOCKED template.
#
# Spec (corr=f4e2569e29918563, /tmp/draft-lint-brief.txt). Per numbered entry checks:
#   1. header: "## [N] title" line immediately followed by
#      "MM: <https url>  .  Category: <bug-fixed|data-repaired|answered|wont-do|needs-info>"
#      with NO "Ticket:" field and NO "Author:" field in the header.
#   2. entry has "### REVIEW CONTEXT" then "### DRAFT REPLY", in that order.
#   3. DRAFT REPLY carries the required lines: Symptom:, Root cause:, Fix:, Data:,
#      Going forward:. The Fix line, WHEN it asserts a deployed fix (contains
#      "deployed to prod" or "on prod by"), must contain a full https URL AND
#      "by <author>" AND "CDT". The Data line must contain "CDT" or one of the two
#      no-repair phrases ("no records needed correction" / "repair pending").
#   4. no bare PR number like "PR 2420" without an adjacent https URL, anywhere in
#      the DRAFT REPLY block.
#   5. a "Suggested reply to" line, when present, addresses one of
#      merchant|partner|rep|customer|user or a Proper Name (Capitalized word).
#
# Output: one "entry [N]: <problem>" line per violation; exit 1 if any; else a summary
# and exit 0. Plain bash + grep/awk, no external deps.
#
# Usage: bin/fm-draft-lint.sh [path/to/draft-replies.md]
#   default path: data/mm-devsupport-triage/draft-replies.md

set -u

FILE="${1:-data/mm-devsupport-triage/draft-replies.md}"
if [[ ! -f "$FILE" ]]; then
  echo "fm-draft-lint: file not found: $FILE" >&2
  exit 2
fi

# Split the file into per-entry blocks on "## [" and validate each with awk, so multi-line
# structure is easy to reason about. awk prints "entry [N]: <problem>" lines and a final
# "VIOLATIONS=<n> ENTRIES=<m>" summary line we parse below.
awk '
function flush(  hdr, isdeploy) {
  if (id == "") return
  entries++

  # --- 1. header ---
  # title line already captured as id/title; header line must be the MM: line stored in hdrline
  hdr = hdrline
  if (hdr !~ /^MM:[[:space:]]/) {
    viol++; print "entry [" id "]: missing MM: header line"
  } else {
    if (hdr !~ /https?:\/\//) { viol++; print "entry [" id "]: header MM has no https permalink" }
    if (hdr ~ /Ticket:/)      { viol++; print "entry [" id "]: header still carries a Ticket field" }
    if (hdr ~ /Author:/)      { viol++; print "entry [" id "]: header still carries an Author field" }
    if (hdr !~ /Category:[[:space:]]*(bug-fixed|data-repaired|answered|wont-do|needs-info)([[:space:]]|$)/) {
      viol++; print "entry [" id "]: header Category missing or not one of the allowed values"
    }
  }

  # --- 2. section presence and order ---
  if (rcpos == 0) { viol++; print "entry [" id "]: missing ### REVIEW CONTEXT" }
  if (drpos == 0) { viol++; print "entry [" id "]: missing ### DRAFT REPLY" }
  if (rcpos > 0 && drpos > 0 && rcpos > drpos) {
    viol++; print "entry [" id "]: REVIEW CONTEXT appears after DRAFT REPLY"
  }

  # --- 3. required DRAFT REPLY lines ---
  if (drpos > 0) {
    if (!seen_sym)  { viol++; print "entry [" id "]: DRAFT REPLY missing Symptom: line" }
    if (!seen_root) { viol++; print "entry [" id "]: DRAFT REPLY missing Root cause: line" }
    if (!seen_fix)  { viol++; print "entry [" id "]: DRAFT REPLY missing Fix: line" }
    if (!seen_data) { viol++; print "entry [" id "]: DRAFT REPLY missing Data: line" }
    if (!seen_going){ viol++; print "entry [" id "]: DRAFT REPLY missing Going forward: line" }

    # Fix line quality - only enforce URL/by/CDT when it asserts a deployed fix
    if (seen_fix) {
      isdeploy = (fixline ~ /deployed to prod/ || fixline ~ /on prod by/)
      if (isdeploy) {
        if (fixline !~ /https?:\/\//) { viol++; print "entry [" id "]: Fix asserts a deploy but has no https URL" }
        if (fixline !~ /[[:space:]]by[[:space:]]/) { viol++; print "entry [" id "]: Fix asserts a deploy but has no by <author>" }
        if (fixline !~ /CDT/) { viol++; print "entry [" id "]: Fix asserts a deploy but has no CDT datetime" }
      }
    }

    # Data line - must carry a CDT datetime, OR a recognized no-completed-repair phrase
    # (pending / not run / scan needed, case-insensitive), OR an explicit repair-ran
    # marker for an in-thread manual fix whose exact clock time was never recorded
    # (RUN in-thread / done in-thread / fixed ... in-thread / data-side fix). We do not
    # require a CDT on those because the source never captured a time and the never-invent
    # rule forbids fabricating one.
    if (seen_data) {
      dl = tolower(dataline)
      ok = 0
      if (dataline ~ /CDT/) ok = 1
      else if (dl ~ /no records needed correction/) ok = 1
      else if (dl ~ /pending/) ok = 1
      else if (dl ~ /not run/) ok = 1
      else if (dl ~ /scan needed/) ok = 1
      else if (dl ~ /no retroactive cleanup/) ok = 1
      else if (dl ~ /in-thread/) ok = 1
      else if (dl ~ /done in-thread/ || dl ~ /run in-thread/) ok = 1
      else if (dl ~ /data-side fix/) ok = 1
      if (!ok) {
        viol++; print "entry [" id "]: Data line has neither a CDT datetime, a no-repair/pending phrase, nor an in-thread repair marker"
      }
    }
  }

  # --- 4. bare PR numbers in DRAFT REPLY ---
  if (barepr) { viol++; print "entry [" id "]: DRAFT REPLY has a bare PR number without an adjacent https URL" }

  # --- 4b. no UTC datetime anywhere in the DRAFT REPLY (all datetimes must be CDT) ---
  if (utc) { viol++; print "entry [" id "]: DRAFT REPLY carries a UTC datetime (Z/+0000); all datetimes must be CDT" }

  # --- 5. Suggested reply addressee ---
  if (sugg != "") {
    if (sugg !~ /Suggested reply to (merchant|partner|rep|customer|user|[A-Z][A-Za-z]+)/) {
      viol++; print "entry [" id "]: Suggested reply addressee is not merchant/partner/rep/customer/user or a proper name"
    }
  }
}

# entry boundary: "## [N] title" (numbered only; skip "## [planning]")
/^## \[/ {
  flush()
  # reset state
  id=""; title=""; hdrline=""; rcpos=0; drpos=0; pos=0
  seen_sym=0; seen_root=0; seen_fix=0; seen_data=0; seen_going=0
  fixline=""; dataline=""; sugg=""; indraft=0; barepr=0; expect_hdr=0; utc=0
  # extract numeric id from "## [N]" without gawk 3-arg match (mawk-safe)
  hdr0=$0
  if (hdr0 ~ /^## \[[0-9]+\]/) {
    tmp=hdr0
    sub(/^## \[/, "", tmp)      # -> "N] title"
    nid=tmp
    sub(/\].*$/, "", nid)       # -> "N"
    id=nid; expect_hdr=1
  }
  next
}

{
  if (id=="") next
  pos++
  # first non-blank line after the title is the header MM line
  if (expect_hdr && $0 ~ /[^[:space:]]/) {
    hdrline=$0; expect_hdr=0
  }
  if ($0 ~ /^### REVIEW CONTEXT/) rcpos=pos
  if ($0 ~ /^### DRAFT REPLY/)   { drpos=pos; indraft=1 }
  if (indraft) {
    if ($0 ~ /^Symptom:/)       seen_sym=1
    if ($0 ~ /^Root cause:/)    seen_root=1
    if ($0 ~ /^Fix:/)         { seen_fix=1; fixline=$0 }
    if ($0 ~ /^Data:/)        { seen_data=1; dataline=$0 }
    if ($0 ~ /^Going forward:/) seen_going=1
    if ($0 ~ /^Suggested reply to/) sugg=$0
    # bare PR: "PR <4+ digits>" on a line that has NO bitbucket pull-requests URL.
    # mawk has no {4} interval, so match 4 explicit digits.
    if ($0 ~ /PR[s]?[ ]?#?[0-9][0-9][0-9][0-9]/ && $0 !~ /pull-requests\/[0-9]/) barepr=1
    # UTC datetime detection: ISO "...T##:##Z" (optionally with seconds) or "... +0000".
    if ($0 ~ /[0-9][0-9]:[0-9][0-9]Z/ || $0 ~ /[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z/ || $0 ~ /\+0000/ || $0 ~ /[0-9] UTC/) utc=1
  }
}

END { flush(); print "VIOLATIONS=" viol+0 " ENTRIES=" entries+0 }
' "$FILE" > /tmp/.fm-draft-lint.$$ 2>/dev/null

# separate violation lines from the summary
summary="$(grep -E '^VIOLATIONS=' /tmp/.fm-draft-lint.$$ | tail -1)"
grep -vE '^VIOLATIONS=' /tmp/.fm-draft-lint.$$
rm -f /tmp/.fm-draft-lint.$$

v="${summary#VIOLATIONS=}"; v="${v%% *}"
e="${summary##*ENTRIES=}"
if [[ "${v:-0}" -eq 0 ]]; then
  echo "fm-draft-lint: clean - $e entries validated, 0 violations"
  exit 0
else
  echo "fm-draft-lint: $v violation(s) across $e entries"
  exit 1
fi
