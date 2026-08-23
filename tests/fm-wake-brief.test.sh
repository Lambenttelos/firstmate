#!/usr/bin/env bash
# Behavior tests for bin/fm-wake-brief.sh, the batched wake-handling-turn read.
#
# The brief composes owners rather than reimplementing them, so these tests
# assert the COMPOSITION: that the drain's raw records survive verbatim, that
# every task a wake names is briefed, that a missing file becomes an explicit
# ABSENT marker instead of a failure or a silent omission, that the default
# brief prints only what changed since the last drain (new status lines, changed
# endpoint states, the full endpoint sweep only on a heartbeat wake) while
# --full restores the untrimmed read, and - the safety property - that nothing
# in state/ is written except the queue the drain consumes and the brief's own
# per-task seen-position records.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

BRIEF="$ROOT/bin/fm-wake-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-brief-tests)

# Build an isolated home with a fake tmux and a fake crew-state verdict, so the
# brief never touches the real fleet, the real terminal, or a real no-mistakes.
make_home() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "list-windows" ]; then
  [ -n "${FM_FAKE_TMUX_CALLS:-}" ] && printf 'x\n' >> "$FM_FAKE_TMUX_CALLS"
  # Real tmux rewrites control characters in a -F format before printing it (a
  # literal tab comes back as `_`), so a control-delimited format silently
  # collapses to one field and every live window reads dead. Refuse it here
  # rather than letting a fixture echo back a separator real tmux never emits.
  for arg in "$@"; do
    case "$arg" in
      *[[:cntrl:]]*)
        printf 'fake tmux: -F format contains a control character real tmux would rewrite\n' >&2
        exit 1 ;;
    esac
  done
  [ -n "${FM_FAKE_TMUX_WINDOWS:-}" ] && printf '%s\n' "$FM_FAKE_TMUX_WINDOWS"
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/tmux"
  make_fake_crew_state "$fakebin" >/dev/null
  printf '%s\n' "$dir"
}

run_brief() {
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" \
    "$BRIEF" "$@" 2>&1
}

# Fingerprint EVERY file in state/, content plus mtime, so a rewrite with
# identical bytes is still caught. Nothing is excluded by name: the read-only
# claim is proved below by differencing the brief's footprint against a bare
# fm-wake-drain.sh's, rather than by trusting a hand-maintained allowlist.
mtime_of() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1"
  else
    stat -c %Y "$1"
  fi
}

