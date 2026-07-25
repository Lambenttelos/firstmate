#!/usr/bin/env bash
# fm-memory-report.sh - answer "what is actually eating this machine's memory,
# and who owns it" accurately and the SAME way every time.
#
# Invoked MANUALLY, on request, like bin/fm-desk-refresh.sh. No daemon, no
# watcher wiring, no schedule. It is READ-ONLY over the system and the fleet: it
# kills nothing, stops nothing, and shortens no work.
#
# Usage:
#   fm-memory-report.sh              compact ranking, owner groups, reclaim list
#   fm-memory-report.sh --all        every process, not just the top slice
#   fm-memory-report.sh --limit N    show N processes in the ranking (default 20)
#   fm-memory-report.sh --tree       group every process under its owner
#   fm-memory-report.sh --json       machine-readable form for other scripts
#   fm-memory-report.sh --verify     cross-check the reading against footprint(1)
#   fm-memory-report.sh --help
#
# Exit status:
#   0  a reading was taken and reported
#   1  a required input could not be collected at all
#   3  REFUSED - the instrument is broken (see SELF-CHECK); no table was printed
#   64 usage error
#
# NEVER WAKES. This script must never call bin/fm-wake-lib.sh, fm_wake_append,
# bin/fm-send.sh, or append to a status file - the same contract
# bin/fm-desk-refresh.sh documents. Taking a reading is not captain-facing
# progress (AGENTS.md section 8), so it reports to its caller and interrupts
# nobody.
#
# NOT bin/fm-resource-check.sh. That script answers a different question - host
# pressure and the concurrent-agent ceiling - and other code depends on its
# contract. This script never calls it and never changes it.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS - four traps this tool makes impossible by construction
#
# On 2026-07-24 the same question was answered wrong three times on a machine at
# 86% swap while two lanes sat parked waiting for memory. Each wrong answer was a
# distinct reproducible trap, and each maps to a defense below.
#
# 1. A FILTERED PROCESS TABLE WAS REPORTED AS TRUTH. `ps -Ao rss,command | sort`
#    returned only system daemons topping out at 24 MB on a 16 GB machine that
#    was swapping hard. That is impossible, and it was reported anyway.
#    This is NOT hypothetical: while building this script, the very first
#    `ps -Ao pid= | wc -l` on this machine returned 31 - against 649-652 across
#    the next 40 samples. ps really does occasionally return a truncated table.
#    DEFENSE: SELF-CHECK below refuses (exit 3) rather than print a figure it
#    cannot stand behind.
#
# 2. THE FLEET WAS EXCLUDED BY ACCIDENT. Filtering on processes named `node`
#    missed every agent, because agents run as `claude` - and in top's COMMAND
#    column a claude agent shows as its version string ("2.1.219"), not as
#    "claude" at all. The conclusion "it's the editor, not the fleet" followed
#    directly from that hole.
#    DEFENSE: enumeration is UNFILTERED. Every process on the machine is ranked.
#    Name matching is used ONLY to LABEL a process that is already counted, never
#    to decide whether it counts.
#
# 3. TWO DIFFERENT QUANTITIES WERE COMPARED AS ONE. `rss` was read and compared
#    against Activity Monitor, which shows phys_footprint. Under heavy swap most
#    of a process's memory is compressed out of residency, so rss understates
#    badly AND unevenly - which produced the opposite wrong answer, "the agents
#    are the hogs".
#    DEFENSE: phys_footprint is the primary and sorting number everywhere. rss is
#    shown only beside it, always labelled, never as a substitute. --verify
#    re-checks the footprint reading against footprint(1) on demand.
#
# 4. OWNERSHIP WAS GUESSED INSTEAD OF READ. A worktree was called an orphan when
#    state/*.meta plainly recorded which live task owned it.
#    DEFENSE: ownership is resolved from durable records (state/*.meta,
#    data/secondmates.md) against each process's own working directory. "unowned"
#    means the records WERE read and none claimed it. A process whose facts could
#    not be read is "unclassified" - a separate bucket that never masquerades as
#    a finding.
#
# ---------------------------------------------------------------------------
# MEASUREMENT - why top(1) is the primary source
#
# Verified on this machine, 2026-07-24, macOS 24.6.0:
#   `top -l 1 -o mem -stats pid,mem` MEM column == `footprint -p <pid>` exactly
#   for 9 of 11 sampled processes; the 2 that differed by one unit were live
#   processes drifting between the two samples. That MEM column IS
#   phys_footprint, the same quantity Activity Monitor's Memory column shows.
# top is preferred over per-pid footprint(1) for two reasons:
#   - Cost: one 0.4s call covers the whole machine; footprint(1) costs ~0.03s per
#     pid, ~20s for 600 processes.
#   - Coverage: footprint(1) is DENIED on root-owned processes (WindowServer
#     returns nothing), so a footprint-only reading would silently drop the very
#     system processes a total has to include.
# footprint(1) remains the cross-check, wired to --verify.
#
# ---------------------------------------------------------------------------
# OWNERSHIP - records and working directory, never ancestry alone
#
# ANCESTRY LIES EXACTLY WHERE ATTRIBUTION MATTERS. When a process's spawner dies
# the kernel reparents it to launchd, so it reports ppid 1 - indistinguishable
# from a system daemon by ancestry alone. That is precisely how a live-task
# language server got misjudged as an orphan. Live proof on this machine while
# writing this: pid 67870 (ppid 1) sits in a no-mistakes worktree and pid 76895
# (ppid 1) sits in the firstmate home - both plainly owned, both reparented.
#
# So ownership is resolved in this order, and ancestry is never the first word:
#   1. The process's working directory (lsof -d cwd), longest-prefix matched
#      against paths read from durable records: state/*.meta `worktree=`,
#      `home=`, `tasktmp=`; data/secondmates.md `home:`; $FM_HOME; and the
#      project clones under $FM_HOME/projects. Recorded as via=cwd.
#   2. Only if the working directory is UNREADABLE, the parent's
#      already-cwd-derived owner may be inherited - and NEVER from ppid 1, which
#      is the reparented case above. Recorded as via=ancestry so a weaker
#      attribution is always visible as one.
#   3. Otherwise the process is system (by its own executable path), tooling,
#      unowned, or unclassified - see the bucket rules in classify_rows().
#
# pstree(1) was evaluated as an input and deliberately NOT used: on macOS it
# prints no memory column, and it reads the same `ps -axwwo user,pid,ppid,...`
# ancestry this script already collects, so it adds no fact - only a rendering of
# the one axis that lies. --tree groups by OWNER instead, which is the axis
# capacity decisions actually run on. Nothing here depends on pstree being
# installed.
#
# ---------------------------------------------------------------------------
# ROLLUP - the true cost of a worker
#
# An agent spawns its own language server, and on this fleet each costs about
# 1 GB, three to four times the agent process itself. A flat per-process ranking
# therefore UNDERSTATES what a worker really costs, which is the number capacity
# decisions depend on. Every owner group reports both its agent's own footprint
# and its total-with-children, rolled up by OWNERSHIP (working directory against
# the records), not by ancestry - so a language server whose parent editor was
# killed still rolls up to the task whose worktree it is indexing.
#
# RECLAIM classes make the cheap wins obvious: a process in a checkout no live
# record claims, a detached process whose spawner is gone, and editor/language
# tooling carrying no fleet work.
#
# ---------------------------------------------------------------------------
# SELF-CHECK - refuse loudly rather than print a confident wrong table
#
# A refusal IS the correct output when the instrument is broken. All of these
# must hold or the script exits 3 having printed no ranking:
#   - this script's own pid appears in BOTH the top and ps listings;
#   - at least MIN_PROCS processes were enumerated;
#   - the ps and top process counts agree within tolerance;
#   - top's PhysMem line parses;
#   - the summed footprint is a plausible fraction of PhysMem used.
#
# Test seams: FM_MEMREPORT_TOP and FM_MEMREPORT_PS read a captured listing from a
# file instead of running the tool, FM_MEMREPORT_LSOF likewise for working
# directories, and FM_MEMREPORT_SELF_PID overrides which pid the self-check
# requires to be present.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# Self-check thresholds. Deliberately generous: they exist to catch an
# obviously broken instrument (the 31-process reading), not to police normal
# sampling drift between two tools read a fraction of a second apart.
MIN_PROCS=${FM_MEMREPORT_MIN_PROCS:-50}
COUNT_TOLERANCE_PCT=30
# The summed footprint normally sits ABOVE used memory, because footprint counts
# compressed pages and charges shared regions to each process. Measured on this
# machine 2026-07-24: 111% across five consecutive samples, and 126% under
# heavier load. The floor is therefore one-sided and set at 60% - a 1.85x margin
# below the lowest reading actually observed, while still catching a listing that
# has lost most of the machine's memory.
FOOTPRINT_FLOOR_PCT=60

