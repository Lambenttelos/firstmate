#!/usr/bin/env bash
# Bitbucket Cloud REST 2.0 helpers: the Bitbucket counterpart to the GitHub
# gh-axi PR path. Firstmate can push a validated fm/<id> branch to a Bitbucket
# product repository over SSH, but has no forge CLI that opens or merges a
# Bitbucket pull request object the way gh-axi does for GitHub. These helpers
# close that gap by calling the REST API directly with curl, so hyfin and
# hyfin-server can move from direct-push delivery to full PR-based delivery.
#
# Credentials. Authentication reuses the exact environment variables the
# no-mistakes binary already reads for its own Bitbucket integration, so the
# fleet configures one credential in one place rather than inventing a second
# store:
#   NO_MISTAKES_BITBUCKET_EMAIL      Atlassian account email (Basic-auth username)
#   NO_MISTAKES_BITBUCKET_API_TOKEN  Atlassian API token / app password (Basic-auth password)
#   NO_MISTAKES_BITBUCKET_API_BASE_URL  optional API base; defaults to https://api.bitbucket.org
# The token is passed to curl only through a --config file on a private
# descriptor, never on the command line or in the process environment of a child
# it does not own, so it cannot leak into `ps` output or a shared log.
#
# Scope. This library owns Bitbucket REST request construction and the three
# operations the PR lifecycle needs: open a pull request, read its state, and
# merge it. Callers (bin/fm-pr-check.sh, bin/fm-pr-merge.sh, bin/fm-pr-poll.sh,
# and bin/fm-bitbucket-pr.sh) validate task IDs and URLs through bin/fm-pr-lib.sh
# before calling here. This file performs no task-state mutation of its own.

# Default REST base. The web host bitbucket.org (where PR URLs live) is distinct
# from the API host api.bitbucket.org, so the API base is resolved here and never
# stored in the provider-tagged PR identity.
FM_BITBUCKET_DEFAULT_API_BASE=https://api.bitbucket.org

FM_BITBUCKET_PR_URL=
FM_BITBUCKET_PR_NUMBER=
FM_BITBUCKET_PR_STATE=

# Resolve the API base URL: the NO_MISTAKES_BITBUCKET_API_BASE_URL override when
# set to an https URL, else the default. A trailing slash is stripped so callers
# can append "/2.0/..." without doubling it. An override that is not a plain
# https URL is refused so a malformed value fails closed rather than silently
# targeting an attacker-chosen host.
fm_bitbucket_api_base() {
  local base=${NO_MISTAKES_BITBUCKET_API_BASE_URL-}
  if [ -z "$base" ]; then
    printf '%s\n' "$FM_BITBUCKET_DEFAULT_API_BASE"
    return 0
  fi
  case "$base" in
    https://*) ;;
    *) return 1 ;;
  esac
  case "$base" in
    *[[:space:]]*) return 1 ;;
  esac
  printf '%s\n' "${base%/}"
}

# True when both credential parts are present and non-empty. The email and token
# are the Basic-auth username and password; neither alone can authenticate.
fm_bitbucket_credentials_present() {
  [ -n "${NO_MISTAKES_BITBUCKET_EMAIL-}" ] && [ -n "${NO_MISTAKES_BITBUCKET_API_TOKEN-}" ]
}

# The tools the Bitbucket path needs beyond git: curl to call the REST API and
# jq to parse the JSON responses. Returns non-zero and names the first missing
# tool on stderr, so an arming or merge caller can refuse loudly instead of
# silently doing nothing.
fm_bitbucket_tools_present() {
  local tool
  for tool in curl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "error: Bitbucket pull request support requires $tool on PATH" >&2
      return 1
    fi
  done
}

# Combined readiness guard used by the arming and merge paths: the tools and the
# credentials must both be present. Each failure prints its own specific reason.
fm_bitbucket_ready() {
  fm_bitbucket_tools_present || return 1
  if ! fm_bitbucket_credentials_present; then
    echo "error: Bitbucket pull request support requires NO_MISTAKES_BITBUCKET_EMAIL and NO_MISTAKES_BITBUCKET_API_TOKEN" >&2
    return 1
  fi
}

