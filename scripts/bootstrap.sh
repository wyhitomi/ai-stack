#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# One-shot setup for ai-stack. Safe to re-run: it never overwrites existing
# secrets, keys or Hermes config. Needs only bash + docker on the host.
#
#   WSL PoC (runs the models):
#     scripts/bootstrap.sh --profile poc-wsl                # GPU   → docker-compose.gpu.yml
#     scripts/bootstrap.sh --profile poc-wsl --serve-vps    #   + publish models to the VPS (Tailscale)
#     scripts/bootstrap.sh --profile poc-wsl-cpu            # CPU   → docker-compose.cpu.yml
#     scripts/bootstrap.sh --profile poc-wsl-cpu --local-model off   # CPU file without a model
#   VPS (no local model, uses the WSL GPU):
#     scripts/bootstrap.sh --profile vps --gpu-host <wsl-tailscale-ip>
#   Re-run with what is in .env:
#     scripts/bootstrap.sh
#
#   1. creates .env from .env.example + the profile, generates every secret
#   2. seeds data/hermes (config.yaml + Hindsight plugin config)
#   3. starts Postgres, the local models and LiteLLM
#   4. creates LiteLLM virtual keys for Hermes, Hindsight and VS Code
#   5. starts Hindsight + Hermes and installs the Hindsight memory plugin
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ── Arguments ────────────────────────────────────────────────────────────────
PROFILE=""
LOCAL_MODEL_ARG=""
GPU_HOST_ARG=""
SERVE_VPS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local-model) LOCAL_MODEL_ARG="${2:?--local-model needs on|off}"; shift 2 ;;
    --local-model=*) LOCAL_MODEL_ARG="${1#*=}"; shift ;;
    --profile) PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    --gpu-host) GPU_HOST_ARG="${2:?--gpu-host needs an IP or hostname}"; shift 2 ;;
    --gpu-host=*) GPU_HOST_ARG="${1#*=}"; shift ;;
    --serve-vps) SERVE_VPS=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -z "$PROFILE" ]] && PROFILE="$(get_env STACK_PROFILE)"
[[ -n "$PROFILE" ]] || die "Choose a profile: scripts/bootstrap.sh --profile <$(ls profiles | paste -sd'|')>"
[[ -f "profiles/$PROFILE/stack.env" ]] || die "Unknown profile '$PROFILE'. Available: $(ls profiles | paste -sd' ')"

# ── Pre-flight ───────────────────────────────────────────────────────────────
command -v docker >/dev/null || die "docker not found. See docs/deploy-vps.md or docs/deploy-poc-wsl.md."
docker compose version >/dev/null 2>&1 || die "docker compose v2 plugin not found."
docker info >/dev/null 2>&1 || die "Docker daemon not reachable (is it running? are you in the docker group?)."

if [[ "$(grep -E '^COMPOSE_FILE=' "profiles/$PROFILE/stack.env")" == *gpu* ]] && ! docker run --rm --gpus all ubuntu:24.04 nvidia-smi >/dev/null 2>&1; then
  die "Docker can't see the GPU. Install the NVIDIA Container Toolkit (docs/deploy-poc-wsl.md)."
fi

# ── .env + profile + secrets ─────────────────────────────────────────────────
[[ -f .env ]] || { cp .env.example .env; log "Created .env from .env.example"; }

# Apply the profile: every KEY=VALUE in stack.env overwrites .env. Switching
# profiles later re-applies the new one (secrets and keys are untouched).
if [[ "$(get_env STACK_PROFILE)" != "$PROFILE" ]]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^[A-Z_]+= ]] || continue
    set_env "${line%%=*}" "${line#*=}"
  done < "profiles/$PROFILE/stack.env"
  log "Applied profile '$PROFILE'"
fi

# ── Tailscale address (VPS: LiteLLM bind · WSL: what the VPS connects to) ────
tailscale_ip() {
  local ip=""
  command -v tailscale >/dev/null && ip="$(tailscale ip -4 2>/dev/null | head -1)"
  # WSL with Tailscale installed on Windows: call the Windows CLI via interop
  [[ -z "$ip" ]] && command -v tailscale.exe >/dev/null && ip="$(tailscale.exe ip -4 2>/dev/null | tr -d '\r' | head -1)"
  echo "$ip"
}
HAS_LOCAL_MODEL_FILE=0; [[ -f "profiles/$PROFILE/llm-coder.env" ]] && HAS_LOCAL_MODEL_FILE=1
IS_GPU=0; [[ "$(get_env COMPOSE_FILE)" == *gpu* ]] && IS_GPU=1

