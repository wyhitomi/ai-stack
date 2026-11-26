# Resource budget

The stack runs entirely in Docker containers. Each one has a hard **cgroup limit** for CPU and memory. Together, all services except the main local model fit a fixed envelope of **4 CPU / 7 GB RAM**:

| Service | CPUs | Memory | What drives its usage |
|---|---:|---:|---|
| postgres | 0.50 | 768 MB | tuned for the limit: `shared_buffers=192MB`, 60 connections, no parallel query |
| litellm | 0.50 | 1024 MB | one worker (`--num_workers 1`), DB pool of 5 |
| hindsight | 1.00 | 2048 MB | in-container embedding + reranker models on CPU (~1.0–1.5 GB RSS), one thread each |
| hermes | 1.50 | 2560 MB | agent runtime **plus every shell command it runs** (builds, tests, git) |
| llm-autocomplete | 0.50 | 768 MB | weights in VRAM; one compute thread |
| **total** | **4.00** | **7168 MB** | |
| llm-coder | unbounded | unbounded | the one service allowed to use more (GPU, plus CPU/RAM if you offload experts) |

`memswap_limit` equals the memory limit, so a container never swaps. If it goes over its limit, the kernel OOM-kills it and Docker restarts it (`restart: unless-stopped`). That one service fails; the rest of the stack keeps running.

## Checking it

```bash
scripts/doctor.sh        # first section: sums the limits of every non-model container
docker stats             # live usage vs. limit per container
```

`doctor.sh` fails if any container except `llm-coder` has no limit, or if the limits add up to more than `STACK_CPUS` / `STACK_MEM_MB` in `.env`.

## Moving budget between services

The split lives in `.env` (`*_CPUS`, `*_MEM`). The total must stay within the envelope, so give to one service by taking from another, then run `docker compose up -d`. Typical cases:

- **Hermes OOM-killed during `npm install` / large test suites** (`docker inspect hermes -f '{{.State.OOMKilled}}'`): raise `HERMES_MEM` to 3072m and lower `HINDSIGHT_MEM` to 1536m. Hindsight still runs at 1.5 GB, its documented minimum, though recall under load gets slower.
- **Autocomplete feels laggy**: it is usually network or GPU bound, not CPU. Check `docker stats` before giving it more CPU.
- **Hermes' browser tools** (headless Chromium) need ~500 MB each. Leave them off, or move memory to Hermes.

## What the limits don't cover

- **The WSL VM itself** must be larger than the envelope: 7 GB + the model's host RAM + ~1.5 GB for the kernel and dockerd. See `windows/wslconfig.example`.
- **GPU VRAM** is not limited by cgroups. The two llama.cpp servers share the card (see [models.md](models.md)).
- **Disk**: models ~20 GB, images ~10 GB, Postgres grows with memories and logs.
