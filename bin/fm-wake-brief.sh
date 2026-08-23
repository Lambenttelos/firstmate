#!/usr/bin/env bash
# fm-wake-brief.sh - one composed read for a wake-handling turn.
#
# Firstmate repeats the same read sequence at the top of every wake-handling
# turn (AGENTS.md section 8): drain the durable queue, read each woken task's
# status tail, reconcile its current state, read its metadata, take one host
# reading, and check whether the endpoints are still alive. Run separately that
# is five or more tool calls per turn. This script batches them into one
# invocation with one bounded, labeled output, so a typical wake turn is the
# brief plus whatever action it justifies.
#
# COMPOSITION, NOT REIMPLEMENTATION. Every section shells out to the script
# that already owns it: bin/fm-wake-drain.sh owns the drain and its annotations,
# bin/fm-crew-state.sh owns current-state reconciliation, bin/fm-resource-check.sh
# owns the host reading and its thresholds, and bin/fm-backend.sh owns endpoint
# liveness. Nothing here re-derives any of those contracts, so a change to an
# owner changes this brief with it.
#
# TRIMMED BY DEFAULT. A wake turn needs what changed since the last drain, not
# everything again: each woken task's status tail shows only the lines appended
# since the previous brief, and the endpoint-liveness sweep prints only the
# endpoints whose state changed, while a heartbeat wake (the fleet-wide review)
# still prints the whole sweep. Per-task read positions live durably under
# state/.wake-brief-seen-<id> and are written only when a value actually changes,
# so the brief stays byte-silent on a turn with nothing new. --full restores the
# old untrimmed read for that call, and the full status log path is always named
# alongside the trimmed tail. Metadata was already printed only for woken tasks
# and stays that way.
#
# SIDE EFFECTS. The drain in section 1 is one mutating component, and it is
# the same already-approved drain firstmate is required to run first anyway;
# the seen-position records in sections 2 and 4 are the second, and they exist
# only to make the next brief cheaper. Everything else is strictly read-only. This script
# never arms, restarts, or touches the watcher: arming remains a separate call,
# because the supervision protocols require it to be its own background task and
# never bundled (docs/supervision-protocols/). fm-wake-drain.sh's own liveness
# assertion still fires from inside section 1, so a lapsed chain still surfaces
# here.
#
# Usage:
#   fm-wake-brief.sh              trimmed brief for the tasks the wakes name
#   fm-wake-brief.sh --full       untrimmed brief (the pre-trim behavior)
#   fm-wake-brief.sh <id>...      also brief these tasks, whether or not they woke
#   fm-wake-brief.sh --help
#
# Environment:
#   FM_WAKE_BRIEF_TAIL   status-tail lines per task in --full mode (default 5)
#
# Exit status is 0 whenever the reads themselves succeed. A missing file is a
# fact about the fleet, not an error: it prints an explicit ABSENT marker rather
# than failing the brief or silently omitting the task. A FAILED DRAIN is the
# exception: the queue is still full and this turn's work is unknown, so it
# prints an explicit DRAIN FAILED marker, keeps the spooled records under this
# home's state dir and names that path, and exits non-zero rather than reading
# like an empty queue.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

# Same stub seam bin/fm-classify-lib.sh already publishes, so a test can fix the
# reconciled verdict without a real worktree or a real no-mistakes run.
CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
# Same shape of stub seam for the drain, so a test can exercise the failed-drain
# path without corrupting a real queue or wedging a real lock.
DRAIN_BIN="${FM_WAKE_DRAIN_BIN:-$SCRIPT_DIR/fm-wake-drain.sh}"

TAIL_LINES=${FM_WAKE_BRIEF_TAIL:-5}
case "$TAIL_LINES" in
  ''|*[!0-9]*|0) TAIL_LINES=5 ;;
esac

usage() {
  cat <<'EOF'
usage: fm-wake-brief.sh [--full] [<id>...]

Compose one wake-handling turn's reads: drain the durable wake queue, then for
every task the wakes name (plus any id given explicitly) print its new status
lines since the last brief, reconciled current state, and key metadata, followed
by one host-resource reading and one endpoint-liveness sweep (state changes
only, or the full sweep when a heartbeat wake was drained).

--full restores the pre-trim behavior: the bounded status tail and the complete
endpoint sweep, whether or not a heartbeat woke.

Read-only apart from the wake drain and the per-task seen-position records that
make the next brief cheaper. Never arms or touches the watcher.

Environment:
  FM_WAKE_BRIEF_TAIL   status-tail lines per task in --full mode (default 5)
EOF
}