state_fingerprint() {
  local state=$1 f name
  for f in "$state"/* "$state"/.[!.]*; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    printf '%s %s %s\n' "$name" "$(mtime_of "$f")" "$(cksum < "$f")"
  done
}

test_empty_queue_and_empty_home() {
  local home out
  home=$(make_home empty)
  out=$(run_brief "$home") || fail "brief must exit 0 on an empty home"
  case "$out" in
    *"(no queued wakes)"*) ;;
    *) fail "empty queue must say so: $out" ;;
  esac
  case "$out" in
    *"(no task named by a drained wake, and no id given)"*) ;;
    *) fail "empty task section must say so: $out" ;;
  esac
  case "$out" in
    *"(no recorded endpoints)"*) ;;
    *) fail "empty endpoint sweep must say so: $out" ;;
  esac
  case "$out" in
    *"=== HOST RESOURCES ==="*) ;;
    *) fail "host reading section is missing: $out" ;;
  esac
  pass "wake brief reports an empty queue, no tasks, and no endpoints without failing"
}

test_drained_wakes_brief_their_tasks() {
  local home state out
  home=$(make_home drained)
  state="$home/state"
  fm_write_meta "$state/alpha.meta" \
    'window=firstmate:fm-alpha' \
    'worktree=/tmp/alpha-worktree' \
    'project=alpha' \
    'harness=claude' \
    'model=opus' \
    'effort=high' \
    'mode=no-mistakes' \
    'pr=https://example.invalid/pr/1'
  printf 'working: started\nblocked: needs a key\nresolved: key supplied\n' > "$state/alpha.status"
  append_wake "$state" signal alpha.status 'signal: alpha.status'
  append_wake "$state" heartbeat heartbeat 'heartbeat: fleet review'

  out=$(FM_FAKE_CREW_STATE='state: working · source: run-step · running' \
    run_brief "$home") || fail "brief must exit 0 with drained wakes"

  case "$out" in
    *"signal"*"alpha.status"*) ;;
    *) fail "raw drained record must survive verbatim: $out" ;;
  esac
  case "$out" in
    *"--- alpha ---"*) ;;
    *) fail "signal wake must brief its task: $out" ;;
  esac
  case "$out" in
    *"wake-EVENT history, not current state"*) ;;
    *) fail "status tail must be labeled as event history: $out" ;;
  esac
  case "$out" in
    *"resolved: key supplied"*) ;;
    *) fail "status tail must include the latest events: $out" ;;
  esac
  case "$out" in
    *"current: state: working · source: run-step · running"*) ;;
    *) fail "reconciled current state must come from fm-crew-state.sh: $out" ;;
  esac
  case "$out" in
    *"meta: window=firstmate:fm-alpha worktree=/tmp/alpha-worktree project=alpha harness=claude model=opus effort=high mode=no-mistakes pr=https://example.invalid/pr/1"*) ;;
    *) fail "meta key facts are missing or reordered: $out" ;;
  esac
  # A fleet-wide key names no task, and must not conjure one.
  case "$out" in
    *"--- heartbeat ---"*) fail "fleet-wide wake key must not become a task: $out" ;;
  esac
  pass "wake brief prints raw records, then the status tail, current state, and meta of each woken task"
}

test_full_flag_restores_the_bounded_status_tail() {
  local home state out lines
  home=$(make_home tail)
  state="$home/state"
  fm_write_meta "$state/beta.meta" 'window=firstmate:fm-beta'
  printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\n' > "$state/beta.status"

  out=$(run_brief "$home" --full beta) || fail "brief must exit 0"
  lines=$(printf '%s\n' "$out" | grep -c '^l[0-9]$')
  [ "$lines" -eq 5 ] || fail "--full must still bound the tail at 5 lines, got $lines"
  case "$out" in
    *l7*) ;;
    *) fail "--full tail must be the LAST lines: $out" ;;
  esac

  out=$(FM_WAKE_BRIEF_TAIL=2 run_brief "$home" --full beta) || fail "brief must exit 0"
  lines=$(printf '%s\n' "$out" | grep -c '^l[0-9]$')
  [ "$lines" -eq 2 ] || fail "FM_WAKE_BRIEF_TAIL must bound the --full tail, got $lines"

  # --full advances the seen baseline, so the trimmed run right after it must
  # report no new lines instead of re-printing the log.
  out=$(run_brief "$home" beta) || fail "brief must exit 0"
  case "$out" in
    *"no new lines since the last brief"*) ;;
    *) fail "a trimmed run after --full must not re-print the briefed log: $out" ;;
  esac
  pass "wake brief --full restores the bounded status tail and advances the seen baseline"
}

test_trimmed_mode_prints_only_new_status_lines() {
  local home state out
  home=$(make_home newlines)
  state="$home/state"
  fm_write_meta "$state/eta.meta" 'window=firstmate:fm-eta'
  printf 'working: began\n' > "$state/eta.status"
  append_wake "$state" signal eta.status 'signal: eta.status'

  out=$(run_brief "$home") || fail "brief must exit 0"
  case "$out" in
    *"1 new line(s) since the last brief"*"working: began"*) ;;
    *) fail "the first brief must print the whole log as new: $out" ;;
  esac

  printf 'blocked: stuck\nresolved: moving\n' >> "$state/eta.status"
  append_wake "$state" signal eta.status 'signal: eta.status'
  out=$(run_brief "$home") || fail "brief must exit 0"
  case "$out" in
    *"2 new line(s) since the last brief"*"blocked: stuck"*"resolved: moving"*) ;;
    *) fail "the trimmed brief must show only lines appended since the last drain: $out" ;;
  esac
  case "$out" in
    *"working: began"*) fail "already-briefed status lines must not re-print: $out" ;;
  esac
  pass "wake brief prints only status lines new since the last drain"
}

test_trimmed_mode_reports_no_new_lines_and_file_resets() {
  local home state out
  home=$(make_home nonew)
  state="$home/state"
  fm_write_meta "$state/theta.meta" 'window=firstmate:fm-theta'
  printf 'working: going\nstill: here\n' > "$state/theta.status"
  append_wake "$state" signal theta.status 'signal: theta.status'
  run_brief "$home" >/dev/null || fail "first brief must exit 0"

  append_wake "$state" signal theta.status 'signal: theta.status'
  out=$(run_brief "$home") || fail "brief must exit 0"
  case "$out" in
    *"no new lines since the last brief"*) ;;
    *) fail "an unchanged status log must say so, not re-print: $out" ;;
  esac
  case "$out" in
    *"working: going"*) fail "an unchanged status log must not re-print its lines: $out" ;;
  esac

  # A replaced (shorter) log is treated as fully new, never silently skipped.
  printf 'working: fresh task\n' > "$state/theta.status"
  append_wake "$state" signal theta.status 'signal: theta.status'
  out=$(run_brief "$home") || fail "brief must exit 0"
  case "$out" in
    *"file reset: 1 new line(s)"*"working: fresh task"*) ;;
    *) fail "a reset status log must print the whole new file: $out" ;;
  esac
  pass "wake brief reports no new lines on an unchanged log and a file reset as all-new"
}

test_absent_files_are_marked_not_skipped() {
  local home state out
  home=$(make_home absent)
  state="$home/state"
  # A task with meta but no status file yet, and an id with neither.
  fm_write_meta "$state/gamma.meta" 'window=firstmate:fm-gamma' 'harness=codex'

  out=$(run_brief "$home" gamma ghost) || fail "brief must exit 0 with absent files"
  case "$out" in
    *"--- gamma ---"*"status tail: ABSENT"*) ;;
    *) fail "a task with no status file must be marked ABSENT: $out" ;;
  esac
  case "$out" in
    *"--- ghost ---"*) ;;
    *) fail "an id with no records at all must still be briefed, not skipped: $out" ;;
  esac
  case "$out" in
    *"meta: ABSENT"*) ;;
    *) fail "a missing meta file must be marked ABSENT: $out" ;;
  esac
  pass "wake brief marks missing status and meta files ABSENT instead of failing or omitting them"
}

test_explicit_ids_join_the_wake_named_ones() {
  local home state out
  home=$(make_home explicit)
  state="$home/state"
  fm_write_meta "$state/one.meta" 'window=firstmate:fm-one'
  fm_write_meta "$state/two.meta" 'window=firstmate:fm-two'
  printf 'done: shipped\n' > "$state/one.status"
  printf 'working: still going\n' > "$state/two.status"
  append_wake "$state" signal one.status 'signal: one.status'

  out=$(run_brief "$home" two) || fail "brief must exit 0"
  case "$out" in
    *"--- one ---"*) ;;
    *) fail "wake-named task missing from explicit-id run: $out" ;;
  esac
  case "$out" in
    *"--- two ---"*) ;;
    *) fail "explicit id missing: $out" ;;
  esac
  [ "$(printf '%s\n' "$out" | grep -c '^--- two ---$')" -eq 1 ] \
    || fail "an id that is both explicit and wake-named must be briefed once: $out"
  pass "wake brief briefs explicit ids alongside the wake-named ones, without duplicates"
}

test_stale_wake_key_resolves_through_the_window_label() {
  local home state out
  home=$(make_home stale)
  state="$home/state"
  fm_write_meta "$state/delta.meta" 'window=firstmate:fm-delta'
  printf 'working: alive\n' > "$state/delta.status"
  append_wake "$state" stale fm-delta 'stale: fm-delta'

  out=$(run_brief "$home") || fail "brief must exit 0"
  case "$out" in
    *"--- delta ---"*) ;;
    *) fail "a stale wake's fm-<id> window label must resolve to its task: $out" ;;
  esac
  pass "wake brief resolves a stale wake's window label back to the task it names"
}

test_endpoint_sweep_uses_exact_window_match() {
  local home state out
  home=$(make_home endpoints)
  state="$home/state"
  fm_write_meta "$state/live.meta" 'window=firstmate:fm-live'
  fm_write_meta "$state/husk.meta" 'window=firstmate:fm-husk'
  fm_write_meta "$state/gone.meta" 'window=firstmate:fm-gone'
  fm_write_meta "$state/nowindow.meta" 'project=x'

  # fm-live-extra deliberately CONTAINS fm-live as a substring: a fuzzy or
  # prefix match would report the torn-down fm-gone or a partial name as alive.
  out=$(FM_FAKE_TMUX_WINDOWS="claude firstmate:fm-live
zsh firstmate:fm-husk
claude firstmate:fm-live-extra" run_brief "$home") || fail "brief must exit 0"

  case "$out" in
    *"live backend=tmux window=firstmate:fm-live endpoint=alive pane=claude"*) ;;
    *) fail "a live harness pane must read alive with its command: $out" ;;
  esac
  case "$out" in
    *"husk backend=tmux window=firstmate:fm-husk endpoint=alive pane=zsh"*) ;;
    *) fail "a bare shell husk must be visible as such: $out" ;;
  esac
  case "$out" in
    *"gone backend=tmux window=firstmate:fm-gone endpoint=dead"*) ;;
    *) fail "a window absent from the listing must read dead: $out" ;;
  esac
  case "$out" in
    *"nowindow backend=tmux endpoint=unknown (no window recorded)"*) ;;
    *) fail "a meta with no window must read unknown, not dead: $out" ;;
  esac
  pass "wake brief sweeps endpoints by exact window match and shows the live pane command"
}

test_trimmed_endpoint_sweep_prints_only_state_changes() {
  local home state out
  home=$(make_home epchanges)
  state="$home/state"
  fm_write_meta "$state/u1.meta" 'window=firstmate:fm-u1'
  fm_write_meta "$state/u2.meta" 'window=firstmate:fm-u2'

  # First observation: no baseline yet, so every endpoint prints once.
  out=$(FM_FAKE_TMUX_WINDOWS="claude firstmate:fm-u1" run_brief "$home") || fail "brief must exit 0"
  case "$out" in
    *"u1 backend=tmux window=firstmate:fm-u1 endpoint=alive"*"u2 backend=tmux window=firstmate:fm-u2 endpoint=dead"*) ;;
    *) fail "the first-ever sweep must print every endpoint: $out" ;;
  esac

  # Unchanged: one summary line, no per-endpoint rows.
  out=$(FM_FAKE_TMUX_WINDOWS="claude firstmate:fm-u1" run_brief "$home") || fail "brief must exit 0"
  case "$out" in
    *"(no endpoint state changes since the last brief)"*) ;;
    *) fail "an unchanged sweep must collapse to one summary line: $out" ;;
  esac
  case "$out" in
    *"u1 backend=tmux"*) fail "an unchanged endpoint row must not re-print: $out" ;;
  esac

  # u2 came alive: only its row prints.
  out=$(FM_FAKE_TMUX_WINDOWS="claude firstmate:fm-u1
zsh firstmate:fm-u2" run_brief "$home") || fail "brief must exit 0"
  case "$out" in
    *"u2 backend=tmux window=firstmate:fm-u2 endpoint=alive pane=zsh"*) ;;
    *) fail "a changed endpoint row must print: $out" ;;
  esac
  case "$out" in
    *"u1 backend=tmux"*) fail "an unchanged endpoint row must not re-print alongside a change: $out" ;;
  esac
  pass "wake brief prints endpoint rows only when the endpoint state changed"
}

test_heartbeat_wake_forces_the_full_endpoint_sweep() {
  local home state out
  home=$(make_home hb)
  state="$home/state"
  fm_write_meta "$state/v1.meta" 'window=firstmate:fm-v1'
  fm_write_meta "$state/v2.meta" 'window=firstmate:fm-v2'
  printf 'working: going\n' > "$state/v1.status"
  append_wake "$state" signal v1.status 'signal: v1.status'

  # Establish the baseline (first observation prints every row once, then the
  # seen records hold the states).
  run_brief "$home" >/dev/null || fail "baseline brief must exit 0"

  # A plain wake with an unchanged fleet: one summary line, no rows.
  append_wake "$state" signal v1.status 'signal: v1.status'
  out=$(run_brief "$home") || fail "brief must exit 0"
  case "$out" in
    *"(no endpoint state changes since the last brief)"*) ;;
    *) fail "a plain wake must not print an unchanged endpoint sweep: $out" ;;
  esac

  # A heartbeat wake prints the whole sweep even though nothing changed.
  append_wake "$state" heartbeat heartbeat 'heartbeat: fleet review'
  out=$(run_brief "$home") || fail "brief must exit 0"
  case "$out" in
    *"v1 backend=tmux window=firstmate:fm-v1 endpoint=dead"*"v2 backend=tmux window=firstmate:fm-v2 endpoint=dead"*) ;;
    *) fail "a heartbeat wake must print the full endpoint sweep: $out" ;;
  esac
  pass "wake brief prints the whole endpoint sweep on a heartbeat wake"
}

test_seen_records_are_pruned_with_the_task() {
  local home state
  home=$(make_home prune)
  state="$home/state"
  fm_write_meta "$state/xi.meta" 'window=firstmate:fm-xi'
  printf 'working: going\n' > "$state/xi.status"
  run_brief "$home" xi >/dev/null || fail "brief must exit 0"
  [ -f "$state/.wake-brief-seen-xi" ] || fail "a briefed task must have a seen record"

  rm -f "$state/xi.meta" "$state/xi.status"
  run_brief "$home" >/dev/null || fail "brief must exit 0"
  [ ! -e "$state/.wake-brief-seen-xi" ] \
    || fail "a seen record must be pruned once its task is gone"
  pass "wake brief prunes seen-position records for tasks that no longer exist"
}

# Seed two identical homes so the brief's write footprint can be differenced
# against a bare fm-wake-drain.sh's. Both get the same fixtures, aged past the
# one-second mtime boundary so an in-run rewrite shows up as a fresher mtime.
seed_readonly_home() {
  local name=$1 home state
  home=$(make_home "$name")
  state="$home/state"
  fm_write_meta "$state/epsilon.meta" 'window=firstmate:fm-epsilon'
  printf 'working: going\n' > "$state/epsilon.status"
  append_wake "$state" signal epsilon.status 'signal: epsilon.status'
  touch -t 200001010000 "$state/epsilon.meta" "$state/epsilon.status"
  printf '%s\n' "$home"
}

# Names whose fingerprint changed (or that appeared) across a run.
footprint() {
  local before=$1 after=$2
  diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") \
    | sed -n 's/^[<>] \([^ ]*\) .*/\1/p' | sort -u
}

