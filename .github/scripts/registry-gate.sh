#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# registry-gate.sh — the checks a publishing workflow runs against its registry
# before it builds or publishes anything.
#
#   credential  proves that the registry accepts the stored credential, with one
#               authenticated GET /v2/;
#   image       waits, for a bounded time, until the tooling image a later job
#               runs inside exists in the registry.
#
# Neither pushes anything or opens an upload session: the credential check is one
# GET and the image check is a manifest HEAD.
#
# This file is one of four deliberate, byte-identical copies, one in each
# repository that publishes to the hub — aggrega-cli, aggrega-docs, aggrega-hub
# and aggrega-plugins — because each repository's CI runs from its own checkout
# alone. A change to one copy is made to all four in the same change. Every value
# that differs between the repositories — the registry and the names of the
# settings a failure points at — arrives as an argument, so the same bytes run in
# each of them and against a loopback registry.
#
# Run with --help for the arguments.

set -euo pipefail
# The credential must never reach the log, so tracing stays off even when the
# caller turned it on.
set +x

usage() {
  cat <<'EOF'
usage:
  registry-gate.sh credential --registry-url <url>
      --registry-setting <name> --username-setting <name> --password-setting <name>
  registry-gate.sh image --registry-url <url> --repository <path> --tag <tag>
      --tag-setting <name> --username-setting <name> --password-setting <name>
      [--timeout <seconds>] [--interval <seconds>]
  registry-gate.sh --help

Both commands read the credential from the environment: the username from
REGISTRY_USERNAME and the password from REGISTRY_PASSWORD. Neither value is
printed, placed on a command line, or written anywhere; under GitHub Actions the
encoded form sent to the registry is masked in the log as well.

credential
  Sends one GET <url>/v2/ with Basic credentials. It passes when the registry
  answers 200. A missing username or password is refused before any request.
  Any other answer fails, naming the setting that holds the registry, the one
  that holds the username and the one that holds the password, and reporting
  the HTTP status alone.

image
  Asks the registry for the manifest of <repository>:<tag> with a HEAD request,
  until it answers 200 or the timeout passes. A 404, a 429, a 5xx or no answer
  at all is waited through; a 401 or a 403 fails at once, because waiting does
  not change a refused credential. On a timeout it fails, naming the missing
  image and how to run the workflow again once the image exists. Under GitHub
  Actions the reference is written to the step's outputs as image=<reference>.
  An empty tag is refused before any request, naming the setting that holds it.

  --timeout   seconds to wait in all, default 1800
  --interval  seconds between two checks, default 30

Arguments:
  --registry-url      the registry's base URL, with its scheme:
                      https://hub.aggrega.ai, http://127.0.0.1:5000
  --registry-setting  the name of the setting that names the registry
  --username-setting  the name of the setting that holds the username
  --password-setting  the name of the setting that holds the password
  --repository        the image's repository path, such as tools/aggrega
  --tag               the image's tag
  --tag-setting       the name of the setting that holds the tag

Exit status: 0 when the check passes, 1 when it fails, 2 for a usage error.
EOF
}

fail() {
  echo "registry-gate: $*" >&2
  exit 1
}

usage_error() {
  echo "registry-gate: $*" >&2
  echo "registry-gate: run with --help for the arguments" >&2
  exit 2
}

if [ "$#" -eq 0 ]; then
  usage_error "name a command: credential or image"
fi

case "$1" in
  -h|--help)
    usage
    exit 0
    ;;
  credential|image)
    command="$1"
    shift
    ;;
  *)
    usage_error "unknown command '$1'"
    ;;
esac

registry_url=""
registry_setting=""
username_setting=""
password_setting=""
repository=""
tag=""
tag_set=false
tag_setting=""
timeout=1800
interval=30

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --registry-url|--registry-setting|--username-setting|--password-setting|--repository|--tag|--tag-setting|--timeout|--interval)
      [ "$#" -ge 2 ] || usage_error "$1 needs a value"
      case "$1" in
        --registry-url) registry_url="$2" ;;
        --registry-setting) registry_setting="$2" ;;
        --username-setting) username_setting="$2" ;;
        --password-setting) password_setting="$2" ;;
        --repository) repository="$2" ;;
        --tag) tag="$2"; tag_set=true ;;
        --tag-setting) tag_setting="$2" ;;
        --timeout) timeout="$2" ;;
        --interval) interval="$2" ;;
      esac
      shift 2
      ;;
    *)
      usage_error "unknown argument '$1'"
      ;;
  esac
done

require() {
  local flag="$1" value="$2"
  [ -n "$value" ] || usage_error "$command needs $flag"
}

require --registry-url "$registry_url"
require --username-setting "$username_setting"
require --password-setting "$password_setting"
case "$registry_url" in
  http://*|https://*) ;;
  *) usage_error "--registry-url '$registry_url' needs its scheme, http:// or https://" ;;
esac
registry_url="${registry_url%/}"
registry_host="${registry_url#*://}"

if [ "$command" = "credential" ]; then
  require --registry-setting "$registry_setting"
