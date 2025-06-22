# run with wget -O sme.py https://raw.githubusercontent.com/MachoDrone/MDbiginstaller/refs/heads/main/sme.py && python3 sme.py
# DO NOT DELETE THIS COMMENT.
# =============================================================================
# STRICT PODMAN VERSION DETECTION LOGIC & DYNAMIC LOGIN LOGIC -- READ THIS BEFORE EDITING!
#
# This script supports two login modes:
#   - Static: All hosts use the same username/password (static_user/static_password)
#   - Dynamic: Username is the first occurrence of <dynamic_user_keyword><number> in the hostname (e.g., lifestyle14),
#              password is <dynamic_password_prefix><number> (e.g., Nosana14). Prefix before keyword is ignored.
#              If dynamic_leading_zero is True, single digits are padded to two digits (e.g., 1 -> 01).
#
# Example:
#   Hostname: biglifestyle14-MT-7C91 -> Username: lifestyle14, Password: Nosana14
#   Hostname: pillarlifestyle1OICU812 -> Username: lifestyle1, Password: Nosana1
#
# Podman version detection is strict:
#   - On native Linux: always use docker exec podman podman -v (if fails, _Podman_Down_)
#   - On WSL2: always use podman -v
#
# If you are editing this script, DO NOT revert to fallback or 'try both' logic for podman or login.
# =============================================================================

import subprocess
import threading
from queue import Queue
import re

# CONFIGURATION
threads = 43

# Login method: "static" or "dynamic"
login_mode = "dynamic"  # options: "static", "dynamic"

# For static login
static_user = "sameUsername" # if all of your PCs have the same username, replace sameUserneme with your username
static_password = "staticPW" # if all of your PCs have the same password, replace staticPW with your password

# For dynamic login
dynamic_user_keyword = "lifestyle"      # the keyword to search for in the hostname
dynamic_password_prefix = "Nosana"      # the password prefix
dynamic_leading_zero = False            # pad single digits with leading zero if True

# Network/subnet to scan
subnet = "192.168.0.1/24"

csv_header = (
    "hostname,ip,mac_address,wallet,platform,ubuntu_version,genuine_ubuntu,ping_rtt,"
    "nvidia_driver,cuda_version,gpu_model,vram,ram,storage,storage_type,"
    "cpu,node_ver,npm_ver,docker_ver,docker_loggedin,podman_ver"
)

output_file = "scanhosts.csv"

with open(output_file, "w") as f:
    f.write(csv_header + "\n")

for pkg in ["nmap", "sshpass"]:
    if subprocess.call(f"dpkg -s {pkg} >/dev/null 2>&1", shell=True) != 0:
        subprocess.check_call(f"sudo apt-get install -y {pkg}", shell=True)

# 1. Scan for live IPs
nmap_cmd = f"sudo nmap -sn {subnet} -oG -"
ips = []
for line in subprocess.check_output(nmap_cmd, shell=True).decode().splitlines():
    if "Up" in line:
        parts = line.split()
        for part in parts:
            if part.count('.') == 3:
                ips.append(part)
with open("iplist.txt", "w") as f:
    f.write('\n'.join(ips))

# 1b. Build IP -> MAC mapping using arp or ip neigh
mac_map = {}
# Try ip neigh first, fallback to arp -n
try:
    neigh = subprocess.check_output("ip neigh", shell=True).decode().splitlines()
    for line in neigh:
        parts = line.split()
        if len(parts) >= 5 and parts[0].count('.') == 3:
            ip = parts[0]
            mac = parts[4]
            mac_map[ip] = mac
except Exception:
    try:
        arp = subprocess.check_output("arp -n", shell=True).decode().splitlines()
        for line in arp:
            parts = line.split()
            if len(parts) >= 3 and parts[0].count('.') == 3:
                ip = parts[0]
                mac = parts[2]
                mac_map[ip] = mac
    except Exception:
        pass

print()
print("---scanning---")

# 2. mDNS scan: build ip->hostname mapping
mdns_results = {}
results_lock = threading.Lock()

def resolve_ip(ip):
    try:
        result = subprocess.run(
            ["timeout", "1", "avahi-resolve-address", ip],
            capture_output=True, text=True
        )
        if result.returncode == 0 and "failed" not in result.stdout:
            line = result.stdout.strip()
            parts = line.split()
            if len(parts) == 2:
                ip_addr, hostname = parts
                if hostname.endswith('.local'):
                    hostname = hostname[:-6]
                with results_lock:
                    mdns_results[ip_addr] = hostname
    except Exception:
        pass