EXPLICIT_IDS=
FULL=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --full) FULL=1 ;;
    -*) echo "fm-wake-brief: unknown argument: $arg" >&2; usage >&2; exit 2 ;;
    *) EXPLICIT_IDS="$EXPLICIT_IDS $arg" ;;
  esac
done

section() { printf '\n=== %s ===\n' "$1"; }

# A task id is only ever used to build a path under this home's state dir, so
# reject anything that could escape it or name a dotfile before it is used.
valid_id() {
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

known_id() {
  [ -f "$STATE/$1.meta" ] || [ -f "$STATE/$1.status" ]
}

# Durable per-task read positions for the trimmed brief: the status-line count
# printed so far and the last observed endpoint state. One small key=value file
# per task under state/.wake-brief-seen-<id>. Two rules keep the brief cheap and
# quiet: a value is written only when it differs from what is already recorded,
# so a turn with nothing new writes nothing at all, and nothing is written at all
# when the drain failed, because then the queue is still full and the reads this
# turn made must not advance any baseline.
SEEN_PERSIST=1
seen_file() { printf '%s/.wake-brief-seen-%s' "$STATE" "$1"; }

# Print the recorded value for <key>, or nothing when the record is absent.
# Deliberately exits 0 either way: an absent baseline simply behaves as 0 or as
# "nothing known", which is exactly what a first-ever brief must assume.
seen_get() {
  local f=$1 key=$2
  [ -f "$f" ] || return 0
  sed -n "s/^$key=//p" "$f" | tail -n 1
  return 0
}

# Record <key>=<value>, replacing any older value for that key, only when the
# stored content actually changes and only when the drain succeeded. Written via
# a same-dir temp plus rename so a partial write can never be observed.
seen_put() {
  local f=$1 key=$2 value=$3 base new tmp
  [ "$SEEN_PERSIST" -eq 1 ] || return 0
  if [ -f "$f" ]; then
    base=$(sed "/^$key=/d" "$f")
    if [ -z "$base" ]; then
      new="${key}=${value}"
    else
      new=$(printf '%s\n%s=%s' "$base" "$key" "$value")
    fi
    [ "$new" = "$(cat "$f")" ] && return 0
  else
    new="${key}=${value}"
  fi
  tmp="$f.$$"
  if printf '%s\n' "$new" > "$tmp"; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
  fi
}

# Drop seen-position records whose task no longer exists (no meta, no status
# log), so a torn-down task cannot leave its read position behind forever.
prune_seen() {
  local f id
  for f in "$STATE"/.wake-brief-seen-*; do
    [ -f "$f" ] || continue
    id=${f##*/}
    id=${id#.wake-brief-seen-}
    valid_id "$id" || { rm -f "$f"; continue; }
    if [ -f "$STATE/$id.meta" ] || [ -f "$STATE/$id.status" ]; then
      continue
    fi
    rm -f "$f"
  done
}

# Map one drained wake key to the task it is about, or print nothing.
#
# The queue's key is kind-specific (bin/fm-wake-lib.sh): `signal` keys are the
# status filename, `stale` keys are the backend window label, and `check` keys
# are the check name, which for the per-task checks is the id or an id suffixed
# onto a check prefix. Rather than encoding each producer's naming, this peels
# the known decorations off and accepts the first candidate this home actually
# has a record for - so an unrecognized or fleet-wide key (heartbeat,
# host-resources) simply yields no task, and no key can ever conjure one.
id_for_wake_key() {
  local key=$1 candidate
  for candidate in \
    "$key" \
    "${key%.status}" \
    "${key%.turn-ended}" \
    "${key#fm-}" \
    "${key#secondmate-context-}"; do
    valid_id "$candidate" || continue
    known_id "$candidate" || continue
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

# --- 1. wake queue ----------------------------------------------------------
# Print the drained records first and verbatim: they are this turn's work queue,
# and fm-wake-drain.sh's own annotation lines are part of its output contract.
#
# The drain deletes the durable queue as it prints, so its output must never
# live only in this process's memory: it is spooled to a file on disk that is
# removed ONLY after the records have been printed and mined. If this script is
# interrupted before that, the spool still holds the drained records. The spool
# lives under this home's state dir rather than an anonymous TMPDIR file, so a
# retained one is discoverable and sweepable where the rest of this home's
# durable records already are.
#
# The drain's stderr is kept on its own fd: the record stream stays verbatim,
# and a warning line can never be printed as if it were queue content nor mined
# for a task id.
section "WAKE QUEUE (drained)"
mkdir -p "$STATE" 2>/dev/null || true
DRAIN_SPOOL="$STATE/.wake-brief-spool-$$"
DRAIN_ERR="$STATE/.wake-brief-spool-$$.err"
: > "$DRAIN_SPOOL" 2>/dev/null || {
  echo "fm-wake-brief: cannot create the drain spool file $DRAIN_SPOOL" >&2
  exit 1
}
: > "$DRAIN_ERR" 2>/dev/null || {
  rm -f "$DRAIN_SPOOL"
  echo "fm-wake-brief: cannot create the drain spool file $DRAIN_ERR" >&2
  exit 1
}
DRAIN_STATUS=0
"$DRAIN_BIN" >"$DRAIN_SPOOL" 2>"$DRAIN_ERR" || DRAIN_STATUS=$?
if [ -s "$DRAIN_SPOOL" ]; then
  cat "$DRAIN_SPOOL"
elif [ "$DRAIN_STATUS" -eq 0 ]; then
  printf '(no queued wakes)\n'
fi
if [ -s "$DRAIN_ERR" ]; then
  printf 'DRAIN STDERR (not queue content):\n'
  cat "$DRAIN_ERR"
fi
if [ "$DRAIN_STATUS" -ne 0 ]; then
  printf 'DRAIN FAILED (exit %s): the queue was NOT drained, so this is not an empty queue. Any DRAIN STDERR text above is the drain error, not wakes. Drained records, if any, are retained in %s\n' \
    "$DRAIN_STATUS" "$DRAIN_SPOOL"
  # A failed drain leaves the queue full, so the reads below must not advance
  # any seen position: the next successful drain re-presents the same records.
  SEEN_PERSIST=0
fi

# A heartbeat wake is the fleet-wide review, the one wake whose contract is the
# whole sweep, so it forces the untrimmed endpoint output for this call.
HEARTBEAT_WAKE=0
WAKE_KINDS=$(awk -F '\t' 'NF >= 5 { print $3 }' "$DRAIN_SPOOL")
for kind in $WAKE_KINDS; do
  [ "$kind" = heartbeat ] && HEARTBEAT_WAKE=1
done

# --- 2. tasks named by the wakes -------------------------------------------
IDS=
REJECTED_IDS=
add_id() {
  local id=$1 seen
  valid_id "$id" || return 0
  for seen in $IDS; do
    [ "$seen" = "$id" ] && return 0
  done
  IDS="$IDS $id"
}

# Ids arrive as whitespace-separated words, so disable pathname expansion while
# iterating them: an argument or wake key containing a glob character must be
# validated as written, never silently rewritten by matching the working dir.
set -f
for id in $EXPLICIT_IDS; do
  if valid_id "$id"; then
    add_id "$id"
  else
    REJECTED_IDS="$REJECTED_IDS $id"
  fi
done

# Only the raw TSV records carry a key; the annotation lines fm-wake-drain.sh
# appends are prose and are deliberately not mined for ids.
WAKE_KEYS=$(awk -F '\t' 'NF >= 5 { print $4 }' "$DRAIN_SPOOL")
for key in $WAKE_KEYS; do
  resolved=$(id_for_wake_key "$key") || continue
  add_id "$resolved"
done
set +f

# The records have been printed and mined; the spool has served its purpose. A
# failed drain keeps its spool, because then it is the only copy that exists.
[ "$DRAIN_STATUS" -eq 0 ] && rm -f "$DRAIN_SPOOL" "$DRAIN_ERR"

section "TASKS"
set -f
for id in $REJECTED_IDS; do
  printf 'REJECTED id %s: not a usable task id, so it was not briefed\n' "$id"
done
set +f
if [ -z "$IDS" ]; then
  printf '(no task named by a drained wake, and no id given)\n'
fi
set -f
for id in $IDS; do
  printf '\n--- %s ---\n' "$id"

  status="$STATE/$id.status"
  seen=$(seen_file "$id")
  if [ -f "$status" ]; then
    if [ "$FULL" -eq 1 ]; then
      printf 'status tail (last %s line(s), wake-EVENT history, not current state; full log: %s):\n' \
        "$TAIL_LINES" "$status"
      tail -n "$TAIL_LINES" "$status"
    else
      total=$(wc -l < "$status")
      old=$(seen_get "$seen" status-lines)
      case "$old" in ''|*[!0-9]*) old=0 ;; esac
      if [ "$total" -le "$old" ]; then
        if [ "$total" -lt "$old" ]; then
          # The log shrank (rebuilt or replaced): everything in it is new.
          printf 'status tail (file reset: %s new line(s), wake-EVENT history, not current state; full log: %s):\n' \
            "$total" "$status"
          cat "$status"
          seen_put "$seen" status-lines "$total"
        else
          printf 'status tail (no new lines since the last brief; full log: %s):\n' "$status"
        fi
      else
        printf 'status tail (%s new line(s) since the last brief, wake-EVENT history, not current state; full log: %s):\n' \
          "$((total - old))" "$status"
        tail -n +"$((old + 1))" "$status"
        seen_put "$seen" status-lines "$total"
      fi
    fi
    # --full also advances the baseline: the captain just saw the whole tail.
    [ "$FULL" -eq 1 ] && seen_put "$seen" status-lines "$(wc -l < "$status")"
  else
    printf 'status tail: ABSENT (%s)\n' "$status"
    seen_put "$seen" status-lines 0
  fi

  printf 'current: '
  "$CREW_STATE_BIN" "$id" 2>&1 || true

  meta="$STATE/$id.meta"
  if [ -f "$meta" ]; then
    printf 'meta:'
    for key in window worktree project harness model effort kind mode yolo pr; do
      value=$(fm_meta_get "$meta" "$key")
      [ -n "$value" ] || continue
      printf ' %s=%s' "$key" "$value"
    done
    printf '\n'
  else
    printf 'meta: ABSENT (%s)\n' "$meta"
  fi
done
set +f

# --- 3. host resources ------------------------------------------------------
# No --sweep: that flag belongs to the watcher's own slow sweep, which is the
# only caller allowed to pay for a full backend probe (bin/fm-resource-check.sh).
section "HOST RESOURCES"
RESOURCE_OUT=$("$SCRIPT_DIR/fm-resource-check.sh" 2>/dev/null) || true
if [ -n "$RESOURCE_OUT" ]; then
  printf '%s\n' "$RESOURCE_OUT"
else
  printf 'unavailable\n'
fi

# --- 4. endpoint liveness sweep --------------------------------------------
# One sweep over every recorded endpoint in this home, not just the woken ones,
# because a crew that died quietly never appends a wake. A heartbeat wake (the
# fleet-wide review) or --full prints every row as before; otherwise only the
# rows whose endpoint state differs from what the last brief observed are
# printed, so a quiet fleet costs one summary line instead of one line per task.
#
# For tmux this takes ONE `tmux list-windows -a` reading and compares the
# recorded window against it with an EXACT string compare. Deliberately not
# `tmux display-message -p -t <window>`: display-message resolves its target
# with tmux's own fuzzy name matching, so a recorded window whose pane is gone
# can still resolve onto a different live window and read as alive. The same
# reading carries `pane_current_command`, so a live harness process and a bare
# `zsh` husk are distinguishable at a glance without a second call.
section "ENDPOINTS"
FULL_SWEEP=0
[ "$FULL" -eq 1 ] && FULL_SWEEP=1
[ "$HEARTBEAT_WAKE" -eq 1 ] && FULL_SWEEP=1
TMUX_WINDOWS=
TMUX_READ=0
# The two fields are separated by a single SPACE, and the command comes FIRST,
# deliberately. tmux rewrites control characters in a `-F` format before it
# prints them (a literal tab comes back as `_`), so a tab-delimited reading
# parses as one field and every live window reads dead. A window name may
# itself contain spaces, but `pane_current_command` is a process name and
# cannot, so putting the command first keeps the window name as the whole
# unambiguous remainder of the line.
tmux_windows_load() {
  [ "$TMUX_READ" -eq 0 ] || return 0
  TMUX_READ=1
  command -v tmux >/dev/null 2>&1 || return 0
  TMUX_WINDOWS=$(tmux list-windows -a -F "#{pane_current_command} #{session_name}:#{window_name}" 2>/dev/null) || TMUX_WINDOWS=
}

# Resolve an exact recorded window against the one listing into TMUX_ROW_STATE
# and TMUX_ROW_CMD. Deliberately assigns globals rather than printing into a
# command substitution: a substitution runs in a subshell, which would discard
# the cached listing and turn the single reading into one fork per task.
TMUX_ROW_STATE=dead
TMUX_ROW_CMD=-
tmux_window_row() {
  local want=$1 line name command
  tmux_windows_load
  TMUX_ROW_STATE=dead
  TMUX_ROW_CMD=-
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    command=${line%% *}
    name=${line#* }
    [ "$name" = "$want" ] || continue
    TMUX_ROW_STATE=alive
    TMUX_ROW_CMD=${command:--}
    return 0
  done <<EOF
$TMUX_WINDOWS
EOF
  return 0
}

META_FOUND=0
PRINTED=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  META_FOUND=1
  id=$(basename "$meta" .meta)
  seen=$(seen_file "$id")
  backend=$(fm_backend_of_meta "$meta")
  window=$(fm_meta_get "$meta" window)
  target=$(fm_backend_target_of_meta "$meta")
  if [ -z "$window" ]; then
    printf '%s backend=%s endpoint=unknown (no window recorded)\n' "$id" "$backend"
    PRINTED=1
    continue
  fi
  if [ "$backend" = tmux ]; then
    tmux_window_row "${target:-$window}"
    line=$(printf '%s backend=tmux window=%s endpoint=%s pane=%s\n' \
      "$id" "$window" "$TMUX_ROW_STATE" "$TMUX_ROW_CMD")
    exists=$TMUX_ROW_STATE
  else
    # Non-tmux backends expose no equivalent single-listing sweep, so reuse the
    # liveness primitives bin/fm-backend.sh already publishes rather than
    # inventing a probe this script would then own.
    if fm_backend_target_exists "$backend" "${target:-$window}" "fm-$id"; then
      exists=alive
    else
      exists=dead
    fi
    # fm_backend_agent_alive only classifies the backends with an empirically
    # verified classifier (tmux, herdr) and returns a constant `unknown` for
    # every other backend. Paying a probe for an answer that is known in
    # advance would make this sweep slower than the unbatched sequence it
    # replaces, so an unclassifiable backend is reported without probing.
    case "$backend" in
      herdr) agent=$(fm_backend_agent_alive "$backend" "${target:-$window}") ;;
      *) agent='unknown (backend cannot classify)' ;;
    esac
    line=$(printf '%s backend=%s window=%s endpoint=%s agent=%s\n' \
      "$id" "$backend" "$window" "$exists" "$agent")
  fi
  if [ "$FULL_SWEEP" -eq 1 ]; then
    printf '%s\n' "$line"
    PRINTED=1
  elif [ "$(seen_get "$seen" endpoint)" != "$exists" ]; then
    printf '%s\n' "$line"
    PRINTED=1
  fi
  seen_put "$seen" endpoint "$exists"
done
[ "$META_FOUND" -eq 1 ] || printf '(no recorded endpoints)\n'
if [ "$META_FOUND" -eq 1 ] && [ "$PRINTED" -eq 0 ]; then
  printf '(no endpoint state changes since the last brief)\n'
fi

# A failed drain is the one read that cannot be reported as a fleet fact: the
# queue is still full and this turn's work is unknown, so it fails the brief.
prune_seen
[ "$DRAIN_STATUS" -eq 0 ] || exit 1
exit 0