# The header comment IS the help text: every line from the description down to
# the first line of code. Derived rather than a hardcoded line range so the help
# cannot drift out of sync with the header it is quoting.
usage() {
  awk 'NR==1 { next } /^[^#]/ { exit } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

die() { printf 'fm-memory-report: %s\n' "$1" >&2; exit "${2:-1}"; }

# refuse <reason> <detail>...: the SELF-CHECK failure path. Prints what is wrong
# and exits 3 WITHOUT printing a ranking. Never soften this into a warning: a
# confident wrong table is the exact failure this script was built to end.
refuse() {
  local reason=$1
  shift
  {
    printf 'fm-memory-report: REFUSING to report - the reading is not trustworthy.\n'
    printf '  problem: %s\n' "$reason"
    local line
    for line in "$@"; do printf '  %s\n' "$line"; done
    printf '  No ranking was printed. A refusal is the correct output when the\n'
    printf '  instrument is broken; re-run to take a fresh reading.\n'
  } >&2
  exit 3
}

# --- argument parsing -------------------------------------------------------

mode=text
show_all=0
show_tree=0
verify=0
limit=20

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --all) show_all=1 ;;
    --tree) show_tree=1 ;;
    --json) mode=json ;;
    --verify) verify=1 ;;
    --limit)
      shift
      [ "$#" -gt 0 ] || die "--limit needs a number" 64
      case "$1" in ''|*[!0-9]*) die "--limit needs a number, got '$1'" 64 ;; esac
      limit=$1
      ;;
    *) die "unknown option '$1' (see --help)" 64 ;;
  esac
  shift
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-memory-report.XXXXXX") || die "cannot create a temp dir"
trap 'rm -rf "$TMP"' EXIT

