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
    # While restarting, ExitCode is the previous run's: remember a kill (137).
    if [[ "$status" == restarting ]]; then
      LAST_EXIT=$(docker inspect -f '{{.State.ExitCode}}' "$c" 2>/dev/null || echo 0)
    fi
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
  local oom limit; oom=$(docker inspect -f '{{.State.OOMKilled}} {{.State.ExitCode}}' "$c" 2>/dev/null || true)
  limit=$(docker inspect -f '{{.HostConfig.Memory}}' "$c" 2>/dev/null || echo 0)
  # 137 = SIGKILL. Docker does not always set OOMKilled on cgroup v2, and a
  # process killed while loading leaves an empty log: both point to memory.
  if [[ "$oom" == true* || "$oom" == *" 137" || "${LAST_EXIT:-0}" == 137 ]] || { [[ -z "${logs//[[:space:]]/}" ]] && (( limit > 0 )); }; then
    warn "Killed (exit 137 / no log output): it most likely hit its memory limit of $((limit / 1024 / 1024)) MB."
    warn "Raise the matching *_MEM in .env (e.g. LITELLM_MEM=2048m), keep the envelope in mind (docs/resources.md), then re-run."
  elif grep -qiE 'certificate|ssl|tls' <<<"$logs"; then
    warn "TLS error while downloading the model: typical on a corporate network that inspects HTTPS."
    warn "Download the .gguf in a browser instead and point the profile at it (docs/models.md → 'Offline / corporate network')."
  elif grep -qi 'No GGUF layer found' <<<"$logs"; then
    warn "llama.cpp can't read Docker Hub's ai/ model format (LLAMA_ARG_DOCKER_REPO). In profiles/<profile>/llm-coder.env use"
    warn "MODEL_DOCKER_REPO=<repo:tag> + LLAMA_ARG_MODEL=/root/.cache/gguf/<file>.gguf instead: bootstrap downloads it (docs/models.md)."
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

