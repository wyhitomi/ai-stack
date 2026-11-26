#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# One-shot setup for ai-stack on the WSL2 laptop. Safe to re-run: it never
# overwrites existing secrets, keys or Hermes config. Needs only bash + docker.
#
#   scripts/bootstrap.sh                         # gpu profile (default) → docker-compose.gpu.yml
#   scripts/bootstrap.sh --profile cpu           # CPU only              → docker-compose.cpu.yml
#   scripts/bootstrap.sh --profile cpu --local-model off   # CPU file, no local model
#                                                #   (routes to the external API in .env CODER_*)
#   Re-running without --profile keeps the profile already in .env.
#
#   1. creates .env from .env.example + the profile, generates every secret
#   2. seeds data/hermes (config.yaml + Hindsight plugin config)
#   3. starts Postgres, the local model(s) and LiteLLM
#   4. creates LiteLLM virtual keys for Hermes, Hindsight and VS Code
#   5. starts Hindsight + Hermes and installs the Hindsight memory plugin
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ── Arguments ────────────────────────────────────────────────────────────────
PROFILE=""
LOCAL_MODEL_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:?--profile needs gpu|cpu}"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    --local-model) LOCAL_MODEL_ARG="${2:?--local-model needs on|off}"; shift 2 ;;
    --local-model=*) LOCAL_MODEL_ARG="${1#*=}"; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -z "$PROFILE" ]] && PROFILE="$(get_env STACK_PROFILE)"
PROFILE="${PROFILE:-gpu}"
[[ -f "profiles/$PROFILE/stack.env" ]] || die "Unknown profile '$PROFILE'. Available: $(ls profiles | paste -sd' ')"

