# Resource budgets

Laptop: **16 CPU / 32 GB RAM / Blackwell 8 GB**, WSL VM 14 CPU / 24 GB (`windows/wslconfig.example`).

Every container has a hard **cgroup memory limit** (with `memswap_limit` equal to it, so no container swaps) and a **CPU cap**. Together, all services except the coding model fit an envelope of **4 CPU / 7 GB**. The coding model is the one service allowed to use more. Budgets live in `profiles/<profile>/stack.env`.

| Service | Memory | CPU cap | `gpu` | `cpu` |
|---|---:|---:|:-:|:-:|
| postgres | 512 MB | 0.50 | ✓ | ✓ |
| litellm | 768 MB | 0.50 | ✓ | ✓ |
| hindsight | 2048 MB | 1.00 | ✓ | ✓ |
| hermes | 3072 MB | 2.00 | ✓ | ✓ |
| llm-autocomplete | 512 MB | 0.50 | ✓ (weights on GPU) | — (llm-coder serves it) |
| **envelope total** | | | **6912 MB** ≤ 7168 | **6400 MB** ≤ 7168 |
| llm-coder | | | **uncapped**: ~6 GB VRAM + ~17 GB RAM | 19 GB / 10 CPU cap: ~18.5 GB RAM |

Hermes gets the largest share because the agent's shell commands (builds, tests, git) run inside its container.

## Memory vs. CPU

- **Memory is a summed, hard budget.** `scripts/doctor.sh` fails if any counted container lacks a limit, or if the limits add up to more than `STACK_MEM_MB`.
- **CPU caps are per service and may overlap.** CPU time is shared, so capping each service to a slice that sums to exactly 4 would only leave cores idle. The caps stop any one service from taking the machine. Each cap must be ≤ `STACK_CPUS`, and `doctor.sh` reports the sum.
- **Limits are ceilings, not reservations.** At idle the four core services use ~2.5–3 GB together. That's why a 24 GB WSL VM fits the ~17 GB model plus the stack, even though the caps add up to 6.9 GB.

## When a container hits its limit

The kernel OOM-kills it and Docker restarts it (`restart: unless-stopped`). The rest of the stack keeps running.

```bash
docker stats                                         # live usage vs. limit
docker inspect hermes -f '{{.State.OOMKilled}}'      # was it the limit?
```

Rebalance in `.env` and keep the total within the envelope:

- **Hermes OOM-killed during `npm install` / big test suites.** The gpu profile has ~250 MB of headroom and the cpu profile ~750 MB. Raise `HERMES_MEM` by that much, or take from Hindsight. Below 1.5 GB, Hindsight's local embedding and reranker models get tight; its docs list 1.5 GB as the minimum. To lift the envelope itself, raise `STACK_MEM_MB`: on a 32 GB laptop the 7 GB envelope is a choice, not a hard limit.
- **The cpu-profile model OOM-killed.** Lower `LLAMA_ARG_CACHE_RAM` or use a `q4_0` V-cache (`profiles/cpu/llm-coder.env`).

## What the limits don't cover

- **GPU VRAM.** cgroups don't limit it. llama.cpp's `--fit` sizes the coder to the free VRAM after autocomplete has loaded.
- **The WSL VM size.** See `windows/wslconfig.example` (24 GB + 8 GB swap, 14 CPU).
- **Disk.** Images ~10 GB. Models ~19 GB (gpu) / ~15 GB (cpu). Postgres grows with memories and logs.