# ── Model download from Docker Hub ───────────────────────────────────────────
# Docker Hub's ai/ namespace publishes models as CNCF ModelPack artifacts: the
# .gguf is a layer of type application/vnd.cncf.model.weight.v1.raw. llama.cpp's
# own --docker-repo only accepts "gguf" layer types, so it fails with "No GGUF
# layer found in Docker manifest". We fetch the blob ourselves instead.
#
# fetch_hub_model <repo:tag> <dest on the host>
#   0 = file present and verified · 1 = failed (reason printed with warn).
#   Resumable: a partial download is kept as <dest>.part and continued on re-run.
REGISTRY="https://registry-1.docker.io"
hub_curl() {
  docker run --rm --user "$(id -u):$(id -g)" -v "$ROOT/data/models:/models" \
    "$CURL_IMAGE" "$@"
}
hub_token() {
  hub_curl -fsS --max-time 30 \
    "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$1:pull" \
  | json_field token
}
fetch_hub_model() {
  local ref="$1" dest="$2" repo tag tok manifest layers n digest size have free rel
  repo="${ref%:*}"; tag="${ref##*:}"
  [[ "$ref" == *:* && -n "$repo" && -n "$tag" ]] || { warn "MODEL_DOCKER_REPO must be <repo>:<tag>, got '$ref'"; return 1; }
  [[ "$dest" == "$ROOT/data/models/"* ]] || { warn "The model path must be under data/models (LLAMA_ARG_MODEL=/root/.cache/...)"; return 1; }
  rel="${dest#"$ROOT/data/models/"}"

  tok="$(hub_token "$repo")" || true
  if [[ -z "$tok" ]]; then
    warn "Could not get a Docker Hub token. Check that containers reach Docker Hub:"
    warn "  docker run --rm $CURL_IMAGE -sSI $REGISTRY/v2/ | head -1   (expect HTTP 401: reachable)"
    return 1
  fi
  manifest="$(hub_curl -sS --max-time 60 -H "Authorization: Bearer $tok" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
    "$REGISTRY/v2/$repo/manifests/$tag" | tr -d '\n')" || true
  if grep -qi 'toomanyrequests' <<<"$manifest"; then
    warn "Docker Hub rate limit (anonymous pulls are limited per IP). Wait and re-run, or use a local .gguf (docs/models.md)."
    return 1
  elif grep -q '"errors"' <<<"$manifest" || [[ -z "$manifest" ]]; then
    warn "Docker Hub did not return the manifest of $ref: ${manifest:0:200}"
    warn "Check the tag at https://hub.docker.com/r/$repo/tags"
    return 1
  fi

  # One line per layer/config object; keep the model-weight / gguf layers.
  layers="$(sed 's/"mediaType"/\n&/g' <<<"$manifest" | grep -E '^"mediaType" *: *"[^"]*(gguf|model\.weight)' || true)"
  n="$(grep -c . <<<"$layers" || true)"
  if (( n == 0 )); then
    warn "$ref has no GGUF layer (manifest: ${manifest:0:300})"; return 1
  elif (( n > 1 )); then
    warn "$ref is split into $n files; only single-file models are supported. Pick another tag or use a local .gguf (docs/models.md)."
    return 1
  fi
  digest="$(grep -o '"digest" *: *"sha256:[0-9a-f]\{64\}"' <<<"$layers" | grep -o 'sha256:[0-9a-f]*')"
  size="$(grep -o '"size" *: *[0-9]*' <<<"$layers" | grep -o '[0-9]*$')"
  [[ -n "$digest" && -n "$size" ]] || { warn "Could not read the layer digest/size of $ref"; return 1; }

  if [[ -f "$dest" && "$(stat -c %s "$dest")" == "$size" ]]; then
    return 0   # already downloaded (verified when it was)
  fi

  mkdir -p "$(dirname "$dest")" || return 1
  have=0; [[ -f "$dest.part" ]] && have="$(stat -c %s "$dest.part")"
  free="$(df -PB1 "$(dirname "$dest")" | awk 'NR==2 {print $4}')"
  if (( free < size - have )); then
    warn "Not enough disk space for $ref: need $(( (size - have) / 1024**3 + 1 )) GB, $(( free / 1024**3 )) GB free in data/models."
    return 1
  fi

  log "Downloading $ref → data/models/$rel ($(( size / 1024**2 )) MB; resumable, re-run to continue)…"
  local attempt rc
  for attempt in 1 2 3 4 5; do
    have=0; [[ -f "$dest.part" ]] && have="$(stat -c %s "$dest.part")"
    (( have >= size )) && break
    # A fresh token each attempt (they expire after 5 min). curl does not send
    # the Authorization header on to the CDN host the registry redirects to.
    tok="$(hub_token "$repo")" || true
    hub_curl -fL --progress-bar --connect-timeout 30 -C - \
      -H "Authorization: Bearer $tok" \
      -o "/models/$rel.part" "$REGISTRY/v2/$repo/blobs/$digest" && continue
    rc=$?
    # 22 = HTTP error (403/404/429…): retrying won't help.
    (( rc == 22 )) && { warn "Docker Hub refused the download of $ref (see the curl error above)."; return 1; }
    warn "Download interrupted (curl exit $rc, attempt $attempt/5), resuming in 10 s…"
    sleep 10
  done
  have=0; [[ -f "$dest.part" ]] && have="$(stat -c %s "$dest.part")"
  if (( have != size )); then
    warn "Download incomplete ($(( have / 1024**2 )) of $(( size / 1024**2 )) MB). Re-run scripts/bootstrap.sh to resume."
    return 1
  fi

  log "Verifying the checksum (about a minute)…"
  if [[ "sha256:$(sha256sum "$dest.part" | cut -d' ' -f1)" != "$digest" ]]; then
    rm -f "$dest.part"
    warn "Checksum mismatch: the download was corrupted and has been deleted. Re-run scripts/bootstrap.sh."
    return 1
  fi
  mv "$dest.part" "$dest"
  log "Model ready: data/models/$rel"
}

# profile_var <profile> <file> <KEY>: value of an uncommented KEY= line.
profile_var() {
  grep -E "^$3=" "profiles/$1/$2" 2>/dev/null | tail -1 | cut -d= -f2- \
    | sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//'
}
