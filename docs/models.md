# Choosing the local models

Clients never see real model names. LiteLLM exposes stable aliases (`coder`, `autocomplete`, `memory`, `hermes-agent`), and each profile decides what serves them. Model tuning lives in `profiles/<profile>/llm-*.env` as `LLAMA_ARG_*` variables, one per [llama-server flag](https://github.com/ggml-org/llama.cpp/tree/master/tools/server). To change a model, edit that file and run `docker compose up -d llm-coder`.

All defaults are Apache-2.0 (commercial use OK). Avoid Qwen2.5-Coder-**3B**: unlike its 0.5B/1.5B/7B/14B/32B siblings, it uses a non-commercial research license.

## Where the model comes from: Docker Hub

`huggingface.co` is blocked on the corporate network, so the model is pulled from **Docker Hub's `ai/` namespace**. Docker publishes GGUF models there, and llama.cpp downloads them natively (`LLAMA_ARG_DOCKER_REPO`). Docker Hub is already reachable, since the stack's images come from there.

```
LLAMA_ARG_DOCKER_REPO=ai/qwen3-coder:30b-a3b-q4_K_M      # 18.56 GB, both profiles share the file
```

Other tags: <https://hub.docker.com/r/ai/qwen3-coder/tags> (e.g. `30B-A3B-UD-Q4_K_XL`, 17.67 GB; `30b-a3b-q8_0`). On a network where Hugging Face works, swap the line for the commented `LLAMA_ARG_HF_REPO=` one in the same file. Anonymous Docker Hub downloads are rate-limited per IP. `bootstrap.sh` recognises that error and says so.

## One model for every route

| Route | Served by |
|---|---|
| `coder` (chat, agent, tools) | **Qwen3-Coder-30B-A3B-Instruct** Q4_K_M |
| `autocomplete` (FIM) | the same model: Qwen states that "FIM is supported in every version of Qwen3-Coder", using the `<\|fim_prefix\|>…<\|fim_suffix\|>…<\|fim_middle\|>` format Continue sends |
| `memory` (Hindsight extraction) | the same model |

The server runs **two slots that share one 64k KV pool** (`LLAMA_ARG_N_PARALLEL=2`, `LLAMA_ARG_KV_UNIFIED=true`). An autocomplete request doesn't wait for a long Hermes turn to finish, and Hermes can still use the whole 64k window. Autocomplete takes ~1–2k tokens of the pool while it runs.

## Profile `gpu` (default): Blackwell 8 GB + 32 GB RAM

Why a 30B model works on 8 GB: it's a Mixture-of-Experts model with only ~3B parameters active per token. llama.cpp's `--fit` (on by default) puts what fits on the GPU (attention, KV cache, shared weights, some experts) and keeps the rest of the experts in RAM. Generation then reads ~3B params per token, which a 16-core laptop handles at roughly 15–25 tok/s. Prompt processing uses the GPU.

Approximate VRAM use:

| | VRAM |
|---|---:|
| KV cache 64k @ q8_0 | ~3.2 GB |
| non-expert weights + compute buffers | ~1.5–2 GB |
| experts that fit in the rest | ~1–2 GB |
| margin (`LLAMA_ARG_FIT_TARGET=768`) | ~0.8 GB |

Knobs in `profiles/gpu/llm-coder.env`, if VRAM is tight (the log shows `--fit` reducing what it offloads, or it OOMs):

- `LLAMA_ARG_CACHE_TYPE_V=q4_0` saves ~0.8 GB of KV cache, at a small quality cost.
- `LLAMA_ARG_UBATCH=512` gives a smaller compute buffer, but slower prefill.
- `ai/qwen3-coder:30B-A3B-UD-Q4_K_XL` (17.67 GB) is a little smaller, with similar quality.

## Profile `cpu`: same laptop, CPU only (`docker-compose.cpu.yml`)

It uses the **same file** as the gpu profile, so there's no second download, run entirely from RAM. Budget: weights 18.56 GB, plus KV 64k with K q8_0 and V q4_0 (~2.6 GB), plus buffers (~0.6 GB), against a cap of `CODER_MEM=22g`. That needs a WSL VM of ~27 GB (`windows/wslconfig.example`). With 10 threads, expect ~8–15 tok/s and noticeably slower prompt processing than on the GPU.

The cpu profile can also run **without** a local model (`scripts/bootstrap.sh --profile cpu --local-model off`). Then every route goes to the external OpenAI-compatible endpoint set in `.env` (`CODER_MODEL`, `CODER_API_BASE`, `CODER_API_KEY`), and prompts and memory extraction leave the laptop.

## Llama or Qwen?

**For this stack and this hardware: Qwen, for both coding and reasoning.** The reasons, in order of weight:

| | Qwen (Qwen3 / Qwen3-Coder) | Llama (3.x / 4) |
|---|---|---|
| **Fits 8 GB VRAM + 32 GB RAM at a usable speed** | Yes. Qwen3-Coder-30B-A3B and Qwen3-30B-A3B are MoE with ~3B active params, so 30B-class quality runs at small-model speed with experts in RAM | Partly. Llama 3.1 8B fits but is much weaker. Llama 3.3 70B (dense) runs at ~1–3 tok/s from RAM. Llama 4 Scout (109B total) needs ~60 GB at Q4, so it doesn't fit |
| **Agentic coding / tool calling** (what Hermes needs) | Qwen3-Coder is trained specifically for multi-step agentic coding and tool use, with a 256k native context | Llama 3.x tool calling works but is weaker. Llama 4 was received as mediocre at coding for its size |
| **Reasoning** | Qwen3 has dedicated *Thinking* variants (e.g. Qwen3-30B-A3B-Thinking-2507, same footprint) | No reasoning ("thinking") variant at these sizes |
| **License** | Apache-2.0: no conditions beyond attribution | Llama Community License: acceptable-use policy, "Built with Llama" branding, 700M-MAU clause. Usable commercially, but not OSI-open |
| **FIM autocomplete** | Every Qwen3-Coder (and the small Qwen2.5-Coder models) supports fill-in-the-middle | No maintained code/FIM Llama |

**Coding vs. reasoning is a model choice, not a family choice.** Qwen3-Coder is a non-thinking model. It answers directly and handles tool calls best, which is the right default for an agent. For reasoning-heavy work (algorithm design, tricky debugging, planning), swap in **Qwen3-30B-A3B-Thinking-2507**. It has the same size and the same split across GPU and RAM, so it's a one-line change in `profiles/gpu/llm-coder.env`:

```
LLAMA_ARG_HF_REPO=unsloth/Qwen3-30B-A3B-Thinking-2507-GGUF:Q4_K_M
```

Thinking models emit long reasoning traces before answering. They're slower per turn and cost more of the 64k context in agent loops.

Running both at once doesn't fit 32 GB of RAM (~18 GB each). Run one at a time, or keep the thinking model as a cloud/remote route in LiteLLM.

Caveat: open-weight releases move fast, and this comparison reflects the models available when this stack was written. Before committing, check current agentic-coding results (e.g. SWE-bench Verified and Aider polyglot) for models that fit **≤ 8 GB VRAM + ~20 GB RAM**. Swapping costs one line in the profile.

## If Docker Hub is blocked too

**A) Proxy.** If Docker itself needs a proxy, set it once in `~/.docker/config.json` in WSL. Docker passes it to every container:

