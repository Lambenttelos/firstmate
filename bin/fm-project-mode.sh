#!/usr/bin/env bash
# Resolve a project's delivery mode, yolo flag, and autoland flag from the
# data/projects.md registry.
# Prints three words to stdout: "<mode> <yolo> <autoland>" where mode is one of
# no-mistakes|direct-PR|direct-push|local-only and yolo/autoland are on|off.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                              -> no-mistakes off off
#   - <name> [<mode>] - <desc> (added <date>)                     -> <mode> off off
#   - <name> [<mode> +yolo] - <desc> (added <date>)               -> <mode> on off
#   - <name> [<mode> +autoland] - <desc> (added <date>)           -> <mode> off on
#   - <name> [<mode> +yolo +autoland] - <desc> (added <date>)     -> <mode> on on
# The +yolo and +autoland flags are order-independent inside the brackets.
#
# mode = how a finished change reaches main:
#   no-mistakes  full pipeline -> PR -> captain merge (default)
#   direct-PR    push + PR via gh-axi, no pipeline -> captain merge
#   direct-push  full pipeline (PR/CI steps skipped) -> push validated branch to
#                origin -> configured merge authority lands it on the forge. For
#                forges firstmate cannot open PRs on (e.g. Bitbucket); no PR, no CI wait.
#   local-only   local branch, no remote/PR -> captain approve -> guarded local merge
# yolo (orthogonal) = when on, firstmate makes approval decisions itself (PR merges,
#   ask-user findings, local-only merge approval) without checking the captain - except
#   anything destructive/irreversible/security-sensitive, which still escalates.
# autoland (orthogonal) = a durable standing captain grant that GREEN work self-lands
#   without waiting for the captain, set ONLY on repos we own (never on a read-only or
#   not-owned clone). Its effect depends on the mode:
#     direct-push  the crew, after the pipeline reports `passed`, merges its own green
#                  `fm/<id>` branch onto the origin default branch as a clean `--no-ff`
#                  merge and pushes; firstmate then records a captain-review hold.
#     local-only   firstmate fires the guarded local merge (bin/fm-merge-local.sh)
#                  automatically once the single review gate is green, instead of waiting.
#   A conflict, or any destructive/irreversible/security-sensitive choice, still escalates.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off off" and warns
# to stderr, so a typo never silently drops the gate.
# Usage: fm-project-mode.sh <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
NAME=${1:?usage: fm-project-mode.sh <project-name>}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off off" >&2
  echo "no-mistakes off off"
  exit 0
fi

# awk emits "<mode> <yolo> <autoland>" (one line) or nothing if the project is absent.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; autoland="off";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      if (a[1] != "" && a[1] != "+yolo" && a[1] != "+autoland") mode = a[1];
      for (j=1; j<=k; j++) {
        if (a[j]=="+yolo")     yolo="on";
        if (a[j]=="+autoland") autoland="on";
      }
    }
    print mode, yolo, autoland; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off off" >&2
  echo "no-mistakes off off"
  exit 0
fi

read -r mode yolo autoland _ <<EOF
$parsed
EOF
case "$mode" in
  no-mistakes|direct-PR|direct-push|local-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off off" >&2; mode=no-mistakes; yolo=off; autoland=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
case "$autoland" in on|off) ;; *) autoland=off ;; esac
echo "$mode $yolo $autoland"