else
  require --repository "$repository"
  require --tag-setting "$tag_setting"
  "$tag_set" || usage_error "image needs --tag"
  case "$timeout" in ''|*[!0-9]*) usage_error "--timeout '$timeout' is not a whole number of seconds" ;; esac
  case "$interval" in ''|*[!0-9]*|0) usage_error "--interval '$interval' is not a positive whole number of seconds" ;; esac
fi

# The credential is read here and nowhere else.
username="${REGISTRY_USERNAME:-}"
password="${REGISTRY_PASSWORD:-}"
if [ -z "$password" ]; then
  fail "the secret $password_setting is empty in this run, so nothing was sent to the registry. Store the registry password as a repository secret named $password_setting; a variable of that name is not read in its place."
fi
if [ -z "$username" ]; then
  fail "the variable $username_setting is empty in this run, so nothing was sent to the registry. Set it to the registry username that $password_setting belongs to."
fi

# The Authorization header's value is built in the shell and handed to curl on
# its standard input, so it never appears on a command line.
basic="$(printf '%s:%s' "$username" "$password" | base64 | tr -d '\n')"
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  # GitHub masks the secret itself but not an encoding of it.
  echo "::add-mask::$basic"
fi

# http_status <method> <url> [curl arguments...] prints the HTTP status the
# registry answered, or 000 when no answer arrived.
http_status() {
  local method="$1" url="$2"
  shift 2
  local method_args=()
  if [ "$method" = "HEAD" ]; then
    method_args=(--head)
  fi
  local status
  if status="$(printf 'Authorization: Basic %s\n' "$basic" \
      | curl --silent --output /dev/null --write-out '%{http_code}' \
          --connect-timeout 10 --max-time 30 \
          --header @- "${method_args[@]}" "$@" "$url")"; then
    printf '%s\n' "$status"
  else
    printf '%s\n' "${status:-000}"
  fi
}

check_credential() {
  local status
  status="$(http_status GET "$registry_url/v2/")"
  case "$status" in
    200)
      echo "registry-gate: $registry_host accepts the stored credential (GET /v2/ answered HTTP 200)"
      ;;
    000)
      fail "no answer from $registry_url (GET /v2/). Check that the variable $registry_setting names the registry, written as its host."
      ;;
    401|403)
      fail "$registry_host refused the stored credential (GET /v2/ answered HTTP $status). Check the variable $username_setting and the secret $password_setting, and that the variable $registry_setting names the registry they belong to."
      ;;
    *)
      fail "$registry_host answered GET /v2/ with HTTP $status rather than 200. Check that the variable $registry_setting names the registry, and the variable $username_setting and the secret $password_setting."
      ;;
  esac
}

rerun_hint() {
  if [ -n "${GITHUB_RUN_ID:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    local workflow_file="${GITHUB_WORKFLOW_REF:-}"
    workflow_file="${workflow_file%%@*}"
    workflow_file="${workflow_file##*/}"
    printf ': gh run rerun %s --repo %s' "$GITHUB_RUN_ID" "$GITHUB_REPOSITORY"
    if [ -n "$workflow_file" ]; then
      printf ', or start it again with the same inputs: gh workflow run %s --repo %s' "$workflow_file" "$GITHUB_REPOSITORY"
    fi
  fi
}

wait_for_image() {
  if [ -z "$tag" ]; then
    fail "the variable $tag_setting is empty in this run, so no image can be named. Set it to the tag of the tooling image the jobs run in, such as stable."
  fi
  local reference="$registry_host/$repository:$tag"
  local url="$registry_url/v2/$repository/manifests/$tag"
  local accept="application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json"
  local started=$SECONDS status waited
  while :; do
    status="$(http_status HEAD "$url" --header "Accept: $accept")"
    waited=$((SECONDS - started))
    case "$status" in
      200)
        echo "registry-gate: the tooling image $reference exists (found after ${waited}s)"
        if [ -n "${GITHUB_OUTPUT:-}" ]; then
          printf 'image=%s\n' "$reference" >> "$GITHUB_OUTPUT"
        fi
        return 0
        ;;
      401|403)
        fail "$registry_host refused the stored credential while looking for $reference (HTTP $status). Check the variable $username_setting and the secret $password_setting."
        ;;
      404|429|000|5??)
        ;;
      *)
        fail "$registry_host answered HTTP $status for $reference, which waiting does not change. Check the variable $tag_setting."
        ;;
    esac
    if [ $((waited + interval)) -gt "$timeout" ]; then
      fail "the tooling image $reference does not exist after ${waited}s (last answer: HTTP $status). It is published by the CLI's release publisher in aggrega-cli. Publish the CLI release first, then, once the image exists, re-run this workflow$(rerun_hint)."
    fi
    echo "registry-gate: waiting for the tooling image $reference (HTTP $status after ${waited}s; checking again in ${interval}s, for at most ${timeout}s)"
    sleep "$interval"
  done
}

case "$command" in
  credential) check_credential ;;
  image) wait_for_image ;;
esac