test_brief_writes_nothing_beyond_the_drain_and_its_seen_records() {
  local brief_home drain_home before after brief_extra drain_extra unexpected missing state

  brief_home=$(seed_readonly_home readonly-brief)
  before=$(state_fingerprint "$brief_home/state")
  run_brief "$brief_home" >/dev/null || fail "brief must exit 0"
  after=$(state_fingerprint "$brief_home/state")
  brief_extra=$(footprint "$before" "$after")

  drain_home=$(seed_readonly_home readonly-drain)
  before=$(state_fingerprint "$drain_home/state")
  PATH="$drain_home/fakebin:$PATH" FM_HOME="$drain_home" \
    FM_STATE_OVERRIDE="$drain_home/state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 \
    || fail "drain fixture must exit 0"
  after=$(state_fingerprint "$drain_home/state")
  drain_extra=$(footprint "$before" "$after")

  # The brief must reproduce every drain write, and its only additional write is
  # its own seen-position record for the one task.
  missing=$(comm -23 <(printf '%s\n' "$drain_extra") <(printf '%s\n' "$brief_extra"))
  [ -z "$missing" ] || fail "the brief must reproduce the drain's own writes, missing:
$missing"
  unexpected=$(comm -13 <(printf '%s\n' "$drain_extra") <(printf '%s\n' "$brief_extra") \
    | grep -v '^\.wake-brief-seen-epsilon$' || true)
  [ -z "$unexpected" ] || fail "brief wrote state beyond its drain and its seen record:
$unexpected"

  state="$brief_home/state"
  case "$brief_extra" in
    *epsilon.meta*) fail "brief must not touch task metadata" ;;
    *epsilon.status*) fail "brief must not touch a task status log" ;;
  esac
  [ -f "$state/.wake-brief-seen-epsilon" ] || fail "the brief must leave its seen record"
  grep -q '^status-lines=1$' "$state/.wake-brief-seen-epsilon" \
    || fail "the seen record must hold the briefed status position"
  grep -q '^endpoint=dead$' "$state/.wake-brief-seen-epsilon" \
    || fail "the seen record must hold the observed endpoint state"
  [ ! -s "$state/.wake-queue" ] || fail "brief must consume the queue it drained"

  # Second run: the queue is empty now, so nothing names a task, and the task's
  # own records plus the seen record are still byte- and mtime-identical to
  # their post-brief state.
  before=$(state_fingerprint "$state")
  run_brief "$brief_home" >/dev/null || fail "brief must exit 0 on a re-run"
  rerun=$(footprint "$before" "$(state_fingerprint "$state")")
  [ -z "$rerun" ] || fail "re-running the brief modified state records:
