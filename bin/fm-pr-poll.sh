#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits exactly one merged line for a merged PR or MR and stays silent
# otherwise, including on every error, so a failed lookup can never be read as
# a merge. The provider-tagged identity is data in the sidecar and is never
# interpolated into this source: these bytes are identical for every task.
# Each provider is read through its own standard interface, gh for GitHub,
# glab for GitLab, and the Bitbucket Cloud REST API (curl + jq) for Bitbucket,
# so an upstream checkout follows GitHub and GitLab with no extra tooling and
# Bitbucket when curl, jq, and the NO_MISTAKES_BITBUCKET_* credentials are
# present. A Bitbucket poll with a missing tool or credential stays silent,
# exactly like every other error, so it can never be misread as a merge.
set -u
LC_ALL=C
export LC_ALL

if [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot redirect this poll at another host or project.
case "$provider" in
  github)
    [ "$host" = github.com ] || exit 0
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
    case "$owner" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0
    state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || exit 0
    [ "$state" = MERGED ] && printf '%s\n' merged
    ;;
  bitbucket)
    # Bitbucket Cloud is served only from the constant web host bitbucket.org and
    # addresses a repository by a validated two-segment workspace/repository path.
    [ "$host" = bitbucket.org ] || exit 0
    workspace=${path%%/*}
    repo=${path#*/}
    [ "${#workspace}" -ge 1 ] && [ "${#workspace}" -le 100 ] || exit 0
    case "$workspace" in
      .|..|*/*|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*/*|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://bitbucket.org/$workspace/$repo/pull-requests/$number" ] || exit 0
    # The REST API host is distinct from the web host and is resolved from the
    # optional NO_MISTAKES_BITBUCKET_API_BASE_URL override, defaulting to
    # api.bitbucket.org. An override must be a plain https URL with no
    # whitespace, so a malformed value stays silent rather than targeting an
    # unexpected host.
    api_base=${NO_MISTAKES_BITBUCKET_API_BASE_URL:-https://api.bitbucket.org}
    case "$api_base" in
      https://*) ;;
      *) exit 0 ;;
    esac
    case "$api_base" in
      *[[:space:]]*) exit 0 ;;
    esac
    api_base=${api_base%/}
    # Silent unless curl, jq, and both credential parts are present: a missing
    # tool or credential is indistinguishable from a PR that is never merged, so
    # it must never be reported as a merge.
    command -v curl >/dev/null 2>&1 || exit 0
    command -v jq >/dev/null 2>&1 || exit 0
    [ -n "${NO_MISTAKES_BITBUCKET_EMAIL:-}" ] || exit 0
    [ -n "${NO_MISTAKES_BITBUCKET_API_TOKEN:-}" ] || exit 0
    # The credential is passed to curl only through a private --config file, never
    # on the command line, so the token cannot leak into a process listing.
    cfg=$(mktemp "${TMPDIR:-/tmp}/fm-bb-poll.XXXXXX") || exit 0
    printf 'user = "%s:%s"\n' "$NO_MISTAKES_BITBUCKET_EMAIL" "$NO_MISTAKES_BITBUCKET_API_TOKEN" > "$cfg" 2>/dev/null || { rm -f -- "$cfg"; exit 0; }
    response=$(curl --silent --show-error --config "$cfg" \
      --header 'Accept: application/json' \
      "$api_base/2.0/repositories/$workspace/$repo/pullrequests/$number" 2>/dev/null)
    rm -f -- "$cfg"
    [ -n "$response" ] || exit 0
    state=$(printf '%s' "$response" | jq -r '.state // empty' 2>/dev/null) || exit 0
    [ "$state" = MERGED ] && printf '%s\n' merged
    ;;
  gitlab)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A GitLab project sits under at least one group at no fixed depth, and
    # GitLab reserves the "-" segment as its route separator.
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 0
    [ "$url" = "https://$host/$path/-/merge_requests/$number" ] || exit 0
    # glab resolves the instance from the project URL passed to -R, so the host
    # comes from the validated record rather than glab's configured default.
    # It cannot take a merge request URL the way gh does: that form shells out
    # to git for the current repository, and the watcher runs in no repository.
    # The state is read from glab's own field output rather than its JSON,
    # because plain glab has no field selector and firstmate does not require a
    # JSON processor; only an exact "merged" wakes, so a changed format or an
    # unreadable merge request stays silent instead of reporting a merge.
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 0
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    [ "$state" = merged ] && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
