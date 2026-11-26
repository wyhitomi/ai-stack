#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# One-shot setup for ai-stack. Safe to re-run: it never overwrites existing
# secrets, keys or Hermes config. Needs only bash + docker on the host.
#
#   scripts/bootstrap.sh --profile poc-wsl   # WSL2 + NVIDIA GPU (PoC)
#   scripts/bootstrap.sh --profile vps       # 4 vCPU / 8 GB, CPU only
#   scripts/bootstrap.sh                     # re-run with the profile in .env
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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
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

if [[ "$PROFILE" == poc-wsl ]] && ! docker run --rm --gpus all ubuntu:24.04 nvidia-smi >/dev/null 2>&1; then
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

# VPS: publish on the Tailscale interface when available, never on 0.0.0.0
if [[ "$PROFILE" == vps && "$(get_env LAN_BIND)" == 127.0.0.1 ]] && command -v tailscale >/dev/null; then
  TS_IP="$(tailscale ip -4 2>/dev/null | head -1)"
  if [[ -n "$TS_IP" ]]; then
    set_env LAN_BIND "$TS_IP"; log "LiteLLM will listen on the Tailscale IP $TS_IP"
  fi
fi
[[ "$PROFILE" == vps && "$(get_env LAN_BIND)" == 127.0.0.1 ]] && \
  warn "LiteLLM listens on 127.0.0.1 only. Install Tailscale (docs/deploy-vps.md) or use an SSH tunnel."

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
[[ "$WORKSPACE_DIR" == /mnt/* ]] && warn "WORKSPACE_DIR is on the Windows drive ($WORKSPACE_DIR). Keep code in the WSL filesystem (~/...) — /mnt/c is 5-10x slower for git and file watchers."
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

log "Starting postgres, local model(s), litellm…   (profile: $PROFILE)"
# `up` without names starts everything in the profile; hermes/hindsight wait
# for their keys, so start the first group explicitly.
MODELS="llm-coder"; [[ "$(get_env COMPOSE_PROFILES)" == *autocomplete* ]] && MODELS="llm-autocomplete llm-coder"
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

  First start downloads the model(s) (VPS ~1.3 GB, PoC ~20 GB). Follow it with:
    docker compose logs -f llm-coder
  Then run:  scripts/doctor.sh

  Resource budget check:  scripts/doctor.sh  (first section)
  Next: docs/deploy-$PROFILE.md (network access, client setup).
EOF