# ── Pre-flight ───────────────────────────────────────────────────────────────
# The repo must live in the Linux filesystem: on /mnt/c (the Windows drive)
# Postgres cannot chmod its data dir and fails to start, and I/O is 5-10x slower.
if [[ "$PWD" == /mnt/* ]]; then
  die "The repo is on the Windows drive ($PWD). Clone it inside WSL instead:
      cd ~ && git clone <repo-url> ai-stack && cd ~/ai-stack && scripts/bootstrap.sh"
fi
# A Windows checkout with CRLF line endings breaks .env and YAML parsing too.
if grep -q $'\r' .env.example docker-compose.gpu.yml 2>/dev/null; then
  die "Files have Windows (CRLF) line endings. Re-clone inside WSL (see above) or run: git config core.autocrlf input && git rm -rq --cached . && git reset --hard"
fi
command -v docker >/dev/null || die "docker not found. See docs/setup-wsl.md."
docker compose version >/dev/null 2>&1 || die "docker compose v2 plugin not found."
if ! docker info >/dev/null 2>&1; then
  if id -nG "$(id -un)" | grep -qw docker && ! id -Gn | grep -qw docker; then
    die "You were just added to the docker group, but this shell predates it. Close and reopen the Ubuntu terminal (or run: newgrp docker), then re-run."
  fi
  die "Docker daemon not reachable. Is it running? (sudo systemctl status docker) Are you in the docker group? (scripts/install-docker-wsl.sh --check)"
fi

if [[ "$(grep -E '^COMPOSE_FILE=' "profiles/$PROFILE/stack.env")" == *gpu* ]] && ! docker run --rm --gpus all ubuntu:24.04 nvidia-smi >/dev/null 2>&1; then
  die "Docker can't see the GPU. Install the NVIDIA Container Toolkit (docs/setup-wsl.md), or use --profile cpu."
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
IS_GPU=0; [[ "$(get_env COMPOSE_FILE)" == *gpu* ]] && IS_GPU=1

# ── Local model on/off (cpu profile only) ────────────────────────────────────
case "$LOCAL_MODEL_ARG" in
  "") ;;
  on|true|yes)
    set_env LOCAL_MODEL true
    # Back to fully local routes: profile defaults, no external model/key overrides.
    for route in CODER AUTOCOMPLETE MEMORY; do
      set_env ${route}_API_BASE "$(grep -E "^${route}_API_BASE=" "profiles/$PROFILE/stack.env" | cut -d= -f2-)"
      set_env ${route}_MODEL ""; set_env ${route}_API_KEY ""
    done
    log "Local model ON: all routes → local llama.cpp" ;;
  off|false|no)
    (( IS_GPU )) && die "The gpu profile always runs its local models. Use --profile cpu --local-model off."
    set_env LOCAL_MODEL false ;;
  *) die "--local-model takes on|off" ;;
esac

# ── External routes (no local model) ─────────────────────────────────────────
is_local() { [[ -z "$1" || "$1" == *llm-coder* || "$1" == *llm-autocomplete* ]]; }
if [[ "$(get_env LOCAL_MODEL)" == false ]]; then
  # Validate first, change nothing else until the external route is complete.
  coder_base="$(get_env CODER_API_BASE)"; coder_model="$(get_env CODER_MODEL)"
  is_local "$coder_base" && die "LOCAL_MODEL=false but CODER_API_BASE is '${coder_base:-empty}'. Set CODER_MODEL / CODER_API_BASE / CODER_API_KEY in .env (see .env.example) and re-run."
  [[ -n "$coder_model" ]] || die "LOCAL_MODEL=false: set CODER_MODEL in .env (LiteLLM syntax, e.g. openai/<model-id>)."
  [[ -n "$(get_env CODER_API_KEY)" ]] || die "LOCAL_MODEL=false: set CODER_API_KEY in .env (your key at that endpoint)."
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
  log "No local model: coder/autocomplete/memory → $coder_base"
  warn "Prompts and Hindsight's memory extraction now go to that external endpoint."
elif (( ! IS_GPU )); then
  set_env COMPOSE_PROFILES local-model
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

# ── Phase 1: persistence + router (no models yet) ────────────────────────────
log "Pulling images (first run downloads several GB)…"
docker compose pull --quiet
docker pull --quiet "$CURL_IMAGE" >/dev/null

# Models start LAST (phase 4): a model download/start problem must not block
# Postgres, LiteLLM, Hindsight or Hermes, and it gets its own diagnosis.
log "Starting postgres + litellm…   (profile: $PROFILE, local model: $(get_env LOCAL_MODEL))"
docker compose up -d postgres litellm
wait_healthy ai-postgres 120 postgres || { diagnose ai-postgres; exit 1; }
wait_healthy ai-litellm  300 litellm  || { diagnose ai-litellm;  exit 1; }
log "postgres + litellm are healthy"

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

# ── Phase 4: local models (slow first time: downloads) ───────────────────────
# autocomplete first: on the GPU, llm-coder's --fit sizes itself around it.
MODELS=""
docker compose config --services | grep -qx llm-autocomplete && MODELS="llm-autocomplete"
docker compose config --services | grep -qx llm-coder        && MODELS="$MODELS llm-coder"
MODEL_FAILED=""
for svc in $MODELS; do
  c="ai-$svc"
  timeout=1800; [[ "$svc" == llm-coder ]] && timeout=7200   # ~19 GB on a slow link
  log "Starting $svc (first start downloads the model; progress below)…"
  docker compose up -d "$svc"
  if wait_healthy "$c" "$timeout" "$svc"; then
    log "$svc is healthy"
  else
    diagnose "$c"
    MODEL_FAILED="$svc"
    break
  fi
done

# ── Summary ──────────────────────────────────────────────────────────────────
LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
cat <<EOF

$( [[ -z "$MODEL_FAILED" ]] && printf '\033[1;32m✓ ai-stack is up\033[0m' || printf '\033[1;33m! ai-stack is up EXCEPT %s (see the diagnosis above)\033[0m' "$MODEL_FAILED")

  LiteLLM (OpenAI API)  http://${LAN_IP:-<host-ip>}:$(get_env LITELLM_PORT)/v1
  LiteLLM admin UI      http://localhost:$(get_env LITELLM_PORT)/ui   (user: $(get_env LITELLM_UI_USERNAME), password in .env)
  Hermes Agent API      http://${LAN_IP:-<host-ip>}:$(get_env HERMES_API_PORT)/v1   (model: hermes-agent)
  Hindsight memory UI   http://localhost:9999
  Postgres              127.0.0.1:5432  (local only)

  VS Code key (LiteLLM):  grep VSCODE_LLM_API_KEY .env
  Hermes API key:         grep HERMES_API_KEY .env

  Check every hop with:  scripts/doctor.sh

  LAN access from other machines: windows\\setup-lan.ps1 on Windows (docs/setup-wsl.md).
EOF

# Non-zero exit when a model failed, so scripts/CI notice.
[[ -z "$MODEL_FAILED" ]] || exit 1
