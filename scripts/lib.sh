#!/usr/bin/env bash
# Shared helpers. Host requirements: bash + docker. Nothing else: HTTP calls
# run in a throwaway curl container attached to the stack's network.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.11.1}"

log()  { printf '\033[1;35m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

get_env() {
  [[ -f .env ]] || return 0
  grep -E "^$1=" .env | head -1 | cut -d= -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}
set_env() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${val}|" .env   # secrets are hex: no '|' possible
  else
    echo "${key}=${val}" >> .env
  fi
}

# Cryptographically random hex from the kernel; no openssl needed.
rand_hex() { head -c "${1:-24}" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# curl inside the ai-stack network: use service names (http://litellm:4000).
dcurl() { docker run --rm --network ai-stack "$CURL_IMAGE" -fsS --max-time "${DCURL_TIMEOUT:-60}" "$@"; }

# Extract a top-level string field from a JSON response (no jq/python on host).
json_field() { grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/'; }
