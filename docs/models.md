# Choosing the local models

Two llama.cpp servers run side by side:

| Service | Role | Default | Why |
|---|---|---|---|
| `llm-coder` | chat, agent, tool calling (Hermes + Continue) | `unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_K_M` | MoE with ~3B active params: 30B-class quality at 7B-class speed; trained for agentic coding and tool calls; 256k native context |
| `llm-autocomplete` | inline completion (FIM) | `ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF` | tiny, sub-100 ms completions, proper FIM tokens |

Clients never see these names. LiteLLM exposes them as `coder` and `autocomplete`, so you can swap a model by editing `.env` and running `docker compose up -d llm-coder`.

## Sizing by GPU VRAM

Hermes needs **at least 64k context**, so the KV cache counts as much as the weights. `CODER_KV_TYPE=q8_0` roughly halves the cache.

| VRAM | `CODER_MODEL` | Extra flags / notes |
|---|---|---|
| 8–12 GB | `unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_K_M` + experts on CPU | add `--n-cpu-moe`, `30` to the `llm-coder` command (needs 32 GB+ system RAM); or a 7B coder, which has weaker tool calling |
| 16 GB | same, with fewer experts on CPU | `--n-cpu-moe`, `12` (lower the number until it stops fitting) |
| **24 GB** (RTX 3090/4090) | **default** | Q4_K_M + 64k ctx + q8_0 KV ≈ 21–22 GB, plus ~2 GB for autocomplete |
| 32 GB (RTX 5090) | `...:Q5_K_M` or `CODER_CTX=131072` | or `CODER_PARALLEL=2` with `CODER_CTX=131072` (two 64k slots: Hermes and Continue at the same time) |
| 48 GB+ | `...:Q8_0`, or a larger MoE (e.g. GLM-4.5-Air GGUF with `--n-cpu-moe`) | |

New open-weight coding models ship every few months. Before you swap, check that the model is good at **tool calling**, since agents depend on it more than on raw benchmark scores, and that its GGUF chat template works with `--jinja`.

## Validating a swap

```bash
docker compose up -d llm-coder && docker compose logs -f llm-coder   # wait for "server is listening"
scripts/doctor.sh
```

Then give Hermes a real multi-step task (e.g. "read README.md and list the services"). If tool calls come back as plain text instead of executed calls, the chat template is the problem. Try another GGUF build of the same model.

## No GPU

`docker compose -f docker-compose.yml -f compose.cpu.yml up -d`. This works, but it is slow for agent use.
