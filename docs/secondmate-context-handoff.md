# Secondmate context handoff

When a persistent secondmate's context window fills, running `/compact` degrades its working memory and answer quality.
This home instead hands the work off to a FRESH secondmate agent that recovers from durable on-disk state plus a continuation document, done BEFORE the context fills.

This document is the evidence and mechanism narrative.
The procedure lives in the `secondmate-provisioning` skill's "Context handoff" section.
Exact flags, paths, and commands live in the headers and `--help` of `bin/fm-secondmate-context.sh` and `bin/fm-secondmate-handoff.sh`.
The threshold configuration schema lives in `docs/configuration.md`.

## Reading a live secondmate's context usage

The monitor never guesses.
For each supported harness it either has an evidence-backed read or it reports `unknown` and the monitor fails closed (no handoff is ever triggered from an unreadable context).

### claude (VERIFIED 2026-07-20, Claude Code 2.1.215)

The authoritative signal is the harness's own session transcript, not the pane footer.

**Why not the pane footer.**
The pane footer is unreliable as a machine signal:

- It is a user-configurable surface.
  This home runs a third-party `ccstatusline` command statusline, so the footer reads `Opus 4.8 | low | Total: 1142.2M | 976...` rather than any standard claude context line.
  A different home with a different (or no) custom statusline shows something else entirely.
- It is truncated to the pane width.
  Captured at 80 columns the context figure is cut off mid-number (`976...`, `84.7k...`), so the exact token count is frequently not even present in the capture.
- The standard claude footer only surfaces a context figure when context is already low, which is too late for a proactive handoff.

Exact commands and output that established this (this home, 2026-07-20):

```
$ claude --version
2.1.215 (Claude Code)

$ tmux capture-pane -p -t firstmate:3 -S -3 | tail -3
  Opus 4.8 | low | Total: 1142.2M | 976...
  ⏵⏵ bypass permissions on · 1 shell · ← for agents

$ grep -A6 -i statusline ~/.claude/settings.json
  "statusLine": {
    "type": "command",
    "command": "ccstatusline",
    "padding": 0,
    "refreshInterval": 1
  },
```

**The authoritative read.**
Claude Code appends a JSONL transcript per session under `<config-dir>/projects/<munged-cwd>/<session-id>.jsonl`, where:

- `<config-dir>` is `$CLAUDE_CONFIG_DIR` when set, otherwise `~/.claude`.
- `<munged-cwd>` is the session's launch directory with every `/` and `.` replaced by `-`.
  Verified: `/Users/cyuan/.treehouse/firstmate-7bab20/3/firstmate` maps to the on-disk directory `-Users-cyuan--treehouse-firstmate-7bab20-3-firstmate` (the `/.` in `/.treehouse` becomes `--`).
- The launch directory of a secondmate agent is its home, recorded as `home=` in `state/<id>.meta`.
  Verified: the live `fm-pricing-qa` pane reports `pane_current_path` = its recorded `home=`.

Each assistant turn writes a `message.usage` object.
The context-window occupancy at that turn is the sum of the three input components:

```
context_tokens = input_tokens + cache_creation_input_tokens + cache_read_input_tokens
```

Verified against the same live secondmate the ccstatusline footer described (2026-07-20):

```
$ F=~/.claude/projects/-Users-cyuan--treehouse-firstmate-7bab20-5-firstmate/64738c64-....jsonl
$ grep '"usage"' "$F" | grep -v '"isSidechain":true' | tail -1 \
    | jq '(.message.usage.input_tokens // 0)+(.message.usage.cache_creation_input_tokens // 0)+(.message.usage.cache_read_input_tokens // 0)'
88563
```

The pane's ccstatusline had shown `84.7k...` a few turns earlier, so the transcript sum tracks the harness's own accounting.

Read rules that keep this robust:

- Pick the newest-mtime `*.jsonl` in the project directory; that is the active session (a resumed or compacted session keeps writing the same file).
- Consider only lines carrying `message.usage` and skip `isSidechain:true` lines: sub-agent (Task) turns are a separate context and must not be counted as the main thread's occupancy.
- Take the LAST such line: it is the most recent completed main-thread turn.
- `jq` is required to parse the line safely; when `jq` is absent the read returns `unknown` and the monitor fails closed.

Known staleness edge: between a `/compact` (or resume) and the first assistant turn afterward, the last recorded usage still reflects the pre-compact turn, so the read is briefly stale-high.
This is safe for a threshold monitor - it can only over-report, never silently miss - and the handoff orchestrator re-checks safety (idle, not mid-turn) before acting, and this feature exists precisely to make that `/compact` unnecessary.

