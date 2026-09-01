#!/usr/bin/env bash
#
# Delete the GitHub Actions cache entry stored under a given cache key, so that a
# subsequent actions/cache/save under the same key is not rejected as "already exists".
#
# Inputs (environment):
#   RC_KEY                   required  the exact cache key to delete
#   RC_REF                   optional  git ref the entry is scoped to (default: $GITHUB_REF)
#   RC_TOKEN                 required  token with `actions: write`
#   RC_REPOSITORY            optional  owner/repo (default: $GITHUB_REPOSITORY)
#   RC_API_URL               optional  API base (default: $GITHUB_API_URL, then api.github.com)
#   RC_FAIL_ON_DELETE_ERROR  optional  "true" to exit non-zero on a failed delete
#   RC_SKIP_DELETE           optional  "true" to do nothing
#
# Outputs (written to $GITHUB_OUTPUT):
#   deleted        "true" | "false"
#   http-status    the HTTP status code, or "skipped"

set -u

emit() {
  # emit <name> <value>
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  fi
}

# GitHub Actions workflow commands. Harmless plain text when run outside Actions.
notice() { printf '::notice::%s\n' "$1"; }
warn()   { printf '::warning::%s\n' "$1"; }
fail()   { printf '::error::%s\n' "$1"; }

# Percent-encode everything outside the unreserved set, so keys containing
# "/", "+", spaces, etc. survive the query string.
# LC_ALL=C so we walk bytes, not multibyte characters, and mask to 0xFF because
# printf "'x" yields a signed value for bytes above 127.
urlencode() {
  local LC_ALL=C
  local string="$1" i char byte hex out=''
  for (( i = 0; i < ${#string}; i++ )); do
    char="${string:i:1}"
    case "$char" in
      [A-Za-z0-9._~-])
        out="${out}${char}"
        ;;
      *)
        byte=$(( $(printf '%d' "'$char") & 0xFF ))
        printf -v hex '%%%02X' "$byte"
        out="${out}${hex}"
        ;;
    esac
  done
  printf '%s' "$out"
}

KEY="${RC_KEY:-}"
REF="${RC_REF:-${GITHUB_REF:-}}"
TOKEN="${RC_TOKEN:-}"
REPOSITORY="${RC_REPOSITORY:-${GITHUB_REPOSITORY:-}}"
API_URL="${RC_API_URL:-${GITHUB_API_URL:-https://api.github.com}}"
FAIL_ON_DELETE_ERROR="${RC_FAIL_ON_DELETE_ERROR:-false}"
SKIP_DELETE="${RC_SKIP_DELETE:-false}"

if [ "$SKIP_DELETE" = "true" ]; then
  notice "refresh-cache: skip-delete is true, going straight to save."
  emit deleted false
  emit http-status skipped
  exit 0
fi

if [ -z "$KEY" ]; then
  fail "refresh-cache: input 'key' is required."
  exit 1
fi

if [ -z "$REPOSITORY" ]; then
  fail "refresh-cache: could not determine the repository (GITHUB_REPOSITORY is unset)."
  exit 1
fi

if [ -z "$TOKEN" ]; then
  fail "refresh-cache: no token available. Pass 'token:' explicitly, or make sure GITHUB_TOKEN is exposed to the job."
  exit 1
fi

URL="${API_URL}/repos/${REPOSITORY}/actions/caches?key=$(urlencode "$KEY")"
if [ -n "$REF" ]; then
  URL="${URL}&ref=$(urlencode "$REF")"
fi

BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT

STATUS="$(
  curl --silent --show-error \
    --request DELETE \
    --write-out '%{http_code}' \
    --output "$BODY_FILE" \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer ${TOKEN}" \
    --header "X-GitHub-Api-Version: 2022-11-28" \
    "$URL"
)" || STATUS="000"

emit http-status "$STATUS"

case "$STATUS" in
  200)
    notice "refresh-cache: deleted the existing cache entry for key '${KEY}' (ref '${REF}')."
    emit deleted true
    exit 0
    ;;
  204)
    notice "refresh-cache: deleted the existing cache entry for key '${KEY}'."
    emit deleted true
    exit 0
    ;;
  404)
    # Cache miss, or the entry lives on a different ref. Nothing to delete; this is normal
    # on the very first run of a workflow and must not fail the build.
    notice "refresh-cache: no existing cache entry for key '${KEY}' (ref '${REF}'). Nothing to delete."
    emit deleted false
    exit 0
    ;;
  401)
    emit deleted false
    MSG="refresh-cache: 401 Unauthorized from the cache API. The token passed to 'token:' is invalid or expired."
    ;;
  403)
    emit deleted false
    MSG="refresh-cache: 403 Forbidden when deleting cache key '${KEY}'. Deleting a cache requires the 'actions: write' permission. Add this to your job (or workflow):

  permissions:
    actions: write

Note that GITHUB_TOKEN is always read-only for workflow runs triggered by a pull request from a fork; in that case pass a PAT with the 'repo' scope via 'token:', or skip the refresh on fork PRs."
    ;;
  000)
    emit deleted false
    MSG="refresh-cache: could not reach ${API_URL}. Network error or curl is unavailable on this runner."
    ;;
  *)
    emit deleted false
    MSG="refresh-cache: unexpected HTTP ${STATUS} when deleting cache key '${KEY}'. Response: $(tr -d '\n' <"$BODY_FILE" | cut -c1-500)"
    ;;
esac

if [ "$FAIL_ON_DELETE_ERROR" = "true" ]; then
  fail "$MSG"
  exit 1
fi

warn "$MSG"
warn "refresh-cache: continuing to the save step anyway. If an entry already exists under this key, the save will be a no-op and your cache will stay stale. Set 'fail-on-delete-error: true' to make this an error instead."
exit 0
