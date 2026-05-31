# WatchYourNetwork (WYN)

**Real-time network traffic visualization for Linux server infrastructures.**

WatchYourNetwork lets you see — in a live animated browser interface — which servers are talking to each other and what flows to the internet, all at the packet level. Lightweight agents run on each monitored host and report to a central WYN Server, which drives an interactive graph visualization.

---

## Features

- **Animated graph** — colored node circles connected by dashed lines; packets animate as colored dots in real time
- **Force-directed (Net) layout** or **sorted Line layout** — switch with one click
- **Inside Net mode** — instead of one Internet node, individual external IPs appear as temporary nodes (60 s TTL) inside an Internet Zone box
- **Application tracking** — when enabled, packets are labeled with the process name (nginx, flask, sshd …); connection lines show the app name; a filter panel lets you hide/show per application
- **Inbound / Outbound colors** — distinct dot colors for traffic direction (Internet→Node vs. Node→Internet vs. Node↔Node)
- **Settings panel** — node color pickers, packet dot color pickers, layout toggle, Inside Net toggle; all saved in localStorage
- **BPF filter presets** — reduce internet noise with one command (`change-conf.sh`)
- **`wyn` CLI** — `wyn status`, `wyn restart`, `wyn logs`, `wyn update`, `wyn uninstall` and more
- **Automated installers** — OS-aware scripts for Debian/Ubuntu, RHEL/Rocky, Arch, Alpine, SUSE

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                    WYN Server                         │
│                                                       │
│  Agent WebSocket  ──▶  TopologyManager  ──▶  Web WS  │
│  :8765                                       :8080    │
│                                                       │
│                      FastAPI HTTP :8080               │
│                      (serves index.html + REST API)   │
└──────────────────────────────────────────────────────┘
        ▲                                    │
        │  WebSocket (packet batches)        │  WebSocket + REST
        │                                    ▼
┌──────────────────┐                ┌──────────────────┐
│  WYN Agent       │                │  Browser         │
│  (each server)   │                │  Canvas UI       │
└──────────────────┘                └──────────────────┘
```

| Port | Purpose |
|------|---------|
| **8080** | Web UI (HTML), REST API, browser WebSocket `/ws/ui` |
| **8765** | Agent WebSocket (agents connect here) |

---

## Installation

### WYN Server

```bash
git clone https://github.com/studio-justin-braun/WatchYourNetwork.git
cd WatchYourNetwork
sudo bash install-server.sh
```

The installer:
- Detects your OS and installs Python 3.10+ and pip if needed
- Asks for HTTP port (default 8080) and Agent port (default 8765)
- Installs server files to `/opt/wyn-server/`
- Writes config to `/etc/wyn/server.yaml`
- Optionally creates and starts a **systemd service**
- Installs the **`wyn` CLI** to `/usr/local/bin/wyn`

### WYN Agent (on each monitored host)

```bash
sudo bash install-agent.sh
```

The installer:
- Lists available network interfaces with IPs — pick one or more
- Asks for WYN Server IP, node ID, node display name
- Writes config to `/etc/wyn/agent.conf`
- Installs to `/opt/wyn-agent/`
- Optionally creates and starts a **systemd service**

---

## `wyn` CLI Reference

```bash
# Service control
wyn status                  # Show server + agent status and web UI URL
wyn start  [server|agent|all]
wyn stop   [server|agent|all]
wyn restart [server|agent|all]
wyn logs   [server|agent] [-n 100]

# Maintenance
wyn update                  # Download + install latest version from GitHub
wyn uninstall [server|agent|all]
wyn version                 # Show installed versions

# Config & access
wyn config                  # Interactive agent config editor (change-conf.sh)
wyn open                    # Print + open web UI URL
```

---

## Agent Config (`/etc/wyn/agent.conf`)

Edit interactively with `sudo wyn config` or `sudo bash /opt/wyn-agent/change-conf.sh`.

```yaml
server:
  host: "192.168.1.100"     # WYN Server IP
  port: 8765
  reconnect_interval_s: 10

node:
  id: "web-01"              # unique node identifier
  name: "Web Server 01"     # display name in the graph

