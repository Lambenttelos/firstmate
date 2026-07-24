#!/usr/bin/env bash
# tests/fm-afk-skill-routing.test.sh - static regression tests for the /afk
# skill's entry-path router.
#
# The paneless pull-delivery path is only worth building if the procedure
# firstmate actually follows reaches it. A router that sends "no injectable
# supervisor pane" straight to the daemon-free entry leaves the whole outbox and
# reader path dead code, which is exactly the shape the 2026-07-23 incident had.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AFK="$ROOT/.agents/skills/afk/SKILL.md"

router() {
  awk '
    /^## Pick the entry path first$/ { found = 1 }
    found && /^## Daemon entry/ { exit }
    found { print }
  ' "$AFK"
}

daemon_entry() {
  awk '
    /^## Daemon entry/ { found = 1 }
    found && /^## Daemon-free entry/ { exit }
    found { print }
  ' "$AFK"
}

daemon_free_entry() {
  awk '
    /^## Daemon-free entry/ { found = 1 }
    found && /^## How to exit afk$/ { exit }
    found { print }
  ' "$AFK"
}

test_a_paneless_supported_session_routes_to_the_daemon_entry() {
  local text
  text=$(router)
  assert_contains "$text" "No injectable supervisor pane, but this harness has a native tracked-background tool" \
    "the router has no paneless case for a session with no supervisor pane"
  assert_contains "$text" "use the **daemon entry** below in its paneless pull-delivery form" \
    "a paneless session is not routed to the daemon entry"
  assert_not_contains "$text" "Never start a daemon without a pane it can inject into" \
    "the router still forbids the paneless daemon it is supposed to select"
  assert_contains "$text" "Never start a daemon with nowhere to deliver." \
    "the router lost the accurate no-delivery-channel rule"
  assert_contains "$text" "IS a delivery channel" \
    "the router does not state that paneless pull delivery satisfies the delivery requirement"
  pass "a session with no supervisor pane routes to the daemon entry in paneless delivery"
}

test_the_paneless_entry_arms_the_inbox_reader() {
  local text
  text=$(daemon_entry)
  assert_contains "$text" "On the paneless form, arm the away-mode inbox reader as a tracked background task." \
    "the reader-arming step is not scoped to the paneless daemon entry"
  assert_contains "$text" 'bin/fm-afk-inbox.sh' \
    "the daemon entry no longer names the reader it must arm"
  assert_contains "$text" "a pane-delivery entry does not arm a reader" \
    "the entry does not say the pane form skips the reader"
  pass "the paneless daemon entry arms the away-mode inbox reader"
}

test_the_daemon_free_entry_is_scoped_to_a_missing_delivery_channel() {
  local text
  text=$(daemon_free_entry)
  assert_contains "$text" "Use this only when the daemon has neither a pane nor a hostable pull path" \
    "the daemon-free entry is not scoped to a genuinely missing delivery channel"
  assert_contains "$text" "A session that merely lacks a supervisor pane is NOT this case" \
    "the daemon-free entry still swallows the paneless case"
  pass "the daemon-free entry stays scoped to a genuinely missing delivery channel"
}

test_a_paneless_supported_session_routes_to_the_daemon_entry
test_the_paneless_entry_arms_the_inbox_reader
test_the_daemon_free_entry_is_scoped_to_a_missing_delivery_channel