SELF_PID=${FM_MEMREPORT_SELF_PID:-$$}

# --- collection -------------------------------------------------------------

# top(1) is the primary measurement: its MEM column is phys_footprint (see
# MEASUREMENT above). Captured whole so the header counters used by the
# self-check come from the SAME sample as the per-process numbers.
collect_top() {
  if [ -n "${FM_MEMREPORT_TOP:-}" ]; then
    [ -r "$FM_MEMREPORT_TOP" ] || die "FM_MEMREPORT_TOP is not readable: $FM_MEMREPORT_TOP"
    cat "$FM_MEMREPORT_TOP" > "$TMP/top.raw"
    return 0
  fi
  command -v top >/dev/null 2>&1 || die "top(1) not found; it is the primary memory source"
  top -l 1 -n 20000 -o mem -stats pid,mem > "$TMP/top.raw" 2>/dev/null || true
  [ -s "$TMP/top.raw" ] || die "top(1) produced no output"
}

collect_ps() {
  if [ -n "${FM_MEMREPORT_PS:-}" ]; then
    [ -r "$FM_MEMREPORT_PS" ] || die "FM_MEMREPORT_PS is not readable: $FM_MEMREPORT_PS"
    cat "$FM_MEMREPORT_PS" > "$TMP/ps.raw"
    return 0
  fi
  # No name filter and no head/sort: the full table, always. Trap 2 was a filter
  # deciding what counted.
  ps -Ao pid=,ppid=,rss=,user=,command= > "$TMP/ps.raw" 2>/dev/null || true
  [ -s "$TMP/ps.raw" ] || die "ps(1) produced no output"
}

# Working directories for every enumerated pid in ONE batched lsof call (~0.2s
# for 600 pids). A pid missing from the result is permission-denied, which is a
# fact about readability, not about ownership - it becomes via=none downstream.
collect_cwd() {
  : > "$TMP/cwd.tsv"
  if [ -n "${FM_MEMREPORT_LSOF:-}" ]; then
    [ -r "$FM_MEMREPORT_LSOF" ] || die "FM_MEMREPORT_LSOF is not readable: $FM_MEMREPORT_LSOF"
    cat "$FM_MEMREPORT_LSOF" > "$TMP/cwd.tsv"
    return 0
  fi
  command -v lsof >/dev/null 2>&1 || return 0
  local pidlist
  pidlist=$(cut -f1 "$TMP/top.tsv" | paste -sd, -)
  [ -n "$pidlist" ] || return 0
  lsof -a -d cwd -Fpn -p "$pidlist" 2>/dev/null \
    | awk '
        /^p/ { pid = substr($0, 2); next }
        /^n/ { if (pid != "") { printf "%s\t%s\n", pid, substr($0, 2); pid = "" } }
      ' > "$TMP/cwd.tsv" || true
}

# Parse top's per-process rows into pid<TAB>footprint_kb, and its header counters
# into top.vars. MEM carries a B/K/M/G/T suffix and may be fractional.
parse_top() {
  awk '
    function tokb(v,   u, n) {
      u = substr(v, length(v), 1)
      n = substr(v, 1, length(v) - 1) + 0
      if (u == "B") return n / 1024
      if (u == "K") return n
      if (u == "M") return n * 1024
      if (u == "G") return n * 1024 * 1024
      if (u == "T") return n * 1024 * 1024 * 1024
      return -1
    }
    NR == 1 && /^Processes:/ { procs = $2 }
    /^PhysMem:/ {
      # PhysMem: 14G used (2798M wired, 1823M compressor), 1731M unused.
      for (i = 1; i <= NF; i++) if ($i == "used") { used = tokb($(i - 1)); break }
    }
    /^PID/ { rows = 1; next }
    rows && NF >= 2 && $1 ~ /^[0-9]+$/ {
      kb = tokb($2)
      if (kb >= 0) { printf "%s\t%d\n", $1, kb > TSV; n++ }
    }
    END {
      printf "top_header_procs=%d\n", procs + 0 > VARS
      printf "top_rows=%d\n", n + 0 > VARS
      printf "physmem_used_kb=%d\n", used + 0 > VARS
    }
  ' TSV="$TMP/top.tsv" VARS="$TMP/top.vars" "$TMP/top.raw"
  [ -f "$TMP/top.tsv" ] || : > "$TMP/top.tsv"
  [ -f "$TMP/top.vars" ] || : > "$TMP/top.vars"
}

# ps rows into pid<TAB>ppid<TAB>rss_kb<TAB>user<TAB>command. The command is the
# rest of the line and may contain anything, including tabs, so it is
# whitespace-normalised into the final field.
parse_ps() {
  awk '
    $1 ~ /^[0-9]+$/ && NF >= 5 {
      pid = $1; ppid = $2; rss = $3; user = $4
      cmd = ""
      for (i = 5; i <= NF; i++) cmd = cmd (i > 5 ? " " : "") $i
      gsub(/\t/, " ", cmd)
      printf "%s\t%s\t%s\t%s\t%s\n", pid, ppid, rss, user, cmd
    }
  ' "$TMP/ps.raw" > "$TMP/ps.tsv"
}

# --- self-check -------------------------------------------------------------
#
# Every gate here exists because a real wrong answer got past its absence.

