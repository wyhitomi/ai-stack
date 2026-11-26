#!/usr/bin/env bash
# End-to-end health check: resource budget + every hop, Postgres → Hermes.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ -f .env ]] || die "No .env — run scripts/bootstrap.sh first"

VK="$(get_env VSCODE_LLM_API_KEY)"
HK="$(get_env HERMES_API_KEY)"
fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=1; }
chk() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }

echo "Containers"
docker compose ps --format '  {{.Service}}\t{{.State}}\t{{.Health}}'

# ── Budget: everything except llm-coder must fit STACK_CPUS / STACK_MEM_MB ──
echo "Resource budget (all services except llm-coder)"
max_cpu="$(get_env STACK_CPUS)"; max_cpu="${max_cpu:-4}"
max_mem="$(get_env STACK_MEM_MB)"; max_mem="${max_mem:-7168}"
read -r cpu_n mem_b unlimited < <(
  for c in $(docker compose ps -q); do
    [[ "$(docker inspect -f '{{.Name}}' "$c")" == /ai-llm-coder ]] && continue
    docker inspect -f '{{.Name}} {{.HostConfig.NanoCpus}} {{.HostConfig.Memory}}' "$c"
  done | awk '{ if ($2==0 || $3==0) u=u $1 " "; c+=$2; m+=$3 } END { print c+0, m+0, (u==""?"-":u) }'
)
cpu_used=$(awk -v n="$cpu_n" 'BEGIN{printf "%.2f", n/1e9}')
mem_used=$(( mem_b / 1024 / 1024 ))
if [[ "$unlimited" != "-" ]]; then
  bad "containers without a CPU or memory limit: $unlimited"
elif awk -v u="$cpu_used" -v m="$max_cpu" 'BEGIN{exit !(u<=m)}' && (( mem_used <= max_mem )); then
  ok "limits: ${cpu_used}/${max_cpu} CPU, ${mem_used}/${max_mem} MB"
else
  bad "limits exceed the envelope: ${cpu_used}/${max_cpu} CPU, ${mem_used}/${max_mem} MB"
fi
docker stats --no-stream --format '  {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' $(docker compose ps -q) 2>/dev/null

echo "Hops"
chk "postgres accepts connections"        docker exec ai-postgres pg_isready -U postgres
chk "llm-coder /health"                   docker exec ai-llm-coder curl -fsS http://localhost:8080/health
chk "llm-autocomplete /health"            docker exec ai-llm-autocomplete curl -fsS http://localhost:8080/health
chk "litellm liveliness"                  dcurl http://litellm:4000/health/liveliness
chk "litellm lists models (vscode key)"   dcurl http://litellm:4000/v1/models -H "Authorization: Bearer $VK"
chk "hindsight API"                       dcurl http://hindsight:8888/health
chk "hermes API /v1/models"               dcurl http://hermes:8642/v1/models -H "Authorization: Bearer $HK"
chk "LAN port 4000 published"             bash -c "docker port ai-litellm 4000 | grep -q ."

echo "Inference"
t0=$(date +%s)
if out=$(DCURL_TIMEOUT=300 dcurl http://litellm:4000/v1/chat/completions -H "Authorization: Bearer $VK" -H 'Content-Type: application/json' \
      -d '{"model":"coder","max_tokens":20,"messages":[{"role":"user","content":"Reply with the word: pong"}]}'); then
  ok "coder via LiteLLM ($(( $(date +%s) - t0 ))s): $(echo "$out" | json_field content | cut -c1-60)"
else bad "coder via LiteLLM"; fi

if DCURL_TIMEOUT=60 dcurl http://litellm:4000/v1/completions -H "Authorization: Bearer $VK" -H 'Content-Type: application/json' \
     -d '{"model":"autocomplete","max_tokens":16,"prompt":"<|fim_prefix|>def add(a, b):\n    <|fim_suffix|>\n<|fim_middle|>"}' >/dev/null; then
  ok "autocomplete (FIM) via LiteLLM"
else bad "autocomplete (FIM) via LiteLLM"; fi

echo "GPU"
docker exec ai-llm-coder nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader 2>/dev/null | sed 's/^/  /' \
  || echo "  (nvidia-smi not available in container)"

exit $fail
