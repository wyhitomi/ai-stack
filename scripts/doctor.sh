#!/usr/bin/env bash
# End-to-end health check: every hop of the stack, from Postgres to Hermes.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ -f .env ]] || { echo "No .env — run scripts/bootstrap.sh first"; exit 1; }
get_env() { grep -E "^$1=" .env | head -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*$//' | xargs; }

LL="http://127.0.0.1:$(get_env LITELLM_PORT)"
HM="http://127.0.0.1:$(get_env HERMES_API_PORT)"
VK="$(get_env VSCODE_LLM_API_KEY)"
HK="$(get_env HERMES_API_KEY)"
fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=1; }
chk() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }

echo "Containers"
docker compose ps --format '  {{.Service}}\t{{.State}}\t{{.Health}}'

echo "Hops"
chk "postgres accepts connections"        docker exec ai-postgres pg_isready -U postgres
chk "llm-coder /health"                   docker exec ai-llm-coder curl -fsS http://localhost:8080/health
chk "llm-autocomplete /health"            docker exec ai-llm-autocomplete curl -fsS http://localhost:8080/health
chk "litellm liveliness"                  curl -fsS "$LL/health/liveliness"
chk "litellm lists models (vscode key)"   curl -fsS "$LL/v1/models" -H "Authorization: Bearer $VK"
chk "hindsight reachable from hermes"     docker exec hermes curl -fsS http://hindsight:8888/health
chk "hermes API /v1/models"               curl -fsS "$HM/v1/models" -H "Authorization: Bearer $HK"

echo "Inference"
t0=$(date +%s)
if out=$(curl -fsS "$LL/v1/chat/completions" -H "Authorization: Bearer $VK" -H 'Content-Type: application/json' \
      -d '{"model":"coder","max_tokens":20,"messages":[{"role":"user","content":"Reply with the word: pong"}]}'); then
  ok "coder via LiteLLM ($(( $(date +%s) - t0 ))s): $(echo "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["choices"][0]["message"]["content"].strip()[:60])')"
else bad "coder via LiteLLM"; fi

if curl -fsS "$LL/v1/completions" -H "Authorization: Bearer $VK" -H 'Content-Type: application/json' \
     -d '{"model":"autocomplete","max_tokens":16,"prompt":"<|fim_prefix|>def add(a, b):\n    <|fim_suffix|>\n<|fim_middle|>"}' >/dev/null; then
  ok "autocomplete (FIM) via LiteLLM"
else bad "autocomplete (FIM) via LiteLLM"; fi

echo "GPU"
docker exec ai-llm-coder nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader 2>/dev/null | sed 's/^/  /' || echo "  (nvidia-smi not available in container)"

exit $fail
