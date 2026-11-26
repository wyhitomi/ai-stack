# Deploying on the VPS (profile `vps`)

Target: **4 vCPU / 8 GB RAM, no GPU**, Ubuntu 24.04 (or Debian 12). Everything runs inside that machine, model included, with a hard memory limit on every container:

| Service | Memory | CPU cap |
|---|---:|---:|
| postgres | 512 MB | 0.50 |
| litellm | 768 MB | 0.50 |
| hindsight | 1536 MB | 0.75 |
| hermes | 1536 MB | 1.00 |
| llm-coder (Qwen2.5-Coder-1.5B, 64k ctx) | 3072 MB | 3.00 |
| **containers** | **7424 MB** | |
| kernel, dockerd, sshd | ~768 MB | |

## What to expect on CPU

This is the honest part. With 3 CPU threads, a 1.5B model generates **~15–25 tokens/s**. Prompt processing runs at **~100–200 tokens/s**. In practice:

- **Autocomplete and quick chat** work fine.
- **Hermes agent turns are slow, and the small model is weak at tool calling.** Hermes' system prompt and tool schemas are long, so the first turn of a session can spend a minute or more reading the prompt. Later turns reuse the prompt cache. Expect simple tasks to work and complex multi-step ones to fail more often than on the PoC.

To get PoC-level agent quality on the VPS, point `coder` at a GPU host. Keep the small local model for `autocomplete` and `memory`. It's one line in `.env`, since the routing lives in LiteLLM:

```bash
# GPU host (e.g. the PoC machine), .env:
CODER_BIND=100.a.b.c          # its Tailscale IP: never 0.0.0.0
CODER_API_KEY=<random secret>  # e.g. head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'
docker compose up -d llm-coder

# VPS, .env:
CODER_API_BASE=http://100.a.b.c:8080/v1
CODER_API_KEY=<same secret>
docker compose up -d litellm
```

The `memory` route always stays on the VPS's local model, so memory content never leaves the box.

## Running without a local model

The local model is **optional** on the CPU file (`vps`, `poc-wsl-cpu`). Without it, LiteLLM routes `coder`, `autocomplete` and `memory` to a remote OpenAI-compatible endpoint, and clients and Hermes don't notice the difference.

```bash
# 1. In .env, point `coder` somewhere (LiteLLM provider/model syntax):
CODER_MODEL=openai/coder                       # a remote llama.cpp, e.g. the PoC GPU
CODER_API_BASE=http://100.a.b.c:8080/v1        #   over Tailscale
CODER_API_KEY=<the GPU host's CODER_API_KEY>
#   …or a hosted open-weight provider:
#   CODER_MODEL=openai/qwen/qwen3-coder   CODER_API_BASE=https://<provider>/v1   CODER_API_KEY=<key>

# 2. Turn the local model off
scripts/bootstrap.sh --local-model off
docker compose up -d --remove-orphans          # stops the old llm-coder container
```

- `bootstrap.sh` refuses to turn the model off until `CODER_API_BASE` points at a real remote endpoint. It then redirects `autocomplete` and `memory` to the same endpoint, unless you set `AUTOCOMPLETE_*` / `MEMORY_*` yourself.
- **Autocomplete** needs an endpoint that serves raw `/v1/completions` (FIM). llama.cpp does; many hosted chat APIs don't. Without one, turn autocomplete off in Continue.
- **Privacy:** with the model off, Hindsight's memory extraction runs remotely, so conversation facts leave the VPS. `bootstrap.sh` warns you about this.
- **Budget:** the 3 GB the model used becomes free. A good split is `HERMES_MEM=3072m` and `HINDSIGHT_MEM=2048m` in `.env` (still ≤ 7424 MB), then `docker compose up -d`.
- Back to local: `scripts/bootstrap.sh --local-model on`. It restores every route to the local server.

The GPU file (`poc-wsl`) always runs its local models; that's its purpose.

## Install

```bash
# Docker Engine + compose plugin (the only host dependency besides bash)
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER && newgrp docker

# A small host swap file: a safety net for the OS only (containers can't swap)
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

git clone <this repo> ~/ai-stack && cd ~/ai-stack
scripts/bootstrap.sh --profile vps
scripts/doctor.sh
```

## Network: never on the public interface

The VPS profile binds LiteLLM and Hermes to `127.0.0.1`. To reach them from VS Code, use either:

**Tailscale (recommended).** Install it **before** `bootstrap.sh`, which then binds LiteLLM to the Tailscale IP automatically.

```bash
curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up
```

Clients on your tailnet use `http://<tailscale-ip>:4000/v1`. Traffic is encrypted end to end, with no open ports on the internet.

**SSH tunnel** (no extra software): `ssh -N -L 4000:127.0.0.1:4000 you@vps`, then clients use `http://localhost:4000/v1`.

Close everything else with the firewall:

```bash
sudo ufw default deny incoming && sudo ufw allow OpenSSH && sudo ufw enable
```

Docker publishes ports through iptables and bypasses ufw. That's why the stack never binds to `0.0.0.0` on the VPS: the bind address is the real protection.

## Operating within 8 GB

- `scripts/doctor.sh` fails if the memory limits add up to more than `STACK_MEM_MB` (7424), or if a container has no limit.
- Hermes runs the agent's shell commands inside its 1.5 GB. A heavy `npm install` or test suite can get it OOM-killed (Docker restarts it). Check with `docker inspect hermes -f '{{.State.OOMKilled}}'`. If it happens often, run those builds in CI instead, or move memory from Hindsight (see [resources.md](resources.md)).
- Backups work the same as on the PoC (README → Day-to-day).
