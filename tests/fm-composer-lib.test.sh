#!/usr/bin/env bash
# tests/fm-composer-lib.test.sh - the shared composer-content classifier
# (bin/fm-composer-lib.sh), the ONE fleet-wide owner every backend adapter
# delegates its empty|pending|unknown verdict to.
#
# The load-bearing contract, task fm-composer-shellglyph-safety:
#   1. A BARE shell prompt glyph (`>`/`$`/`%`/`#`) on an unstructured row is a
#      dead shell, NOT an empty agent composer - it must read `unknown`
#      (unsafe-for-injection), never `empty`. This is the safety fix.
#   2. The SAME shell glyph INSIDE a bordered composer box is the harness's own
#      prompt and still reads `empty` (existing behavior preserved).
#   3. The AGENT prompt glyphs `❯` (claude) and `›` (codex) are a genuine empty
#      agent composer either way, bordered or bare.
#   4. Real unsubmitted text reads `pending`; a known idle placeholder reads
#      `empty`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"

# classify <bordered> <content> [idle_re] -> echoes the verdict.
classify() { fm_composer_classify_content "$@"; }

# --- Safety fix: bare shell prompt is NOT an empty agent composer -----------

test_bare_shell_glyphs_are_unknown() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "$g")
    [ "$out" = unknown ] \
      || fail "bare shell glyph '$g' must read unknown (dead shell, unsafe), got '$out'"
  done
  pass "fm_composer_classify_content: a bare shell prompt glyph (>/\$/%/#) reads unknown, never empty"
}

test_stripped_unbordered_content_uses_plain_content() {
  local plain out
  for plain in '$' 'user@host $'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = unknown ] \
      || fail "stripped unbordered content '$plain' must retain its unknown safety verdict, got '$out'"
  done
  for plain in '❯' '›'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = empty ] \
      || fail "a stripped agent glyph '$plain' must remain empty, got '$out'"
  done
  pass "fm_composer_classify_content: stripped unbordered content is unknown except verified agent glyphs"
}

test_bare_shell_prompt_with_command_is_not_empty() {
  local out
  # A dead shell showing a typed command must not read empty either.
  out=$(classify 0 '$ ls -la')
  [ "$out" != empty ] || fail "a bare shell prompt with a command must not read empty, got '$out'"
  pass "fm_composer_classify_content: a bare shell prompt carrying a command is not empty"
}

# --- Preserved: shell glyph inside a composer box is the harness prompt ------

test_bordered_shell_glyph_is_empty() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 1 "$g")
    [ "$out" = empty ] \
      || fail "a shell glyph '$g' inside a bordered composer box must read empty, got '$out'"
  done
  pass "fm_composer_classify_content: a bare prompt glyph inside a bordered composer box reads empty (claude's own idle composer)"
}

# --- Agent glyphs are empty either way --------------------------------------

test_agent_glyphs_are_empty_bordered_and_bare() {
  local out
  out=$(classify 0 '❯'); [ "$out" = empty ] || fail "bare claude '❯' should read empty, got '$out'"
  out=$(classify 0 '›'); [ "$out" = empty ] || fail "bare codex '›' should read empty, got '$out'"
  out=$(classify 1 '❯'); [ "$out" = empty ] || fail "bordered claude '❯' should read empty, got '$out'"
  out=$(classify 1 '›'); [ "$out" = empty ] || fail "bordered codex '›' should read empty, got '$out'"
  pass "fm_composer_classify_content: agent prompt glyphs (❯ claude, › codex) read empty bordered or bare"
}

# --- jcode's numbered prompt row ---------------------------------------------
# jcode (verified 2026-07-30, jcode server 0.64.2) draws neither a composer box
# nor a known agent glyph: its composer row is a turn counter, a state glyph
# ("3>" idle, "4…" mid-turn), the typed text, then a right-aligned status glyph
# (⏳) padded out to the far edge of the pane. Every run is bright truecolor, so
# the ghost stripper keeps the whole row and the classifier sees it verbatim.
# Rows below are the real captures, with the padding shortened.

test_jcode_idle_prompt_row_is_empty() {
  local out
  out=$(classify 0 '3>                    ⏳')
  [ "$out" = empty ] \
    || fail "an idle jcode composer row must read empty (it read '$out'; pending here is the false-pending wedge)"
  out=$(classify 0 '12>                   ⏳')
  [ "$out" = empty ] || fail "a multi-digit jcode turn counter must still read empty, got '$out'"
  out=$(classify 0 '3>')
  [ "$out" = empty ] || fail "a jcode prompt row with no status glyph must read empty, got '$out'"
  pass "fm_composer_classify_content: an idle jcode numbered prompt row reads empty"
}