threads_mdns = []
for ip in ips:
    t = threading.Thread(target=resolve_ip, args=(ip,))
    t.start()
    threads_mdns.append(t)
for t in threads_mdns:
    t.join()

def extract_dynamic_login(hostname):
    m = re.search(rf"{re.escape(dynamic_user_keyword)}(\d+)", hostname)
    if not m:
        return None, None
    number = m.group(1)
    # Pad with leading zero if needed
    if dynamic_leading_zero and len(number) == 1:
        number = f"0{number}"
    username = f"{dynamic_user_keyword}{number}"
    password = f"{dynamic_password_prefix}{number}"
    return username, password

def get_host_wallet(ip):
    hostname = mdns_results.get(ip, ip)
    if login_mode == "dynamic":
        user, password = extract_dynamic_login(hostname)
        if not user or not password:
            return hostname, ip, "__N/A__", user, password
    else:
        user = static_user
        password = static_password
    try:
        ssh_cmd = (
            f"sshpass -p '{password}' ssh "
            f"-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
            f"{user}@{ip} \"docker logs nosana-node 2>/dev/null | head -12 | grep 'Wallet:' | awk '{{print \\$2}}'\" 2>/dev/null"
        )
        output = subprocess.check_output(ssh_cmd, shell=True, timeout=20).decode().splitlines()
        if len(output) >= 1:
            wallet = output[0].strip()
            return hostname, ip, wallet, user, password
        else:
            return hostname, ip, "__N/A__", user, password
    except Exception:
        return hostname, ip, "__N/A__", user, password

