#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Install Docker Engine (+ Compose plugin) and the NVIDIA Container Toolkit on
# Ubuntu running in WSL2. Run it as your normal user from the Ubuntu terminal;
# it calls sudo where needed. Safe to re-run: finished steps are skipped.
#
#   scripts/install-docker-wsl.sh            # Docker + GPU support
#   scripts/install-docker-wsl.sh --no-gpu   # Docker only (cpu profile)
#   scripts/install-docker-wsl.sh --check    # report what is installed, change nothing
#
# Steps
#   1. checks: WSL2, Ubuntu, not running as root, no Docker Desktop integration
#   2. enables systemd in /etc/wsl.conf (then asks you to `wsl --shutdown`
#      from PowerShell and run this script again)
#   3. Docker Engine + buildx + compose plugin from Docker's official apt repo
#   4. NVIDIA Container Toolkit from NVIDIA's apt repo, registered with Docker
#   5. adds you to the `docker` group
#   6. verifies: hello-world, and nvidia-smi inside a container
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

log()  { printf '\033[1;35m▸\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

GPU=1; CHECK=0
USER="${USER:-$(id -un)}"
for arg in "$@"; do
  case "$arg" in
    --no-gpu) GPU=0 ;;
    --check)  CHECK=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

# ── 1. Checks ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] || die "Run as your normal user (not root / not with sudo): the script uses sudo itself and adds YOU to the docker group."
grep -qi microsoft /proc/version 2>/dev/null || die "This is not WSL. This script is only for Ubuntu on WSL2."
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == ubuntu ]] || die "Expected Ubuntu, found '${ID:-unknown}'. Use docs/setup-wsl.md for other distros."
CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
ARCH="$(dpkg --print-architecture)"