test_jcode_busy_prompt_row_is_empty() {
  local out
  # Mid-turn the counter's glyph flips to '…'. Nothing is typed, so there is no
  # pending input to defer on.
  out=$(classify 0 '4…                    ⏳')
  [ "$out" = empty ] || fail "a mid-turn jcode composer row must read empty, got '$out'"
  pass "fm_composer_classify_content: a mid-turn jcode prompt row reads empty"
}

# jcode's SKILL-ACTIVE idle prompt glyph (task fix-daemon-composer-defer-wedge,
# verified 2026-08-05). jcode's input_prompt() draws "» " (U+00BB) for an idle
# composer while a skill is active (the away-mode supervisor pane always has one),
# not "> ". Before this fix that idle-but-nonblank row read pending and wedged the
# away daemon for 3+ hours.
test_jcode_skill_active_prompt_row_is_empty() {
  local out
  out=$(classify 0 '22»                   ⏳')
  [ "$out" = empty ] || fail "an idle skill-active jcode composer (») must read empty, got '$out' (pending here is the away-mode wedge)"
  out=$(classify 0 '22»')
  [ "$out" = empty ] || fail "a skill-active jcode prompt with no status glyph must read empty, got '$out'"
  out=$(classify 0 '22» hello unsubmitted text     ⏳')
  [ "$out" = pending ] || fail "real text in a skill-active jcode composer must read pending, got '$out'"
  pass "fm_composer_classify_content: an idle skill-active jcode prompt row (») reads empty, typed text reads pending"
}

# The glyph-agnostic backstop (fix 2): an EMPTY jcode composer whose prompt glyph
# is unknown to the recognizer (a future jcode build) must still read empty so a
# glyph rename can never re-wedge injection, while the same shape with real typed
# text stays pending and a row with no ⏳ composer indicator is never claimed.
test_jcode_future_glyph_empty_backstop() {
  local out
  # 'ǂ' (U+01C2) is a deliberately-unknown prompt glyph. Empty composer -> empty.
  out=$(classify 0 '7ǂ                    ⏳')
  [ "$out" = empty ] || fail "an empty jcode composer with an unknown future glyph must read empty, got '$out'"
  # Same shape with real text -> pending (never inject over real input).
  out=$(classify 0 '7ǂ real unsubmitted text     ⏳')
  [ "$out" = pending ] || fail "a future-glyph jcode composer with real text must read pending, got '$out'"
  # No ⏳ composer indicator: not a recognized empty composer (the recognizer must
  # not claim an arbitrary digit-plus-glyph row).
  if fm_composer_jcode_prompt_text '7ǂ' >/dev/null 2>&1; then
    fail "a lone future glyph with no ⏳ indicator must not be claimed as a jcode composer"
  fi
  # The dead-shell safety rule is untouched: a bare shell prompt with no digit
  # prefix and no indicator stays unknown.
  out=$(classify 0 '$')
  [ "$out" = unknown ] || fail "a bare shell prompt must stay unknown, got '$out'"
  pass "fm_composer_jcode_prompt_text: an empty future-glyph composer reads empty, text stays pending, dead shell stays unknown"
}

test_jcode_typed_text_is_pending() {
  local out
  out=$(classify 0 '3> hello unsubmitted text          ⏳')
  [ "$out" = pending ] || fail "real text in a jcode composer must read pending, got '$out'"
  # The slash-command popup fill: typed but unsubmitted, so the submit retry
  # must still be told to send the second Enter.
  out=$(classify 0 '3> /model claude-opus-4-8          ⏳')
  [ "$out" = pending ] || fail "an unsubmitted jcode slash command must read pending, got '$out'"
  pass "fm_composer_classify_content: real and slash-popup text in a jcode composer reads pending"
}

test_jcode_recognizer_rejects_non_composer_rows() {
  local row out
  # jcode's own transcript rows use a digit plus '›' (U+203A), not '>', and its
  # footer rows start with digits too. None of them is a composer row.
  for row in '1› Reply with exactly OK and nothing else.' '2.7s · 32.6 tps · ↑254 ↓4' '27k/1.0M ▱▱▱▱▱▱ 3%'; do
    if fm_composer_jcode_prompt_text "$row" >/dev/null 2>&1; then
      fail "fm_composer_jcode_prompt_text must not claim the jcode row '$row' as a composer prompt"
    fi
  done
  # And the safety rule is untouched: a bare shell prompt is still a dead shell.
  out=$(classify 0 '>')
  [ "$out" = unknown ] || fail "the bare shell glyph must stay unknown after the jcode case, got '$out'"
  out=$(classify 0 '$ ls -la')
  [ "$out" != empty ] || fail "a dead shell with a command must not read empty, got '$out'"
  pass "fm_composer_jcode_prompt_text: only jcode's numbered prompt row matches, and the dead-shell rule is preserved"
}

