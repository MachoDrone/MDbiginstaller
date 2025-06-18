
#!/bin/bash

TIMEOUT=600

# Show current DNS servers at the very top
echo ""
echo ""
echo "-----------------------------------"
echo "Current DNS servers before change:"
if command -v systemd-resolve >/dev/null 2>&1; then
    systemd-resolve --status 2>/dev/null | grep 'DNS Servers' | head -n 1 | awk -F': ' '{print $2}'
elif command -v resolvectl >/dev/null 2>&1; then
    resolvectl status 2>/dev/null | grep 'DNS Servers' | head -n 1 | awk -F': ' '{print $2}'
elif command -v nmcli >/dev/null 2>&1; then
    nmcli dev show 2>/dev/null | grep DNS | awk '{print $2}' | sort -u | paste -sd' ' -
else
    grep ^nameserver /etc/resolv.conf | awk '{print $2}' | paste -sd' ' -
fi
echo "-----------------------------------"
echo ""
echo ""

# DNS provider list
PROVIDERS=(
    "Google        (8.8.8.8, 8.8.4.4)         [Blocked in China]"
    "Cloudflare    (1.1.1.1, 1.0.0.1)         [Blocked in China]"
    "Quad9         (9.9.9.9, 149.112.112.112)"
    "OpenDNS       (208.67.222.222, 208.67.220.220)"
    "Yandex        (77.88.8.8, 77.88.8.1)"
)

DNS1_LIST=("8.8.8.8" "1.1.1.1" "9.9.9.9" "208.67.222.222" "77.88.8.8")
DNS2_LIST=("8.8.4.4" "1.0.0.1" "149.112.112.112" "208.67.220.220" "77.88.8.1")

echo "DNS Configuration Script"
echo "-----------------------------------"
echo "Choose a DNS provider:"
for i in "${!PROVIDERS[@]}"; do
    printf "  %d) %s\n" $((i+1)) "${PROVIDERS[$i]}"
done
echo "  6) Enter your own DNS servers"
echo ""
echo "Note: Google and Cloudflare are often blocked in China."
echo ""

read_dns_choice() {
    local choice
    read -t "$TIMEOUT" -p "Select [1-6, default 1]: " choice
    if [[ -z "$choice" ]]; then
        choice=1
    fi
    if ! [[ "$choice" =~ ^[1-6]$ ]]; then
        echo "Invalid choice. Defaulting to 1."
        choice=1
    fi
    echo "$choice"
}

CHOICE=$(read_dns_choice)

if [[ "$CHOICE" -ge 1 && "$CHOICE" -le 5 ]]; then
    DNS1="${DNS1_LIST[$((CHOICE-1))]}"
    DNS2="${DNS2_LIST[$((CHOICE-1))]}"
    echo "Selected: ${PROVIDERS[$((CHOICE-1))]}"
else
    # Custom entry
    DEFAULT_DNS1="8.8.8.8"
    DEFAULT_DNS2="8.8.4.4"
    read_dns() {
        local prompt="$1"
        local default="$2"
        local var
        read -t "$TIMEOUT" -p "$prompt [$default]: " var
        if [[ -z "$var" ]]; then
            echo "$default"
        else
            echo "$var"
        fi
    }
    DNS1=$(read_dns "Enter primary DNS server" "$DEFAULT_DNS1")
    DNS2=$(read_dns "Enter secondary DNS server" "$DEFAULT_DNS2")
fi

echo ""
echo "Using DNS servers: $DNS1, $DNS2"
echo ""

# Detect WSL
if grep -qi microsoft /proc/version 2>/dev/null; then
    echo "Detected WSL."
    echo -e "[network]\ngenerateResolvConf = false" | sudo tee /etc/wsl.conf > /dev/null
    sudo rm -f /etc/resolv.conf
    echo -e "nameserver $DNS1\nnameserver $DNS2" | sudo tee /etc/resolv.conf > /dev/null
    echo ""
    echo "WSL: DNS set."
    echo "--------------------------------------------------"
    echo "IMPORTANT: Please fully close and restart your WSL"
    echo "instance for DNS changes to take effect."
    echo "--------------------------------------------------"
    exit 0
fi

# NetworkManager
if command -v nmcli >/dev/null 2>&1; then
    if nmcli -t -f RUNNING general 2>/dev/null | grep -q '^running$'; then
        ACTIVE_CONN=$(nmcli -g NAME connection show --active 2>/dev/null | head -n1)
        if [[ -n "$ACTIVE_CONN" ]]; then
            echo "Detected NetworkManager. Setting DNS for connection: $ACTIVE_CONN"
            nmcli connection modify "$ACTIVE_CONN" ipv4.dns "$DNS1 $DNS2" ipv4.ignore-auto-dns yes 2>/dev/null
            nmcli connection up "$ACTIVE_CONN" 2>/dev/null
            echo "NetworkManager: DNS set."
        fi
    fi
fi

# Netplan (always overwrite)
if [ -d /etc/netplan ]; then
    echo "Detected netplan. Setting global DNS."
    sudo bash -c "echo -e 'network:\n  version: 2\n  ethernets:\n    eth0:\n      nameservers:\n        addresses: [$DNS1, $DNS2]' > /etc/netplan/99-dns.yaml"
    sudo netplan apply 2>/dev/null
    echo "netplan: DNS set."
fi

# systemd-resolved (always overwrite)
if [ -d /etc/systemd/resolved.conf.d ] || [ -f /etc/systemd/resolved.conf ]; then
    sudo mkdir -p /etc/systemd/resolved.conf.d
    sudo bash -c "echo -e '[Resolve]\nDNS=$DNS1 $DNS2\nFallbackDNS=' > /etc/systemd/resolved.conf.d/dns.conf"
    sudo systemctl restart systemd-resolved 2>/dev/null
    echo "systemd-resolved: DNS set."
fi

echo ""
echo "-----------------------------"
echo "DNS configuration summary:"
echo "-----------------------------"
echo "Configured DNS servers: $DNS1, $DNS2"

if [ -f /etc/netplan/99-dns.yaml ]; then
    echo "Netplan config: /etc/netplan/99-dns.yaml"
fi
if [ -f /etc/systemd/resolved.conf.d/dns.conf ]; then
    echo "systemd-resolved drop-in: /etc/systemd/resolved.conf.d/dns.conf"
fi
if command -v nmcli >/dev/null 2>&1; then
    if nmcli -t -f RUNNING general 2>/dev/null | grep -q '^running$'; then
        ACTIVE_CONN=$(nmcli -g NAME connection show --active 2>/dev/null | head -n1)
        if [[ -n "$ACTIVE_CONN" ]]; then
            echo "NetworkManager connection: $ACTIVE_CONN"
        fi
    fi
fi

echo ""
echo "Current effective DNS servers:"
if command -v systemd-resolve >/dev/null 2>&1; then
    systemd-resolve --status 2>/dev/null | grep 'DNS Servers' | head -n 1 | awk -F': ' '{print $2}'
elif command -v resolvectl >/dev/null 2>&1; then
    resolvectl status 2>/dev/null | grep 'DNS Servers' | head -n 1 | awk -F': ' '{print $2}'
elif command -v nmcli >/dev/null 2>&1; then
    nmcli dev show 2>/dev/null | grep DNS | awk '{print $2}' | sort -u | paste -sd' ' -
else
    grep ^nameserver /etc/resolv.conf | awk '{print $2}' | paste -sd' ' -
fi
echo "-----------------------------"
