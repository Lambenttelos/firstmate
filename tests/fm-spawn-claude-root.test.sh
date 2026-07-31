#!/usr/bin/env bash
# Behavior tests for the claude launch template's root gating.
# claude refuses --dangerously-skip-permissions under root/sudo ("cannot be used
# with root/sudo privileges for security reasons"), so every claude crew spawn
# fails closed at launch on a root-run server (verified 2026-07-30 and
# 2026-07-31). launch_template() prepends IS_SANDBOX=1 ONLY when uid is 0, which
# clears the root refusal; a non-root host must keep the byte-identical template.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-claude-root)

# Extract launch_template() and drive its uid branch with a fake id command.
extract_launch_template() {  # <uid>
  local uid=$1
  local fn="$TMP_ROOT/launch_template-$uid.sh" fb="$TMP_ROOT/fake-$uid"
  mkdir -p "$fb"
  cat > "$fb/id" <<SH
#!/usr/bin/env bash
[ "\$1" = -u ] && { printf '%s\n' "$uid"; exit 0; }
exit 1
SH
  chmod +x "$fb/id"
  awk '/^launch_template\(\) \{/ { inside = 1 } inside { print } inside && /^\}/ { exit }' \
    "$ROOT/bin/fm-spawn.sh" > "$fn"
  [ -s "$fn" ] || fail "could not extract launch_template() from bin/fm-spawn.sh"
  # shellcheck source=/dev/null
  ( PATH="$fb:$PATH"; . "$fn"; launch_template claude ship )
}

test_claude_template_root_injects_sandbox() {
  local launch
  launch=$(extract_launch_template 0)
  case "$launch" in
    'IS_SANDBOX=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions '*) : ;;
    *) fail "under root the claude template must prepend IS_SANDBOX=1, got '$launch'" ;;
  esac
  pass "launch_template claude: root prepends IS_SANDBOX=1 to clear the root refusal"
}

test_claude_template_nonroot_byte_unchanged() {
  local launch
  launch=$(extract_launch_template 1000)
  case "$launch" in
    IS_SANDBOX=*) fail "a non-root host must not carry IS_SANDBOX=1, got '$launch'" ;;
    'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions '*) : ;;
    *) fail "the non-root claude template changed unexpectedly, got '$launch'" ;;
  esac
  pass "launch_template claude: a non-root host keeps the byte-identical template"
}

test_claude_template_root_injects_sandbox
test_claude_template_nonroot_byte_unchanged