# --- jcode's WRAPPED composer tail row (prompt row scrolled off) --------------
# Task fix-afk-daemon-jcode-submit-verification (verified 2026-08-01, jcode
# server 0.64.2, scratch jcode + live away daemon): jcode renders its composer
# inline and grows it downward one wrapped row at a time, so a long single-line
# message (the away daemon's ~13k-char digest) pushes the "NNN>" prompt row far
# above the visible pane, leaving only wrapped continuation rows - each ending in
# jcode's right-aligned status indicator ⏳ (U+23F3). The herdr adapter has no
# cursor primitive (tmux reads #{cursor_y} and is immune) and scans a bounded
# window, so without recognizing the wrapped tail the row reads `unknown` and the
# daemon aborts its submit-confirm and re-fires the same batch forever. The tail
# always carries real text, so it must read pending.
# INDICATOR is U+23F3 (\xe2\x8f\xb3); padding right-aligns it, as on the prompt row.
JCODE_IND=$'\xe2\x8f\xb3'

test_jcode_wrapped_tail_is_pending() {
  local out
  # A wrapped continuation row: real text, then right-align padding, then ⏳.
  out=$(classify 0 "le                                        ${JCODE_IND}")
  [ "$out" = pending ] \
    || fail "a jcode wrapped-composer tail row (prompt scrolled off) must read pending, got '$out'"
  out=$(classify 0 "s in the eighty column jcode composer to show structure   ${JCODE_IND}")
  [ "$out" = pending ] || fail "a longer jcode wrapped tail must read pending, got '$out'"
  pass "fm_composer_classify_content: a jcode wrapped-composer tail row reads pending"
}

test_jcode_wrapped_tail_recognizer_is_precise() {
  local out
  # It recognizes only a genuine right-aligned indicator tail with real content.
  fm_composer_jcode_wrapped_tail "le                 ${JCODE_IND}" >/dev/null 2>&1 \
    || fail "the recognizer must accept a wrapped tail with content + padded indicator"
  out=$(fm_composer_jcode_wrapped_tail "le                 ${JCODE_IND}")
  [ "$out" = le ] || fail "the recognizer must extract the tail content 'le', got '$out'"
  # A bare "NNN>"/"NNN…" prompt row is the idle/empty case, NOT a wrapped tail.
  if fm_composer_jcode_wrapped_tail "3>                 ${JCODE_IND}" >/dev/null 2>&1; then
    fail "the recognizer must reject an idle 'NNN>' prompt row (that is the empty case)"
  fi
  if fm_composer_jcode_wrapped_tail "4…                 ${JCODE_IND}" >/dev/null 2>&1; then
    fail "the recognizer must reject a mid-turn 'NNN…' prompt row"
  fi
  # An indicator with no content before it is not a wrapped tail.
  if fm_composer_jcode_wrapped_tail "${JCODE_IND}" >/dev/null 2>&1; then
    fail "the recognizer must reject a bare indicator with no content"
  fi
  # A row that merely ENDS in the glyph with no right-align padding is not a tail.
  if fm_composer_jcode_wrapped_tail "text${JCODE_IND}" >/dev/null 2>&1; then
    fail "the recognizer must reject a glyph glued to text (no right-align padding)"
  fi
  # A transcript/footer row without the indicator is never a wrapped tail.
  if fm_composer_jcode_wrapped_tail '2.7s · 32.6 tps · ↑254 ↓4' >/dev/null 2>&1; then
    fail "the recognizer must reject a jcode footer row (no indicator)"
  fi
  pass "fm_composer_jcode_wrapped_tail: only a right-aligned indicator tail with real content matches"
}

# --- Empty content and idle placeholder -------------------------------------

test_empty_content_is_empty() {
  local out
  out=$(classify 0 ''); [ "$out" = empty ] || fail "empty bare content should read empty, got '$out'"
  out=$(classify 1 ''); [ "$out" = empty ] || fail "empty bordered content should read empty, got '$out'"
  pass "fm_composer_classify_content: an empty composer reads empty"
}

