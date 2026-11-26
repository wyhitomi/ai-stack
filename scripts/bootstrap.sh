#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# One-shot setup for ai-stack. Safe to re-run: it never overwrites existing
# secrets, keys or Hermes config.
#
#   1. creates .env from .env.example and generates every secret
#   2. seeds data/hermes (config.yaml + Hindsight plugin config)
#   3. starts Postgres, the local models and LiteLLM
#   4. creates LiteLLM virtual keys for Hermes, Hindsight and VS Code
#   5. starts Hindsight + Hermes and installs the Hindsight memory plugin
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log()  { printf '\033[1;35m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# ── Pre-flight ───────────────────────────────────────────────────────────────
command -v docker >/dev/null || die "docker not found. See docs/wsl-lan.md → 'Install Docker'."
docker compose version >/dev/null 2>&1 || die "docker compose v2 plugin not found."
command -v openssl >/dev/null || die "openssl not found (sudo apt install openssl)."
command -v curl >/dev/null || die "curl not found (sudo apt install curl)."

if ! docker run --rm --gpus all ubuntu:24.04 true >/dev/null 2>&1; then
  warn "Docker can't see a GPU. The llama.cpp services will fail to start."
  warn "Install the NVIDIA Container Toolkit (docs/wsl-lan.md) or switch to CPU (docs/models.md)."
fi

# ── .env + secrets ───────────────────────────────────────────────────────────
[[ -f .env ]] || { cp .env.example .env; log "Created .env from .env.example"; }

get_env() { grep -E "^$1=" .env | head -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*$//' | xargs || true; }
set_env() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" .env; then
    # use a delimiter that can't appear in hex/base64url secrets
    sed -i "s|^${key}=.*|${key}=${val}|" .env
  else
    echo "${key}=${val}" >> .env
  fi
}
gen_if_empty() {
  local key="$1" val="$2"
  if [[ -z "$(get_env "$key")" ]]; then set_env "$key" "$val"; log "Generated $key"; fi
}

gen_if_empty POSTGRES_PASSWORD     "$(openssl rand -hex 24)"
gen_if_empty LITELLM_DB_PASSWORD   "$(openssl rand -hex 24)"
gen_if_empty HINDSIGHT_DB_PASSWORD "$(openssl rand -hex 24)"
gen_if_empty LITELLM_MASTER_KEY    "sk-$(openssl rand -hex 24)"
gen_if_empty LITELLM_SALT_KEY      "sk-$(openssl rand -hex 24)"
gen_if_empty LITELLM_UI_PASSWORD   "$(openssl rand -hex 12)"
gen_if_empty HERMES_API_KEY        "hermes-$(openssl rand -hex 24)"

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

log "Starting postgres, llm-coder, llm-autocomplete, litellm…"
docker compose up -d postgres llm-coder llm-autocomplete litellm

LITELLM_PORT="$(get_env LITELLM_PORT)"; LITELLM_PORT="${LITELLM_PORT:-4000}"
LITELLM_URL="http://127.0.0.1:${LITELLM_PORT}"
MASTER="$(get_env LITELLM_MASTER_KEY)"

log "Waiting for LiteLLM to become healthy…"
for _ in $(seq 1 90); do
  curl -fsS "$LITELLM_URL/health/liveliness" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "$LITELLM_URL/health/liveliness" >/dev/null 2>&1 || die "LiteLLM did not start. Check: docker compose logs litellm"

# ── Phase 2: virtual keys ────────────────────────────────────────────────────
create_key() {
  local alias="$1" models="$2" par="$3"
  curl -fsS "$LITELLM_URL/key/generate" \
    -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" \
    -d "{\"key_alias\":\"$alias\",\"models\":$models,\"metadata\":{\"created_by\":\"bootstrap\"},\"max_parallel_requests\":$par}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])'
}
ensure_key() {
  local var="$1" alias="$2" models="$3" par="$4" cur
  cur="$(get_env "$var")"
  if [[ -z "$cur" || "$cur" == "pending" ]]; then
    set_env "$var" "$(create_key "$alias" "$models" "$par")"
    log "Created LiteLLM virtual key '$alias' → $var"
  fi
}
ensure_key HERMES_LLM_API_KEY    hermes    '["coder"]'                  8
ensure_key HINDSIGHT_LLM_API_KEY hindsight '["memory"]'                 4
ensure_key VSCODE_LLM_API_KEY    vscode    '["coder","autocomplete","hermes-agent"]'   8

# ── Phase 3: memory + orchestration ──────────────────────────────────────────
log "Starting hindsight + hermes…"
docker compose up -d hindsight hermes

log "Waiting for Hermes container…"
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
LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"
HERMES_PORT="$(get_env HERMES_API_PORT)"; HERMES_PORT="${HERMES_PORT:-8642}"
cat <<EOF

$(printf '\033[1;32m✓ ai-stack is up\033[0m')

  LiteLLM (OpenAI API)  http://${LAN_IP:-<host-ip>}:${LITELLM_PORT}/v1
  LiteLLM admin UI      http://localhost:${LITELLM_PORT}/ui   (user: $(get_env LITELLM_UI_USERNAME), password in .env)
  Hermes Agent API      http://${LAN_IP:-<host-ip>}:${HERMES_PORT}/v1   (model: hermes-agent)
  Hindsight memory UI   http://localhost:9999
  Postgres              127.0.0.1:5432  (local only)

  VS Code key (LiteLLM):  grep VSCODE_LLM_API_KEY .env
  Hermes API key:         grep HERMES_API_KEY .env

  First start downloads the models (~20 GB). Follow it with:
    docker compose logs -f llm-coder
  Then run:  scripts/doctor.sh

  For LAN access from other machines, run windows/setup-lan.ps1 on Windows (docs/wsl-lan.md).
EOF