capture:
  interfaces:
    - eth0
    - ens6
  bpf_filter: ""            # BPF expression (see presets in change-conf.sh)
  track_processes: false    # set true to show nginx/flask/sshd labels in UI
  ignore_loopback: true

report:
  batch_interval_ms: 50     # lower = smoother animation
  heartbeat_interval_s: 5
  max_batch_size: 500
```

### BPF Filter Presets (`wyn config` → option 4)

| Preset | Expression |
|--------|-----------|
| Web only | `port 80 or port 443` |
| Web + SSH | `port 22 or port 80 or port 443` |
| No WireGuard | `not port 51820` |
| No WG + DNS | `not port 51820 and not port 53` |
| Services | `port 22 or port 80 or port 443 or port 3306 or port 5432 or port 6379` |
| Custom | any valid BPF expression |

---

## Server Config (`/etc/wyn/server.yaml`)

```yaml
server:
  http_port: 8080           # Web UI + browser WebSocket
  agent_port: 8765          # Agent WebSocket

topology:
  connection_ttl: 1800      # seconds before idle connection fades
  node_colors: {}           # override auto-assigned colors: {node-id: "#hexcolor"}
  inside_net: false         # enable individual external IP tracking (toggle in UI)

internet_node:
  label: "Internet"
  color: "#95A5A6"

logging:
  level: INFO
```

---

## UI Features

### Settings Panel (⚙ top-right)
- **Traffic dot colors** — set separate colors for Inbound, Outbound, Internal, and Unknown traffic
- **Node colors** — color picker for every connected node (saved to browser localStorage, also synced to server)

### Layout Modes (toolbar, top-center)
| Mode | Description |
|------|-------------|
| **Net** | Force-directed graph — nodes repel each other and settle naturally |
| **Line** | Nodes sorted alphabetically in a left column, connections as arcs |

### Inside Net Mode
When enabled (toolbar button or settings panel), instead of routing all unknown IPs to a single Internet node, individual external IPs appear as temporary nodes inside a dashed **Internet Zone** box. Each IP disappears after **60 seconds** of inactivity.

### Application Filter Panel
When `track_processes: true` is set in the agent config, a filter panel appears bottom-right in the browser with a checkbox per detected application. Unchecking an app hides its connection lines and packet dots.

---

## Visualization Reference

| Event | Visual |
|-------|--------|
| Node comes online | Colored circle with glow |
| Node goes offline | Circle dims, × overlay |
| Packet A → Internet | Outbound-colored dot (default: red) |
| Packet Internet → A | Inbound-colored dot (default: teal) |
| Packet A → B | Internal-colored dot (default: blue) |
| App tracked (nginx …) | Process-colored dot + label on connection line |
| New connection | Dashed line drawn |
| Connection idle 30 min | Line fades out |
| External IP (Inside Net) | IP node in Internet Zone, disappears after 60 s |

---

## Security Notes

- WYN Agent requires **root / CAP_NET_RAW** for raw packet capture.
- Only packet headers are transmitted — no payload data ever leaves the agent.
- Agent↔Server communication is plain WebSocket. For production, place the server behind a TLS reverse proxy (nginx, Caddy).
- Restrict agent port 8765 to your internal network via firewall.

---

## Repository

```
WatchYourNetwork/
├── install-server.sh       # Server installer (all distros)
├── install-agent.sh        # Agent installer (all distros)
├── wyn-ctl/
│   └── wyn                 # CLI control command → /usr/local/bin/wyn
├── wyn-server/
│   ├── server.py           # FastAPI + websockets server
│   ├── requirements.txt
│   ├── config.example.yaml
│   └── wyn-server.service  # systemd unit template
├── wyn-agent/
│   ├── agent.py            # Scapy packet capture agent
│   ├── requirements.txt
│   ├── change-conf.sh      # Interactive config editor
│   ├── wyn-agent.example.conf
│   └── wyn-agent.service
└── wyn-ui/
    └── index.html          # Self-contained UI (no external dependencies)
```

---

## License

MIT — see [LICENSE](LICENSE).
