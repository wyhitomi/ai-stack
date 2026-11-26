# Choosing the local models

Clients never see real model names. LiteLLM exposes stable aliases (`coder`, `autocomplete`, `memory`, `hermes-agent`), and each profile decides what serves them. Model tuning lives in `profiles/<profile>/llm-*.env` as `LLAMA_ARG_*` variables, one per [llama-server flag](https://github.com/ggml-org/llama.cpp/tree/master/tools/server). To change a model, edit that file and run `docker compose up -d llm-coder`.

All defaults are Apache-2.0 (commercial use OK). Avoid Qwen2.5-Coder-**3B**: unlike its 0.5B/1.5B/7B/14B/32B siblings, it uses a non-commercial research license.

## Profile `poc-wsl`: Blackwell 8 GB + 32 GB RAM

| Route | Model | Where it runs |
|---|---|---|
| `coder`, `memory` | **Qwen3-Coder-30B-A3B-Instruct** Q4_K_M (~18.6 GB) | GPU: attention, KV cache, shared weights. RAM: most MoE experts |
| `autocomplete` | Qwen2.5-Coder-1.5B (base, FIM) Q8_0 | GPU, ~2 GB |

Why it works on 8 GB: it's a Mixture-of-Experts model with only ~3B parameters active per token. llama.cpp's `--fit` (on by default) puts what fits on the GPU and keeps the rest of the experts in RAM. Generation then reads ~3B params per token from RAM, which a 16-core desktop handles at roughly 15–25 tok/s. Prompt processing uses the GPU.

Approximate VRAM budget:

| | VRAM |
|---|---:|
| autocomplete 1.5B Q8_0 + 8k ctx | ~2.0 GB |
| coder: KV cache 64k @ q8_0 | ~3.2 GB |
| coder: non-expert weights + compute buffers | ~1.5–2 GB |
| margin (`LLAMA_ARG_FIT_TARGET=768`) + Windows desktop | ~1 GB |

Knobs in `profiles/poc-wsl/llm-coder.env`, if VRAM is tight (the log shows `--fit` reducing what it offloads, or it OOMs):

- `LLAMA_ARG_CACHE_TYPE_V=q4_0` saves ~0.8 GB of KV cache, with a small quality cost.
- `LLAMA_ARG_UBATCH=512` gives a smaller compute buffer, at the cost of slower prefill.
- The model's `UD-Q3_K_XL` quant (~13 GB) frees ~5 GB of RAM if Windows feels starved.

If the GPU is the monitor's GPU, close GPU-heavy apps during long agent runs: Windows' own VRAM use reduces what `--fit` gets.

## Profile `vps`: 4 vCPU / 8 GB, no GPU

| Route | Model | Budget |
|---|---|---|
| `coder`, `autocomplete`, `memory` | **Qwen2.5-Coder-1.5B-Instruct** Q6_K, 64k ctx (YaRN ×2) | 3 GB RAM, 3 CPU |

One model serves all three routes. Its memory budget: weights ~1.3 GB, KV 64k @ q8_0 ~1.0 GB, buffers and a 128 MB prompt cache ~0.4 GB. It was picked because it is small enough to hold the 64k window Hermes requires, it has FIM tokens for autocomplete, and it has basic tool calling. Its KV cache is small (only 2 KV heads), which is what makes 64k fit.

Limits you should know about:

- **Tool calling at 1.5B is unreliable.** Hermes works for simple tasks and fails more often on multi-step ones.
- **Autocomplete shares the single slot.** While Hermes is generating, completions wait.

Options, in order of impact:

1. **Route `coder` to a GPU host.** Use the PoC machine or a GPU VPS, and keep the small model for `autocomplete` and `memory`. See [deploy-vps.md](deploy-vps.md).
2. Try **IBM Granite 4.0-H-Micro** (3B, Apache-2.0, hybrid Mamba, built for tool calling; 128k context with a very small KV cache) as `coder`. It has no FIM, so keep autocomplete on the Qwen model. That needs a second llama.cpp container, so take its memory from Hindsight or Hermes.

## Validating a swap

```bash
docker compose up -d llm-coder && docker compose logs -f llm-coder   # wait for "server is listening"
scripts/doctor.sh
```

Then give Hermes a real multi-step task (e.g. "read README.md and list the services"). If tool calls come back as plain text instead of being executed, the chat template is the problem. Try another GGUF build of the same model.

Keep `LLAMA_ARG_CTX_SIZE`, `CODER_CTX` (stack.env), `max_input_tokens` (litellm/config.yaml) and `model.context_length` (data/hermes/config.yaml) in sync. Hermes refuses windows smaller than 64k.