# ── Local model on/off ───────────────────────────────────────────────────────
case "$LOCAL_MODEL_ARG" in
  "") ;;
  on|true|yes)
    (( HAS_LOCAL_MODEL_FILE )) || die "Profile '$PROFILE' has no local model (no profiles/$PROFILE/llm-coder.env). Models run on the WSL machine."
    set_env LOCAL_MODEL true
    # Back to fully local routes: profile defaults, no remote model/key overrides.
    for route in CODER AUTOCOMPLETE MEMORY; do
      set_env ${route}_API_BASE "$(grep -E "^${route}_API_BASE=" "profiles/$PROFILE/stack.env" | cut -d= -f2-)"
      set_env ${route}_MODEL ""; set_env ${route}_API_KEY ""
    done
    log "Local model ON: all routes → local llama.cpp" ;;
  off|false|no)
    (( IS_GPU )) && die "The GPU compose file always runs its local models. Use a CPU profile for --local-model off."
    set_env LOCAL_MODEL false ;;
  *) die "--local-model takes on|off" ;;
esac

# ── GPU host: protect the model servers, optionally publish them for the VPS ─
if (( IS_GPU )); then
  # Always keyed: the ports may be published beyond localhost (--serve-vps).
  [[ -n "$(get_env CODER_API_KEY)" ]] || { set_env CODER_API_KEY "llm-$(rand_hex 24)"; log "Generated CODER_API_KEY"; }
  if (( SERVE_VPS )); then
    TS_IP="$(tailscale_ip)"
    [[ -n "$TS_IP" ]] || die "--serve-vps: no Tailscale IP found. Install Tailscale on Windows or in WSL, run 'tailscale up', then retry (docs/deploy-poc-wsl.md)."
    set_env CODER_BIND "$TS_IP"
    log "llm-coder :8080 and llm-autocomplete :8081 published on Tailscale IP $TS_IP (API key required)"
  fi
elif (( SERVE_VPS )); then
  die "--serve-vps only applies to the GPU profile (poc-wsl)."
fi

# ── Remote routes (no local model) ───────────────────────────────────────────
is_local() { [[ -z "$1" || "$1" == *llm-coder* || "$1" == *llm-autocomplete* ]]; }
if [[ "$(get_env LOCAL_MODEL)" == false ]]; then
  if [[ -n "$GPU_HOST_ARG" ]]; then
    for route in CODER AUTOCOMPLETE MEMORY; do
      cur="$(get_env ${route}_API_BASE)"
      [[ "$cur" == *GPU_HOST* ]] && set_env ${route}_API_BASE "${cur//GPU_HOST/$GPU_HOST_ARG}"
    done
    log "Model routes → GPU host $GPU_HOST_ARG"
  fi
  # Validate first, change nothing else until the remote routes are complete.
  for route in CODER AUTOCOMPLETE MEMORY; do
    if [[ "$(get_env ${route}_API_BASE)" == *GPU_HOST* ]]; then
      die "${route}_API_BASE still has the GPU_HOST placeholder. Re-run with --gpu-host <wsl-tailscale-ip>."
    fi
  done
  coder_base="$(get_env CODER_API_BASE)"; coder_model="$(get_env CODER_MODEL)"
  is_local "$coder_base" && die "LOCAL_MODEL=false but CODER_API_BASE is '${coder_base:-empty}'. Set CODER_MODEL / CODER_API_BASE / CODER_API_KEY in .env (see .env.example) and re-run."
  [[ -n "$coder_model" ]] || die "LOCAL_MODEL=false: set CODER_MODEL in .env (e.g. openai/coder for a remote llama.cpp)."
  [[ -n "$(get_env CODER_API_KEY)" ]] || die "Set CODER_API_KEY in .env to the CODER_API_KEY from the GPU host's .env (on WSL: grep CODER_API_KEY ~/ai-stack/.env)."
  # Routes still pointing at the (absent) local server follow `coder`.
  for route in AUTOCOMPLETE MEMORY; do
    if is_local "$(get_env ${route}_API_BASE)"; then
      set_env ${route}_API_BASE "$coder_base"
      case "$route" in
        MEMORY)       set_env MEMORY_MODEL "$coder_model" ;;
        AUTOCOMPLETE) set_env AUTOCOMPLETE_MODEL "text-completion-openai/${coder_model#*/}" ;;
      esac
    fi
  done
  set_env COMPOSE_PROFILES ""
  log "No local model: coder → $coder_base · autocomplete → $(get_env AUTOCOMPLETE_API_BASE)"
