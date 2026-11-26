#!/usr/bin/env bash
# Create a LiteLLM virtual key for another developer / machine on the LAN.
#   scripts/new-key.sh <alias> [max_budget_usd] [models_json]
#   scripts/new-key.sh laptop-joao
#   scripts/new-key.sh ci-bot 5 '["coder"]'
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
alias="${1:?usage: new-key.sh <alias> [max_budget_usd] [models_json]}"
budget="${2:-null}"
models="${3:-[\"coder\",\"autocomplete\",\"hermes-agent\"]}"
dcurl http://litellm:4000/key/generate \
  -H "Authorization: Bearer $(get_env LITELLM_MASTER_KEY)" -H 'Content-Type: application/json' \
  -d "{\"key_alias\":\"$alias\",\"models\":$models,\"max_budget\":$budget}" \
| json_field key
