#!/bin/bash

# run with: curl -sSL https://raw.githubusercontent.com/MachoDrone/MDbiginstaller/refs/heads/main/installer-beta3.sh | bash

# Version and timestamp - increment on changes
echo "Version: 0.00.6 - 15:26:11 20JUL25"

# Error handling and logging
set -euo pipefail
RED='\033[1;31m'
GREEN='\033[1;32m'
BRIGHT_GREEN='\033[1;92m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
BLUE='\033[0;34m'
NC='\033[0m'
exec > >(tee -a ~/nosana-install.log) 2>&1
trap 'echo -e "${BOLD}${RED}An error occurred on line $LINENO. Exiting.${NC}"' ERR

# Globals
MAX_RETRIES=100
REBOOT_NEEDED=0
SUPPORT_LAPTOPS=0  # Toggle: 1 to allow laptops/mobile GPUs
SUPPORTED_GPU_REGEX="RTX [3-9][0-9]{3}|A[0-9]+|Quadro RTX [4-9][0-9]{3}"  # Includes A-series/Quadro by default
MIN_COMPUTE_CAP=8.0
MIN_VRAM_MB=6144

# Retry wrapper
retry_cmd() {
  local retries=$MAX_RETRIES
  while [ $retries -gt 0 ]; do
    "$@" && return 0
    echo -e "${YELLOW}Command failed, retries left: $retries${NC}"
    ((retries--))
    sleep 10
  done
  echo -e "${RED}Failed after $MAX_RETRIES retries. Exiting.${NC}"
  exit 1
}

# Ensure package function
ensure_pkg() {
  if ! dpkg -s "$1" &>/dev/null; then
    retry_cmd sudo apt install -y "$1"
  fi
}

# Refresh sudo
sudo -v

# Show logo and warnings
clear
echo -e "\n\n${GREEN}  | \\ \\ \\  |\n  |  \\ \\ \\ |\n  | \\ \\ \\  |\n  |  \\_\\ \\_|\n\n  N O S A N A${NC}\n\n"
echo -e "${YELLOW}${BOLD}Warning: Review this script or trust its source before running. It uses sudo for installs but user-level where possible.${NC}"
echo -e "${GREEN}${BOLD}Current user: $(whoami)${NC}"
sleep 2

# No root
if [ "$(id -u)" -eq 0 ]; then
  echo -e "${RED}${BOLD}Run as regular user with sudo privileges. Exiting.${NC}"
  exit 1
fi

# Home dir
cd "$HOME"

# Block invalid envs
grep -qiE 'microsoft|wsl' /proc/version /proc/sys/kernel/osrelease && { echo -e "${RED}${BOLD}WSL not supported.${NC}"; exit 1; }
grep -qiE 'hive' /etc/*release && { echo -e "${RED}${BOLD}Hive OS not supported.${NC}"; exit 1; }
grep -q '^ID=ubuntu$' /etc/os-release || { echo -e "${RED}${BOLD}Genuine Ubuntu only.${NC}"; exit 1; }
UBUNTU_VERSION_ID=$(grep '^VERSION_ID=' /etc/os-release | cut -d '"' -f2)
UBUNTU_FULL_VERSION=$(grep '^VERSION=' /etc/os-release | cut -d '"' -f2 | cut -d ' ' -f1)
if [[ "$UBUNTU_FULL_VERSION" < "24.04.1" ]]; then
  echo -e "${RED}${BOLD}Ubuntu 24.04.1 or newer required. Detected: $UBUNTU_FULL_VERSION. Exiting.${NC}"
  exit 1
elif [[ "$UBUNTU_VERSION_ID" > "24.04" ]]; then
  echo -e "${YELLOW}${BOLD}Ubuntu $UBUNTU_VERSION_ID detected—untested version; proceed at own risk.${NC}"
fi

# Initial update
retry_cmd sudo apt update -y

# Ensure base pkgs (expanded for nano/cat/deps)
for pkg in curl gpg gnupg wget ca-certificates software-properties-common apt-transport-https lsb-release ubuntu-drivers-common lshw mokutil net-tools pciutils systemd coreutils nano build-essential linux-headers-generic; do
  ensure_pkg "$pkg"
done

# Hardware checks
CHASSIS=$(hostnamectl chassis 2>/dev/null || echo "unknown")
if [ $SUPPORT_LAPTOPS -eq 0 ] && [[ "$CHASSIS" =~ laptop|convertible|tablet ]]; then
  echo -e "${RED}${BOLD}Laptops not supported.${NC}"
  exit 1
fi
if ! lspci | grep -iq nvidia; then
  echo -e "${RED}${BOLD}No NVIDIA GPU detected.${NC}"
  exit 1
fi
GPU_INFO=$(sudo lshw -c display 2>/dev/null | grep -i product | awk -F: '{print $2}' | sed 's/^\s*//' || lspci | grep -i nvidia | awk -F: '{print $3}' | sed 's/^\s*//')
echo "GPU_INFO: $GPU_INFO"
if [[ $SUPPORT_LAPTOPS -eq 0 && "$GPU_INFO" =~ Mobile|M|Laptop ]]; then
  echo -e "${RED}${BOLD}Mobile GPUs not supported.${NC}"
  exit 1
