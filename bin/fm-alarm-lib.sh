# shellcheck shell=bash
# fm-alarm-lib.sh - shared active-alert dispatcher for firstmate alarms.
# Usage: . bin/fm-alarm-lib.sh
#
# ONE owner for "post an active OS/phone alert from a firstmate background
# process". It exists because the away-mode injection wedge alarm
# (bin/fm-supervise-daemon.sh's wedge_alarm_* functions) and the external
# liveness watchdog (bin/fm-liveness-watchdog.sh) both need the identical
# channel grammar - off/auto/notify-send/osascript/herdr/command:<cmd> read
# from a local, gitignored config file - and duplicating it would drift the two
# copies. The wedge alarm keeps its own in-daemon implementation for now (it is
# entangled with the daemon's bounded-notifier watchdog and its EXEC seam); this
# library is the standalone version the watchdog uses and the shape a future
# consolidation would land on. The channel directive grammar is IDENTICAL to
# config/wedge-alarm (docs/wedge-alarm.md) on purpose, so an operator learns one
# format.
#
# Sourcing is SIDE-EFFECT FREE: it defines functions only, assigns no home path,
# and creates no directories, so any resolved-home caller can source it.
#
# The single test seam is FM_ALARM_EXEC: when set, every channel routes the
# resolved channel category and the summary to that command INSTEAD of the real
# notifier, so a test can never post a real desktop/phone notification and a
# future test author cannot forget to stub. Production leaves it unset.

# Seconds allowed for one channel before its bounded runner terminates it.
FM_ALARM_TIMEOUT_SECS_DEFAULT=10

# Resolve the platform's built-in OS channel, mirroring the wedge alarm:
# macOS -> osascript; Linux -> notify-send when the binary exists; anything else
# (a headless Linux server, an unsupported OS) has no built-in channel and prints
# nothing, so the caller must configure a command: directive.
fm_alarm_platform_default() {
  if [ "$(uname)" = Darwin ]; then
    printf 'osascript\n'
    return 0
  fi
  if command -v notify-send >/dev/null 2>&1; then
    printf 'notify-send\n'
    return 0
  fi
  return 1
}

# Print the configured channel directives, one per line. FM_ALARM_CHANNEL
# overrides the file with a single directive (used by tests and by an explicit
# caller override). An absent/empty config file falls back to `auto`, matching
# the wedge alarm's default-on posture: an alarm's whole point is to not be
# silent.
fm_alarm_configured_channels() {  # <config-file>
  local config=$1 line have=0
  if [ -n "${FM_ALARM_CHANNEL:-}" ]; then
    printf '%s\n' "$FM_ALARM_CHANNEL"
    return 0
  fi
  if [ -f "$config" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        ''|'#'*) continue ;;
      esac
      printf '%s\n' "$line"
      have=1
    done < "$config"
  fi
  [ "$have" -eq 1 ] || printf 'auto\n'
}

# Run <cmd...> with a hard timeout so a hung notifier can never wedge the caller.
# Uses coreutils timeout when present; otherwise a portable background+watchdog
# fallback (the same shape bin/fm-supervise-daemon.sh uses). Returns the command's
# status, or 124 on timeout.
fm_alarm_run_bounded() {  # <cmd>...
  local timeout pid watcher rc
  timeout=${FM_ALARM_TIMEOUT_SECS:-$FM_ALARM_TIMEOUT_SECS_DEFAULT}
  case "$timeout" in
    ''|*[!0-9]*) timeout=$FM_ALARM_TIMEOUT_SECS_DEFAULT ;;
    *) [ "$timeout" -gt 0 ] 2>/dev/null || timeout=$FM_ALARM_TIMEOUT_SECS_DEFAULT ;;
  esac
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout" "$@"
    return $?
  fi
  "$@" &
  pid=$!
  ( sleep "$timeout"; kill -TERM "$pid" 2>/dev/null ) &
  watcher=$!
  wait "$pid" 2>/dev/null
  rc=$?
  kill -TERM "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  return "$rc"
}