run_self_check() {
  local top_rows top_header physmem_used ps_count
  # shellcheck source=/dev/null
  . "$TMP/top.vars"
  top_rows=${top_rows:-0}
  top_header=${top_header_procs:-0}
  physmem_used=${physmem_used_kb:-0}
  ps_count=$(wc -l < "$TMP/ps.tsv" | tr -d ' ')

  [ "$top_rows" -gt 0 ] \
    || refuse "top(1) yielded no parseable process rows" \
              "the memory source produced a header but no measurements"

  [ "$ps_count" -gt 0 ] \
    || refuse "ps(1) yielded no parseable process rows" \
              "the identity source produced nothing to attribute"

  # Trap 1, exactly as observed: a table so small it cannot describe this machine.
  [ "$top_rows" -ge "$MIN_PROCS" ] \
    || refuse "the memory listing is implausibly short: $top_rows processes" \
              "a live machine always runs far more than $MIN_PROCS processes" \
              "this is the signature of a truncated or filtered process table"
  [ "$ps_count" -ge "$MIN_PROCS" ] \
    || refuse "the process listing is implausibly short: $ps_count processes" \
              "a live machine always runs far more than $MIN_PROCS processes" \
              "this is the signature of a truncated or filtered process table"

  # The tool's own pid must be in its own listing. Nothing can enumerate every
  # process while missing the one doing the asking.
  awk -F'\t' -v p="$SELF_PID" '$1 == p { found = 1 } END { exit !found }' "$TMP/top.tsv" \
    || refuse "this script's own pid ($SELF_PID) is absent from the memory listing" \
              "a listing that cannot see the process reading it is not complete"
  awk -F'\t' -v p="$SELF_PID" '$1 == p { found = 1 } END { exit !found }' "$TMP/ps.tsv" \
    || refuse "this script's own pid ($SELF_PID) is absent from the process listing" \
              "a listing that cannot see the process reading it is not complete"

  # The two independent enumerations must broadly agree. They are sampled a
  # fraction of a second apart and count slightly differently, hence 30%.
  if [ "$top_header" -gt 0 ]; then
    local diff allowed
    diff=$(( top_rows > top_header ? top_rows - top_header : top_header - top_rows ))
    allowed=$(( top_header * COUNT_TOLERANCE_PCT / 100 ))
    [ "$allowed" -ge 20 ] || allowed=20
    [ "$diff" -le "$allowed" ] \
      || refuse "the memory listing is truncated: $top_rows rows for $top_header processes" \
                "top reported $top_header processes but only $top_rows measurements survived"
  fi

  local diff2 allowed2
  diff2=$(( ps_count > top_rows ? ps_count - top_rows : top_rows - ps_count ))
  allowed2=$(( top_rows * COUNT_TOLERANCE_PCT / 100 ))
  [ "$allowed2" -ge 20 ] || allowed2=20
  [ "$diff2" -le "$allowed2" ] \
    || refuse "the two process listings disagree: ps says $ps_count, top says $top_rows" \
              "one of the two enumerations is filtered or truncated" \
              "attribution built on disagreeing listings would be arbitrary"

  [ "$physmem_used" -gt 0 ] \
    || refuse "top(1)'s PhysMem line did not parse" \
              "without the machine's real used memory there is nothing to sanity-check against"

  # Trap 1's decisive gate: 31 daemons topping out at 24 MB would sum to well
  # under 1% of used memory. Real readings run ABOVE used memory (footprint
  # counts compressed pages and shared regions per process; this machine
  # measured 17.6 GB summed against 14 GB used), so the floor is one-sided.
  local sum_kb floor_kb
  sum_kb=$(awk -F'\t' '{ s += $2 } END { printf "%d", s }' "$TMP/top.tsv")
  floor_kb=$(( physmem_used * FOOTPRINT_FLOOR_PCT / 100 ))
  [ "$sum_kb" -ge "$floor_kb" ] \
    || refuse "the measured total is impossibly small for this machine" \
              "summed footprint $(fmt_kb "$sum_kb") against $(fmt_kb "$physmem_used") of used memory" \
              "the listing is missing most of the machine's memory; it is filtered or truncated"

  SELF_PS_COUNT=$ps_count
  SELF_PHYSMEM_USED=$physmem_used
  SELF_FOOTPRINT_SUM=$sum_kb
}

# --- ownership records ------------------------------------------------------
#
# Every owner path here is READ from a durable record. Nothing is inferred from a
# path's shape, so "unowned" can mean "the records were read and none claimed
# it" rather than "I did not recognise this".