$rerun"
  pass "wake brief writes nothing in state/ beyond the drain it runs and its own seen records"
}

test_failed_drain_is_distinct_from_an_empty_queue() {
  local home state stub out status spool
  home=$(make_home drainfail)
  state="$home/state"
  stub="$home/fakebin/failing-drain.sh"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
echo "fm-wake-drain: could not acquire the queue lock" >&2
exit 1
SH
  chmod +x "$stub"

  status=0
  out=$(FM_WAKE_DRAIN_BIN="$stub" run_brief "$home") || status=$?
  [ "$status" -ne 0 ] || fail "a failed drain must fail the brief, got exit 0: $out"
  case "$out" in
    *"DRAIN FAILED (exit 1)"*) ;;
    *) fail "a failed drain must be marked explicitly: $out" ;;
  esac
  case "$out" in
    *"(no queued wakes)"*) fail "a failed drain must not read as an empty queue: $out" ;;
  esac
  # The spool the marker names is retained: on a failed drain it is the only
  # copy of anything the drain may already have emitted.
  spool=$(printf '%s\n' "$out" | sed -n 's/.*retained in \(.*\)$/\1/p')
  [ -n "$spool" ] || fail "the failure marker must name the retained spool: $out"
  [ -f "$spool" ] || fail "the spool must survive a failed drain: $spool"
  rm -f "$spool"
  pass "wake brief reports a failed drain distinctly, keeps its spool, and exits non-zero"
}

