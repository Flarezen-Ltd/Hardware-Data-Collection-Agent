#!/usr/bin/env bash

# =========================================================
# MetroVPS Hardware Inventory Agent
#
# Features:
# - Self updating from remote URL
# - Auto installs itself to /opt/metrovps/
# - Sends inventory daily
# - Auto installs cron
# - Works on most Linux distributions
#
# Usage:
#   curl -o install.sh https://your-domain.com/inventory-agent.sh
#   chmod +x install.sh
#   ./install.sh YOUR_SERVER_TOKEN
#
# =========================================================

set +e
export LC_ALL=C

# ---------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------

TOKEN="$1"

if [ -z "$TOKEN" ]; then
    echo "Usage: $0 <SERVER_TOKEN>"
    exit 1
fi

# API Endpoint
BASE_API_URL="https://invenetory-agent.metrovps.com/api/hardware-inventory"

# Script Update URL
SCRIPT_UPDATE_URL="https://raw.githubusercontent.com/Flarezen-Ltd/Hardware-Data-Collection-Agent/refs/heads/main/inventory-agenet.sh"

# Installation Path
INSTALL_DIR="/opt/metrovps"
INSTALL_SCRIPT="${INSTALL_DIR}/inventory-agent.sh"

# Runtime
TMP_JSON="/tmp/system_inventory_$$.json"

# Final API URL
API_ENDPOINT="${BASE_API_URL}?token=${TOKEN}"

# ---------------------------------------------------------
# HELPER FUNCTIONS
# ---------------------------------------------------------

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

safe_run() {
    "$@" 2>/dev/null || true
}

json_escape() {
    echo "$1" | \
        sed 's/\\/\\\\/g' | \
        sed 's/"/\\"/g' | \
        tr '\n' ' '
}

trim() {
    awk '{$1=$1};1'
}

# ---------------------------------------------------------
# SELF INSTALL
# ---------------------------------------------------------

self_install() {

    mkdir -p "$INSTALL_DIR"

    CURRENT_SCRIPT="$(realpath "$0" 2>/dev/null)"

    if [ -f "$CURRENT_SCRIPT" ] && [ "$CURRENT_SCRIPT" != "$INSTALL_SCRIPT" ]; then

        cp "$CURRENT_SCRIPT" "$INSTALL_SCRIPT"
        chmod +x "$INSTALL_SCRIPT"

        echo "Installed agent to:"
        echo "$INSTALL_SCRIPT"
    fi
}

# ---------------------------------------------------------
# SELF UPDATE
# ---------------------------------------------------------

self_update() {

    echo "Checking for script updates..."

    TMP_SCRIPT="/tmp/inventory-agent-update.sh"

    if command_exists curl; then

        curl -fsSL "$SCRIPT_UPDATE_URL" -o "$TMP_SCRIPT"

    elif command_exists wget; then

        wget -qO "$TMP_SCRIPT" "$SCRIPT_UPDATE_URL"

    else
        echo "curl or wget required for updates."
        return
    fi

    if [ -s "$TMP_SCRIPT" ]; then

        chmod +x "$TMP_SCRIPT"

        cp "$TMP_SCRIPT" "$INSTALL_SCRIPT"

        chmod +x "$INSTALL_SCRIPT"

        echo "Agent updated successfully."
    else
        echo "Failed to download update."
    fi

    rm -f "$TMP_SCRIPT"
}

# ---------------------------------------------------------
# INSTALL CRON
# ---------------------------------------------------------

install_cron() {

    CRON_CMD="0 2 * * * ${INSTALL_SCRIPT} ${TOKEN} >/dev/null 2>&1"

    (
        crontab -l 2>/dev/null | grep -v "${INSTALL_SCRIPT}"
        echo "$CRON_CMD"
    ) | crontab -

    echo "Daily cron installed:"
    echo "$CRON_CMD"
}

# ---------------------------------------------------------
# BASIC SYSTEM INFO
# ---------------------------------------------------------

HOSTNAME=$(hostname 2>/dev/null || echo "")
FQDN=$(hostname -f 2>/dev/null || echo "")
KERNEL=$(uname -r 2>/dev/null || echo "")
ARCH=$(uname -m 2>/dev/null || echo "")
UPTIME=$(uptime -p 2>/dev/null || echo "")

# ---------------------------------------------------------
# OS INFO
# ---------------------------------------------------------

OS_NAME=""
OS_VERSION=""

if [ -f /etc/os-release ]; then
    OS_NAME=$(grep '^NAME=' /etc/os-release | cut -d= -f2- | tr -d '"')
    OS_VERSION=$(grep '^VERSION=' /etc/os-release | cut -d= -f2- | tr -d '"')
fi

# ---------------------------------------------------------
# VIRTUALIZATION
# ---------------------------------------------------------

VIRTUALIZATION=""

if command_exists systemd-detect-virt; then
    VIRTUALIZATION=$(safe_run systemd-detect-virt)
fi

# ---------------------------------------------------------
# HARDWARE INFO
# ---------------------------------------------------------

SERVER_MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "")
SERVER_VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "")
SERIAL_NUMBER=$(cat /sys/class/dmi/id/product_serial 2>/dev/null || echo "")
BIOS_VERSION=$(cat /sys/class/dmi/id/bios_version 2>/dev/null || echo "")

MOTHERBOARD=$(cat /sys/class/dmi/id/board_name 2>/dev/null || echo "")
MOTHERBOARD_VENDOR=$(cat /sys/class/dmi/id/board_vendor 2>/dev/null || echo "")

