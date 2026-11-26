# Resource budgets

Every container has a hard **cgroup limit** for memory (with `memswap_limit` equal to it, so no container swaps) and a **CPU cap**. Budgets are per profile, in `profiles/<profile>/stack.env`.

| Service | Memory | CPU cap | `vps` (cpu file) | `poc-wsl` (gpu file) | `poc-wsl-cpu` (cpu file) |
|---|---:|---:|:-:|:-:|:-:|
| postgres | 512 MB | 0.50 | ✓ | ✓ | ✓ |
| litellm | 768 MB | 0.50 | ✓ | ✓ | ✓ |
| hindsight | 2048 MB | 1.00 | ✓ | ✓ | ✓ |
| hermes | 3072 MB | 2.00 | ✓ | ✓ | ✓ |
| llm-autocomplete | 512 MB | 0.50 | — (uses the PoC's) | ✓ (GPU) | — (llm-coder) |
| llm-coder | | | **none: no local model** | **uncapped** (GPU + ~18 GB RAM) | 19 GB / 10 CPU |
| **counted total** | | | **6400 MB** of 7424 | **6912 MB** ≤ 7168 | **6400 MB** ≤ 7168 |

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

- **Hermes OOM-killed during `npm install` / big test suites.** On the VPS, ~1 GB of the budget is still unallocated: raise `HERMES_MEM` to 4096m. Do the same in the PoC profiles to keep them identical. Alternatively, keep heavy builds in CI.
- **Hindsight below 1.5 GB** gets tight: its local embedding and reranker models need ~1.0–1.5 GB, and its docs list 1.5 GB as the minimum.

## What the limits don't cover

- **GPU VRAM** (PoC). cgroups don't limit it. llama.cpp's `--fit` sizes the coder to the free VRAM after autocomplete has loaded.
- **The WSL VM size** (PoC). See `windows/wslconfig.example` (27 GB / 14 CPU).
- **Disk.** Images ~10 GB. Models: PoC ~19 GB (GPU) / ~15 GB (CPU); VPS none. Postgres grows with memories and logs.
