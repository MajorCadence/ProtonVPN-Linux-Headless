#!/usr/bin/env bash
set -euo pipefail
NS_NAME="protonvpn"
STATE_DIR="/run/${NS_NAME}"
PID_FILE="${STATE_DIR}/pf-daemon.pid"
PORT_FILE="${STATE_DIR}/forwarded_port"
ENV_FILE="${STATE_DIR}/forwarded_port.env"
HOOK_SCRIPT="/usr/local/lib/protonvpn/port-change-hook.sh"

# Replace with Proton's NAT-PMP gateway for your WG config if needed.
PF_GATEWAY=""

LIFETIME="60"
SLEEP_SECONDS="45"
parse_port() {
    sed -nE 's/.*Mapped public port ([0-9]+).*/\1/p' | tail -n 1
}
request_mapping() {
    local private_port="$1"
    local public_port="$2"
    local proto="$3"
    local output
    output="$(ip netns exec "$NS_NAME" natpmpc -a "$private_port" "$public_port" "$proto" "$LIFETIME" -g "$PF_GATEWAY" 2>&1)"
    printf '%s\n' "$output" >&2
    printf '%s\n' "$output" | parse_port
}
refresh_once() {
    local current_port
    local old_port
    local new_port
    mkdir -p "$STATE_DIR"
    old_port="$(cat "$PORT_FILE" 2>/dev/null || true)"
    current_port="$old_port"
    if ! [[ "$current_port" =~ ^[0-9]+$ ]] || [ "$current_port" -lt 1 ] || [ "$current_port" -gt 65535 ]; then
        current_port="$(request_mapping 1 0 tcp)"
    else
        if ! new_port="$(request_mapping "$current_port" "$current_port" tcp)"; then
            current_port="$(request_mapping 1 0 tcp)"
        else
            current_port="$new_port"
        fi
    fi
    if ! new_port="$(request_mapping "$current_port" "$current_port" udp)"; then
        :
    else
        current_port="$new_port"
    fi
    printf '%s\n' "$current_port" > "$PORT_FILE"
    printf 'FORWARDED_PORT=%s\n' "$current_port" > "$ENV_FILE"
    if [ "$current_port" != "$old_port" ] && [ -x "$HOOK_SCRIPT" ]; then
        "$HOOK_SCRIPT" "$current_port"
    fi
    printf '%s\n' "$current_port"
}
run_daemon() {
    mkdir -p "$STATE_DIR"
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "Port-forward daemon already running." >&2
        exit 1
    fi
    echo "$$" > "$PID_FILE"
    trap 'rm -f "$PID_FILE"; exit 0' INT TERM EXIT
    while true; do
        if ! refresh_once; then
            sleep 10
        else
            sleep "$SLEEP_SECONDS"
        fi
    done
}
case "${1:---once}" in
    --once)
        refresh_once
        ;;
    --daemon)
        run_daemon
        ;;
    --stop)
        if [ -f "$PID_FILE" ]; then
            kill "$(cat "$PID_FILE")" 2>/dev/null || true
            rm -f "$PID_FILE"
        fi
        ;;
    *)
        echo "Usage: $0 [--once|--daemon|--stop]" >&2
        exit 1
        ;;
esac
