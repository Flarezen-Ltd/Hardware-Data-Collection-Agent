#!/usr/bin/env bash

# =========================================================
# Ultra Lightweight Linux Monitoring Script
#
# Features:
# - Minimal CPU usage
# - No sleep
# - No top/free/vmstat
# - Uses only /proc and /sys
# - Works on almost all Linux distributions
#
# Collects:
# - CPU Usage %
# - RAM Usage
# - Disk Usage
# - Network Total Usage
# - Network Current RX/TX Rate
# =========================================================

API_URL="https://invenetory-agent.metrovps.com/api/system/usage/collect"

STATE_FILE="/tmp/monitor_net_state"
CPU_STATE_FILE="/tmp/monitor_cpu_state"

HOSTNAME=$(hostname)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# =========================================================
# Detect Main Interface
# =========================================================
INTERFACE=$(ip route 2>/dev/null | awk '/default/ {print $5}' | head -n1)

if [ -z "$INTERFACE" ]; then
    INTERFACE=$(ls /sys/class/net | grep -v lo | head -n1)
fi

# =========================================================
# CPU Usage
# =========================================================
read cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat

TOTAL=$((user + nice + system + idle + iowait + irq + softirq + steal))
IDLE=$((idle + iowait))

CPU_USAGE="0"

if [ -f "$CPU_STATE_FILE" ]; then

    read PREV_TOTAL PREV_IDLE < "$CPU_STATE_FILE"

    DIFF_TOTAL=$((TOTAL - PREV_TOTAL))
    DIFF_IDLE=$((IDLE - PREV_IDLE))

    if [ "$DIFF_TOTAL" -gt 0 ]; then
        CPU_USAGE=$(awk "BEGIN {printf \"%.2f\", (1 - $DIFF_IDLE/$DIFF_TOTAL) * 100}")
    fi
fi

echo "$TOTAL $IDLE" > "$CPU_STATE_FILE"

# =========================================================
# Memory Usage
# =========================================================
MEM_TOTAL=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
MEM_AVAILABLE=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)

MEM_USED=$((MEM_TOTAL - MEM_AVAILABLE))

# =========================================================
# Disk Usage
# =========================================================
DISK_TOTAL=$(df -BM / | awk 'NR==2 {gsub("M","",$2); print $2}')
DISK_USED=$(df -BM / | awk 'NR==2 {gsub("M","",$3); print $3}')
DISK_AVAILABLE=$(df -BM / | awk 'NR==2 {gsub("M","",$4); print $4}')

# =========================================================
# Network Total Counters
# =========================================================
RX_BYTES=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes 2>/dev/null || echo 0)
TX_BYTES=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes 2>/dev/null || echo 0)

RX_TOTAL_MB=$(awk "BEGIN {printf \"%.2f\", $RX_BYTES/1024/1024}")
TX_TOTAL_MB=$(awk "BEGIN {printf \"%.2f\", $TX_BYTES/1024/1024}")

# =========================================================
# Network Speed Calculation
# =========================================================
RX_MBPS="0"
TX_MBPS="0"

CURRENT_TIME=$(date +%s)

if [ -f "$STATE_FILE" ]; then

    read OLD_RX OLD_TX OLD_TIME < "$STATE_FILE"

    TIME_DIFF=$((CURRENT_TIME - OLD_TIME))

    if [ "$TIME_DIFF" -gt 0 ]; then

        RX_DIFF=$((RX_BYTES - OLD_RX))
        TX_DIFF=$((TX_BYTES - OLD_TX))

        RX_MBPS=$(awk "BEGIN {printf \"%.2f\", ($RX_DIFF * 8) / $TIME_DIFF / 1024 / 1024}")
        TX_MBPS=$(awk "BEGIN {printf \"%.2f\", ($TX_DIFF * 8) / $TIME_DIFF / 1024 / 1024}")

    fi
fi

echo "$RX_BYTES $TX_BYTES $CURRENT_TIME" > "$STATE_FILE"

# =========================================================
# Load Average
# =========================================================
LOAD_AVG=$(awk '{print $1" "$2" "$3}' /proc/loadavg)

# =========================================================
# Uptime
# =========================================================
UPTIME_SECONDS=$(cut -d. -f1 /proc/uptime)

# =========================================================
# JSON Payload
# =========================================================
JSON_PAYLOAD=$(cat <<EOF
{
  "hostname": "$HOSTNAME",
  "timestamp": "$TIMESTAMP",

  "cpu": {
    "usage_percent": "$CPU_USAGE"
  },

  "memory": {
    "total_mb": "$MEM_TOTAL",
    "used_mb": "$MEM_USED",
    "available_mb": "$MEM_AVAILABLE"
  },

  "disk": {
    "total_mb": "$DISK_TOTAL",
    "used_mb": "$DISK_USED",
    "available_mb": "$DISK_AVAILABLE"
  },

  "network": {
    "interface": "$INTERFACE",

    "total": {
      "rx_mb": "$RX_TOTAL_MB",
      "tx_mb": "$TX_TOTAL_MB"
    },

    "rate": {
      "rx_mbps": "$RX_MBPS",
      "tx_mbps": "$TX_MBPS"
    }
  },

  "system": {
    "load_average": "$LOAD_AVG",
    "uptime_seconds": "$UPTIME_SECONDS"
  }
}
EOF
)

# =========================================================
# Send Data
# =========================================================
curl -s \
    -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    --data "$JSON_PAYLOAD" \
    >/dev/null 2>&1

# Optional debug
echo "$JSON_PAYLOAD"
