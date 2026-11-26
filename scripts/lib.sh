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

# ── Container start-up helpers ───────────────────────────────────────────────
# wait_healthy <container> <timeout_s> [progress_label]
#   0 = healthy · 1 = crashed / unhealthy / timed out. Prints the container's
#   latest log line every 30 s (llama.cpp shows its download progress there).
wait_healthy() {
  local c="$1" timeout="$2" label="${3:-$1}" start now last=0 status health restarts base
  start=$(date +%s)
  base=$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null || echo 0)
  while :; do
    status=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$c" 2>/dev/null || true)
    restarts=$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null || echo 0)
    [[ "$status" == running && "$health" == healthy ]] && return 0
    [[ "$status" == exited || "$status" == dead || "$status" == missing ]] && return 1
    [[ "$health" == unhealthy ]] && return 1
    (( restarts - base >= 2 )) && return 1   # crash loop under restart: unless-stopped
    now=$(date +%s)
    (( now - start > timeout )) && return 1
    if (( now - last >= 30 )); then
      last=$now
      printf '    … %s (%ss): %s\n' "$label" "$((now - start))" \
        "$(docker logs --tail 1 "$c" 2>&1 | tr -d '\r' | cut -c1-110)"
    fi
    sleep 5
  done
}

# diagnose <container>: state, last log lines and a targeted hint.
diagnose() {
  local c="$1" logs
  printf '\n\033[1;31m✗ %s did not become healthy\033[0m\n' "$c" >&2
  docker inspect -f '  status={{.State.Status}} exit={{.State.ExitCode}} oom_killed={{.State.OOMKilled}} restarts={{.RestartCount}} health={{if .State.Health}}{{.State.Health.Status}}{{end}}' "$c" >&2 2>/dev/null || true
  logs="$(docker logs --tail 40 "$c" 2>&1 | tr -d '\r')"
  printf '  ── last log lines ──\n%s\n  ────────────────────\n' "$(sed 's/^/  /' <<<"$logs")" >&2
  local oom; oom=$(docker inspect -f '{{.State.OOMKilled}} {{.State.ExitCode}}' "$c" 2>/dev/null || true)
  if [[ "$oom" == true* || "$oom" == *" 137" ]]; then
    warn "It hit its memory limit. Raise the matching *_MEM in .env (e.g. AUTOCOMPLETE_MEM=3g), then re-run."
  elif grep -qiE 'certificate|ssl|tls' <<<"$logs"; then
    warn "TLS error while downloading the model: typical on a corporate network that inspects HTTPS."
    warn "Download the .gguf in a browser instead and point the profile at it (docs/models.md → 'Offline / corporate network')."
  elif grep -qiE 'toomanyrequests|429|rate limit' <<<"$logs"; then
    warn "Docker Hub rate limit (anonymous pulls are limited per IP; a shared office IP hits it sooner). Wait and re-run, or use a local .gguf (docs/models.md)."
  elif grep -qiE 'could not resolve|timed out|connection refused|failed to (download|fetch)|curl|404|401|403' <<<"$logs"; then
    warn "The model download failed (network, proxy or wrong repo/tag). Check that containers reach the model source:"
    warn "  docker run --rm curlimages/curl:8.11.1 -sSI https://registry-1.docker.io/v2/ | head -1   (expect HTTP 401: reachable)"
    warn "Behind a proxy: set it in ~/.docker/config.json (\"proxies\"), or use a local .gguf (docs/models.md)."
  elif grep -qiE 'no kernel image|CUDA error|cudaMalloc|out of memory' <<<"$logs"; then
    warn "CUDA/VRAM problem. Close GPU-heavy apps; if it says 'no kernel image', set LLAMACPP_GPU_IMAGE=ghcr.io/ggml-org/llama.cpp:server-cuda13 in .env."
  fi
  warn "Full log: docker logs $c   ·   retry: scripts/bootstrap.sh"
}
