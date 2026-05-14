#!/usr/bin/env bash

# =========================================================
# MetroVPS Lightweight System Usage Agent
#
# Features:
# - Extremely lightweight
# - No sleep
# - No top/free/vmstat
# - Uses /proc and /sys only
# - Works on almost all Linux distributions
# - Sends usage metrics every minute
#
# Usage:
#   ./system-usage.sh YOUR_SERVER_TOKEN
#
# Recommended Cron:
#   * * * * * /opt/metrovps/system-usage.sh TOKEN >/dev/null 2>&1
# =========================================================

set +e
export LC_ALL=C

# ---------------------------------------------------------
# CONFIG
# ---------------------------------------------------------

TOKEN="$1"

if [ -z "$TOKEN" ]; then
    echo "Usage: $0 <SERVER_TOKEN>"
    exit 1
fi

API_URL="https://invenetory-agent.metrovps.com/api/system/usage/collect"

API_ENDPOINT="${API_URL}?token=${TOKEN}"

STATE_DIR="/tmp/metrovps-monitor"

NET_STATE_FILE="${STATE_DIR}/net_state"
CPU_STATE_FILE="${STATE_DIR}/cpu_state"

mkdir -p "$STATE_DIR"

# ---------------------------------------------------------
# BASIC INFO
# ---------------------------------------------------------

HOSTNAME=$(hostname 2>/dev/null || echo "")

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ---------------------------------------------------------
# DETECT MAIN INTERFACE
# ---------------------------------------------------------

get_physical_interface() {

    for IFACE in $(ls /sys/class/net); do

        # Skip loopback
        [ "$IFACE" = "lo" ] && continue

        # Must be UP
        STATE=$(cat /sys/class/net/$IFACE/operstate 2>/dev/null)

        [ "$STATE" != "up" ] && continue

        # Skip virtual interfaces
        if [ ! -d "/sys/class/net/$IFACE/device" ]; then
            continue
        fi

        # Skip bridges/bonds/docker/veth/tun/tap
        case "$IFACE" in
            docker*|veth*|br*|virbr*|vmbr*|bond*|tun*|tap*)
                continue
            ;;
        esac

        echo "$IFACE"
        return
    done
}

INTERFACE=$(get_physical_interface)

# Fallback
if [ -z "$INTERFACE" ]; then
    INTERFACE=$(ip route 2>/dev/null | awk '/default/ {print $5}' | head -n1)
fi

# ---------------------------------------------------------
# CPU USAGE
# ---------------------------------------------------------

CPU_USAGE="0"

read cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat

TOTAL=$((user + nice + system + idle + iowait + irq + softirq + steal))

IDLE=$((idle + iowait))

if [ -f "$CPU_STATE_FILE" ]; then

    read PREV_TOTAL PREV_IDLE < "$CPU_STATE_FILE"

    DIFF_TOTAL=$((TOTAL - PREV_TOTAL))
    DIFF_IDLE=$((IDLE - PREV_IDLE))

    if [ "$DIFF_TOTAL" -gt 0 ]; then

        CPU_USAGE=$(awk "BEGIN {printf \"%.2f\", (1 - $DIFF_IDLE/$DIFF_TOTAL) * 100}")

    fi
fi

echo "$TOTAL $IDLE" > "$CPU_STATE_FILE"

# ---------------------------------------------------------
# MEMORY
# ---------------------------------------------------------

MEM_TOTAL=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)

MEM_AVAILABLE=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)

MEM_USED=$((MEM_TOTAL - MEM_AVAILABLE))

# ---------------------------------------------------------
# DISK
# ---------------------------------------------------------

DISK_TOTAL=$(df -BM / | awk 'NR==2 {gsub("M","",$2); print $2}')

DISK_USED=$(df -BM / | awk 'NR==2 {gsub("M","",$3); print $3}')

DISK_AVAILABLE=$(df -BM / | awk 'NR==2 {gsub("M","",$4); print $4}')

# ---------------------------------------------------------
# NETWORK TOTAL
# ---------------------------------------------------------

RX_BYTES=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes 2>/dev/null || echo 0)

TX_BYTES=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes 2>/dev/null || echo 0)

RX_TOTAL_MB=$(awk "BEGIN {printf \"%.2f\", $RX_BYTES/1024/1024}")

TX_TOTAL_MB=$(awk "BEGIN {printf \"%.2f\", $TX_BYTES/1024/1024}")


# ---------------------------------------------------------
# NETWORK SPEED
# ---------------------------------------------------------

RX_MBPS="0"
TX_MBPS="0"

CURRENT_TIME=$(date +%s)

if [ -f "$NET_STATE_FILE" ]; then

    read OLD_RX OLD_TX OLD_TIME < "$NET_STATE_FILE"

    TIME_DIFF=$((CURRENT_TIME - OLD_TIME))

    if [ "$TIME_DIFF" -gt 0 ]; then

        RX_DIFF=$((RX_BYTES - OLD_RX))
        TX_DIFF=$((TX_BYTES - OLD_TX))

        RX_MBPS=$(awk "BEGIN {printf \"%.2f\", ($RX_DIFF * 8) / $TIME_DIFF / 1024 / 1024}")

        TX_MBPS=$(awk "BEGIN {printf \"%.2f\", ($TX_DIFF * 8) / $TIME_DIFF / 1024 / 1024}")
    fi
fi

echo "$RX_BYTES $TX_BYTES $CURRENT_TIME" > "$NET_STATE_FILE"

# ---------------------------------------------------------
# LOAD
# ---------------------------------------------------------

LOAD_AVG=$(awk '{print $1" "$2" "$3}' /proc/loadavg)

# ---------------------------------------------------------
# UPTIME
# ---------------------------------------------------------

UPTIME_SECONDS=$(cut -d. -f1 /proc/uptime)

# ---------------------------------------------------------
# BUILD JSON
# ---------------------------------------------------------

JSON_PAYLOAD=$(cat <<EOF
{
  "timestamp": "$TIMESTAMP",

  "system": {
    "hostname": "$HOSTNAME",
    "uptime_seconds": "$UPTIME_SECONDS",
    "load_average": "$LOAD_AVG"
  },

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
  }
}
EOF
)

# ---------------------------------------------------------
# SEND DATA
# ---------------------------------------------------------

if command -v curl >/dev/null 2>&1; then

    curl -s \
        -X POST "$API_ENDPOINT" \
        -H "Content-Type: application/json" \
        --data "$JSON_PAYLOAD" \
        >/dev/null 2>&1

elif command -v wget >/dev/null 2>&1; then

    TMP_FILE="/tmp/metrovps_usage_$$.json"

    echo "$JSON_PAYLOAD" > "$TMP_FILE"

    wget -q \
        --header="Content-Type: application/json" \
        --post-file="$TMP_FILE" \
        -O /dev/null \
        "$API_ENDPOINT"

    rm -f "$TMP_FILE"
fi