### jcode (VERIFIED 2026-08-01)

jcode (github.com/1jehuang/jcode) is a Claude-Agent-SDK runtime that persists the SAME per-session JSONL transcript claude does, in the SAME `<config-dir>/projects/<munged-cwd>/<session-id>.jsonl` location, with a `message.usage` object carrying `input_tokens`, `cache_creation_input_tokens`, and `cache_read_input_tokens` per assistant turn.
The read is therefore byte-identical to claude's, so `fm_sm_context_tokens` dispatches jcode to the exact same `fm_sm_claude_context_tokens` reader rather than a duplicate one.

Exact commands and output that established this (this machine, 2026-08-01, firstmate running natively on jcode):

```
$ bin/fm-harness.sh
jcode

$ cd ~/.claude/projects/-work-firstmate-work && ls -t *.jsonl | head -1
2d7a971f-556b-4a45-a0d0-b59178870c49.jsonl

$ F=2d7a971f-556b-4a45-a0d0-b59178870c49.jsonl
$ grep '"usage"' "$F" | grep -v '"isSidechain":true' | tail -1 \
    | jq '(.message.usage.input_tokens // 0)+(.message.usage.cache_creation_input_tokens // 0)+(.message.usage.cache_read_input_tokens // 0)'
51046

$ grep '"usage"' "$F" | tail -1 | jq '.message.usage | keys'
["cache_creation","cache_creation_input_tokens","cache_read_input_tokens", ...]
```

The transcript carries the same `cwd`, `isSidechain`, and `message.usage` fields claude writes, so every read rule above applies unchanged.
This same read is what the supervision daemon uses for firstmate's OWN context-stow nudge (`config/context-stow-threshold`, docs/configuration.md), pointed at firstmate's home instead of a secondmate's.

### codex, opencode, pi, grok (NOT APPLICABLE - no verified read)

Each of these harnesses persists session state in its own place and format, none of which has been reverse-engineered and verified for a token-occupancy read:

- codex: `~/.codex/sessions/` (inspected 2026-07-20; format not verified).
- opencode: `~/.local/share/opencode/storage/` (inspected 2026-07-20; format not verified).
- pi: `~/.pi/context-mode/sessions/` (inspected 2026-07-20; format not verified).
- grok: not installed on this machine at inspection time; no artifact to inspect.

For every harness other than claude the context read returns `unknown` and the monitor fails closed: it never triggers a handoff it cannot justify.
Adding a verified read for another harness is future work - reverse-engineer its transcript, record the evidence here in the same date/version/command/output form, and extend `bin/fm-secondmate-context-lib.sh`'s `fm_sm_context_tokens` dispatch.

## Threshold monitoring and the wake

The primary's watcher already runs a slow poll every `FM_CHECK_INTERVAL` seconds (default 300).
That block iterates each live secondmate window, reads its context tokens with the rule above, and when the count first crosses the configured threshold it enqueues a `check:` wake (`secondmate-context <id>`) so firstmate is woken to act rather than relying on noticing it at the next heartbeat.
A per-window surfaced marker makes the crossing idempotent: the wake fires once per crossing and re-arms only after the count drops back below the threshold (which a fresh post-handoff agent does).
The read is bounded and only runs on the slow-poll cadence, never on every fast poll.

## Handoff sequence

`bin/fm-secondmate-handoff.sh <id>` orchestrates the replacement, idempotently and failing closed:

1. Resolve `home`, `window`, `harness`, and `kind=secondmate` from `state/<id>.meta`; refuse if any is missing or the task is not a secondmate.
2. Refuse if the secondmate agent is not confidently idle (mid-turn work must finish first) or its endpoint is unreadable - a handoff must never interrupt in-flight work.
3. Steer the secondmate to write its continuation document to a durable in-home path (`data/handoff-latest.md`, never OS temp) via `/handoff`, then run `stow`, and signal completion.
4. Wait, bounded, for the durable document and completion signal; time out and refuse rather than proceeding blind.
5. Exit the old agent with the harness-correct exit form.
6. Respawn a fresh secondmate with `bin/fm-spawn.sh <id> --secondmate` and point it at the durable document plus its charter.

The respawn preserves the home's backlog, projects, and in-flight crew exactly as `secondmate-provisioning` recovery does; the handoff never tears down or discards unlanded work.
