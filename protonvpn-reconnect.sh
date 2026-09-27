#!/usr/bin/env bash
set -euo pipefail
/usr/local/sbin/protonvpn-disconnect.sh || true
sleep 1
exec /usr/local/sbin/protonvpn-connect.sh