build_owners() {
  : > "$TMP/owners.tsv"
  local f id kind wt home tasktmp name

  # Secondmate registry first, so a secondmate home is labelled with its
  # registered name rather than its task id when both records name the path.
  if [ -r "$DATA/secondmates.md" ]; then
    while IFS=$'\t' read -r name home; do
      [ -n "$name" ] && [ -n "$home" ] || continue
      printf '%s\tsecondmate\t%s\n' "$home" "$name" >> "$TMP/owners.tsv"
    done < <(awk '
      /^- / {
        line = $0
        sub(/^- /, "", line)
        nm = line
        sub(/ - .*$/, "", nm)
        if (match(line, /home: [^;)]+/)) {
          h = substr(line, RSTART + 6, RLENGTH - 6)
          gsub(/^[ \t]+|[ \t]+$/, "", h)
          gsub(/^[ \t]+|[ \t]+$/, "", nm)
          if (nm != "" && h != "") printf "%s\t%s\n", nm, h
        }
      }
    ' "$DATA/secondmates.md")
  fi

  if [ -d "$STATE" ]; then
    for f in "$STATE"/*.meta; do
      [ -e "$f" ] || continue
      id=$(basename "$f" .meta)
      kind=$(awk -F= '/^kind=/ { print $2; exit }' "$f")
      wt=$(awk -F= '/^worktree=/ { print $2; exit }' "$f")
      home=$(awk -F= '/^home=/ { print $2; exit }' "$f")
      tasktmp=$(awk -F= '/^tasktmp=/ { print $2; exit }' "$f")
      local okind=task
      [ "$kind" = secondmate ] && okind=secondmate
      # NOTE: project= is deliberately NOT registered as an owner path. It is the
      # shared clone many tasks read from, so attributing it to whichever task
      # mentioned it last would be a guess - exactly trap 4.
      [ -n "$wt" ] && printf '%s\t%s\t%s\n' "$wt" "$okind" "$id" >> "$TMP/owners.tsv"
      [ -n "$home" ] && printf '%s\t%s\t%s\n' "$home" "$okind" "$id" >> "$TMP/owners.tsv"
      [ -n "$tasktmp" ] && printf '%s\t%s\t%s\n' "$tasktmp" "$okind" "$id" >> "$TMP/owners.tsv"
    done
  fi

  # The firstmate home itself, and each project clone under it. Longest-prefix
  # matching downstream keeps a clone from being swallowed by the home.
  printf '%s\tfirstmate\t%s\n' "$FM_HOME" "$(basename "$FM_HOME")" >> "$TMP/owners.tsv"
  if [ -d "$FM_HOME/projects" ]; then
    for f in "$FM_HOME"/projects/*; do
      [ -d "$f" ] || continue
      printf '%s\tproject\t%s\n' "$f" "$(basename "$f")" >> "$TMP/owners.tsv"
    done
  fi
}

# A working directory that is a git checkout but that NO record claims is the
# incident's "leftover indexing a throwaway worker copy". Testing for .git is a
# filesystem fact, not a guess about the path's shape.
build_git_cwds() {
  : > "$TMP/gitcwd.tsv"
  [ -s "$TMP/cwd.tsv" ] || return 0
  local c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    [ -e "$c/.git" ] && printf '%s\n' "$c" >> "$TMP/gitcwd.tsv"
  done < <(cut -f2 "$TMP/cwd.tsv" | sort -u)
}

# --- classification ---------------------------------------------------------

classify_rows() {
  awk -F'\t' '
    function basename(p,   n, a) { n = split(p, a, "/"); return a[n] }

    # kind is a LABEL applied to a process that is already counted. It never
    # decides whether a process appears - trap 2.
    function kind_of(cmd, user,   b, exe, i, a) {
      split(cmd, a, " ")
      exe = a[1]
      b = basename(exe)
      if (b ~ /^(claude|codex|opencode|grok)$/ || b == "pi") return "agent"
      if (cmd ~ /typescript-language-server|tsserver|\/tsgo|vtsls|rust-analyzer|gopls|pyright|pylsp|clangd|jdtls|lua-language-server|eslint_d|language-server/) return "lsp"
      if (exe ~ /^\/System\// || exe ~ /^\/usr\/libexec\// || exe ~ /^\/usr\/sbin\// || exe ~ /^\/sbin\// || exe ~ /^\/Library\/Apple\//) return "system"
      if (cmd ~ /Visual Studio Code|Code Helper|Cursor|Electron|Zed|Xcode|Sublime Text|JetBrains|Warp|iTerm/) return "editor"
      # A bundled app the captain is running is NOT an unowned leftover. Read
      # from the executable path, so Chrome and friends land in their own bucket
      # instead of inflating the leftover class the reclaim list acts on.
      if (exe ~ /^\/Applications\// || exe ~ /\/Applications\/[^\/]*\.app\// || exe ~ /\.app\/Contents\//) return "app"
      if (b ~ /^(node|npm|npx|bun|deno|python|python3|python3\.[0-9]+|ruby|java|cargo|go|rustc|tsc|vite|esbuild|webpack|jest|vitest|playwright|eslint|prettier)$/) return "tooling"
      if (cmd ~ /playwright|vitest|jest|next-server|webpack|esbuild/) return "tooling"
      if (b ~ /^(zsh|bash|sh|fish|tmux|screen|-zsh|login)$/ || b ~ /^-/) return "shell"
      if (user == "root" && exe ~ /^\/usr\//) return "system"
      return "other"
    }

    # Owner paths, longest prefix wins so a project clone beats the home above it.
    FILENAME == OWN {
      opath[++no] = $1; okind[no] = $2; olabel[no] = $3
      next
    }
    FILENAME == CWDF { cwd[$1] = $2; next }
    FILENAME == GITF { gitcwd[$0] = 1; next }
    FILENAME == TOPF { fp[$1] = $2; next }

    # ps rows arrive last: everything needed to classify is already loaded.
    FILENAME == PSF {
      pid = $1; ppid[$1] = $2; rss[$1] = $3; user[$1] = $4; cmd[$1] = $5
      pids[++np] = pid
      next
    }

    function match_owner(c,   i, best, bestlen, p) {
      best = 0; bestlen = -1
      if (c == "") return 0
      for (i = 1; i <= no; i++) {
        p = opath[i]
        if (p == "") continue
        if (c == p || index(c, p "/") == 1) {
          if (length(p) > bestlen) { bestlen = length(p); best = i }
        }
      }
      return best
    }

    END {
      # Pass 1: direct attribution from the working directory.
      for (i = 1; i <= np; i++) {
        p = pids[i]
        k[p] = kind_of(cmd[p], user[p])
        c = (p in cwd) ? cwd[p] : ""
        mi = match_owner(c)
        if (mi > 0) {
          okindof[p] = okind[mi]; olabelof[p] = olabel[mi]; via[p] = "cwd"
        } else {
          okindof[p] = ""; via[p] = (c == "") ? "none" : "unmatched"
        }
      }

      # Pass 2: ONLY where the working directory was unreadable may a parent
      # lend its cwd-derived owner - and never through ppid 1, the reparented
      # case that produced the original misjudgement.
      for (i = 1; i <= np; i++) {
        p = pids[i]
        if (okindof[p] != "" || via[p] != "none") continue
        pp = ppid[p]
        if (pp == "" || pp == "1" || pp == "0") continue
        if (pp in cwd && okindof[pp] != "" && via[pp] == "cwd") {
          okindof[p] = okindof[pp]; olabelof[p] = olabelof[pp]; via[p] = "ancestry"
        }
      }

      # Pass 3: buckets for everything the records did not claim, plus flags.
      for (i = 1; i <= np; i++) {
        p = pids[i]
        c = (p in cwd) ? cwd[p] : ""
        fl = ""
        # ppid 1 is only evidence of a LOST parent for things that are always
        # spawned by something else. launchd legitimately starts apps and system
        # daemons with ppid 1, so flagging those would manufacture 98 fake
        # findings - ancestry lying again, in the other direction.
        if (ppid[p] == "1" && (k[p] == "lsp" || k[p] == "tooling" || k[p] == "agent")) fl = "no-live-parent"
        unclaimed = (okindof[p] == "" && c != "" && (c in gitcwd))
        if (unclaimed) fl = fl (fl == "" ? "" : ",") "unclaimed-checkout"

        if (okindof[p] == "") {
          if (unclaimed) {
            # A leftover in a checkout nothing claims: the incident case.
            okindof[p] = "unowned"; olabelof[p] = "checkout no record claims"
          } else if (k[p] == "app") {
            okindof[p] = "app"; olabelof[p] = "user applications"; via[p] = "path"
          } else if (k[p] == "editor" || k[p] == "lsp" || k[p] == "tooling") {
            okindof[p] = "tooling"; olabelof[p] = "editor / language tooling"
          } else if (k[p] == "system") {
            okindof[p] = "system"; olabelof[p] = "macOS"; via[p] = "path"
          } else if (c != "") {
            okindof[p] = "unowned"; olabelof[p] = "no record claims it"
          } else {
            # Facts unreadable. NEVER a finding - a separate bucket entirely.
            okindof[p] = "unclassified"; olabelof[p] = "facts unreadable"
          }
        }
        if (fl == "") fl = "-"
        f = (p in fp) ? fp[p] : 0
        printf "%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
          p, ppid[p], f, rss[p], user[p], okindof[p], olabelof[p], via[p], k[p], fl, (c == "" ? "-" : c), cmd[p]
      }
    }
  ' OWN="$TMP/owners.tsv" CWDF="$TMP/cwd.tsv" GITF="$TMP/gitcwd.tsv" TOPF="$TMP/top.tsv" PSF="$TMP/ps.tsv" \
    "$TMP/owners.tsv" "$TMP/cwd.tsv" "$TMP/gitcwd.tsv" "$TMP/top.tsv" "$TMP/ps.tsv" \
    | sort -t$'\t' -k3,3nr > "$TMP/rows.tsv"
}

# --- formatting -------------------------------------------------------------

fmt_kb() {
  awk -v kb="$1" 'BEGIN {
    if (kb >= 1024 * 1024) printf "%.2f GB", kb / 1024 / 1024
    else if (kb >= 1024) printf "%.0f MB", kb / 1024
    else printf "%.0f KB", kb
  }'
}

host_line() {
  local total_b total_kb swap
  total_b=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
  total_kb=$(( total_b / 1024 ))
  swap=$(sysctl -n vm.swapusage 2>/dev/null | awk '
    { for (i = 1; i <= NF; i++) {
        if ($i == "total") t = $(i + 2)
        if ($i == "used") u = $(i + 2)
      }
      if (t != "") printf "swap %s used of %s", u, t
    }')
  printf 'Host: %s total | %s used | %s\n' \
    "$(fmt_kb "$total_kb")" "$(fmt_kb "$SELF_PHYSMEM_USED")" "${swap:-swap unknown}"
}

# --- rendering --------------------------------------------------------------

render_groups() {
  printf '\nBY OWNER - total with children, rolled up by ownership, not ancestry\n'
  awk -F'\t' '
    { key = $6 "\t" $7; tot[key] += $3; n[key]++
      if ($9 == "agent") { agent[key] += $3; agents[key]++ }
      if ($9 == "lsp") { lsp[key] += $3; lsps[key]++ }
      grand += $3
    }
    END {
      for (key in tot) printf "%d\t%s\t%d\t%d\t%d\t%d\t%d\n", tot[key], key, n[key], agent[key], agents[key], lsp[key], lsps[key]
      printf "%d\tGRAND\t\t0\t0\t0\t0\t0\n", grand
    }
  ' "$TMP/rows.tsv" | sort -t$'\t' -k1,1nr | while IFS=$'\t' read -r tot okind olabel n agent nagent lsp nlsp; do
    if [ "$okind" = GRAND ]; then continue; fi
    local extra=""
    if [ "${nagent:-0}" -gt 0 ]; then
      extra=" (agent itself $(fmt_kb "$agent")"
      if [ "${nlsp:-0}" -gt 0 ]; then
        extra="$extra + $nlsp language server$([ "$nlsp" -gt 1 ] && echo s) $(fmt_kb "$lsp")"
      fi
      extra="$extra)"
    elif [ "${nlsp:-0}" -gt 0 ]; then
      extra=" ($nlsp language server$([ "$nlsp" -gt 1 ] && echo s) $(fmt_kb "$lsp"))"
    fi
    printf '  %-12s %-34s %10s  %3d proc%s\n' "$okind" "$(printf '%.34s' "$olabel")" "$(fmt_kb "$tot")" "$n" "$extra"
  done
}

# The classes below are DISJOINT and every process falls in at most one, so the
# numbers can be added up without overstating the win. Overlapping buckets would
# be their own kind of confident wrong answer.
render_reclaim() {
  printf '\nRECLAIMABLE - memory carrying no live fleet work (classes do not overlap)\n'
  awk -F'\t' '
    $6 == "unowned" && $10 ~ /unclaimed-checkout/ { u += $3; un++; next }
    $6 == "tooling" { t += $3; tn++; next }
    $6 == "unowned" { o += $3; on++; next }
    END {
      any = (un + tn + on)
      if (any == 0) { printf "  nothing found in this class\n"; exit }
      if (un) printf "  %-42s %8s  %d processes\n", "leftovers in a checkout no record claims", sz(u), un
      if (tn) printf "  %-42s %8s  %d processes\n", "editor / language tooling, no fleet work", sz(t), tn
      if (on) printf "  %-42s %8s  %d processes\n", "other processes no record claims", sz(o), on
      printf "  %-42s %8s\n", "total, if all of the above were freed", sz(u + t + o)
    }
    function sz(kb) {
      if (kb >= 1024 * 1024) return sprintf("%.2f GB", kb / 1024 / 1024)
      return sprintf("%.0f MB", kb / 1024)
    }
  ' "$TMP/rows.tsv"
  local lsp_n lsp_kb par_n
  lsp_n=$(awk -F'\t' '$9 == "lsp" { n++ } END { print n + 0 }' "$TMP/rows.tsv")
  if [ "$lsp_n" -gt 0 ]; then
    lsp_kb=$(awk -F'\t' '$9 == "lsp" { s += $3 } END { print s + 0 }' "$TMP/rows.tsv")
    printf '  Of these, %d language server%s totalling %s - each typically dwarfs the\n' \
      "$lsp_n" "$([ "$lsp_n" -gt 1 ] && echo s)" "$(fmt_kb "$lsp_kb")"
    printf '  agent that spawned it, so check the owner group above before acting.\n'
  fi
  par_n=$(awk -F'\t' '$10 ~ /no-live-parent/ { n++ } END { print n + 0 }' "$TMP/rows.tsv")
  if [ "$par_n" -gt 0 ]; then
    printf '  %d process%s flagged no-live-parent: its spawner is gone, so nothing will\n' \
      "$par_n" "$([ "$par_n" -gt 1 ] && echo es)"
    printf '  reap it. That is a hint only - a live task may still own it by working\n'
    printf '  directory, so read the OWNER column, never the parent, before acting.\n'
  fi
  printf '  Read-only: this script never kills anything. These are candidates.\n'
}

render_table() {
  local count=$limit
  [ "$show_all" -eq 1 ] && count=$(wc -l < "$TMP/rows.tsv" | tr -d ' ')
  printf '\nTOP PROCESSES by phys_footprint (Activity Monitor Memory column)\n'
  printf '  %-7s %10s %10s  %-7s %-9s %-30s %s\n' PID FOOTPRINT RSS KIND VIA OWNER COMMAND
  head -n "$count" "$TMP/rows.tsv" | while IFS=$'\t' read -r pid _ppid fpkb rsskb _user okind olabel via kind flags _cwd cmd; do
    local owner
    case "$okind" in
      task|secondmate|project) owner="$okind:$olabel" ;;
      *) owner="$olabel" ;;
    esac
    [ "$flags" != "-" ] && owner="$owner [$flags]"
    printf '  %-7s %10s %10s  %-7s %-9s %-30s %.56s\n' \
      "$pid" "$(fmt_kb "$fpkb")" "$(fmt_kb "$rsskb")" "$kind" "$via" "$(printf '%.30s' "$owner")" "$cmd"
  done
  if [ "$show_all" -eq 0 ]; then
    local total
    total=$(wc -l < "$TMP/rows.tsv" | tr -d ' ')
    [ "$total" -gt "$count" ] && printf '  ... %d more (--all to show every process)\n' "$(( total - count ))"
  fi
}

render_tree() {
  printf '\nBY OWNER, EVERY PROCESS - grouped by ownership (pstree is not used: see header)\n'
  awk -F'\t' '{ tot[$6 "\t" $7] += $3 } END { for (k in tot) printf "%d\t%s\n", tot[k], k }' "$TMP/rows.tsv" \
    | sort -t$'\t' -k1,1nr | while IFS=$'\t' read -r tot okind olabel; do
    printf '\n  %s: %s - %s total\n' "$okind" "$olabel" "$(fmt_kb "$tot")"
    awk -F'\t' -v k="$okind" -v l="$olabel" '$6 == k && $7 == l' "$TMP/rows.tsv" \
      | while IFS=$'\t' read -r pid _ppid fpkb _rsskb _user _ok _ol via kind flags _cwd cmd; do
        printf '      %-7s %10s  %-7s %-7s %-18s %.52s\n' \
          "$pid" "$(fmt_kb "$fpkb")" "$kind" "$via" "$flags" "$cmd"
      done
  done
}

render_json() {
  printf '{\n'
  printf '  "kind": "memory-report",\n'
  printf '  "physmem_used_kb": %s,\n' "$SELF_PHYSMEM_USED"
  printf '  "footprint_sum_kb": %s,\n' "$SELF_FOOTPRINT_SUM"
  printf '  "process_count": %s,\n' "$SELF_PS_COUNT"
  printf '  "measured": "phys_footprint",\n'
  printf '  "processes": [\n'
  awk -F'\t' '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, " ", s); return s }
    {
      printf "%s    {\"pid\":%s,\"ppid\":%s,\"footprint_kb\":%s,\"rss_kb\":%s,\"user\":\"%s\",\"owner_kind\":\"%s\",\"owner\":\"%s\",\"via\":\"%s\",\"kind\":\"%s\",\"flags\":\"%s\",\"cwd\":\"%s\",\"command\":\"%s\"}", \
        (NR > 1 ? ",\n" : ""), $1, $2, $3, $4, esc($5), esc($6), esc($7), esc($8), esc($9), esc($10), esc($11), esc($12)
    }
    END { printf "\n" }
  ' "$TMP/rows.tsv"
  printf '  ],\n'
  printf '  "groups": [\n'
  awk -F'\t' '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    { key = $6 "\t" $7; tot[key] += $3; n[key]++ }
    END {
      first = 1
      for (k in tot) {
        split(k, a, "\t")
        printf "%s    {\"owner_kind\":\"%s\",\"owner\":\"%s\",\"footprint_kb\":%d,\"processes\":%d}", \
          (first ? "" : ",\n"), esc(a[1]), esc(a[2]), tot[k], n[k]
        first = 0
      }
      printf "\n"
    }
  ' "$TMP/rows.tsv"
  printf '  ]\n'
  printf '}\n'
}

# --verify: re-measure the largest processes with footprint(1) and report
# agreement. This is trap 3's standing regression check - the comparison that
# would have caught reporting rss as though it were the Activity Monitor number.
render_verify() {
  printf '\nVERIFY - top(1) MEM against footprint(1), the Activity Monitor quantity\n'
  if ! command -v footprint >/dev/null 2>&1; then
    printf '  footprint(1) unavailable; cannot cross-check\n'
    return 0
  fi
  printf '  %-7s %12s %12s %10s  %s\n' PID 'top(MEM)' 'footprint' DELTA COMMAND
  head -n 12 "$TMP/rows.tsv" | while IFS=$'\t' read -r pid _ppid fpkb _rss _user _ok _ol _via _kind _fl _cwd cmd; do
    local fkb delta
    fkb=$(footprint -p "$pid" 2>/dev/null | awk '
      /Footprint:/ {
        for (i = 1; i <= NF; i++) if ($i == "Footprint:") {
          n = $(i + 1) + 0; u = $(i + 2)
          if (u ~ /^KB/) print n
          else if (u ~ /^MB/) print n * 1024
          else if (u ~ /^GB/) print n * 1024 * 1024
          else print n / 1024
          exit
        }
      }')
    if [ -z "$fkb" ]; then
      printf '  %-7s %12s %12s %10s  %.40s\n' "$pid" "$(fmt_kb "$fpkb")" 'denied' '-' "$cmd"
      continue
    fi
    delta=$(awk -v a="$fpkb" -v b="$fkb" 'BEGIN { d = (a > b ? a - b : b - a); printf "%.1f%%", (b > 0 ? d * 100 / b : 0) }')
    printf '  %-7s %12s %12s %10s  %.40s\n' "$pid" "$(fmt_kb "$fpkb")" "$(fmt_kb "$fkb")" "$delta" "$cmd"
  done
  printf '  A few percent of drift is two samples taken moments apart, not disagreement.\n'
  printf '  footprint(1) reports "denied" for root-owned processes; top still measures them.\n'
}

# --- main -------------------------------------------------------------------

collect_top
collect_ps
parse_top
parse_ps
collect_cwd
run_self_check
build_owners
build_git_cwds
classify_rows

if [ "$mode" = json ]; then
  render_json
  exit 0
fi

host_line
printf 'Reading: %s processes, phys_footprint - the same quantity Activity Monitor shows.\n' "$SELF_PS_COUNT"
printf 'Ownership read from durable records against each process working directory.\n'
render_groups
render_reclaim
if [ "$show_tree" -eq 1 ]; then
  render_tree
else
  render_table
fi
[ "$verify" -eq 1 ] && render_verify
exit 0
