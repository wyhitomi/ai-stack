# Resource budgets

Every container has a hard **cgroup limit** for memory (with `memswap_limit` equal to it, so no container swaps) and a **CPU cap**. Budgets are per profile, in `profiles/<profile>/stack.env`.

| Service | Memory | CPU cap | `vps` (cpu file) | `poc-wsl` (gpu file) | `poc-wsl-cpu` (cpu file) |
|---|---:|---:|:-:|:-:|:-:|
| postgres | 512 MB | 0.50 | ✓ | ✓ | ✓ |
| litellm | 768 MB | 0.50 | ✓ | ✓ | ✓ |
| hindsight | 1536 MB | 0.75 | ✓ | ✓ | ✓ |
| hermes | 1536 MB | 1.00 | ✓ | ✓ | ✓ |
| llm-autocomplete | 512 MB | 0.50 | — (llm-coder) | ✓ (GPU) | — (llm-coder) |
| llm-coder | | | 3 GB / 3 CPU | **uncapped** (GPU + ~18 GB RAM) | 19 GB / 10 CPU |
| **counted total** | | | **7424 MB** of 8 GB | **4864 MB** ≤ 7168 | **4352 MB** ≤ 7168 |

With `--local-model off` (CPU file only), `llm-coder` doesn't run. On the VPS that frees 3 GB. Give it to Hermes and Hindsight (e.g. 3072m / 2048m) to stay within 7424 MB.

**The PoC uses the VPS limits on purpose.** If Hermes, Hindsight, LiteLLM and Postgres run well in the PoC, they fit the VPS. Only the model is allowed to be bigger there.

## Memory vs. CPU

- **Memory is a summed, hard budget.** It can't be shared or reclaimed in a hurry. `scripts/doctor.sh` fails if any counted container lacks a limit, or if the limits add up to more than `STACK_MEM_MB`.
- **CPU caps are per service and may overlap.** CPU time is shared, so capping each service to a slice that sums to exactly 4 would just leave cores idle. The caps stop any one service (for example the model) from taking the whole machine. Each cap must be ≤ `STACK_CPUS`, and `doctor.sh` reports the sum.

## When a container hits its limit

The kernel OOM-kills it and Docker restarts it (`restart: unless-stopped`). The rest of the stack keeps running.

```bash
docker stats                                         # live usage vs. limit
docker inspect hermes -f '{{.State.OOMKilled}}'      # was it the limit?
```

Typical rebalancing, done in `.env` and kept within the total:

- **Hermes OOM-killed during `npm install` / big test suites.** Raise `HERMES_MEM` to 2048m and lower `HINDSIGHT_MEM` to 1024m. Below 1.5 GB, Hindsight's local embedding and reranker models get tight; its docs list 1.5 GB as the minimum. Alternatively, keep heavy builds in CI.
- **The VPS model is OOM-killed.** Lower `LLAMA_ARG_CACHE_RAM`, or use a `q4_0` V-cache (`profiles/vps/llm-coder.env`).

## What the limits don't cover

- **GPU VRAM** (PoC). cgroups don't limit it. llama.cpp's `--fit` sizes the coder to the free VRAM after autocomplete has loaded.
- **The WSL VM size** (PoC). See `windows/wslconfig.example` (26 GB / 14 CPU).
- **Disk.** Images ~10 GB. Models: VPS ~1.3 GB, PoC ~20 GB. Postgres grows with memories and logs.