```json
{ "proxies": { "default": { "httpProxy": "http://proxy:8080", "httpsProxy": "http://proxy:8080", "noProxy": "localhost,127.0.0.1,litellm,hermes,hindsight,postgres,llm-coder" } } }
```

**B) Bring the file yourself, with no download at start-up.** Get the `.gguf` on a network where it's reachable (e.g. at home, off the VPN), from Docker Hub (`docker model pull ai/qwen3-coder:30b-a3b-q4_K_M` with Docker Desktop's Model Runner) or from Hugging Face (`unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF`, the `Q4_K_M` file). Then:

1. Copy it into the stack. `data/models` is mounted at `/root/.cache` in the model container:
   ```bash
   mkdir -p data/models/gguf
   cp /mnt/c/Users/<you>/Downloads/*.gguf data/models/gguf/
   ```
2. In `profiles/<profile>/llm-coder.env`, comment out `LLAMA_ARG_DOCKER_REPO` and point at the file:
   ```
   # LLAMA_ARG_DOCKER_REPO=...
   LLAMA_ARG_MODEL=/root/.cache/gguf/<file-name>.gguf
   ```
3. Run `scripts/bootstrap.sh` again.

Hindsight's embedding and reranker models are baked into its image, and the stack runs it with `HF_HUB_OFFLINE=1`, so it never contacts Hugging Face.

## Validating a swap

```bash
docker compose up -d llm-coder && docker compose logs -f llm-coder   # wait for "server is listening"
scripts/doctor.sh
```

Then give Hermes a real multi-step task (e.g. "read README.md and list the services"). If tool calls come back as plain text instead of being executed, the chat template is the problem. Try another GGUF build of the same model.

Keep `LLAMA_ARG_CTX_SIZE`, `CODER_CTX` (stack.env), `max_input_tokens` (litellm/config.yaml) and `model.context_length` (data/hermes/config.yaml) in sync. Hermes refuses windows smaller than 64k.