test_drain_spool_is_removed_only_after_the_records_are_printed() {
  local home state out spools_before spools_after
  home=$(make_home spool)
  state="$home/state"
  fm_write_meta "$state/zeta.meta" 'window=firstmate:fm-zeta'
  printf 'working: going\n' > "$state/zeta.status"
  append_wake "$state" signal zeta.status 'signal: zeta.status'

  spools_before=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'fm-wake-brief.*' 2>/dev/null | wc -l)
  out=$(run_brief "$home") || fail "brief must exit 0"
  spools_after=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'fm-wake-brief.*' 2>/dev/null | wc -l)
  [ "$spools_before" -eq "$spools_after" ] || fail "a successful drain must leave no spool behind"
  case "$out" in
    *"--- zeta ---"*) ;;
    *) fail "the spooled records must still name their task: $out" ;;
  esac
  pass "wake brief spools the drained records to disk and removes the spool only after printing them"
}

test_invalid_explicit_id_is_reported_not_dropped() {
  local home out
  home=$(make_home rejected)
  out=$(run_brief "$home" '../escape' 'ok-id') || fail "brief must exit 0"
  case "$out" in
    *"REJECTED id ../escape"*) ;;
    *) fail "an unusable id must be reported, not silently dropped: $out" ;;
  esac
  case "$out" in
    *"--- ok-id ---"*) ;;
    *) fail "a valid id alongside a rejected one must still be briefed: $out" ;;
  esac
  case "$out" in
    *"--- ../escape ---"*) fail "a rejected id must not be briefed: $out" ;;
  esac
  pass "wake brief reports an unusable explicit id instead of silently dropping it"
}

