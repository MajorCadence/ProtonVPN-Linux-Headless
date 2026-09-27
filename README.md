# Proton VPN — Headless Linux

A small set of root-run shell scripts that connect to Proton VPN over WireGuard
without the official app. The tunnel lives in its own network namespace, an
nftables kill switch keeps anything inside it from leaking, and an optional
NAT-PMP daemon maintains Proton's port-forwarding mapping. Built for servers,
homelab boxes, and other headless machines.

## How it works

1. **Isolation** — a network namespace named `protonvpn` is created with its own
   default route, DNS (`/etc/netns/protonvpn/resolv.conf`), and firewall.
2. **Tunnel** — the WireGuard interface `wg-proton` is created in the *root*
   namespace first (so the encrypted UDP socket keeps the host's normal routing
   and can reach the Proton server), configured, then moved into the
   `protonvpn` namespace where the VPN address, routes, and MTU are applied.
3. **Kill switch** — inside the namespace an `inet protonvpn` nftables table
   sets `policy drop` on input/output/forward, accepting only loopback and
   `wg-proton`. The namespace's only path to the network is the tunnel, so if
   WireGuard goes down nothing can leak — connections just fail.
4. **Port forwarding (optional)** — if `natpmpc` is installed, `connect`
   launches a daemon that keeps a NAT-PMP mapping alive through the tunnel
   (60 s lifetime, refreshed every 45 s), records the public port, and runs an
   optional hook script whenever the port changes.

Anything you launch with `ip netns exec protonvpn …` (wrapped by
`protonvpn-run.sh`) gets the VPN and nothing else; the rest of the host is
untouched.

## Requirements

- Linux with in-kernel WireGuard (5.6+) and `bash`
- `iproute2` (`ip`), `wireguard-tools` (`wg`), `nftables` (`nft`)
- `natpmpc` — only for port forwarding (Debian/Ubuntu: `natpmp-client`;
  Fedora/Arch: `libnatpmp`)
- Root
- A Proton VPN account and a generated **WireGuard config** (account.proton.me
  → VPN → third-party app setup). Port forwarding and custom DNS require a paid
  plan that includes them.

> Unofficial project — not affiliated with Proton. Check Proton's terms of
> service before using generated configs with custom clients.

## Scripts

| File | Purpose |
|---|---|
| `protonvpn-connect.sh` | Fill in your WireGuard config values, then connect: creates the namespace, tunnel, DNS, and kill switch, and starts the port-forward daemon if available |
| `protonvpn-disconnect.sh` | Tears everything down (daemon, namespace, state, per-namespace resolv.conf) |
| `protonvpn-reconnect.sh` | Disconnect, wait 1 s, connect |
| `protonvpn-run.sh` | Runs a command inside the VPN namespace: `protonvpn-run.sh <command> [args…]` |
| `protonvpn-port-forward.sh` | NAT-PMP client: `--once` (refresh one mapping and print the port), `--daemon` (keep refreshing), `--stop` |

## Install

The scripts reference fixed paths (`/usr/local/sbin/…`), so install all five
there. They hold your private key — keep them root-only:

```sh
sudo install -m 700 protonvpn-*.sh /usr/local/sbin/
```

Configure the port-change hook directory only if you want the hook (see below).

## Configure

Edit `/usr/local/sbin/protonvpn-connect.sh` and copy values from your Proton
WireGuard config (`.conf` / `[Interface]` + `[Peer]` sections):

| Variable | Source in your config | Required |
|---|---|---|
| `PRIVATE_KEY` | `PrivateKey` | yes |
| `PRESHARED_KEY` | `PresharedKey` | recommended (Proton configs include one) |
| `WG_ADDR4` | first entry of `Address` | yes |
| `WG_ADDR6` | second entry of `Address` | optional (enables IPv6 inside the namespace) |
| `DNS4` / `DNS6` | `DNS` | optional, see DNS note below |
| `SERVER_PUBLIC_KEY` | peer `PublicKey` | yes |
| `SERVER_ENDPOINT_IP` / `SERVER_ENDPOINT_PORT` | peer `Endpoint` | yes |
| `MTU` | `MTU` | yes |
| `KEEPALIVE` | `PersistentKeepalive` | yes |
| `ALLOWED_IPS` | `AllowedIPs` | yes — quote the whole list, e.g. `"0.0.0.0/0 ::/0"` |

