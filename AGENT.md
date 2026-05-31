# WYN Agent — Installation & Reference

The WYN Agent is a small Python daemon that runs on every server you want to monitor. It captures network packets at the OS level and streams lightweight event reports to the central WYN Server.

---

## Requirements

| Requirement | Notes |
|------------|-------|
| Linux (any modern distro) | Debian/Ubuntu, RHEL/Rocky, Arch all supported |
| Python 3.10+ | `python3 --version` |
| Root or `CAP_NET_RAW` capability | Required for raw packet capture |
| Scapy 2.5+ | `pip install scapy` |
| websockets 12+ | `pip install websockets` |
| Network access to WYN Server port | Default: 8765/TCP |

---

## Installation

### Option A — Manual

```bash
git clone https://github.com/studio-justin-braun/WatchYourNetwork.git
cd WatchYourNetwork
sudo bash install-agent.sh
```

### Option B — Installer Script (Recommended)

```bash
sudo bash install-agent.sh
```

The installer handles OS detection, pip, interface selection, config creation, and systemd service setup automatically.

### Option C — Manual systemd Service

After editing `/etc/wyn/agent.conf`:

```bash
sudo cp wyn-agent.service /etc/systemd/system/wyn-agent.service
sudo systemctl daemon-reload
sudo systemctl enable wyn-agent
sudo systemctl start wyn-agent
sudo systemctl status wyn-agent
```

Example unit file (`wyn-agent.service`):

```ini
[Unit]
Description=WatchYourNetwork Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/wyn-agent/agent.py --config /etc/wyn-agent/wyn-agent.conf
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
```

### Option C — Minimal One-liner Config (for quick tests)

```bash
sudo python agent.py \
  --server 192.168.1.100 \
  --node-id my-server \
  --iface eth0
```

CLI flags override the config file when both are present.

---

## Configuration Reference (`wyn-agent.conf`)

```yaml
# ─────────────────────────────────────────
# WYN Agent Configuration
# ─────────────────────────────────────────

server:
  host: "192.168.1.100"    # [REQUIRED] IP or hostname of the WYN Server
  port: 8765               # WYN Server agent listener port
  reconnect_interval_s: 10 # Seconds to wait before reconnect on disconnect

node:
  id: "web-01"             # [REQUIRED] Unique identifier for this node
                           # Must be unique across all agents reporting to the same server
  name: "Web Server 01"    # Human-readable display name shown in the UI
  color: null              # null = let the server auto-assign a color
                           # or specify hex: "#4A90D9"

capture:
  interfaces:              # [REQUIRED] List of interfaces to sniff on
    - eth0
    # - ens3
    # - bond0

  bpf_filter: ""           # Optional BPF filter (passed directly to Scapy/libpcap)
                           # Example: "not port 22" to exclude SSH
                           # Example: "port 80 or port 443" for HTTP/S only
                           # Leave empty to capture all traffic

  ignore_loopback: true    # Skip packets on 127.0.0.1 / ::1 (recommended)
  ignore_multicast: true   # Skip multicast/broadcast packets
  ignore_arp: true         # Skip ARP packets

  track_processes: false   # Attempt to resolve which process owns each connection
                           # Uses /proc/net/tcp and /proc/net/udp
                           # Requires root. Adds slight CPU overhead.

report:
  batch_interval_ms: 50    # Collect packets for this many ms, then send as a batch
                           # Lower = smoother animation, higher = less overhead
                           # Recommended range: 20–200

  heartbeat_interval_s: 5  # How often to send a keep-alive ping to the server
                           # Server marks node offline if no ping received for 3× this value

  max_batch_size: 500      # Maximum events per batch (prevents burst flooding)
```

---

## Event Protocol

The agent sends JSON messages over WebSocket to the WYN Server.

### Handshake (on connect)

```json
{
  "type": "hello",
  "node_id": "web-01",
  "node_name": "Web Server 01",
  "color": null,
  "agent_version": "0.1.0",
  "interfaces": ["eth0"],
  "ip_addresses": ["192.168.1.10", "10.0.0.5"]
}
```

### Packet Batch

```json
{
  "type": "packets",
  "node_id": "web-01",
  "ts": 1748649600.123,
  "events": [
    {
      "src_ip": "192.168.1.10",
      "dst_ip": "8.8.8.8",
      "src_port": 52341,
      "dst_port": 443,
      "proto": "TCP",
      "bytes": 1452,
      "process": "nginx"
    },
    {
      "src_ip": "203.0.113.5",
      "dst_ip": "192.168.1.10",
      "src_port": 443,
      "dst_port": 52341,
      "proto": "TCP",
      "bytes": 890,
      "process": "nginx"
    }
  ]
}
```

### Heartbeat

```json
{
  "type": "heartbeat",
  "node_id": "web-01",
  "ts": 1748649605.000
}
```

### Goodbye (on clean shutdown)

```json
{
  "type": "bye",
  "node_id": "web-01"
}
```

---

## Process Tracking

When `track_processes: true`, the agent reads `/proc/net/tcp`, `/proc/net/tcp6`, `/proc/net/udp`, `/proc/net/udp6` to map socket inode → PID → process name. This mapping is cached and refreshed every 500 ms.

**Limitations:**
- Works only for connections the node itself originated (not forwarded/routed traffic)
- Short-lived connections may not be resolved
- Requires root access (to read `/proc/<pid>/fd/`)

---

## BPF Filter Examples

```
# Only HTTP and HTTPS
port 80 or port 443

# Exclude SSH and DNS
not port 22 and not port 53

# Only traffic to/from a specific subnet
net 10.0.0.0/8

# Only TCP traffic
tcp

# Everything except loopback (alternative to ignore_loopback option)
not host 127.0.0.1
```

---

## Minimal Footprint

The agent is designed to be lightweight:

- Captures only packet headers (not payload data)
- Batches reports instead of one-per-packet WebSocket messages
- Uses async I/O — one thread for capture, one for sending

Typical resource usage on a 1 Gbps link with 10k pps:
- CPU: ~3–8% of one core
- RAM: ~30–60 MB
- Network overhead to WYN Server: ~50–200 KB/s

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `Permission denied` on start | Run as root or grant `CAP_NET_RAW` |
| Agent connects but no packets appear | Check `bpf_filter`, check interface name |
| High CPU usage | Increase `batch_interval_ms`, add BPF filter to reduce capture scope |
| Agent keeps reconnecting | Check firewall — is port 8765 open on the WYN Server? |
| Process names not resolved | Enable `track_processes: true` and confirm running as root |
| Interface not found | List interfaces with `ip link show` |

---

## Security Hardening

1. **Firewall**: Restrict port 8765 to known agent IPs only.
2. **TLS** (planned v0.3): Wrap the WebSocket connection in TLS with client certificates.
3. **Minimal capture**: Use `bpf_filter` and `ignore_*` options to minimize sensitive traffic exposure.
4. **No payload capture**: The agent hardcodes `snap_length: 96` — application payload is never read or transmitted.
5. **Dedicated user with capabilities** (instead of full root):
   ```bash
   sudo setcap cap_net_raw,cap_net_admin=eip /usr/bin/python3.10
   ```
   Then run the agent as a non-root user (with care — this grants python-wide raw socket access).