# Perform one authenticated REST call and print the raw response body to stdout,
# with the numeric HTTP status printed to a caller-provided file. curl reads the
# Basic-auth credential from a --config file on a private, unlinked temporary
# file so the token never appears in an argument vector or the environment of any
# other process. Args:
#   $1  HTTP method (GET, POST)
#   $2  absolute request URL
#   $3  path to write the HTTP status code into
#   $4  optional request body (JSON); empty for a bodyless GET
# Returns curl's exit status; a non-2xx HTTP response is NOT an error here, the
# caller inspects the status file and body.
fm_bitbucket_request() {
  local method=$1 url=$2 status_file=$3 body=${4-}
  local cfg rc
  fm_bitbucket_credentials_present || return 1
  case "$url" in
    https://*) ;;
    *) return 1 ;;
  esac
  cfg=$(mktemp "${TMPDIR:-/tmp}/fm-bb-cfg.XXXXXX") || return 1
  # curl --config understands "user = name:password". The credential lives only
  # in this private file, which is removed immediately after the call.
  {
    printf 'user = "%s:%s"\n' "$NO_MISTAKES_BITBUCKET_EMAIL" "$NO_MISTAKES_BITBUCKET_API_TOKEN"
  } > "$cfg" || { rm -f -- "$cfg"; return 1; }
  local -a curl_args=(
    --silent --show-error
    --config "$cfg"
    --request "$method"
    --write-out '%{http_code}'
    --output -
    --header 'Accept: application/json'
  )
  if [ -n "$body" ]; then
    curl_args+=(--header 'Content-Type: application/json' --data-binary "$body")
  fi
  # Capture the status code (from --write-out, appended after the body) by
  # writing the body to stdout and the code to the status file. curl prints the
  # write-out string to stdout after the body, so split it: run curl capturing
  # all stdout, then peel the trailing status code off.
  local combined
  combined=$(curl "${curl_args[@]}" "$url" 2>>"${FM_BITBUCKET_CURL_ERR:-/dev/null}"; printf '\n%s' "$?")
  rc=${combined##*$'\n'}
  combined=${combined%$'\n'*}
  rm -f -- "$cfg"
  # The last 3 characters of the body-plus-code stream are the HTTP status.
  local code=${combined: -3}
  local response=${combined:0:${#combined}-3}
  printf '%s' "$code" > "$status_file"
  printf '%s' "$response"
  return "$rc"
}

# A 2xx status string is a success. Bitbucket returns 200 or 201 for the calls
# this library makes.
fm_bitbucket_status_ok() {
  case "${1-}" in
    2[0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

# Open a pull request. Args:
#   $1 workspace  $2 repository  $3 source branch  $4 destination branch
#   $5 title      $6 optional description
# On success sets FM_BITBUCKET_PR_URL and FM_BITBUCKET_PR_NUMBER from the
# response and prints the PR URL. On any failure prints a diagnostic to stderr
# and returns non-zero. The web PR URL is reconstructed canonically from the
# workspace, repository, and returned id rather than trusting the response's own
# links, so it always matches the shape bin/fm-pr-lib.sh validates.
fm_bitbucket_open_pr() {
  local workspace=$1 repo=$2 source=$3 dest=$4 title=$5 description=${6-}
  FM_BITBUCKET_PR_URL=
  FM_BITBUCKET_PR_NUMBER=
  fm_bitbucket_ready || return 1
  local base status_file status response body id
  base=$(fm_bitbucket_api_base) || { echo "error: invalid NO_MISTAKES_BITBUCKET_API_BASE_URL" >&2; return 1; }
  status_file=$(mktemp "${TMPDIR:-/tmp}/fm-bb-status.XXXXXX") || return 1
  body=$(jq -n \
    --arg title "$title" \
    --arg source "$source" \
    --arg dest "$dest" \
    --arg description "$description" \
    '{title: $title, source: {branch: {name: $source}}, destination: {branch: {name: $dest}}}
     + (if $description == "" then {} else {description: $description} end)') \
    || { rm -f -- "$status_file"; echo "error: could not build Bitbucket request body" >&2; return 1; }
  response=$(fm_bitbucket_request POST \
    "$base/2.0/repositories/$workspace/$repo/pullrequests" \
    "$status_file" "$body") || {
    rm -f -- "$status_file"
    echo "error: Bitbucket pull request request failed" >&2
    return 1
  }
  status=$(cat "$status_file" 2>/dev/null)
  rm -f -- "$status_file"
  if ! fm_bitbucket_status_ok "$status"; then
    echo "error: Bitbucket refused to open the pull request (HTTP ${status:-unknown})" >&2
    printf '%s\n' "$response" | jq -r '.error.message // empty' 2>/dev/null >&2 || true
    return 1
  fi
  id=$(printf '%s' "$response" | jq -r '.id // empty' 2>/dev/null)
  case "$id" in
    ''|*[!0-9]*) echo "error: Bitbucket response had no pull request id" >&2; return 1 ;;
  esac
  # shellcheck disable=SC2034  # Consumed by callers (bin/fm-bitbucket-pr.sh, tests).
  FM_BITBUCKET_PR_NUMBER=$id
  FM_BITBUCKET_PR_URL="https://bitbucket.org/$workspace/$repo/pull-requests/$id"
  printf '%s\n' "$FM_BITBUCKET_PR_URL"
}

# Read a pull request's state. Args: $1 workspace $2 repository $3 number.
# On success sets FM_BITBUCKET_PR_STATE to the raw Bitbucket state string
# (OPEN, MERGED, DECLINED, SUPERSEDED) and returns 0. Returns non-zero on any
# transport or parse error WITHOUT printing, so a silent poll can call it and
# treat non-zero as "not known merged".
fm_bitbucket_pr_state() {
  local workspace=$1 repo=$2 number=$3
  FM_BITBUCKET_PR_STATE=
  fm_bitbucket_credentials_present || return 1
  command -v curl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  case "$number" in
    ''|*[!0-9]*) return 1 ;;
  esac
  local base status_file status response state
  base=$(fm_bitbucket_api_base) || return 1
  status_file=$(mktemp "${TMPDIR:-/tmp}/fm-bb-status.XXXXXX") || return 1
  response=$(fm_bitbucket_request GET \
    "$base/2.0/repositories/$workspace/$repo/pullrequests/$number" \
    "$status_file") || { rm -f -- "$status_file"; return 1; }
  status=$(cat "$status_file" 2>/dev/null)
  rm -f -- "$status_file"
  fm_bitbucket_status_ok "$status" || return 1
  state=$(printf '%s' "$response" | jq -r '.state // empty' 2>/dev/null) || return 1
  [ -n "$state" ] || return 1
  # shellcheck disable=SC2034  # Consumed by callers and the poll/merge paths.
  FM_BITBUCKET_PR_STATE=$state
}

# Merge a pull request. Args: $1 workspace $2 repository $3 number
#   $4 optional merge strategy (merge_commit, squash, fast_forward); default squash
# Returns 0 only on a 2xx response, else prints a diagnostic and returns
# non-zero. Bitbucket refuses the merge itself (returning a non-2xx) on a
# conflict, an open required check, or a declined PR, so a red or unmergeable PR
# fails here rather than being force-landed.
fm_bitbucket_merge_pr() {
  local workspace=$1 repo=$2 number=$3 strategy=${4:-squash}
  fm_bitbucket_ready || return 1
  case "$number" in
    ''|*[!0-9]*) echo "error: invalid Bitbucket pull request number" >&2; return 1 ;;
  esac
  case "$strategy" in
    merge_commit|squash|fast_forward) ;;
    *) echo "error: invalid Bitbucket merge strategy: $strategy" >&2; return 1 ;;
  esac
  local base status_file status response body
  base=$(fm_bitbucket_api_base) || { echo "error: invalid NO_MISTAKES_BITBUCKET_API_BASE_URL" >&2; return 1; }
  status_file=$(mktemp "${TMPDIR:-/tmp}/fm-bb-status.XXXXXX") || return 1
  body=$(jq -n --arg strategy "$strategy" '{merge_strategy: $strategy}') \
    || { rm -f -- "$status_file"; echo "error: could not build Bitbucket merge body" >&2; return 1; }
  response=$(fm_bitbucket_request POST \
    "$base/2.0/repositories/$workspace/$repo/pullrequests/$number/merge" \
    "$status_file" "$body") || {
    rm -f -- "$status_file"
    echo "error: Bitbucket merge request failed" >&2
    return 1
  }
  status=$(cat "$status_file" 2>/dev/null)
  rm -f -- "$status_file"
  if ! fm_bitbucket_status_ok "$status"; then
    echo "error: Bitbucket refused to merge the pull request (HTTP ${status:-unknown})" >&2
    printf '%s\n' "$response" | jq -r '.error.message // empty' 2>/dev/null >&2 || true
    return 1
  fi
}