test_glob_like_id_is_not_expanded_against_the_working_dir() {
  local home out
  home=$(make_home globby)
  out=$(cd "$home" && run_brief "$home" '*') || fail "brief must exit 0"
  case "$out" in
    *"REJECTED id *"*) ;;
    *) fail "a glob argument must be rejected as written, not expanded: $out" ;;
  esac
  case "$out" in
    *fakebin*) fail "a glob argument must not match working-dir entries: $out" ;;
  esac
  pass "wake brief validates a glob-like id as written instead of expanding it"
}

test_tmux_listing_is_read_once_for_the_whole_sweep() {
  local home state out calls
  home=$(make_home tmuxonce)
  state="$home/state"
  fm_write_meta "$state/t1.meta" 'window=firstmate:fm-t1'
  fm_write_meta "$state/t2.meta" 'window=firstmate:fm-t2'
  fm_write_meta "$state/t3.meta" 'window=firstmate:fm-t3'
  calls="$home/tmux-calls"
  : > "$calls"

  out=$(FM_FAKE_TMUX_CALLS="$calls" FM_FAKE_TMUX_WINDOWS="claude firstmate:fm-t1
claude firstmate:fm-t2" run_brief "$home") || fail "brief must exit 0"

  case "$out" in
    *"t3 backend=tmux window=firstmate:fm-t3 endpoint=dead"*) ;;
    *) fail "the cached listing must still resolve a missing window as dead: $out" ;;
  esac
  [ "$(wc -l < "$calls")" -eq 1 ] \
    || fail "the tmux listing must be read exactly once for the whole sweep, got $(wc -l < "$calls")"
  pass "wake brief takes exactly one tmux listing for the whole endpoint sweep"
}

