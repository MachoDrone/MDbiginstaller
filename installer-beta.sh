#!/bin/bash
echo "v6.12pm"
# Error handling and logging
set -e
RED='\033[1;31m'
GREEN='\033[1;32m'
BRIGHT_GREEN='\033[1;92m'
BOLD='\033[1m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
exec > >(tee -a install.log) 2>&1
trap 'echo -e "${BOLD}${RED}An error occurred on line $LINENO. Exiting.${NC}"' ERR

# Show current username
echo -e "${GREEN}${BOLD}Current user: $(whoami)${NC}"

# Do not allow running as root
if [ "$(id -u)" -eq 0 ]; then
  echo -e "${BOLD}${RED}This script must NOT be run as root. Please run as a regular user with sudo privileges. Exiting.${NC}"
  exit 1
fi

# Check if running in home directory
if [ "$PWD" != "$HOME" ]; then
  echo -e "${BOLD}${RED}This script must be run from your home directory: $HOME${NC}"
  echo -e "${BOLD}${RED}Current directory: $PWD${NC}"
  exit 1
fi

# ASCII arrow before first sudo command
echo -e "            /\\"
echo -e "           /   \\"
echo -e "          /      \\"
echo -e "         /         \\"
echo -e "        ~~~~|   |~~~~\\"
echo -e "            |   |"
echo -e "            |___|"

# Capture username at the very beginning
username=$(echo $USER)

# ---------- Checking Ubuntu Version ---------- (@https://docs.nosana.com/hosts/grid-ubuntu.html )
echo -e "${BRIGHT_GREEN}${BOLD}---------- Checking Ubuntu Version ----------${NC}"

# Block WSL
grep -qiE 'microsoft|wsl' /proc/version /proc/sys/kernel/osrelease 2>/dev/null && {
  echo -e "${BOLD}${RED}This script does not support WSL. Exiting.${NC}" >&2
  exit 1
}

