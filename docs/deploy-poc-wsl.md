# Deploying the PoC on WSL2 (profile `poc-wsl`)

Target machine: **16 CPU / 32 GB RAM / NVIDIA Blackwell GPU with 8 GB** (RTX 50xx class), Windows 11 + WSL2.

The PoC runs every non-model service with **exactly the VPS limits**, so a passing PoC shows the stack fits the 4 vCPU / 8 GB VPS. Only the coding model differs. Here it uses the GPU and the spare RAM to run Qwen3-Coder-30B-A3B, where the VPS has to settle for a 1.5B model (see [models.md](models.md)).

```bash
scripts/bootstrap.sh --profile poc-wsl
scripts/doctor.sh
```

## 1. Windows prerequisites

- Windows 11 22H2+ (for mirrored networking), WSL 2.0+: run `wsl --update`, then `wsl --version`
- **NVIDIA driver for Windows, R570 or newer.** Blackwell needs CUDA 12.8+, and older drivers can't run the CUDA 12.8 llama.cpp image. Do **not** install a Linux NVIDIA driver inside WSL: the Windows driver exposes the GPU to WSL.
- An Ubuntu 24.04 distro: `wsl --install -d Ubuntu-24.04`

Check inside WSL: `nvidia-smi` should list your GPU and a CUDA version ≥ 12.8.

### Size the WSL VM

Copy `windows/wslconfig.example` to `%UserProfile%\.wslconfig` (`setup-lan.ps1` does this), then `wsl --shutdown`. Its defaults for this machine:

| | WSL VM | Left for Windows | Why |
|---|---|---|---|
| memory | 26 GB | 6 GB | stack 4.9 GB (capped) + model ~18 GB (MoE experts in RAM) + ~2 GB kernel/dockerd |
| processors | 14 | 2 | stack caps ≤ 4 + 8 model threads + headroom |

If Windows feels starved, switch the model to a smaller quant (docs/models.md) and lower `memory`.

## 2. Docker inside WSL

Two options. Pick one.

**A) Docker Engine inside WSL (recommended for a 24/7 server).** It is lighter, it doesn't need Docker Desktop running, and it doesn't need a license.

```bash
# Docker Engine
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER && newgrp docker

# NVIDIA Container Toolkit
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt update && sudo apt install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker

# systemd must be on (default on recent Ubuntu WSL images). Check /etc/wsl.conf:
#   [boot]
#   systemd=true

docker run --rm --gpus all ubuntu:24.04 nvidia-smi   # must show your GPU, CUDA >= 12.8
```

**B) Docker Desktop** with the WSL2 backend and WSL integration on for your distro. GPU support is built in. Docker Desktop publishes ports on **Windows** directly, so in step 4 you only need the regular Windows firewall rule. The Hyper-V/mirrored steps don't apply.

## 3. Keep code in the Linux filesystem

Put repositories under `~/code` (the default `WORKSPACE_DIR`), **not** under `/mnt/c/...`. File access across the 9P bridge is 5–10x slower and breaks file watchers. From Windows the files are still reachable at `\\wsl$\Ubuntu-24.04\home\<you>\code`.

## 4. Make it reachable from the LAN

By default WSL2 sits behind a NAT, so other machines can't reach it. Run in **PowerShell as Administrator**, from this repo's `windows\` folder (reachable via `\\wsl$\...`):

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\setup-lan.ps1              # mirrored networking + firewall (Windows 11)
wsl --shutdown               # apply .wslconfig
```

Then reopen WSL and run `docker compose up -d`.

The script:

- writes `%UserProfile%\.wslconfig` with `networkingMode=mirrored`. WSL then shares the Windows NICs, so `0.0.0.0:4000` in WSL is `<windows-lan-ip>:4000`.
- opens ports **4000** (LiteLLM) and **8642** (Hermes) in the **Hyper-V firewall** (which filters mirrored WSL traffic) and in the Windows firewall, **Private profile and local subnet only**.

On Windows 10 or older WSL, use `.\setup-lan.ps1 -Mode Nat` (netsh portproxy). The WSL IP changes on every reboot, so re-run it at logon via Task Scheduler.

Set your network to **Private** under Settings → Network & Internet. The rules don't apply on Public networks, by design.

Test from another machine:

```bash
curl http://<windows-lan-ip>:4000/health/liveliness
curl http://<windows-lan-ip>:4000/v1/models -H "Authorization: Bearer <vscode-key>"
```

Tip: give the Windows machine a DHCP reservation, or a hostname like `ai-box.lan`, so client configs don't break.

## 5. Start on boot (optional)

With Docker Engine + systemd, `restart: unless-stopped` brings the stack back whenever WSL starts. To start WSL itself at Windows logon, create a Task Scheduler task that runs `wsl.exe -d Ubuntu-24.04 --exec /bin/true`. WSL stops idle distros after a while, so to keep it alive also add to `.wslconfig`:

```ini
[wsl2]
vmIdleTimeout=-1
```
