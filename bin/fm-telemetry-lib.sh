#!/usr/bin/env bash
# fm-telemetry-lib.sh - the shared writer for the per-task telemetry artifact
# state/<id>.telemetry (design: data/design-visibility-improvements/report.md,
# "The shared PRODUCER artifact").
#
# state/<id>.telemetry is plain key=value lines, the SAME format as
# state/<id>.meta, so fm_meta_get (bin/fm-backend.sh) reads it with zero new
# parser. Different visibility gaps write different keys onto the same file:
# gap-2 (429 anomaly) writes count_429/last_429_ts, gap-1 writes
# account/quota_*, gap-4 writes composer_stuck/last_steer_ts. Because several
# producers share one file, the writer must UPDATE one key in place without
# clobbering any other key already present. This library owns that update.
#
# No side effects on source. set -u / set -e safe. Torn down with the task by
# bin/fm-teardown.sh (which removes state/<id>.telemetry alongside the other
# per-task state files).

# fm_telemetry_set <telemetry-file> <key> <value>
# Set <key>=<value> in <telemetry-file>, updating an existing <key>= line in
# place and appending it when absent. Every OTHER line is preserved verbatim, so
# a sibling producer's keys are never lost. Creates the file (and any missing
# parent directory) on first write. The value is written as-is on one line; a
# key must be a bare identifier (letters, digits, underscore) and a value must
# not contain a newline - the key=value line format cannot represent either.
# Returns 0 on success, 2 on an invalid key, 3 on a multi-line value.
fm_telemetry_set() {  # <telemetry-file> <key> <value>
  local file=$1 key=$2 value=$3 dir tmp line found=0
  case "$key" in
    ''|*[!A-Za-z0-9_]*)
      printf 'fm_telemetry_set: invalid key: %s\n' "$key" >&2
      return 2
      ;;
  esac
  case "$value" in
    *$'\n'*)
      printf 'fm_telemetry_set: value must be single-line for key: %s\n' "$key" >&2
      return 3
      ;;
  esac
  dir=$(dirname "$file")
  [ -d "$dir" ] || mkdir -p "$dir" || return 1
  tmp="$file.tmp.$$"
  : > "$tmp" || return 1
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "$key="*)
          # Only rewrite the first match; drop later duplicates so the key
          # stays single-valued (fm_meta_get would read the last line anyway).
          if [ "$found" -eq 0 ]; then
            printf '%s=%s\n' "$key" "$value" >> "$tmp" || { rm -f "$tmp"; return 1; }
            found=1
          fi
          ;;
        *)
          printf '%s\n' "$line" >> "$tmp" || { rm -f "$tmp"; return 1; }
          ;;
      esac
    done < "$file"
  fi
  if [ "$found" -eq 0 ]; then
    printf '%s=%s\n' "$key" "$value" >> "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  return 0
}