elif [[ "$(get_env COMPOSE_FILE)" == *cpu* ]]; then
  set_env COMPOSE_PROFILES local-model
fi

# VPS: publish on the Tailscale interface when available, never on 0.0.0.0
if [[ "$PROFILE" == vps && "$(get_env LAN_BIND)" == 127.0.0.1 ]]; then
  TS_IP="$(tailscale_ip)"
  [[ -n "$TS_IP" ]] && { set_env LAN_BIND "$TS_IP"; log "LiteLLM will listen on the Tailscale IP $TS_IP"; }
fi
if [[ "$PROFILE" == vps && "$(get_env LAN_BIND)" == 127.0.0.1 ]]; then
  warn "LiteLLM listens on 127.0.0.1 only. Install Tailscale (docs/deploy-vps.md) or use an SSH tunnel."
fi

gen_if_empty() {
  local key="$1" val="$2"
  if [[ -z "$(get_env "$key")" ]]; then set_env "$key" "$val"; log "Generated $key"; fi
}
gen_if_empty POSTGRES_PASSWORD     "$(rand_hex 24)"
gen_if_empty LITELLM_DB_PASSWORD   "$(rand_hex 24)"
gen_if_empty HINDSIGHT_DB_PASSWORD "$(rand_hex 24)"
gen_if_empty LITELLM_MASTER_KEY    "sk-$(rand_hex 24)"
gen_if_empty LITELLM_SALT_KEY      "sk-$(rand_hex 24)"
gen_if_empty LITELLM_UI_PASSWORD   "$(rand_hex 12)"
gen_if_empty HERMES_API_KEY        "hermes-$(rand_hex 24)"

set_env HERMES_UID "$(id -u)"
set_env HERMES_GID "$(id -g)"

WORKSPACE_DIR="$(get_env WORKSPACE_DIR)"
if [[ -z "$WORKSPACE_DIR" || "$WORKSPACE_DIR" == *CHANGE_ME* ]]; then
  WORKSPACE_DIR="$HOME/code"
  set_env WORKSPACE_DIR "$WORKSPACE_DIR"
  log "WORKSPACE_DIR set to $WORKSPACE_DIR (edit .env to change)"
