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

# ── Budget ────────────────────────────────────────────────────────────────────
# Memory: hard, summed. Every non-exempt container must have a limit, and the
#         limits must add up to <= STACK_MEM_MB.
# CPU:    every non-exempt container must have a cap <= STACK_CPUS. Caps may
#         overlap (CPU time is shared), so their sum is reported, not enforced.
echo "Resource budget (profile: $(get_env STACK_PROFILE))"
max_cpu="$(get_env STACK_CPUS)"; max_cpu="${max_cpu:-4}"
max_mem="$(get_env STACK_MEM_MB)"; max_mem="${max_mem:-7168}"
exempt=" $(get_env BUDGET_EXEMPT | tr ',' ' ') "
rows=$(for c in $(docker compose ps -q); do
  docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}} {{.HostConfig.NanoCpus}} {{.HostConfig.Memory}}' "$c"
done)
read -r cpu_n mem_b unlimited over < <(echo "$rows" | awk -v ex="$exempt" -v maxc="$max_cpu" '
  NF==3 && index(ex, " " $1 " ")==0 {
    if ($2==0 || $3==0) u=u $1 ","
    if ($2/1e9 > maxc) o=o $1 ","
    c+=$2; m+=$3 }
  END { print c+0, m+0, (u==""?"-":u), (o==""?"-":o) }')
cpu_sum=$(awk -v n="$cpu_n" 'BEGIN{printf "%.2f", n/1e9}')
mem_used=$(( mem_b / 1024 / 1024 ))
[[ "$exempt" =~ [a-z] ]] && echo "  (not counted, by design:${exempt% })"
if   [[ "$unlimited" != "-" ]]; then bad "no CPU or memory limit on: ${unlimited%,}"
elif [[ "$over" != "-" ]];      then bad "CPU cap above ${max_cpu} on: ${over%,}"
elif (( mem_used > max_mem ));   then bad "memory limits ${mem_used} MB exceed the ${max_mem} MB budget"
else ok "memory ${mem_used}/${max_mem} MB · CPU caps ≤ ${max_cpu} each (sum of caps ${cpu_sum})"
fi
docker stats --no-stream --format '  {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' $(docker compose ps -q) 2>/dev/null

echo "Hops"
chk "postgres accepts connections"        docker exec ai-postgres pg_isready -U postgres
chk "llm-coder /health"                   docker exec ai-llm-coder curl -fsS http://localhost:8080/health
if [[ "$(get_env COMPOSE_PROFILES)" == *autocomplete* ]]; then
  chk "llm-autocomplete /health"          docker exec ai-llm-autocomplete curl -fsS http://localhost:8080/health
else
  echo "  · autocomplete served by llm-coder (profile $(get_env STACK_PROFILE))"
fi
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

if [[ "$(get_env COMPOSE_FILE)" == *gpu* ]]; then
  echo "GPU"
  docker exec ai-llm-coder nvidia-smi --query-gpu=name,compute_cap,memory.used,memory.total --format=csv,noheader 2>/dev/null | sed 's/^/  /' \
    || bad "nvidia-smi not available in llm-coder"
  docker logs ai-llm-coder 2>&1 | grep -qi "no kernel image" && bad "CUDA image lacks kernels for this GPU: set LLAMACPP_GPU_IMAGE=ghcr.io/ggml-org/llama.cpp:server-cuda13"
  docker logs ai-llm-coder 2>&1 | grep -iE "offloaded|fit|CUDA0 model buffer|CPU_Mapped model buffer" | tail -4 | sed 's/^/  /'
fi

exit $fail