# Check for Hive OS
if grep -qiE 'hive' /etc/*release 2>/dev/null; then
  echo -e "${BOLD}${RED}Hive OS is not supported. Exiting.${NC}" >&2
  exit 1
fi

# Check for genuine Ubuntu
if ! grep -q '^ID=ubuntu$' /etc/os-release || ! grep -q '^NAME=\"Ubuntu\"$' /etc/os-release; then
  echo -e "${BOLD}${RED}This script only supports genuine Ubuntu. Exiting.${NC}" >&2
  exit 1
fi

# Check Ubuntu version
UBUNTU_VERSION=$(grep '^VERSION_ID=' /etc/os-release | awk -F'=' '{gsub(/"/, "", $2); print $2}')
if [[ ! $UBUNTU_VERSION =~ ^[0-9]+\.[0-9]+$ ]]; then
  echo -e "${BOLD}${RED}Could not determine Ubuntu version. Exiting.${NC}" >&2
  exit 1
fi

REQUIRED_VERSION=20.04
if awk -v v1="$UBUNTU_VERSION" -v v2="$REQUIRED_VERSION" 'BEGIN { if (v1+0 < v2+0) exit 1 }'; then
  :
else
  echo -e "${BOLD}${RED}Ubuntu 20.04 or newer is required. Detected: $UBUNTU_VERSION. Exiting.${NC}" >&2
  exit 1
fi

# Secure Boot Check (ensure mokutil is installed)
echo -e "${GREEN}${BOLD}Checking Secure Boot status...${NC}"
if ! command -v mokutil >/dev/null 2>&1; then
  sudo apt update -y 2> >(grep -v "apt does not have a stable CLI interface" >&2)
  sudo apt install -y mokutil 2> >(grep -v "apt does not have a stable CLI interface" >&2)
fi
SB_STATE=$(mokutil --sb-state 2>/dev/null)
echo -e "${BLUE}${SB_STATE}${NC}"
if echo "$SB_STATE" | grep -qi "enabled"; then
  echo -e "${BOLD}${RED}Secure Boot is ENABLED. Please disable Secure Boot in your BIOS/UEFI settings before continuing. Exiting.${NC}"
  exit 1
fi

# Show system info
echo -e "${GREEN}${BOLD}lsb_release -a${NC}"
lsb_release -a

echo -e "${BLUE}Optional LSB Modules should not be necessary${NC}"

echo -e "${GREEN}${BOLD}cat /etc/os-release${NC}"
cat /etc/os-release

echo -e "${GREEN}${BOLD}uname -a${NC}"
uname -a

# ---------- Install Docker Engine ---------- (@https://docs.nosana.com/hosts/grid-ubuntu.html#docker )
echo -e "${BRIGHT_GREEN}${BOLD}---------- Install Docker Engine ----------${NC}"

echo -e "${GREEN}${BOLD}sudo apt update${NC}"
sudo apt update -y 2> >(grep -v "apt does not have a stable CLI interface" >&2)

echo -e "${GREEN}${BOLD}sudo apt upgrade -y${NC}"
sudo apt upgrade -y 2> >(grep -v "apt does not have a stable CLI interface" >&2)

# Check if reboot is required after upgrade
if [ -f /var/run/reboot-required ]; then
  echo -e "${BOLD}${RED}A system reboot is required to complete updates (likely a kernel update). Please reboot and re-run this script.${NC}"
  exit 1
fi

# Commented redundant updates/upgrades for reference
# echo -e "${GREEN}${BOLD}sudo apt update${NC}"
# sudo apt update -y
# echo -e "${GREEN}${BOLD}sudo apt upgrade -y${NC}"
# sudo apt upgrade -y

echo -e "${GREEN}${BOLD}sudo apt install apt-transport-https ca-certificates curl software-properties-common${NC}"
sudo apt install -y apt-transport-https ca-certificates curl software-properties-common 2> >(grep -v "apt does not have a stable CLI interface" >&2)

echo -e "${GREEN}${BOLD}sudo rm /usr/share/keyrings/docker-archive-keyring.gpg${NC}"
sudo rm -f /usr/share/keyrings/docker-archive-keyring.gpg

echo -e "${GREEN}${BOLD}curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg${NC}"
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

echo -e "${GREEN}${BOLD}echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable\" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null${NC}"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo -e "${GREEN}${BOLD}sudo apt update${NC}"
sudo apt update -y 2> >(grep -v "apt does not have a stable CLI interface" >&2)

echo -e "${GREEN}${BOLD}apt-cache policy docker-ce${NC}"
apt-cache policy docker-ce | while IFS= read -r line; do echo -e "${BLUE}$line${NC}"; done

echo -e "${GREEN}${BOLD}sudo apt install docker-ce${NC}"
sudo apt install -y docker-ce 2> >(grep -v "apt does not have a stable CLI interface" >&2)

echo -e "${GREEN}${BOLD}sudo systemctl status docker${NC}"
sudo systemctl status docker --no-pager | while IFS= read -r line; do echo -e "${BLUE}$line${NC}"; done

# Executing the Docker Command Without Sudo
echo -e "${GREEN}${BOLD}sudo usermod -aG docker \${username}${NC}"
sudo usermod -aG docker ${username}

# echo -e "${GREEN}${BOLD}sudo usermod -aG docker \$username${NC}"
# sudo usermod -aG docker $username

echo -e "${GREEN}${BOLD}su - \${username} -c \"groups\"${NC}"
echo -e "          __"
echo -e "         |  |"
echo -e "        _|  |_"
echo -e "        \\    /"
echo -e "         \\  /"
echo -e "          \\/"
su - $username -c "groups"

echo -e "${GREEN}${BOLD}docker -v${NC}"
docker -v | while IFS= read -r line; do echo -e "${BLUE}$line${NC}"; done

# ---------- Install Nvidia Driver on Ubuntu ---------- (@https://discord.com/channels/236263424676331521/1359868195443441894/1359868195443441894 )
echo -e "${BRIGHT_GREEN}${BOLD}---------- Install Nvidia Driver on Ubuntu ----------${NC}"

echo -e "${GREEN}${BOLD}sudo lshw -c display${NC}"
sudo lshw -c display 2>/dev/null | while IFS= read -r line; do echo -e "${BLUE}$line${NC}"; done

echo -e "${GREEN}${BOLD}sudo lshw -c video${NC}"
sudo lshw -c video 2>/dev/null | while IFS= read -r line; do echo -e "${BLUE}$line${NC}"; done

echo -e "${GREEN}${BOLD}sudo apt update${NC}"
sudo apt update -y 2> >(grep -v "apt does not have a stable CLI interface" >&2)

# echo -e "${GREEN}${BOLD}sudo apt upgrade -y${NC}"
# sudo apt upgrade -y

echo -e "${GREEN}${BOLD}sudo apt install ubuntu-drivers-common -y${NC}"
sudo apt install -y ubuntu-drivers-common 2> >(grep -v "apt does not have a stable CLI interface" >&2)

echo -e "${GREEN}${BOLD}ubuntu-drivers devices${NC}"
ubuntu-drivers devices 2>/dev/null | sed 's/recommended/\x1b[32m&\x1b[0m/'

echo -e "${GREEN}${BOLD}nvidia-smi --query-gpu=driver_version --format=csv,noheader && nvidia-smi | grep -i \"CUDA Version\"${NC}"
echo -e "\033[0;32m$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null)\n$(nvidia-smi 2>/dev/null | grep -i \"CUDA Version\" | sed 's/$/  <=== YOUR CURRENT VERSIONS/')\033[0m"

echo -e "${GREEN}${BOLD}sudo apt update && sudo apt upgrade -y${NC}"
sudo apt update -y 2> >(grep -v "apt does not have a stable CLI interface" >&2) && sudo apt upgrade -y 2> >(grep -v "apt does not have a stable CLI interface" >&2)

# echo -e "${GREEN}${BOLD}sudo add-apt-repository ppa:graphics-drivers/ppa${NC}"
# sudo add-apt-repository -y ppa:graphics-drivers/ppa

echo -e "${GREEN}${BOLD}sudo add-apt-repository ppa:graphics-drivers/ppa${NC}"
sudo add-apt-repository -y ppa:graphics-drivers/ppa 2>/dev/null

echo -e "${GREEN}${BOLD}sudo apt update${NC}"
sudo apt update -y 2> >(grep -v "apt does not have a stable CLI interface" >&2)

echo -e "${GREEN}${BOLD}ubuntu-drivers list${NC}"
ubuntu-drivers list 2>/dev/null

echo -e "${GREEN}${BOLD}sudo ubuntu-drivers install${NC}"
sudo ubuntu-drivers install 2>/dev/null

echo -e "${GREEN}${BOLD}sudo apt install nvidia-prime${NC}"
sudo apt install -y nvidia-prime 2> >(grep -v "apt does not have a stable CLI interface" >&2)

echo -e "${GREEN}${BOLD}sudo prime-select nvidia${NC}"
sudo prime-select nvidia 2>/dev/null

echo -e "${GREEN}${BOLD}prime-select query${NC}"
prime-select query 2>/dev/null

echo -e "${BLUE}# Skipping reboot for now${NC}"

echo -e "${GREEN}${BOLD}curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg ...${NC}"
sudo rm -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

echo -e "${GREEN}${BOLD}curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list${NC}"
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

echo -e "${GREEN}${BOLD}sudo apt-get update${NC}"
sudo apt-get update -y 2> >(grep -v "apt does not have a stable CLI interface" >&2)

echo -e "${GREEN}${BOLD}sudo apt-get install -y nvidia-container-toolkit${NC}"
sudo apt-get install -y nvidia-container-toolkit 2> >(grep -v "apt does not have a stable CLI interface" >&2)

echo -e "${GREEN}${BOLD}sudo nvidia-ctk runtime configure --runtime=docker${NC}"
sudo nvidia-ctk runtime configure --runtime=docker 2>/dev/null

echo -e "${GREEN}${BOLD}sudo systemctl restart docker${NC}"
sudo systemctl restart docker

echo -e "${GREEN}${BOLD}nvidia-smi${NC}"
nvidia-smi 2>/dev/null || true

# reserve for later:
# sudo systemctl reboot

# ---------- Summary ----------
echo -e "${BRIGHT_GREEN}${BOLD}---------- Installation Summary ----------${NC}"
echo -e "${GREEN}All steps completed. Please review the output above for any errors.${NC}"
echo -e "${BOLD}${RED}A reboot is required if:${NC}"
echo -e "${RED}- You updated the NVIDIA driver (to resolve driver/library version mismatch)"
echo -e "- You updated the kernel or systemd (to load new modules)"
echo -e "- You want Docker group changes to take effect (to use Docker without sudo)"
echo -e "${GREEN}After reboot, your system will be ready for Nosana node operation.${NC}"
