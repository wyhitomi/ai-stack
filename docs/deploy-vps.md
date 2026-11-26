# Deploying on the VPS (profile `vps`)

Target: **4 vCPU / 8 GB RAM, no GPU**, Ubuntu 24.04 (or Debian 12), using `docker-compose.cpu.yml`.

**The VPS runs no model.** It hosts the orchestration stack (Hermes, Hindsight, LiteLLM, Postgres). Every model call goes over Tailscale to the **WSL PoC machine**, which runs the models on its GPU:

```
VS Code ──► VPS: LiteLLM :4000 ──(Tailscale, API key)──► WSL: llm-coder        :8080  coder, memory
              │   Hermes · Hindsight · Postgres                   llm-autocomplete :8081  autocomplete
```

| Service (VPS) | Memory | CPU cap |
|---|---:|---:|
| postgres | 512 MB | 0.50 |
| litellm | 768 MB | 0.50 |
| hindsight | 2048 MB | 1.00 |
| hermes | 3072 MB | 2.00 |
| **containers** | **6400 MB** | (budget 7424 MB) |
| kernel, dockerd, sshd | ≥ 768 MB | |

Hermes gets the largest share because the agent's builds and tests run inside its container.

## What this means in practice

- **The VPS needs the WSL machine online.** When the PoC is off, asleep or out of Tailscale, model calls fail. Hermes, Hindsight and LiteLLM keep running and recover by themselves when the PoC is back. For continuity, add a cloud fallback in `litellm/config.yaml` (`cloud-coder` + `fallbacks`, commented out).
- **Data stays on your machines.** Prompts and memory extraction travel only between the VPS and the PoC, encrypted by Tailscale and protected by the llama.cpp API key. Nothing goes to a third party unless you enable a cloud fallback.
- **Latency.** Over Tailscale, autocomplete adds one network round trip, usually 20–80 ms. Agent turns are dominated by generation time, so you won't notice the network there.

## 1. On the WSL PoC: publish the models

Tailscale must run on the PoC: on Windows (simplest), or inside WSL. Bootstrap finds it either way.

```bash
# WSL, in ~/ai-stack
scripts/bootstrap.sh --profile poc-wsl --serve-vps
```

That binds `llm-coder` (:8080) and `llm-autocomplete` (:8081) to the PoC's **Tailscale IP only**. Both always require `CODER_API_KEY`, which bootstrap generates. At the end it prints the exact lines for the VPS.

Then, in PowerShell as Administrator on Windows:

```powershell
.\windows\setup-lan.ps1 -ServeVps     # opens 8080/8081 to Tailscale peers (100.64.0.0/10) only
```

This needs WSL **mirrored networking** (the script's default mode), so the Tailscale IP is visible inside WSL. With Docker Desktop, ports are published on Windows directly, and the same firewall rule applies.

## 2. On the VPS

```bash
# Docker Engine + compose plugin (the only host dependency besides bash)
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER && newgrp docker

# Tailscale: lets the VPS reach the PoC, and VS Code reach the VPS
curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up

# A small host swap file: a safety net for the OS only (containers can't swap)
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

git clone <this repo> ~/ai-stack && cd ~/ai-stack
cp .env.example .env
echo "CODER_API_KEY=<value printed by the PoC bootstrap>" >> .env
scripts/bootstrap.sh --profile vps --gpu-host <poc-tailscale-ip>
scripts/doctor.sh
```

`bootstrap.sh` refuses to continue in these cases:

- the GPU host is still a placeholder
- `CODER_API_KEY` is missing
- you ask for `--local-model on`, since this profile has no local model

`doctor.sh` then runs a real inference through the PoC, on both chat and autocomplete.

## Network: never on the public interface

LiteLLM and Hermes bind to the VPS's **Tailscale IP** (detected by bootstrap), or to `127.0.0.1` if Tailscale is missing. VS Code clients on your tailnet use `http://<vps-tailscale-ip>:4000/v1`. Without Tailscale, use an SSH tunnel: `ssh -N -L 4000:127.0.0.1:4000 you@vps`.

Close everything else:

```bash
sudo ufw default deny incoming && sudo ufw allow OpenSSH && sudo ufw enable
```

Docker publishes ports through iptables and bypasses ufw. That's why the stack never binds to `0.0.0.0` on the VPS: the bind address is the real protection.

## Using another GPU host or a hosted provider

The routes are plain settings in `.env` (`CODER_*`, `AUTOCOMPLETE_*`, `MEMORY_*`: MODEL, API_BASE, API_KEY). Any OpenAI-compatible endpoint works, for example a GPU cloud VM running this repo's `poc-wsl` profile, or a hosted open-weight provider (`CODER_MODEL=openai/qwen/qwen3-coder`, `CODER_API_BASE=https://<provider>/v1`). With a hosted provider, Hindsight's memory extraction and your prompts leave your machines. Autocomplete then needs an endpoint that serves raw `/v1/completions` (FIM).

## Operating within 8 GB

- `scripts/doctor.sh` fails if the memory limits add up to more than `STACK_MEM_MB` (7424), or if a container has no limit.
- Hermes OOM-killed during a heavy build? Check with `docker inspect hermes -f '{{.State.OOMKilled}}'`. There are still ~1 GB unallocated in the budget: raise `HERMES_MEM` to 4096m.
- Backups work the same as on the PoC (README → Day-to-day).
