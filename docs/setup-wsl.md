# Setting up the WSL2 laptop

Target: a Windows 11 laptop with **16 CPU / 32 GB RAM / NVIDIA Blackwell GPU with 8 GB** (RTX 50xx Laptop class), running the stack in WSL2. It's reachable **only from your home LAN**.

| Profile | Compose file | Model |
|---|---|---|
| `gpu` (default) | `docker-compose.gpu.yml` | Qwen3-Coder-30B-A3B Q4_K_M, split by `--fit` between the 8 GB GPU and RAM, plus a 1.5B autocomplete model on the GPU |
| `cpu` | `docker-compose.cpu.yml` | the same model at Q3_K_M, CPU and RAM only; one server for every route. Optional: `--local-model off` |

```bash
scripts/bootstrap.sh                 # gpu
scripts/bootstrap.sh --profile cpu   # cpu (switching keeps secrets, keys and data)
scripts/doctor.sh
```

To switch, run `docker compose down`, then bootstrap with the other profile. `data/` is shared, so memories, keys and Hermes sessions carry over.

## 1. Windows prerequisites

- Windows 11 22H2+ (for mirrored networking), WSL 2.0+: run `wsl --update`, then `wsl --version`.
- **NVIDIA driver for Windows, R570 or newer.** Blackwell needs CUDA 12.8+. Do **not** install a Linux NVIDIA driver inside WSL: the Windows driver exposes the GPU to WSL.
- An Ubuntu 24.04 distro: `wsl --install -d Ubuntu-24.04`.

Check inside WSL: `nvidia-smi` should list the GPU and a CUDA version ≥ 12.8.

### Laptop specifics

- **Plug in.** On battery, Windows and the NVIDIA driver throttle the dGPU hard. Use power mode *Best performance* while working with the agent.
- **Hybrid graphics is an advantage.** If the integrated GPU drives the display (the default on most laptops), the 8 GB of the NVIDIA card stays almost entirely free for the models.
- **Heat.** Long agent runs keep the GPU and CPU busy. A laptop stand helps sustain clocks.
- **Sleep.** WSL and the containers pause while the laptop sleeps and resume on wake. `restart: unless-stopped` brings everything back after a reboot, once WSL starts.

### Size the WSL VM

Copy `windows/wslconfig.example` to `%UserProfile%\.wslconfig` (`setup-lan.ps1` does this), then `wsl --shutdown`:

| | WSL VM | Left for Windows | Why |
|---|---|---|---|
| memory | 24 GB | 8 GB | typical use ≈ 21 GB: model ~17 GB (MoE experts in RAM) + stack ~3 GB actual + ~1.5 GB OS |
| swap | 8 GB | | absorbs the rare moment when every container sits at its limit (caps total 6.9 GB) |
| processors | 14 | 2 | stack caps ≤ 4 + 8 model threads + headroom |

The container limits are ceilings, not reservations. At idle, Hermes, Hindsight, LiteLLM and Postgres use ~2.5–3 GB together. That's why 24 GB is enough even though the caps add up to 6.9 GB. If Windows still feels starved, switch to the model's Q3_K_M quant (see [models.md](models.md)) and lower `memory` to 20 GB.

## 2. Docker inside WSL

Two options. Pick one.

**A) Docker Engine inside WSL (recommended).** It's lighter and doesn't need Docker Desktop running or a license.

```bash
# Docker Engine
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER && newgrp docker

# NVIDIA Container Toolkit (GPU profile)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt update && sudo apt install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker

# systemd must be on (default on recent Ubuntu WSL images). Check /etc/wsl.conf:
#   [boot]
#   systemd=true

docker run --rm --gpus all ubuntu:24.04 nvidia-smi   # must show the GPU, CUDA >= 12.8
```

**B) Docker Desktop** with the WSL2 backend and WSL integration on for your distro. GPU support is built in. Docker Desktop publishes ports on Windows directly, so in step 4 only the regular Windows firewall rule matters.

## 3. Keep code in the Linux filesystem

Put repositories under `~/code` (the default `WORKSPACE_DIR`), **not** under `/mnt/c/...`. File access across the 9P bridge is 5–10x slower and breaks file watchers. From Windows the files are still reachable at `\\wsl$\Ubuntu-24.04\home\<you>\code`.

## 4. Home LAN access (and nothing else)

By default WSL2 sits behind a NAT, so other machines can't reach it. Run in **PowerShell as Administrator**, from this repo's `windows\` folder (reachable via `\\wsl$\...`):

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\setup-lan.ps1              # mirrored networking + LAN-only firewall rules
wsl --shutdown               # apply .wslconfig
```

Then reopen WSL and run `docker compose up -d`.

What the script sets up:

- **Mirrored networking.** WSL shares the laptop's network adapters, so `0.0.0.0:4000` in WSL is `<laptop-lan-ip>:4000`.
- **Firewall rules limited to the home LAN.** Ports 4000 (LiteLLM) and 8642 (Hermes) are opened only to the subnet of the active adapter (e.g. `192.168.1.0/24`, detected automatically or set with `-LanSubnet`). This applies in both the **Hyper-V firewall** (which filters mirrored WSL traffic) and the **Windows firewall** (Private profile only).
- Nothing else is reachable. Postgres (5432) and Hindsight's UI (9999) listen on `127.0.0.1`. The model servers don't publish any port; they're only reachable inside Docker's `ai-stack` network.

Set your home network to **Private** under Settings → Network & Internet. Away from home (café, office, hotspot), the network is Public and the subnet differs, so the stack isn't reachable there. On those networks, VS Code on the laptop itself still works through `localhost`.

> The subnet filter on the Hyper-V firewall needs a recent Windows 11 build. On older builds the script warns and opens the port without a source filter. The Windows firewall rule still limits it to the Private profile and the LAN subnet. Never forward 4000 or 8642 on your router.

On older Windows or WSL, use `.\setup-lan.ps1 -Mode Nat` (netsh portproxy). The WSL IP changes on every reboot, so re-run the script at logon via Task Scheduler.

Test from another machine on the LAN:

```bash
curl http://<laptop-lan-ip>:4000/health/liveliness
curl http://<laptop-lan-ip>:4000/v1/models -H "Authorization: Bearer <vscode-key>"
```

Tip: give the laptop a DHCP reservation on your router, so client configs don't break.

## 5. Start on boot (optional)

With Docker Engine + systemd, `restart: unless-stopped` brings the stack back whenever WSL starts. To start WSL at Windows logon, create a Task Scheduler task that runs `wsl.exe -d Ubuntu-24.04 --exec /bin/true`. To keep WSL from stopping when idle, add this to `.wslconfig`:

```ini
[wsl2]
vmIdleTimeout=-1
```