test_unclassifiable_backend_costs_no_agent_probe() {
  local home state calls out brief_calls baseline_calls
  home=$(make_home unclassifiable)
  state="$home/state"
  calls="$home/cmux-calls"
  cat > "$home/fakebin/cmux" <<'SH'
#!/usr/bin/env bash
[ -n "${FM_FAKE_CMUX_CALLS:-}" ] && printf 'x\n' >> "$FM_FAKE_CMUX_CALLS"
exit 1
SH
  chmod +x "$home/fakebin/cmux"
  fm_write_meta "$state/kappa.meta" 'window=ws:pane' 'backend=cmux'

  : > "$calls"
  out=$(FM_FAKE_CMUX_CALLS="$calls" run_brief "$home") || fail "brief must exit 0"
  brief_calls=$(wc -l < "$calls")

  case "$out" in
    *"kappa backend=cmux window=ws:pane endpoint="*"agent=unknown (backend cannot classify)"*) ;;
    *) fail "an unclassifiable backend must report unknown without probing: $out" ;;
  esac

  # Baseline: the presence probe alone. A brief that also ran the agent
  # classifier would cost strictly more than this.
  : > "$calls"
  PATH="$home/fakebin:$PATH" FM_FAKE_CMUX_CALLS="$calls" bash -c \
    '. "$1/bin/fm-backend.sh"; fm_backend_target_exists cmux ws:pane fm-kappa >/dev/null 2>&1 || true' \
    _ "$ROOT"
  baseline_calls=$(wc -l < "$calls")
  [ "$brief_calls" -eq "$baseline_calls" ] \
    || fail "the sweep must cost only the presence probe, got $brief_calls vs $baseline_calls"
  pass "wake brief skips the agent probe for a backend that cannot classify it"
}