# ---------------------------------------------------------
# CPU INFO
# ---------------------------------------------------------

CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2- | trim)
CPU_THREADS=$(grep -c ^processor /proc/cpuinfo 2>/dev/null)
CPU_CORES=$(grep -m1 "cpu cores" /proc/cpuinfo 2>/dev/null | cut -d: -f2- | trim)
CPU_FREQ=$(grep -m1 "cpu MHz" /proc/cpuinfo 2>/dev/null | cut -d: -f2- | trim)

CPU_SOCKETS=""

if command_exists lscpu; then
    CPU_SOCKETS=$(lscpu 2>/dev/null | awk -F: '/Socket\(s\)/ {print $2}' | trim)
fi

# ---------------------------------------------------------
# MEMORY INFO
# ---------------------------------------------------------

TOTAL_RAM=$(awk '/MemTotal/ {printf "%.2f GB", $2/1024/1024}' /proc/meminfo 2>/dev/null)
AVAILABLE_RAM=$(awk '/MemAvailable/ {printf "%.2f GB", $2/1024/1024}' /proc/meminfo 2>/dev/null)
SWAP_TOTAL=$(awk '/SwapTotal/ {printf "%.2f GB", $2/1024/1024}' /proc/meminfo 2>/dev/null)

# ---------------------------------------------------------
# STORAGE
# ---------------------------------------------------------

STORAGE_JSON="[]"

if command_exists lsblk; then
    STORAGE_JSON=$(lsblk -b -J -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,MODEL,SERIAL,VENDOR 2>/dev/null)
fi

# ---------------------------------------------------------
# NETWORK
# ---------------------------------------------------------

NETWORK_JSON="[]"
IPV4_LIST=""
IPV6_LIST=""

if command_exists ip; then

    NETWORK_JSON=$(ip -j addr 2>/dev/null)

    IPV4_LIST=$(ip -4 addr show scope global 2>/dev/null | \
        awk '/inet / {print $2}' | paste -sd "," -)

    IPV6_LIST=$(ip -6 addr show scope global 2>/dev/null | \
        awk '/inet6 / {print $2}' | paste -sd "," -)
fi

# ---------------------------------------------------------
# PUBLIC IP
# ---------------------------------------------------------

PUBLIC_IP=""

if command_exists curl; then
    PUBLIC_IP=$(curl -4 -s --max-time 5 https://ifconfig.me 2>/dev/null)
elif command_exists wget; then
    PUBLIC_IP=$(wget -qO- --timeout=5 https://ifconfig.me 2>/dev/null)
fi

# ---------------------------------------------------------
# BUILD JSON
# ---------------------------------------------------------

cat > "$TMP_JSON" <<EOF
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",

  "system": {
    "hostname": "$(json_escape "$HOSTNAME")",
    "fqdn": "$(json_escape "$FQDN")",
    "os_name": "$(json_escape "$OS_NAME")",
    "os_version": "$(json_escape "$OS_VERSION")",
    "kernel": "$(json_escape "$KERNEL")",
    "architecture": "$(json_escape "$ARCH")",
    "uptime": "$(json_escape "$UPTIME")",
    "virtualization": "$(json_escape "$VIRTUALIZATION")"
  },

  "hardware": {
    "server_vendor": "$(json_escape "$SERVER_VENDOR")",
    "server_model": "$(json_escape "$SERVER_MODEL")",
    "serial_number": "$(json_escape "$SERIAL_NUMBER")",
    "bios_version": "$(json_escape "$BIOS_VERSION")",

    "motherboard": {
      "vendor": "$(json_escape "$MOTHERBOARD_VENDOR")",
      "model": "$(json_escape "$MOTHERBOARD")"
    }
  },

  "cpu": {
    "model": "$(json_escape "$CPU_MODEL")",
    "threads": "$(json_escape "$CPU_THREADS")",
    "cores_per_socket": "$(json_escape "$CPU_CORES")",
    "sockets": "$(json_escape "$CPU_SOCKETS")",
    "frequency_mhz": "$(json_escape "$CPU_FREQ")"
  },

  "memory": {
    "total_ram": "$(json_escape "$TOTAL_RAM")",
    "available_ram": "$(json_escape "$AVAILABLE_RAM")",
    "swap_total": "$(json_escape "$SWAP_TOTAL")"
  },

  "network": {
    "public_ip": "$(json_escape "$PUBLIC_IP")",
    "ipv4_addresses": "$(json_escape "$IPV4_LIST")",
    "ipv6_addresses": "$(json_escape "$IPV6_LIST")",
    "interfaces": $NETWORK_JSON
  },

  "storage": $STORAGE_JSON
}
EOF

# ---------------------------------------------------------
# SEND INVENTORY
# ---------------------------------------------------------

echo "Sending inventory..."

if command_exists curl; then

    curl -s \
        -X POST "$API_ENDPOINT" \
        -H "Content-Type: application/json" \
        --data @"$TMP_JSON"

elif command_exists wget; then

    wget \
        --header="Content-Type: application/json" \
        --post-file="$TMP_JSON" \
        -O - \
        "$API_ENDPOINT"
fi

echo
echo "Inventory sent."

# ---------------------------------------------------------
# MAIN
# ---------------------------------------------------------

self_install
self_update
install_cron

# Cleanup
rm -f "$TMP_JSON"