# Emit one resolved channel. <channel> is already resolved (never `auto`/`off`).
# When FM_ALARM_EXEC is set, hand the channel category and summary to it instead
# of the real notifier - the test seam. <cmd> carries the command: directive body.
fm_alarm_emit() {  # <channel> <summary> [cmd]
  local channel=$1 summary=$2 cmd=${3:-} title
  title=${FM_ALARM_TITLE:-firstmate alarm}
  if [ -n "${FM_ALARM_EXEC:-}" ]; then
    fm_alarm_run_bounded "$FM_ALARM_EXEC" "$channel" "$summary"
    return $?
  fi
  case "$channel" in
    osascript)
      fm_alarm_run_bounded osascript -e 'on run argv' \
        -e "display notification (item 1 of argv) with title \"$title\"" \
        -e 'end run' "$summary"
      ;;
    notify-send)
      fm_alarm_run_bounded notify-send --urgency=critical "$title" "$summary"
      ;;
    herdr)
      fm_alarm_run_bounded herdr notification show "$title" --body "$summary" --sound request >/dev/null 2>&1
      ;;
    command)
      [ -n "$cmd" ] || return 1
      printf '%s' "$summary" | fm_alarm_run_bounded sh -c "$cmd" fm-alarm "$summary"
      ;;
    *)
      return 2
      ;;
  esac
}

# Dispatch one configured directive line. Resolves `auto`/`default` to the
# platform channel, splits `command:<cmd>`, and honours `off` as a position-
# independent kill switch handled by the caller loop. Returns non-zero on a
# channel failure so the loop can log and continue, never abort.
fm_alarm_dispatch_directive() {  # <directive> <summary>
  local directive=$1 summary=$2 channel cmd
  case "$directive" in
    off) return 0 ;;
    auto|default)
      channel=$(fm_alarm_platform_default) || return 3
      fm_alarm_emit "$channel" "$summary"
      ;;
    command:*)
      cmd=${directive#command:}
      # Trim one leading space after the colon for readability in the config.
      cmd=${cmd# }
      fm_alarm_emit command "$summary" "$cmd"
      ;;
    osascript|notify-send|herdr)
      fm_alarm_emit "$directive" "$summary"
      ;;
    *)
      return 4
      ;;
  esac
}

# Fire every configured channel best-effort. <config-file> is the local,
# gitignored channel file; <summary> is the alert body. A single `off` anywhere
# in the file is a kill switch that disables ALL channels. Always returns 0: an
# alarm dispatcher must never abort its caller. Sets FM_ALARM_FIRED=1 when at
# least one channel was actually attempted (not off, not an unresolved auto), so
# the caller can tell "alerted" from "no channel available".
fm_alarm_notify() {  # <config-file> <summary>
  local config=$1 summary=$2 directive off=0 fired=0
  FM_ALARM_FIRED=0
  # First pass: a single off directive disables every channel.
  while IFS= read -r directive; do
    [ "$directive" = off ] && off=1
  done < <(fm_alarm_configured_channels "$config")
  [ "$off" -eq 1 ] && return 0
  while IFS= read -r directive; do
    case "$directive" in off) continue ;; esac
    if fm_alarm_dispatch_directive "$directive" "$summary"; then
      fired=1
    else
      # A failed channel (missing binary, no platform default, bad directive) is
      # logged by the caller via the returned nonzero; we still try the rest. An
      # auto/default that could not resolve a platform channel (headless Linux)
      # is not a real attempt; every other channel was actually attempted.
      case "$directive" in
        auto|default) : ;;
        *) fired=1 ;;
      esac
    fi
  done < <(fm_alarm_configured_channels "$config")
  # shellcheck disable=SC2034 # Read by callers after fm_alarm_notify returns.
  FM_ALARM_FIRED=$fired
  return 0
}