fi
if [[ "$WORKSPACE_DIR" == /mnt/* ]]; then
  warn "WORKSPACE_DIR is on the Windows drive ($WORKSPACE_DIR). Keep code in the WSL filesystem (~/...) — /mnt/c is 5-10x slower for git and file watchers."
fi
mkdir -p "$WORKSPACE_DIR"

# ── Data dirs + Hermes seed config ───────────────────────────────────────────
mkdir -p data/postgres data/models data/hermes/hindsight
if [[ ! -f data/hermes/config.yaml ]]; then
  sed "s|__WORKSPACE_DIR__|${WORKSPACE_DIR}|" hermes/config.yaml.tmpl > data/hermes/config.yaml
  log "Seeded data/hermes/config.yaml"
fi
[[ -f data/hermes/hindsight/config.json ]] || cp hermes/hindsight.config.json data/hermes/hindsight/config.json

# ── Phase 1: persistence, models, router ─────────────────────────────────────
log "Pulling images (first run downloads several GB)…"
docker compose pull --quiet
docker pull --quiet "$CURL_IMAGE" >/dev/null

# `up` without names starts everything in the profile; hermes/hindsight wait
# for their keys, so start the first group explicitly.
MODELS=""
docker compose config --services | grep -qx llm-autocomplete && MODELS="llm-autocomplete"
docker compose config --services | grep -qx llm-coder        && MODELS="$MODELS llm-coder"
log "Starting postgres, ${MODELS:+local model(s), }litellm…   (profile: $PROFILE, local model: $(get_env LOCAL_MODEL))"
docker compose up -d postgres $MODELS litellm

log "Waiting for LiteLLM to become healthy…"
for _ in $(seq 1 90); do
  [[ "$(docker inspect -f '{{.State.Health.Status}}' ai-litellm 2>/dev/null)" == healthy ]] && break
  sleep 2
done
[[ "$(docker inspect -f '{{.State.Health.Status}}' ai-litellm)" == healthy ]] \
  || die "LiteLLM did not start. Check: docker compose logs litellm"

# ── Phase 2: virtual keys ────────────────────────────────────────────────────
MASTER="$(get_env LITELLM_MASTER_KEY)"
create_key() {
  local alias="$1" models="$2" par="$3"
  dcurl http://litellm:4000/key/generate \
    -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" \
    -d "{\"key_alias\":\"$alias\",\"models\":$models,\"metadata\":{\"created_by\":\"bootstrap\"},\"max_parallel_requests\":$par}" \
  | json_field key
}
ensure_key() {
  local var="$1" alias="$2" models="$3" par="$4" cur key
  cur="$(get_env "$var")"
  if [[ -z "$cur" || "$cur" == "pending" ]]; then
    key="$(create_key "$alias" "$models" "$par")"
    [[ "$key" == sk-* ]] || die "Could not create LiteLLM key '$alias'. Check: docker compose logs litellm"
    set_env "$var" "$key"
    log "Created LiteLLM virtual key '$alias' → $var"
  fi
}
ensure_key HERMES_LLM_API_KEY    hermes    '["coder"]'                                 4
ensure_key HINDSIGHT_LLM_API_KEY hindsight '["memory"]'                                2
ensure_key VSCODE_LLM_API_KEY    vscode    '["coder","autocomplete","hermes-agent"]'   8

# ── Phase 3: memory + orchestration ──────────────────────────────────────────
log "Starting hindsight + hermes…"
docker compose up -d hindsight hermes

log "Waiting for the Hermes container…"
for _ in $(seq 1 60); do
  docker exec hermes hermes --version >/dev/null 2>&1 && break
  sleep 2
done

if ! docker exec hermes hermes plugins list 2>/dev/null | grep -qi hindsight; then
  log "Installing Hindsight memory plugin into Hermes…"
  docker exec hermes hermes plugins install hindsight --enable --yes-deps \
    || warn "Plugin install failed — run it by hand: docker exec -it hermes hermes plugins install hindsight"
  docker exec hermes hermes config set memory.provider hindsight >/dev/null || true
  docker compose restart hermes
fi

# ── Summary ──────────────────────────────────────────────────────────────────
LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
cat <<EOF

$(printf '\033[1;32m✓ ai-stack is up\033[0m')

  LiteLLM (OpenAI API)  http://${LAN_IP:-<host-ip>}:$(get_env LITELLM_PORT)/v1
  LiteLLM admin UI      http://localhost:$(get_env LITELLM_PORT)/ui   (user: $(get_env LITELLM_UI_USERNAME), password in .env)
  Hermes Agent API      http://${LAN_IP:-<host-ip>}:$(get_env HERMES_API_PORT)/v1   (model: hermes-agent)
  Hindsight memory UI   http://localhost:9999
  Postgres              127.0.0.1:5432  (local only)

  VS Code key (LiteLLM):  grep VSCODE_LLM_API_KEY .env
  Hermes API key:         grep HERMES_API_KEY .env

  First start downloads the model(s) (poc-wsl ~19 GB, poc-wsl-cpu ~15 GB; vps none). Follow it with:
    docker compose logs -f llm-coder
  Then run:  scripts/doctor.sh

  Resource budget check:  scripts/doctor.sh  (first section)
  Next: docs/deploy-$PROFILE.md (network access, client setup).
EOF
if (( IS_GPU )) && [[ "$(get_env CODER_BIND)" != 127.0.0.1 ]]; then cat <<EOF

  Serving the VPS. On the VPS, put this in ~/ai-stack/.env, then bootstrap:
    CODER_API_KEY=$(get_env CODER_API_KEY)
    scripts/bootstrap.sh --profile vps --gpu-host $(get_env CODER_BIND)
  Windows: allow 8080/8081 from Tailscale → windows\\setup-lan.ps1 -ServeVps
EOF
fi
