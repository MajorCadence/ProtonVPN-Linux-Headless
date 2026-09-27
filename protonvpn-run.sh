#!/usr/bin/env bash
set -euo pipefail
NS_NAME="protonvpn"
if [ $# -eq 0 ]; then
    echo "Usage: $0 <command> [args...]" >&2
    exit 1
fi
exec ip netns exec "$NS_NAME" "$@"