fi

# Secure Boot robust
SB_STATE=$(mokutil --sb-state 2>/dev/null || echo "EFI variables not supported")
echo -e "${BLUE}${SB_STATE}${NC}"
if [[ "$SB_STATE" == *"enabled"* ]]; then
  echo -e "${RED}${BOLD}Disable Secure Boot in BIOS/UEFI. Exiting.${NC}"
  exit 1
elif [[ "$SB_STATE" == *"not supported"* ]]; then
  echo -e "${YELLOW}Legacy BIOS detected; Secure Boot not applicable.${NC}"
fi

# Nouveau blacklist early
echo "blacklist nouveau\noptions nouveau modeset=0" | sudo tee /etc/modprobe.d/blacklist-nouveau.conf
retry_cmd sudo update-initramfs -u
sudo modprobe -r nouveau 2>/dev/null || sudo rmmod --force nouveau 2>/dev/null || true

# Docker install
sudo -v  # Renew sudo
retry_cmd curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs || echo 'noble') stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
retry_cmd sudo apt update -y
retry_cmd sudo apt install -y docker-ce
sudo usermod -aG docker "$USER"

# NVIDIA drivers
sudo -v  # Renew sudo
retry_cmd sudo apt upgrade -y
[ -f /var/run/reboot-required ] && REBOOT_NEEDED=1
retry_cmd sudo add-apt-repository -y ppa:graphics-drivers/ppa
retry_cmd sudo apt update -y
recommended_driver=$(ubuntu-drivers devices | awk '/recommended/ {print $3}' | head -n1)
if [ -n "$recommended_driver" ]; then
  retry_cmd sudo apt install -y "$recommended_driver"
else
  echo -e "${YELLOW}No recommended driver detected; falling back to autoinstall.${NC}"
  retry_cmd sudo ubuntu-drivers autoinstall
fi
sudo modprobe nvidia 2>/dev/null || { echo -e "${YELLOW}NVIDIA module load may need reboot.${NC}"; REBOOT_NEEDED=1; }

# Hybrid check
if lspci | grep -i 'VGA' | grep -qi 'Intel'; then
  echo -e "${GREEN}Hybrid detected, installing nvidia-prime.${NC}"
  retry_cmd sudo apt install -y nvidia-prime
  sudo prime-select nvidia
fi

# Toolkit
sudo -v  # Renew sudo
retry_cmd curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
retry_cmd bash -c "curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"
retry_cmd sudo apt update -y
retry_cmd sudo apt install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# Verifications
echo -e "${GREEN}nvidia-smi:${NC}"
if nvidia-smi; then
  CUDA_VER=$(nvidia-smi | grep "CUDA Version" | awk '{print $9}')
  if [ -n "$CUDA_VER" ] && [[ "${CUDA_VER%%.*}" -lt 12 ]]; then
    echo -e "${YELLOW}CUDA $CUDA_VER detected; 12+ recommended for Nosana.${NC}"
  fi
  GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1 2>/dev/null)
  GPU_CAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -n1 2>/dev/null)
  GPU_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader | head -n1 2>/dev/null | sed 's/ MiB//')
  if [ -n "$GPU_NAME" ] && { ! [[ "$GPU_NAME" =~ $SUPPORTED_GPU_REGEX ]] || [[ 1 -eq $(awk "BEGIN {print ($GPU_CAP < $MIN_COMPUTE_CAP)}") ]] || [ "$GPU_VRAM" -lt "$MIN_VRAM_MB" ]; }; then
    echo -e "${YELLOW}GPU $GPU_NAME (cap $GPU_CAP, VRAM ${GPU_VRAM}MiB) may not meet Nosana needs; proceed at own risk? [Y/n]${NC}"
    read -p "" yn
    if [[ $yn =~ ^[Nn]$ ]]; then
      echo -e "${RED}Exiting due to marginal GPU.${NC}"
      exit 1
    fi
  fi
else
  echo -e "${YELLOW}nvidia-smi failed; GPU checks skipped—verify post-reboot.${NC}"
  REBOOT_NEEDED=1
fi

# Create samplex.sh
echo "bash <(wget -qO- https://nosana.com/start.sh)" > ~/samplex.sh
chmod +x ~/samplex.sh

# Summary
echo -e "${BRIGHT_GREEN}${BOLD}Installation complete. Review ~/nosana-install.log for details.${NC}"
if [ $REBOOT_NEEDED -eq 1 ]; then
  echo -e "${YELLOW}Reboot required for full stability (kernel/drivers/Docker group).${NC}"
fi
echo -e "${GREEN}After reboot, run '~/samplex.sh' as non-root (equivalent to Nosana join).${NC}"
# sudo reboot