def worker():
    while True:
        ip = q.get()
        if ip is None:
            break

        hostname, ip_addr, wallet, user, password = get_host_wallet(ip)
        mac_address = mac_map.get(ip_addr, "__N/A__")

        if hostname == "__FAILED__":
            q.task_done()
            continue

        remote_script = r'''
fail="__FAILED__"
not_inst="__NOT_INSTALLED__"
podman_down="_Podman_Down_"
na="__N/A__"

for dep in nvidia-smi lscpu lsblk node npm docker; do
    if ! command -v $dep >/dev/null 2>&1; then
        if [ "$dep" = "nvidia-smi" ]; then continue; fi
        if [ "$dep" = "docker" ]; then
            sudo apt-get update -y >/dev/null 2>&1
            sudo apt-get install -y docker.io >/dev/null 2>&1
        else
            sudo apt-get update -y >/dev/null 2>&1
            sudo apt-get install -y $dep >/dev/null 2>&1
        fi
    fi
done

platform="Linux"
if grep -qi microsoft /proc/version 2>/dev/null; then
    platform="WSL-2"
fi

if [ -f /etc/os-release ]; then
    . /etc/os-release
    if echo "$ID $NAME $PRETTY_NAME" | grep -iq ubuntu; then
        ubuntu_version="${VERSION_ID:-$fail}"
        genuine="✔✔"
    else
        platform="fork "
        ubuntu_version="$fail"
        genuine="OO"
    fi
else
    platform="fork "
    ubuntu_version="$fail"
    genuine="OO"
fi

# Robust ping RTT detection
ping_rtt="$fail"
ping_out=$(ping -c 5 -w 7 google.com 2>/dev/null)
if [ $? -eq 0 ]; then
    rtt_line=$(echo "$ping_out" | grep 'rtt min/avg/max/mdev' || echo "$ping_out" | grep 'round-trip min/avg/max')
    if [ -n "$rtt_line" ]; then
        rtt_vals=$(echo "$rtt_line" | awk -F' = ' '{print $2}' | awk '{print $1}')
        min=$(echo $rtt_vals | awk -F'/' '{print $1}')
        avg=$(echo $rtt_vals | awk -F'/' '{print $2}')
        max=$(echo $rtt_vals | awk -F'/' '{print $3}')
        mdev=$(echo $rtt_vals | awk -F'/' '{print $4}')
        ping_rtt="min:$min avg:$avg max:$max mdev:$mdev"
    fi
else
    ping_out=$(ping -c 5 -w 7 8.8.8.8 2>/dev/null)
    if [ $? -eq 0 ]; then
        rtt_line=$(echo "$ping_out" | grep 'rtt min/avg/max/mdev' || echo "$ping_out" | grep 'round-trip min/avg/max')
        if [ -n "$rtt_line" ]; then
            rtt_vals=$(echo "$rtt_line" | awk -F' = ' '{print $2}' | awk '{print $1}')
            min=$(echo $rtt_vals | awk -F'/' '{print $1}')
            avg=$(echo $rtt_vals | awk -F'/' '{print $2}')
            max=$(echo $rtt_vals | awk -F'/' '{print $3}')
            mdev=$(echo $rtt_vals | awk -F'/' '{print $4}')
            ping_rtt="min:$min avg:$avg max:$max mdev:$mdev"
        fi
    fi
fi
[ -z "$ping_rtt" ] && ping_rtt="$fail"

ram_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
if [ -n "$ram_kb" ]; then
    ram_gb=$(echo $ram_kb | awk '{printf("%03d", int($1/1024/1024+0.5))}')
    if [ ${#ram_gb} -eq 2 ]; then
        ram_gb="_${ram_gb}"
    fi
    ram_gb="${ram_gb} GB"
else
    ram_gb="$fail"
fi

rootdev=$(df / | awk 'NR==2{print $1}' | sed 's|/dev/||')
parentdev=$(lsblk -no PKNAME /dev/$rootdev 2>/dev/null)
if [ -z "$parentdev" ]; then
    parentdev=$rootdev
fi

if [ -n "$parentdev" ]; then
    storage_info=$(lsblk -d -o NAME,SIZE,MODEL,ROTA,TRAN | awk -v dev="$parentdev" '$1==dev')
    dev_name=$(echo "$storage_info" | awk '{print $1}')
    dev_size=$(echo "$storage_info" | awk '{print $2}')
    dev_model=$(echo "$storage_info" | awk '{print $3}')
    dev_rota=$(echo "$storage_info" | awk '{print $4}')
    dev_tran=$(echo "$storage_info" | awk '{print $5}')
    # Convert storage to x.xT
    if [[ "$dev_size" =~ T$ ]]; then
        storage="$dev_size"
    elif [[ "$dev_size" =~ G$ ]]; then
        size_num=$(echo "$dev_size" | sed 's/G//')
        storage=$(awk "BEGIN {printf \"%.1fT\", $size_num/1000}")
    else
        storage="$dev_size"
    fi
    if [[ "$dev_name" == nvme* ]]; then
        storage_type="NVMe"
    elif [[ "$dev_model" =~ [Ss][Ss][Dd] ]]; then
        storage_type="SSD"
    elif [[ "$dev_model" =~ [Hh][Dd][Dd] || "$dev_model" =~ ^ST ]]; then
        storage_type="HDD"
    elif [ "$dev_tran" = "nvme" ]; then
        storage_type="NVMe"
    elif [ "$dev_tran" = "sata" ] && [ "$dev_rota" = "0" ]; then
        storage_type="SSD"
    elif [ "$dev_tran" = "sata" ] && [ "$dev_rota" = "1" ]; then
        storage_type="HDD"
    elif [ "$dev_tran" = "usb" ]; then
        storage_type="USB"
    elif [ "$dev_rota" = "0" ]; then
        storage_type="SSD"
    elif [ "$dev_rota" = "1" ]; then
        storage_type="HDD"
    else
        storage_type="Unknown"
    fi
else
    storage="$not_inst"
    storage_type="$not_inst"
fi

if command -v lscpu >/dev/null 2>&1; then
    cpu=$(lscpu | grep 'Model name' | awk -F: '{print $2}' | xargs)
    [ -z "$cpu" ] && cpu="$fail"
else
    cpu="$not_inst"
fi

if command -v node >/dev/null 2>&1; then
    node_ver=$(node -v 2>/dev/null)
else
    node_ver="$not_inst"
fi

if command -v npm >/dev/null 2>&1; then
    npm_ver=$(npm -v 2>/dev/null)
else
    npm_ver="$not_inst"
fi

if command -v docker >/dev/null 2>&1; then
    docker_ver=$(docker -v 2>/dev/null | awk '{print $3}' | sed 's/,//')
    if docker info 2>/dev/null | grep -q Username; then
        docker_loggedin="yes"
    else
        docker_loggedin="no"
    fi
else
    docker_ver="$not_inst"
    docker_loggedin="__N/A__"
fi

# --- Strict platform-based podman detection ---
if [ "$platform" = "WSL-2" ]; then
    if command -v podman >/dev/null 2>&1; then
        podman_ver=$(podman -v 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    else
        podman_ver="$not_inst"
    fi
else
    if command -v docker >/dev/null 2>&1; then
        podman_ver=$(docker exec podman podman -v 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
        [ -z "$podman_ver" ] && podman_ver="$podman_down"
    else
        podman_ver="$not_inst"
    fi
fi

# Per-GPU output
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia_driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
    # Format nvidia_driver as 123.123.12, with middle number always 2 digits, leading 0 replaced with _
    if [[ "$nvidia_driver" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        d1="${BASH_REMATCH[1]}"
        d2="${BASH_REMATCH[2]}"
        d3="${BASH_REMATCH[3]}"
        if [ ${#d2} -eq 1 ]; then
            d2="_${d2}"
        elif [ ${#d2} -eq 2 ] && "${d2:0:1}" = "0"; then
            d2="_${d2:1:1}"
        fi
        nvidia_driver="${d1}.${d2}.${d3}"
    fi
    cuda_version=$(nvidia-smi 2>/dev/null | grep "CUDA Version" | awk '{print $9}' | head -1)
    nvidia_smi_out=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null)
    gpu_idx=0
    echo "$nvidia_smi_out" | while IFS=, read -r gpu_model vram_mb; do
        gpu_model=$(echo "$gpu_model" | xargs)
        vram_mb=$(echo "$vram_mb" | awk '{print $1}')
        if [[ "$vram_mb" =~ ^[0-9]+$ ]]; then
            vram_gb=$(awk "BEGIN {printf \"%03d\", int($vram_mb/1024+0.5)}")
            if [ ${#vram_gb} -eq 2 ]; then
                vram_gb="_${vram_gb}"
            fi
            vram_gb="${vram_gb} GB"
        else
            vram_gb="$fail"
        fi
        echo ",${platform},${ubuntu_version},${genuine},${ping_rtt},${nvidia_driver},${cuda_version},${gpu_model},${vram_gb},${ram_gb},${storage},${storage_type},${cpu},${node_ver},${npm_ver},${docker_ver},${docker_loggedin},${podman_ver}"
        gpu_idx=$((gpu_idx+1))
    done
    if [ "$gpu_idx" -eq 0 ]; then
        echo ",${platform},${ubuntu_version},${genuine},${ping_rtt},${nvidia_driver},${cuda_version},${not_inst},${not_inst},${ram_gb},${storage},${storage_type},${cpu},${node_ver},${npm_ver},${docker_ver},${docker_loggedin},${podman_ver}"
    fi
else
    echo ",${platform},${ubuntu_version},${genuine},${ping_rtt},${not_inst},${not_inst},${not_inst},${not_inst},${ram_gb},${storage},${storage_type},${cpu},${node_ver},${npm_ver},${docker_ver},${docker_loggedin},${podman_ver}"
fi
'''

        ssh_cmd = (
            f"sshpass -p '{password}' ssh "
            f"-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
            f"{user}@{ip} 'bash -s' 2>/dev/null"
        )

        try:
            result = subprocess.check_output(ssh_cmd, input=remote_script.encode(), shell=True, timeout=90).decode().strip()
            if result:
                for line in result.splitlines():
                    # Insert mac_address after ip and before wallet
                    fields = [hostname, ip_addr, mac_address, wallet] + line.split(",")[1:]
                    full_line = ",".join(fields)
                    print(full_line, flush=True)
                    with lock:
                        with open(output_file, "a") as f:
                            f.write(full_line + "\n")
        except Exception:
            pass
        q.task_done()

q = Queue()
lock = threading.Lock()
for ip in ips:
    q.put(ip)
threads_list = []
for _ in range(threads):
    t = threading.Thread(target=worker)
    t.start()
    threads_list.append(t)
q.join()
for _ in threads_list:
    q.put(None)
for t in threads_list:
    t.join()

# Deduplicate, filter, and count hosts
with open(output_file) as f:
    lines = [line.strip() for line in f if line.strip()]
header = lines[0]
data_lines = [line for line in lines[1:] if not line.startswith("hostname,ip,mac_address,wallet")]
filtered_lines = []
for line in data_lines:
    fields = line.split(",")
    if len(fields) > 13 and not (fields[10] == "__NOT_INSTALLED__" and fields[11] == "__NOT_INSTALLED__"):
        filtered_lines.append(line)
unique_lines = sorted(set(filtered_lines))
with open(output_file, "w") as f:
    f.write(header + "\n")
    for line in unique_lines:
        f.write(line + "\n")

print("Scan complete.")
print(f"\n--- {len(unique_lines)} GPU/host lines with reported information ---")
print(f"\n--- {output_file} (deduplicated, sorted by hostname) ---")
with open(output_file) as f:
    print(f.read())
