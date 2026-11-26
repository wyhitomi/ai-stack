#!/usr/bin/env bash
# Create a LiteLLM virtual key for another developer / machine on the LAN.
#   scripts/new-key.sh <alias> [max_budget_usd] [models_json]
#   scripts/new-key.sh laptop-joao
#   scripts/new-key.sh ci-bot 5 '["coder"]'
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
get_env() { grep -E "^$1=" .env | head -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*$//' | xargs; }
alias="${1:?usage: new-key.sh <alias> [max_budget_usd] [models_json]}"
budget="${2:-null}"
models="${3:-[\"coder\",\"autocomplete\",\"hermes-agent\"]}"
curl -fsS "http://127.0.0.1:$(get_env LITELLM_PORT)/key/generate" \
  -H "Authorization: Bearer $(get_env LITELLM_MASTER_KEY)" -H 'Content-Type: application/json' \
  -d "{\"key_alias\":\"$alias\",\"models\":$models,\"max_budget\":$budget}" \
| python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["key"])'