DOCKER_BIN="$(command -v docker || true)"
if [[ "$DOCKER_BIN" == /mnt/* ]] || [[ -L "$DOCKER_BIN" && "$(readlink -f "$DOCKER_BIN")" == /mnt/wsl/docker-desktop* ]]; then
  die "Docker Desktop's WSL integration is active ($DOCKER_BIN). Use Docker Desktop (option B in docs/setup-wsl.md) or turn off its WSL integration for this distro first — not both."
fi

has_systemd()   { [[ "$(ps -p 1 -o comm= 2>/dev/null)" == systemd ]]; }
has_docker()    { dpkg -s docker-ce >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; }
has_toolkit()   { command -v nvidia-ctk >/dev/null 2>&1; }
in_group()      { id -nG "$USER" | tr ' ' '\n' | grep -qx docker; }
wsl_gpu()       { [[ -e /dev/dxg ]] && { command -v nvidia-smi >/dev/null 2>&1 || [[ -x /usr/lib/wsl/lib/nvidia-smi ]]; }; }

if (( CHECK )); then
  echo "Ubuntu $VERSION_ID ($CODENAME, $ARCH) on WSL"
  has_systemd && ok "systemd is PID 1"        || warn "systemd is not running"
  has_docker  && ok "Docker Engine: $(docker --version)" || warn "Docker Engine not installed"
  has_docker  && ok "Compose: $(docker compose version --short)"
  wsl_gpu     && ok "GPU visible to WSL (Windows NVIDIA driver)" || warn "no GPU visible to WSL"
  has_toolkit && ok "NVIDIA Container Toolkit: $(nvidia-ctk --version | head -1)" || warn "NVIDIA Container Toolkit not installed"
  in_group    && ok "$USER is in the docker group" || warn "$USER is not in the docker group"
  exit 0
fi

# ── 2. systemd (dockerd runs as a systemd service) ───────────────────────────
if ! has_systemd; then
  if grep -qsE '^\s*systemd\s*=\s*true' /etc/wsl.conf; then
    die "systemd is enabled in /etc/wsl.conf but not running yet. In PowerShell run:  wsl --shutdown   then reopen Ubuntu and run this script again."
  fi
  log "Enabling systemd in /etc/wsl.conf"
  if grep -qs '^\[boot\]' /etc/wsl.conf; then
    sudo sed -i '/^\[boot\]/a systemd=true' /etc/wsl.conf
  else
    printf '\n[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf >/dev/null
  fi
  cat <<EOF

  systemd is now enabled. To activate it:
    1. In PowerShell:   wsl --shutdown
    2. Reopen Ubuntu and run:   scripts/install-docker-wsl.sh $*
EOF
  exit 0
fi
ok "systemd is running"

# ── 3. Docker Engine ─────────────────────────────────────────────────────────
if has_docker; then
  ok "Docker Engine already installed: $(docker --version)"
else
  log "Removing conflicting distro packages (docker.io, podman-docker, …) if present"
  for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then sudo apt-get remove -y "$pkg"; fi
  done

  log "Adding Docker's official apt repository"
  sudo apt-get update -qq
  sudo apt-get install -y -qq ca-certificates curl gnupg >/dev/null
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $CODENAME stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  log "Installing Docker Engine, buildx and the compose plugin"
  sudo apt-get update -qq
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker
  ok "Docker Engine installed: $(docker --version)"
fi

# Rotate container logs (Docker's default json-file log grows without bound).
# Only written when no daemon.json exists yet; nvidia-ctk merges into it below.
if [[ ! -f /etc/docker/daemon.json ]]; then
  log "Configuring container log rotation (10 MB × 3 files per container)"
  echo '{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }' \
    | sudo tee /etc/docker/daemon.json >/dev/null
  sudo systemctl restart docker
fi

# ── 4. NVIDIA Container Toolkit ──────────────────────────────────────────────
if (( GPU )); then
  if ! wsl_gpu; then
    warn "WSL can't see an NVIDIA GPU (no /dev/dxg or nvidia-smi). Install/update the NVIDIA driver on WINDOWS (≥ R570 for Blackwell), then re-run. Skipping GPU setup."
    GPU=0
  elif has_toolkit && sudo docker info 2>/dev/null | grep -qi 'nvidia'; then
    ok "NVIDIA Container Toolkit already installed and registered with Docker"
  else
    log "Adding NVIDIA's apt repository"
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | sudo gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
    log "Installing the NVIDIA Container Toolkit"
    sudo apt-get update -qq
    sudo apt-get install -y nvidia-container-toolkit
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
    ok "NVIDIA Container Toolkit installed and registered with Docker"
  fi
fi

# ── 5. docker group ──────────────────────────────────────────────────────────
NEW_GROUP=0
if in_group; then
  ok "$USER is already in the docker group"
else
  sudo usermod -aG docker "$USER"
  NEW_GROUP=1
  ok "Added $USER to the docker group"
fi

# ── 6. Verify (sudo: the new group membership only applies to new shells) ────
log "Verifying"
sudo docker run --rm hello-world >/dev/null && ok "containers run (hello-world)"
sudo docker compose version >/dev/null && ok "compose plugin: $(sudo docker compose version --short)"
if (( GPU )); then
  if out="$(sudo docker run --rm --gpus all ubuntu:24.04 nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>&1)"; then
    ok "GPU inside a container: $out"
  else
    warn "GPU test failed:"; echo "$out" | sed 's/^/    /' >&2
    warn "Check the Windows NVIDIA driver (≥ R570) and run: sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
  fi
fi

cat <<EOF

$(printf '\033[1;32m✓ Docker is ready\033[0m')
EOF
if (( NEW_GROUP )); then cat <<EOF
  Your docker group membership applies to NEW shells. Close and reopen the
  Ubuntu terminal (or run: newgrp docker), then check with:  docker ps
EOF
fi
cat <<EOF
  Next:  cd ~/ai-stack && scripts/bootstrap.sh$( (( GPU )) || printf ' --profile cpu')
EOF