test_drain_stderr_is_labeled_and_not_mined_for_ids() {
  local home state stub out
  home=$(make_home drainstderr)
  state="$home/state"
  fm_write_meta "$state/omega.meta" 'window=firstmate:fm-omega'
  stub="$home/fakebin/noisy-drain.sh"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
printf '1\t1\tsignal\tomega.status\tsignal: omega.status\n'
printf 'fm-wake-drain: warning\t9\tsignal\tomega\tomega\n' >&2
exit 0
SH
  chmod +x "$stub"

  out=$(FM_WAKE_DRAIN_BIN="$stub" run_brief "$home") || fail "brief must exit 0"
  case "$out" in
    *"DRAIN STDERR (not queue content):"*"fm-wake-drain: warning"*) ;;
    *) fail "drain stderr must be labeled distinctly: $out" ;;
  esac
  [ "$(printf '%s\n' "$out" | grep -c '^--- omega ---$')" -eq 1 ] \
    || fail "stderr must not be mined for ids alongside the records: $out"
  pass "wake brief keeps drain stderr labeled and out of the mined record stream"
}

test_failed_drain_spool_is_recoverable_under_state() {
  local home state stub out status spool
  home=$(make_home drainfail-spool)
  state="$home/state"
  stub="$home/fakebin/failing-drain.sh"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
printf '1\t1\tsignal\tlost.status\tsignal: lost.status\n'
echo "fm-wake-drain: could not acquire the queue lock" >&2
exit 1
SH
  chmod +x "$stub"

  status=0
  out=$(FM_WAKE_DRAIN_BIN="$stub" run_brief "$home") || status=$?
  [ "$status" -ne 0 ] || fail "a failed drain must fail the brief: $out"
  spool=$(printf '%s\n' "$out" | sed -n 's/.*retained in \(.*\)$/\1/p')
  [ -n "$spool" ] || fail "the failure marker must name the retained spool: $out"
  case "$spool" in
    "$state"/*) ;;
    *) fail "the retained spool must live under this home's state dir: $spool" ;;
  esac
  grep -q 'lost.status' "$spool" || fail "the retained spool must hold the drained records: $spool"
  pass "a failed drain leaves a recoverable spool under state/ and reports its path"
}

test_empty_queue_and_empty_home
test_unclassifiable_backend_costs_no_agent_probe
test_drain_stderr_is_labeled_and_not_mined_for_ids
test_failed_drain_spool_is_recoverable_under_state
test_drained_wakes_brief_their_tasks
test_failed_drain_is_distinct_from_an_empty_queue
test_drain_spool_is_removed_only_after_the_records_are_printed
test_invalid_explicit_id_is_reported_not_dropped
test_glob_like_id_is_not_expanded_against_the_working_dir
test_tmux_listing_is_read_once_for_the_whole_sweep
test_full_flag_restores_the_bounded_status_tail
test_trimmed_mode_prints_only_new_status_lines
test_trimmed_mode_reports_no_new_lines_and_file_resets
test_absent_files_are_marked_not_skipped
test_explicit_ids_join_the_wake_named_ones
test_stale_wake_key_resolves_through_the_window_label
test_endpoint_sweep_uses_exact_window_match
test_trimmed_endpoint_sweep_prints_only_state_changes
test_heartbeat_wake_forces_the_full_endpoint_sweep
test_seen_records_are_pruned_with_the_task
test_brief_writes_nothing_beyond_the_drain_and_its_seen_records
