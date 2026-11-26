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

## Profile `poc-wsl-cpu`: same box, CPU only (`docker-compose.cpu.yml`)

The same Qwen3-Coder-30B-A3B, at **Q3_K_M** (~14.7 GB) so that weights plus the 64k KV cache fit a 19 GB cap. With 10 threads, expect ~8–15 tok/s for generation and noticeably slower prompt processing than with the GPU. It's useful for an apples-to-apples CPU vs. GPU comparison, or to free the GPU for something else. One server answers `coder`, `autocomplete` and `memory`.

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

## Llama or Qwen?

**For this stack and this hardware: Qwen, for both coding and reasoning.** The reasons, in order of weight:

| | Qwen (Qwen3 / Qwen3-Coder) | Llama (3.x / 4) |
|---|---|---|
| **Fits 8 GB VRAM + 32 GB RAM at a usable speed** | Yes. Qwen3-Coder-30B-A3B and Qwen3-30B-A3B are MoE with ~3B active params, so 30B-class quality runs at small-model speed with experts in RAM | Partly. Llama 3.1 8B fits but is much weaker. Llama 3.3 70B (dense) runs at ~1–3 tok/s from RAM. Llama 4 Scout (109B total) needs ~60 GB at Q4, so it doesn't fit |
| **Agentic coding / tool calling** (what Hermes needs) | Qwen3-Coder is trained specifically for multi-step agentic coding and tool use, with a 256k native context | Llama 3.x tool calling works but is weaker. Llama 4 was received as mediocre at coding for its size |
| **Reasoning** | Qwen3 has dedicated *Thinking* variants (e.g. Qwen3-30B-A3B-Thinking-2507, same footprint) | No reasoning ("thinking") variant at these sizes |
| **License** | Apache-2.0: no conditions beyond attribution | Llama Community License: acceptable-use policy, "Built with Llama" branding, 700M-MAU clause. Usable commercially, but not OSI-open |
| **Small models for FIM autocomplete** | Qwen2.5-Coder 0.5B/1.5B/7B with FIM tokens | No maintained small code/FIM Llama |

**Coding vs. reasoning is a model choice, not a family choice.** Qwen3-Coder is a non-thinking model. It answers directly and handles tool calls best, which is the right default for an agent. For reasoning-heavy work (algorithm design, tricky debugging, planning), swap in **Qwen3-30B-A3B-Thinking-2507**. It has the same size and the same split across GPU and RAM, so it's a one-line change in `profiles/poc-wsl/llm-coder.env`:

```
LLAMA_ARG_HF_REPO=unsloth/Qwen3-30B-A3B-Thinking-2507-GGUF:Q4_K_M
```

Thinking models emit long reasoning traces before answering. They're slower per turn and cost more of the 64k context in agent loops.

Running both at once doesn't fit 32 GB of RAM (~18 GB each). Run one at a time, or keep the thinking model as a cloud/remote route in LiteLLM.

Caveat: open-weight releases move fast, and this comparison reflects the models available when this stack was written. Before committing, check current agentic-coding results (e.g. SWE-bench Verified and Aider polyglot) for models that fit **≤ 8 GB VRAM + ~20 GB RAM**. Swapping costs one line in the profile.

## Validating a swap

```bash
docker compose up -d llm-coder && docker compose logs -f llm-coder   # wait for "server is listening"
scripts/doctor.sh
```

Then give Hermes a real multi-step task (e.g. "read README.md and list the services"). If tool calls come back as plain text instead of being executed, the chat template is the problem. Try another GGUF build of the same model.

Keep `LLAMA_ARG_CTX_SIZE`, `CODER_CTX` (stack.env), `max_input_tokens` (litellm/config.yaml) and `model.context_length` (data/hermes/config.yaml) in sync. Hermes refuses windows smaller than 64k.