Then edit `/usr/local/sbin/protonvpn-port-forward.sh` and set `PF_GATEWAY` to
the gateway address Proton uses for port forwarding for that server (from your
config/connection notes). Leave it empty and the daemon will simply fail to get
a mapping.

**DNS note:** if both `DNS4` and `DNS6` are left empty, the namespace ends up
with an empty `resolv.conf` and apps inside it will not resolve names. Set
`DNS4` to the resolver from your Proton config so DNS travels over the tunnel.

## Usage

```sh
# Connect / disconnect / reconnect
sudo /usr/local/sbin/protonvpn-connect.sh
sudo /usr/local/sbin/protonvpn-disconnect.sh
sudo /usr/local/sbin/protonvpn-reconnect.sh

# Run something through the VPN only
sudo /usr/local/sbin/protonvpn-run.sh curl -fsS https://ipinfo.io/ip

# Drop to a VPN-only shell (as a non-root user)
sudo ip netns exec protonvpn runuser -u youruser -- bash
```

Verify:

```sh
sudo ip netns exec protonvpn wg show          # handshake + transfer
sudo ip netns exec protonvpn ip route         # default via wg-proton
sudo ip netns exec protonvpn curl -fsS https://ipinfo.io/ip   # VPN exit IP
curl -fsS https://ipinfo.io/ip                # host still on its own IP
```

### Port forwarding

On connect, if `natpmpc` is available the daemon starts automatically. The
current mapped port is written to:

- `/run/protonvpn/forwarded_port` — just the port number
- `/run/protonvpn/forwarded_port.env` — `FORWARDED_PORT=<port>` for sourcing

```sh
sudo cat /run/protonvpn/forwarded_port
```

The daemon maps TCP and UDP to the same port where the gateway supports it,
and falls back to a fresh random port if a refresh fails. Control it manually
with:

```sh
sudo /usr/local/sbin/protonvpn-port-forward.sh --once     # refresh + print port
sudo /usr/local/sbin/protonvpn-port-forward.sh --daemon   # start background loop
sudo /usr/local/sbin/protonvpn-port-forward.sh --stop
```

To react to port changes (e.g. reconfigure a download client), create an
executable hook that receives the new port as `$1`:

```sh
#!/usr/bin/env bash
# /usr/local/lib/protonvpn/port-change-hook.sh
port="$1"
# e.g. write the port into an app's config and restart it
```

### Start at boot (systemd)

```ini
# /etc/systemd/system/protonvpn.service
[Unit]
Description=Proton VPN (headless namespace)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/protonvpn-connect.sh
ExecStop=/usr/local/sbin/protonvpn-disconnect.sh

[Install]
WantedBy=multi-user.target
```

`sudo systemctl enable --now protonvpn`

## Troubleshooting

- **"Namespace protonvpn already exists"** — run
  `protonvpn-disconnect.sh`, or `protonvpn-reconnect.sh`.
- **"Missing required command: …"** — install `iproute2`, `wireguard-tools`,
  or `nftables` as reported.
- **Port-forward daemon never starts** — `natpmpc` must be on `PATH` and
  `/usr/local/sbin/protonvpn-port-forward.sh` must be executable when
  `connect` runs. A wrong/empty `PF_GATEWAY` yields mapping errors.
- **Nothing resolves inside the namespace** — set `DNS4` (see DNS note).
- **Recovery after a hard kill/crash** — state lives under `/run` (tmpfs), so
  a reboot clears it. Manually:
  `sudo ip netns del protonvpn && sudo rm -rf /run/protonvpn /etc/netns/protonvpn`.

## Notes & caveats

- The private key is stored in the script in plaintext; keep the mode at `700`
  and owned by root. Keys are handed to `wg set` via process substitution, so
  they never appear in command-line arguments.
- The kill switch protects processes **inside the namespace only**. Anything
  you run on the host stays on the host network by design.
- On reboot the namespace, routes, and firewall are gone (all state is in
  `/run` and kernel memory); reconnect via the systemd unit or manually.
- IPv6 is opt-in: leave `WG_ADDR6` empty and the namespace has no IPv6 route
  (v6 connections inside it simply fail).
