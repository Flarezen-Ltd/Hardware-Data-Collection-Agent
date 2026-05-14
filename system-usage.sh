#!/usr/bin/env bash

# =========================================================
# Universal Linux Server Monitoring Script
# Added:
# - Real-time RX/TX network speed (Mbps)
# =========================================================

API_URL="https://invenetory-agent.metrovps.com/api/system/usage/collect"

HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# =========================================================
# CPU Usage
# =========================================================
get_cpu_usage() {

    CPU_IDLE=$(top -bn1 2>/dev/null | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print int($1)}')

    if [ -z "$CPU_IDLE" ]; then
        CPU_IDLE=$(vmstat 1 2 2>/dev/null | tail -1 | awk '{print $15}')
    fi

    [ -z "$CPU_IDLE" ] && CPU_IDLE=0

    echo $((100 - CPU_IDLE))
}

CPU_USAGE=$(get_cpu_usage)

# =========================================================
# Memory Usage
# =========================================================
if command -v free >/dev/null 2>&1; then

    MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
    MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
    MEM_FREE=$(free -m | awk '/Mem:/ {print $4}')

else

    MEM_TOTAL=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    MEM_FREE=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
    MEM_USED=$((MEM_TOTAL - MEM_FREE))

fi

MEM_PERCENT=$(awk "BEGIN {printf \"%.2f\", ($MEM_USED/$MEM_TOTAL)*100}")

# =========================================================
# Disk Usage
# =========================================================
DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
DISK_USED=$(df -h / | awk 'NR==2 {print $3}')
DISK_AVAIL=$(df -h / | awk 'NR==2 {print $4}')
DISK_PERCENT=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')

# =========================================================
# Network Interface Detection
# =========================================================
get_default_interface() {

    IFACE=$(ip route 2>/dev/null | awk '/default/ {print $5}' | head -n1)

    if [ -z "$IFACE" ]; then
        IFACE=$(route -n 2>/dev/null | awk '/UG/ {print $8}' | head -n1)
    fi

    if [ -z "$IFACE" ]; then
        IFACE=$(ls /sys/class/net | grep -v lo | head -n1)
    fi

    echo "$IFACE"
}

INTERFACE=$(get_default_interface)

# =========================================================
# Network Total Usage
# =========================================================
RX_BYTES_TOTAL=0
TX_BYTES_TOTAL=0

if [ -n "$INTERFACE" ] && [ -d "/sys/class/net/$INTERFACE" ]; then

    RX_BYTES_TOTAL=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes 2>/dev/null || echo 0)
    TX_BYTES_TOTAL=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes 2>/dev/null || echo 0)

fi

RX_TOTAL_MB=$(awk "BEGIN {printf \"%.2f\", $RX_BYTES_TOTAL/1024/1024}")
TX_TOTAL_MB=$(awk "BEGIN {printf \"%.2f\", $TX_BYTES_TOTAL/1024/1024}")

# =========================================================
# Real-time Network Speed
# Measures over 1 second
# =========================================================
RX1=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes 2>/dev/null || echo 0)
TX1=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes 2>/dev/null || echo 0)

sleep 1

RX2=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes 2>/dev/null || echo 0)
TX2=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes 2>/dev/null || echo 0)

RX_RATE_BPS=$((RX2 - RX1))
TX_RATE_BPS=$((TX2 - TX1))

# Convert to Mbps
RX_RATE_MBPS=$(awk "BEGIN {printf \"%.2f\", ($RX_RATE_BPS * 8)/1024/1024}")
TX_RATE_MBPS=$(awk "BEGIN {printf \"%.2f\", ($TX_RATE_BPS * 8)/1024/1024}")

# =========================================================
# Load Average
# =========================================================
LOAD_AVG=$(cat /proc/loadavg | awk '{print $1" "$2" "$3}')

# =========================================================
# Uptime
# =========================================================
UPTIME=$(uptime 2>/dev/null | sed 's/.*up \([^,]*\), .*/\1/' )

# =========================================================
# Public IP
# =========================================================
PUBLIC_IP=$(curl -s --max-time 5 https://ipv4.icanhazip.com 2>/dev/null | tr -d '\n')

# =========================================================
# OS Info
# =========================================================
OS_NAME=$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
KERNEL=$(uname -r)

# =========================================================
# JSON Payload
# =========================================================
JSON_PAYLOAD=$(cat <<EOF
{
  "hostname": "$HOSTNAME",
  "timestamp": "$TIMESTAMP",
  "public_ip": "$PUBLIC_IP",

  "os": {
    "name": "$OS_NAME",
    "kernel": "$KERNEL"
  },

  "cpu": {
    "usage_percent": "$CPU_USAGE"
  },

  "memory": {
    "total_mb": "$MEM_TOTAL",
    "used_mb": "$MEM_USED",
    "free_mb": "$MEM_FREE",
    "usage_percent": "$MEM_PERCENT"
  },

  "disk": {
    "total": "$DISK_TOTAL",
    "used": "$DISK_USED",
    "available": "$DISK_AVAIL",
    "usage_percent": "$DISK_PERCENT"
  },

  "network": {
    "interface": "$INTERFACE",

    "total": {
      "rx_mb": "$RX_TOTAL_MB",
      "tx_mb": "$TX_TOTAL_MB"
    },

    "rate": {
      "rx_mbps": "$RX_RATE_MBPS",
      "tx_mbps": "$TX_RATE_MBPS"
    }
  },

  "system": {
    "load_average": "$LOAD_AVG",
    "uptime": "$UPTIME"
  }
}
EOF
)

# =========================================================
# Send Data
# =========================================================
HTTP_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    --data "$JSON_PAYLOAD")

# =========================================================
# Output
# =========================================================
echo "$JSON_PAYLOAD"
echo ""
echo "HTTP Response: $HTTP_RESPONSE"
