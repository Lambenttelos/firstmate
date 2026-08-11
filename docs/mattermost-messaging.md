# Mattermost captain-firstmate messaging (design)

Status: accepted; inbound poll and outbound poster implemented this change. Away-mode auto-delivery (calling the outbound poster from the away-mode daemon) is designed but not yet wired and is a future step. Both open decisions resolved by the captain (see "Resolved decisions").
Owner of the mechanism: `bin/fm-mm-poll.sh`, `bin/fm-mm-post.sh`, and `bin/fm-mm-lib.sh` headers.
Config owner: [docs/configuration.md](configuration.md#mattermost-captain-firstmate-messaging-env).

## Goal

Two-way messaging between the captain and firstmate over Mattermost, so the captain can command the fleet and receive escalations from a phone with no terminal.
Inbound Mattermost messages behave like a captain steer.
Outbound firstmate escalations (the things AGENTS.md section 9 already surfaces) reach the captain in Mattermost.
Both reuse the existing supervision and away-mode paths rather than inventing a parallel loop.

This mirrors the existing X mode (`bin/fm-x-poll.sh`, docs/configuration.md "X mode"), which already solves the same shape of problem: an external message source ingested into firstmate's watcher wake path, with autonomous away-mode reply delivery, gated by a gitignored token.
Mattermost messaging is X mode's private, single-captain sibling.

## What the Mattermost MCP can and cannot do

Firstmate sessions already have a Mattermost MCP with three tools: `get_thread` (read a thread), `post_reply` (reply into a thread, `confirm: true` required), `get_file` (fetch an attachment).

Hard limits that shape this design:

- The MCP is **agent-only**. It is callable from an agent turn, never from a shell script. `bin/fm-watch.sh` is a plain shell loop and cannot call it.
- There is **no channel-list and no search** tool. Firstmate cannot discover the control channel; the captain must name it.
- There is **no new-message signal / no long-poll**. Nothing pushes "a new message arrived" to the MCP.
- `post_reply` **requires explicit confirmation** (`confirm: true`) and needs a thread root post id to reply into.
- There are **no reactions** and no read-cursor tool.

The consequence is decisive: the MCP alone cannot drive a watcher-integrated inbound path.
The watcher is the only always-on component; it is shell; it cannot call the MCP; and the MCP has nothing to poll against anyway.
If inbound depended on the MCP, firstmate would only ever notice a captain message when it happened to take an agent turn for some other reason, so an away-mode phone message would not wake it. That fails the brief's integration requirement.

## Transport decision: REST poll, MCP as the rich reader

The environment has `curl` and `jq` (the same tools X mode requires).
Mattermost exposes a standard REST API v4.
So the transport is a **shell-side REST poll**, exactly like `bin/fm-x-poll.sh`, authorized by a Mattermost personal access token in the home's gitignored `.env`.

- Inbound: `bin/fm-mm-poll.sh` calls `GET /api/v4/channels/{channel_id}/posts?since=<epoch_ms>`, keeps only posts newer than the last-seen cursor that were authored by the captain (not by firstmate's own bot account), stashes each to `state/mm-inbox/<post_id>.json`, and prints one wake line per new message. The watcher's existing `*.check.sh` sweep runs it and turns its output into a wake, identical to the X-mode shim.
- Outbound: `bin/fm-mm-post.sh` calls `POST /api/v4/posts` with `{channel_id, message, root_id?}`. The token is the authorization, so there is no confirm gate on this path.

The MCP does not disappear. It remains the **agent-facing rich reader**: when firstmate needs the full thread with attachments (a screenshot the captain sent from a phone), the agent uses `get_thread` / `get_file` on the permalink the poll recorded. The MCP is a convenience for reading, never the transport.

Why a separate token rather than the MCP's own credentials: the MCP holds its Mattermost credentials internally and does not expose them to the shell. The watcher is shell. So the always-on transport needs its own credential. The brief anticipates this ("any token", gitignored like `.env`).

## Channel / DM model

One Mattermost channel (or DM) is the captain<->firstmate control channel.
Its `channel_id` is configured (see Open decisions); firstmate cannot discover it.

- Captain messages are identified by author: any post in the control channel whose `user_id` is not firstmate's own bot user id is a captain steer. Firstmate learns its own bot user id once via `GET /api/v4/users/me` and caches it, so it never ingests its own posts as captain input (the same self-post filter X mode needs).
- Thread mapping is flat: the channel itself is the conversation. An outbound escalation that answers a specific captain post is threaded as a reply to that post (`root_id` = the captain post id) so the phone shows context; an unprompted escalation is a new root post. This needs no thread bookkeeping and no channel-list.
- One home, one control channel. A secondmate home that opts in has its own token and its own control channel; nothing is shared across homes (same isolation as X mode).

## Inbound path (captain -> firstmate)

1. The watcher's slow `*.check.sh` sweep runs `bin/fm-mm-poll.sh` (armed by a byte-static identity shim exactly like `state/x-watch.check.sh`, validated before execution, so the watcher's trusted-check contract is unchanged).
2. The poll fetches posts since the durable cursor `state/mm-cursor` (epoch ms), filters to captain-authored posts with non-empty message, stashes each to `state/mm-inbox/<post_id>.json`, advances the cursor, and prints `mm-message <post_id>` per new post.
3. That line becomes a watcher wake through the existing `fm_wake_append check` + wake path. No new loop.
4. On the `check: ... mm-message <post_id>` wake, firstmate reads the stashed message and treats it as a captain steer. When the message is richer than plain text (attachments), the agent reads the full thread via the MCP `get_thread` on the recorded permalink.

Cadence: like X mode, an opted-in home writes `config/mm-mode.env` exporting `FM_CHECK_INTERVAL=30`, so the control channel is polled every 30 seconds instead of the default 300. A non-opted-in home is completely inert (no shim, no cadence change, no poll), the same additive posture X mode has.

### Away-mode integration (inbound)

When the captain is afk and messaging from a phone, the inbound wake is a normal watcher wake, and the away-mode daemon already owns watcher wakes. A captain Mattermost message during away mode is an operational input, handled by the away-mode daemon exactly as any other steer-shaped wake: it does not need a new daemon. A marked-internal escalation stays internal; a genuine captain instruction is acted on with no elevation of authority (see safety policy).

## Outbound path (firstmate -> captain)

Outbound reuses the escalation content firstmate already produces per AGENTS.md section 9. It does not invent new escalation triggers.

- Foreground (captain present): firstmate posts escalations to the control channel with `bin/fm-mm-post.sh`. This is a courtesy mirror of what it already says in chat.
- Away mode (captain afk, no terminal): the away-mode daemon already buffers each escalation digest to the durable outbox (`bin/fm-afk-outbox-lib.sh`) and delivers it through the armed reader (`bin/fm-afk-inbox.sh`). The planned future integration adds the Mattermost outbound helper as an **additional delivery sink** for that same digest, so the captain's phone would receive exactly the digests the away-mode path already produces. This sink is **not yet wired** in this change: no code in `bin/fm-afk-outbox-lib.sh` or the away daemon calls `bin/fm-mm-post.sh` today. It is designed to reuse the daemon, not duplicate it.

Once wired, the away-mode outbox already guarantees at-least-once delivery and never loses a record, so a failed Mattermost post would simply retry on the next delivery, the same as the pane path.

## Safety policy (the safety-sensitive decision)

The transport token authorizes firstmate to **read the control channel and post escalations to it**. It does not expand approval authority for anything else. Concretely:

- A phone message is a steer, never an approval. An inbound Mattermost message NEVER auto-approves a merge, a destructive action, an irreversible action, or a security-sensitive choice. Those still require the captain's explicit word under the existing rules, whether firstmate is present or afk. Away mode never expands authority (AGENTS.md section 8), and this path does not either.
- Firstmate never auto-executes a captain-directed destructive action received over Mattermost. If a phone message asks for something destructive/irreversible/security-sensitive, firstmate treats it as a request and replies in-channel asking for the explicit confirmation the existing rules already require, rather than acting.
- Outbound auto-post is limited to escalation content (AGENTS.md section 9 material) plus firstmate's own replies to captain questions. It never posts an action's execution as a fait accompli it was not already authorized to take.
- The agent-side MCP `post_reply` keeps its `confirm: true` gate untouched. Only the REST helper (`bin/fm-mm-post.sh`), authorized by the token, posts autonomously, and only escalation/answer content. This is the exact boundary the brief asks for: an autonomous away-mode escalation may post, but no captain-directed destructive action is ever silently auto-posted or auto-executed.

No AGENTS.md section 1 boundary is weakened. Firstmate still never writes to a project, never merges without the captain's word, never tears down unlanded work, and crewmates still never address the captain. This feature only adds a captain<->firstmate transport.

## Config (home `.env`, all gitignored)

[docs/configuration.md](configuration.md#mattermost-captain-firstmate-messaging-env) owns the full config contract. The keys:

- `MM_TOKEN` - Mattermost personal access token (the opt-in; absent = feature fully inert).
- `MM_SERVER_URL` - Mattermost base URL, e.g. `https://mattermost.hyfin.app`.
- `MM_CHANNEL_ID` - the control channel id; wins when set, no name lookup runs.
- `MM_TEAM` and `MM_CHANNEL` - team and channel URL slugs, used to resolve the channel id once when `MM_CHANNEL_ID` is unset (the id is not discoverable, so the captain names it by URL).
- `MM_DRY_RUN` - preview an outbound post to `state/mm-outbox/` without posting.
- `MM_ENV_FILE` - optional alternate `.env`-style file for direct invocations.

Cadence: the inbound poll is registered as the home's watcher custom check, so it runs on the watcher's existing slow-check interval (`FM_CHECK_INTERVAL`). A home that wants a faster control-channel cadence lowers that interval by the existing mechanism rather than adding a second cadence knob.

Generated runtime state under `state/` (all gitignored): `mm-inbox/<post_id>.json` (stashed captain messages), `mm-cursor` (last-seen epoch ms), `mm-self-user` (cached bot user id), `mm-channel-id` (cached resolved control channel id), `mm-poll.error` (rate-limited diagnostic dedupe), and `mm-outbox/` (dry-run previews). The inbound poll is wired through the watcher's existing custom-check path (`state/<id>.check.sh` registered with `bin/fm-check-register.sh`), so it needs no new watcher gate.

## Resolved decisions

Both were genuine captain choices (the channel id is un-discoverable and the auto-post policy is safety-sensitive), so implementation waited on the captain's ruling. The captain answered both on 2026-08-10:

1. Control channel: the channel at `https://mattermost.hyfin.app/dashnow/channels/fm-cyuan`, team slug `dashnow`, channel slug `fm-cyuan`. Its id is resolved once from those slugs and cached to `state/mm-channel-id`, or set directly via `MM_CHANNEL_ID`. Flat thread model; escalations threaded onto the captain post they answer.

2. Auto-post safety policy: approved as written above. The token authorizes reading the control channel and auto-posting escalations and firstmate's own answers. An inbound phone message is a steer that never auto-approves or auto-executes a merge or any destructive, irreversible, or security-sensitive action. The agent-side MCP `post_reply` confirm gate stays intact.

## Maintaining this file

Keep this as the design and rationale record.
Once built, the exact flags, wire calls, and paths live in the script headers and docs/configuration.md; this file points at them rather than restating them.
