#!/usr/bin/env bash

# =========================================================
# MetroVPS Hardware Inventory Agent
#
# Usage:
#   ./inventory-agent.sh <SERVER_TOKEN>
#
# Example:
#   ./inventory-agent.sh abc123xyz
#
# Features:
# - Collects hardware & system inventory
# - Sends JSON to API endpoint
# - Auto installs daily cronjob
# - Works across most Linux distributions
# =========================================================

set +e
export LC_ALL=C

# ---------------------------------------------------------
# Configuration
# ---------------------------------------------------------

BASE_URL="https://invenetory-agent.metrovps.com/api/hardware-inventory"

TOKEN="$1"

if [ -z "$TOKEN" ]; then
    echo "Usage: $0 <SERVER_TOKEN>"
    exit 1
fi

API_ENDPOINT="${BASE_URL}?token=${TOKEN}"

SCRIPT_PATH="$(realpath "$0" 2>/dev/null)"

if [ -z "$SCRIPT_PATH" ]; then
    SCRIPT_PATH="$0"
fi

TMP_JSON="/tmp/system_inventory_$$.json"

# ---------------------------------------------------------
# Helper Functions
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
# Install Daily Cronjob
# ---------------------------------------------------------

install_cron() {

    CRON_CMD="0 2 * * * ${SCRIPT_PATH} ${TOKEN} >/dev/null 2>&1"

    (
        crontab -l 2>/dev/null | grep -v "inventory-agent.sh"
        echo "$CRON_CMD"
    ) | crontab -

    echo "Daily cron installed:"
    echo "$CRON_CMD"
}

# ---------------------------------------------------------
# Basic System Info
# ---------------------------------------------------------

HOSTNAME=$(hostname 2>/dev/null || echo "")
FQDN=$(hostname -f 2>/dev/null || echo "")
KERNEL=$(uname -r 2>/dev/null || echo "")
ARCH=$(uname -m 2>/dev/null || echo "")
UPTIME=$(uptime -p 2>/dev/null || cat /proc/uptime 2>/dev/null || echo "")

# ---------------------------------------------------------
# OS Information
# ---------------------------------------------------------

OS_NAME=""
OS_VERSION=""

if [ -f /etc/os-release ]; then
    OS_NAME=$(grep '^NAME=' /etc/os-release | cut -d= -f2- | tr -d '"')
    OS_VERSION=$(grep '^VERSION=' /etc/os-release | cut -d= -f2- | tr -d '"')
fi

# ---------------------------------------------------------
# Virtualization
# ---------------------------------------------------------

VIRTUALIZATION=""

if command_exists systemd-detect-virt; then
    VIRTUALIZATION=$(safe_run systemd-detect-virt)
fi

# ---------------------------------------------------------
# Hardware Info
# ---------------------------------------------------------

SERVER_MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "")
SERVER_VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "")
SERIAL_NUMBER=$(cat /sys/class/dmi/id/product_serial 2>/dev/null || echo "")
BIOS_VERSION=$(cat /sys/class/dmi/id/bios_version 2>/dev/null || echo "")

MOTHERBOARD=$(cat /sys/class/dmi/id/board_name 2>/dev/null || echo "")
MOTHERBOARD_VENDOR=$(cat /sys/class/dmi/id/board_vendor 2>/dev/null || echo "")

# ---------------------------------------------------------
# CPU Info
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
# RAM Info
# ---------------------------------------------------------

TOTAL_RAM=$(awk '/MemTotal/ {printf "%.2f GB", $2/1024/1024}' /proc/meminfo 2>/dev/null)
AVAILABLE_RAM=$(awk '/MemAvailable/ {printf "%.2f GB", $2/1024/1024}' /proc/meminfo 2>/dev/null)
SWAP_TOTAL=$(awk '/SwapTotal/ {printf "%.2f GB", $2/1024/1024}' /proc/meminfo 2>/dev/null)

# ---------------------------------------------------------
# Storage
# ---------------------------------------------------------

STORAGE_JSON="[]"

if command_exists lsblk; then
    STORAGE_JSON=$(lsblk -b -J -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,MODEL,SERIAL,VENDOR 2>/dev/null)
fi

# ---------------------------------------------------------
# Network
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
# Public IP
# ---------------------------------------------------------

PUBLIC_IP=""

if command_exists curl; then
    PUBLIC_IP=$(curl -4 -s --max-time 5 https://ifconfig.me 2>/dev/null)
elif command_exists wget; then
    PUBLIC_IP=$(wget -qO- --timeout=5 https://ifconfig.me 2>/dev/null)
fi

# ---------------------------------------------------------
# Docker Info
# ---------------------------------------------------------

DOCKER_VERSION=""

if command_exists docker; then
    DOCKER_VERSION=$(docker --version 2>/dev/null)
fi

# ---------------------------------------------------------
# GPU Info
# ---------------------------------------------------------

GPU_INFO=""

if command_exists lspci; then
    GPU_INFO=$(lspci 2>/dev/null | grep -Ei 'vga|3d|display')
fi

# ---------------------------------------------------------
# Build JSON
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

  "storage": $STORAGE_JSON,

  "gpu": "$(json_escape "$GPU_INFO")",

  "docker": "$(json_escape "$DOCKER_VERSION")"
}
EOF

# ---------------------------------------------------------
# Send JSON to API
# ---------------------------------------------------------

echo "Sending inventory to:"
echo "$API_ENDPOINT"

HTTP_CODE=""

if command_exists curl; then

    HTTP_CODE=$(curl -s \
        -o /tmp/inventory_response.txt \
        -w "%{http_code}" \
        -X POST "$API_ENDPOINT" \
        -H "Content-Type: application/json" \
        --data @"$TMP_JSON")

elif command_exists wget; then

    wget \
        --header="Content-Type: application/json" \
        --post-file="$TMP_JSON" \
        -O /tmp/inventory_response.txt \
        "$API_ENDPOINT"

    HTTP_CODE=$?

else
    echo "curl or wget is required."
    exit 1
fi

# ---------------------------------------------------------
# Output Result
# ---------------------------------------------------------

echo "HTTP Status: $HTTP_CODE"

if [ -f /tmp/inventory_response.txt ]; then
    echo "Response:"
    cat /tmp/inventory_response.txt
    echo
fi

# ---------------------------------------------------------
# Install Cron Automatically
# ---------------------------------------------------------

install_cron

# ---------------------------------------------------------
# Cleanup
# ---------------------------------------------------------

rm -f "$TMP_JSON"
