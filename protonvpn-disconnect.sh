#!/usr/bin/env bash
set -euo pipefail
NS_NAME="protonvpn"
STATE_DIR="/run/${NS_NAME}"
PID_FILE="${STATE_DIR}/pf-daemon.pid"
RESOLV_DIR="/etc/netns/${NS_NAME}"
if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root." >&2
    exit 1
fi
if [ -f "$PID_FILE" ]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f "$PID_FILE"
fi
if [ -e "/run/netns/${NS_NAME}" ]; then
    ip netns del "$NS_NAME"
fi
rm -f "${STATE_DIR}/forwarded_port" "${STATE_DIR}/forwarded_port.env"
rmdir "$STATE_DIR" 2>/dev/null || true
rm -f "${RESOLV_DIR}/resolv.conf"
rmdir "$RESOLV_DIR" 2>/dev/null || true
echo "Disconnected."
