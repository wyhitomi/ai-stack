# Resource budgets

Laptop: **16 CPU / 32 GB RAM / Blackwell 8 GB**, WSL VM 14 CPU / 24 GB (`windows/wslconfig.example`).

Every container has a hard **cgroup memory limit** (with `memswap_limit` equal to it, so no container swaps) and a **CPU cap**, except `llm-coder` in the gpu profile. Postgres, LiteLLM, Hindsight and Hermes together fit an envelope of **4 CPU / 7 GB**. The local models are the only services allowed to use more. Budgets live in `profiles/<profile>/stack.env`.

| Service | Memory | CPU cap | `gpu` | `cpu` |
|---|---:|---:|:-:|:-:|
| postgres | 512 MB | 0.50 | ✓ | ✓ |
| litellm | 2048 MB | 0.50 | ✓ | ✓ |
| hindsight | 1536 MB | 1.00 | ✓ | ✓ |
| hermes | 3072 MB | 2.00 | ✓ | ✓ |
| **envelope total** | | | **7168 MB** = 7168 | **7168 MB** = 7168 |
| llm-coder (serves coder + autocomplete + memory) | | | **uncapped**: ~6–7 GB VRAM + ~15–17 GB RAM | 22 GB / 10 CPU cap: ~21.5 GB RAM |

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

- **LiteLLM exits with 137 right after starting.** It's killed for memory while loading, before it logs anything. The proxy with its database client needs ~1–1.5 GB, so `LITELLM_MEM` must stay ≥ 1536m. (768 MB was too small and was raised to 2048m.)
- **Hermes OOM-killed during `npm install` / big test suites.** The envelope is fully allocated. Hindsight is already at its documented minimum (1.5 GB), so the way to give Hermes more is to raise the envelope: on a 32 GB laptop the 7 GB envelope is a choice, not a hard limit. E.g. `STACK_MEM_MB=8192` and `HERMES_MEM=4096m`.
- **A GPU model container dies within seconds of starting.** The CUDA runtime alone needs ~0.5–1 GB of host RAM before the model loads, so a GPU llama.cpp container needs a cap of at least ~1.5 GB. (512 MB was too small and was raised to 2 GB.) `bootstrap.sh` prints the container's OOM status and last log lines when this happens.
- **The cpu-profile model OOM-killed.** Lower `LLAMA_ARG_CACHE_RAM` or use a `q4_0` V-cache (`profiles/cpu/llm-coder.env`).

## What the limits don't cover

- **GPU VRAM.** cgroups don't limit it. llama.cpp's `--fit` sizes the coder to the free VRAM after autocomplete has loaded.
- **The WSL VM size.** See `windows/wslconfig.example`: 24 GB + 8 GB swap for the gpu profile, ~27 GB for the cpu profile.
- **Disk.** Images ~10 GB. One 18.6 GB model file, shared by both profiles. Postgres grows with memories and logs.
