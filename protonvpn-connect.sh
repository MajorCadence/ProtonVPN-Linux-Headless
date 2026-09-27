#!/usr/bin/env bash
set -euo pipefail
NS_NAME="protonvpn"
WG_IF="wg-proton"
STATE_DIR="/run/${NS_NAME}"
PID_FILE="${STATE_DIR}/pf-daemon.pid"
RESOLV_DIR="/etc/netns/${NS_NAME}"
PF_DAEMON="/usr/local/sbin/protonvpn-port-forward.sh"


# Replace these with values from your Proton WireGuard config.
PRIVATE_KEY=""
PRESHARED_KEY=""
WG_ADDR4=""
WG_ADDR6="" # optional
DNS4="" # optional if you want DNS over the VPN
DNS6="" # optional
SERVER_PUBLIC_KEY=""
SERVER_ENDPOINT_IP=""
SERVER_ENDPOINT_PORT=""
MTU=""
KEEPALIVE=""
ALLOWED_IPS=""

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Run as root." >&2
        exit 1
    fi
}
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing required command: $1" >&2
        exit 1
    }
}
cleanup_on_error() {
    set +e
    if [ -f "$PID_FILE" ]; then
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
        rm -f "$PID_FILE"
    fi
    ip netns del "$NS_NAME" 2>/dev/null || true
    rm -f "${RESOLV_DIR}/resolv.conf"
    rmdir "$RESOLV_DIR" 2>/dev/null || true
    rmdir "$STATE_DIR" 2>/dev/null || true
}
require_root
require_cmd ip
require_cmd wg
require_cmd nft
if [ -e "/run/netns/${NS_NAME}" ]; then
    echo "Namespace ${NS_NAME} already exists. Disconnect first." >&2
    exit 1
fi
trap cleanup_on_error ERR
mkdir -p "$STATE_DIR" "$RESOLV_DIR"
{
    [ -n "$DNS4" ] && printf 'nameserver %s\n' "$DNS4"
    [ -n "$DNS6" ] && printf 'nameserver %s\n' "$DNS6"
} > "${RESOLV_DIR}/resolv.conf"
ip netns add "$NS_NAME"
ip -n "$NS_NAME" link set lo up
# Create WG in the main namespace first so the encrypted UDP socket stays there.
ip link add "$WG_IF" type wireguard
wg set "$WG_IF" \
    private-key <(printf '%s\n' "$PRIVATE_KEY") \
    peer "$SERVER_PUBLIC_KEY" \
    endpoint "${SERVER_ENDPOINT_IP}:${SERVER_ENDPOINT_PORT}" \
    allowed-ips "$ALLOWED_IPS" \
    persistent-keepalive "$KEEPALIVE"
if [ -n "$PRESHARED_KEY" ]; then
    wg set "$WG_IF" \
        peer "$SERVER_PUBLIC_KEY" \
        preshared-key <(printf '%s\n' "$PRESHARED_KEY")
fi
ip link set "$WG_IF" netns "$NS_NAME"
ip -n "$NS_NAME" addr add "$WG_ADDR4" dev "$WG_IF"
if [ -n "$WG_ADDR6" ]; then
    ip -n "$NS_NAME" addr add "$WG_ADDR6" dev "$WG_IF"
fi
ip -n "$NS_NAME" link set dev "$WG_IF" mtu "$MTU" up
ip -n "$NS_NAME" route replace default dev "$WG_IF"
if [ -n "$WG_ADDR6" ]; then
    ip -n "$NS_NAME" -6 route replace default dev "$WG_IF"
fi
ip netns exec "$NS_NAME" nft delete table inet protonvpn >/dev/null 2>&1 || true
ip netns exec "$NS_NAME" nft -f - <<EOF
table inet protonvpn {
    chain input {
        type filter hook input priority 0; policy drop;
        ct state established,related accept
        iifname "lo" accept
        iifname "${WG_IF}" accept
    }
    chain output {
        type filter hook output priority 0; policy drop;
        ct state established,related accept
        oifname "lo" accept
        oifname "${WG_IF}" accept
    }
    chain forward {
        type filter hook forward priority 0; policy drop;
    }
}
EOF
if command -v natpmpc >/dev/null 2>&1 && [ -x "$PF_DAEMON" ]; then
    nohup "$PF_DAEMON" --daemon >/dev/null 2>&1 &
fi
trap - ERR
echo "Connected."
echo "Run VPN-only apps with:"
echo "  ip netns exec ${NS_NAME} <command>"