test_idle_placeholder_is_empty() {
  local idle='^Type a message\.\.\.$' out
  # Placeholder with no prompt glyph (grok's bordered empty composer).
  out=$(classify 1 'Type a message...' "$idle")
  [ "$out" = empty ] || fail "the grok idle placeholder should read empty, got '$out'"
  # Placeholder after an agent glyph (post-strip match).
  out=$(classify 0 '❯ Type a message...' "$idle")
  [ "$out" = empty ] || fail "the idle placeholder after a glyph should read empty, got '$out'"
  # Without the idle regex it is just text -> pending.
  out=$(classify 1 'Type a message...')
  [ "$out" = pending ] || fail "without an idle regex the placeholder text is pending, got '$out'"
  pass "fm_composer_classify_content: a known idle placeholder reads empty, before and after glyph stripping"
}

test_idle_placeholder_case_mode_is_explicit() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 1 'type a message...' "$idle")
  [ "$out" = pending ] || fail "a case-variant idle placeholder should remain pending by default, got '$out'"
  out=$(classify 1 'type a message...' "$idle" insensitive)
  [ "$out" = empty ] || fail "an explicitly insensitive idle placeholder should read empty, got '$out'"
  pass "fm_composer_classify_content: idle matching preserves the caller's case mode"
}

# --- Real text is pending ---------------------------------------------------

test_real_text_is_pending() {
  local out
  out=$(classify 0 '❯ fix findings 1 and 3'); [ "$out" = pending ] || fail "bare '❯ <text>' should be pending, got '$out'"
  out=$(classify 1 '> deploy staging now'); [ "$out" = pending ] || fail "bordered '> <text>' should be pending, got '$out'"
  # A slash-command popup argument-hint placeholder is still unsubmitted text.
  out=$(classify 1 '/compact compaction instructions'); [ "$out" = pending ] || fail "a popup placeholder fill should be pending, got '$out'"
  pass "fm_composer_classify_content: real unsubmitted text reads pending (including a popup argument-hint fill)"
}

# --- NBSP prompt-padding fold (root cause of the false "Enter swallowed") -----

test_nbsp_padded_empty_composer_is_empty() {
  local nbsp nnbsp out
  nbsp=$(printf '\302\240')       # U+00A0 NO-BREAK SPACE
  nnbsp=$(printf '\342\200\257')  # U+202F NARROW NO-BREAK SPACE
  # claude 2.1.220 pads its empty composer prompt with a NO-BREAK SPACE, which
  # the callers' ASCII [:space:] trim leaves attached, so the classifier receives
  # "❯ ". It must still read empty, not pending.
  out=$(classify 0 "❯${nbsp}")
  [ "$out" = empty ] || fail "an NBSP-padded empty claude composer must read empty, got '$out'"
  out=$(classify 0 "❯${nnbsp}")
  [ "$out" = empty ] || fail "a narrow-NBSP-padded empty claude composer must read empty, got '$out'"
  # The same fold applies to the codex glyph and via plain_content.
  out=$(classify 0 '' '' sensitive "❯${nbsp}")
  [ "$out" = empty ] || fail "an NBSP-padded empty composer via plain_content must read empty, got '$out'"
  pass "fm_composer_classify_content: an NBSP-padded empty agent composer reads empty (claude 2.1.220)"
}

test_nbsp_padded_real_text_is_pending() {
  local nbsp out
  nbsp=$(printf '\302\240')
  # A genuinely pending composer padded the same way still reads pending: the
  # fold must not swallow real typed text.
  out=$(classify 0 "❯${nbsp}fix findings 1 and 3")
  [ "$out" = pending ] || fail "NBSP-padded real text must stay pending, got '$out'"
  pass "fm_composer_classify_content: NBSP folding never turns real typed text into empty"
}

test_bare_shell_glyphs_are_unknown
test_stripped_unbordered_content_uses_plain_content
test_nbsp_padded_empty_composer_is_empty
test_nbsp_padded_real_text_is_pending
test_bare_shell_prompt_with_command_is_not_empty
test_bordered_shell_glyph_is_empty
test_agent_glyphs_are_empty_bordered_and_bare
test_empty_content_is_empty
test_idle_placeholder_is_empty
test_idle_placeholder_case_mode_is_explicit
test_real_text_is_pending
test_jcode_idle_prompt_row_is_empty
test_jcode_busy_prompt_row_is_empty
test_jcode_skill_active_prompt_row_is_empty
test_jcode_future_glyph_empty_backstop
test_jcode_typed_text_is_pending
test_jcode_recognizer_rejects_non_composer_rows
test_jcode_wrapped_tail_is_pending
test_jcode_wrapped_tail_recognizer_is_precise
