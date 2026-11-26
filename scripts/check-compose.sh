#!/usr/bin/env bash
# The CPU and GPU compose files must define the shared services identically,
# so a stack validated on one behaves the same on the other. Run after editing
# either file. Only llm-coder / llm-autocomplete may differ.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ -f .env ]] || die "No .env — run scripts/bootstrap.sh first"
shared=(postgres litellm hindsight hermes)
rc=0
for svc in "${shared[@]}"; do
  if diff <(COMPOSE_FILE= docker compose -f docker-compose.cpu.yml config "$svc" 2>&1) \
          <(COMPOSE_FILE= docker compose -f docker-compose.gpu.yml config "$svc" 2>&1) >/dev/null; then
    printf '  \033[32m✓\033[0m %s identical\n' "$svc"
  else
    printf '  \033[31m✗\033[0m %s differs:\n' "$svc"; rc=1
    diff <(COMPOSE_FILE= docker compose -f docker-compose.cpu.yml config "$svc") \
         <(COMPOSE_FILE= docker compose -f docker-compose.gpu.yml config "$svc") | sed 's/^/      /'
  fi
done
exit $rc
