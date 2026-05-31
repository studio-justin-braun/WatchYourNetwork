# WatchYourNetwork (WYN)

**Real-time network traffic visualization for Linux server infrastructures.**

WatchYourNetwork lets you see — in a live animated web interface — which servers are talking to each other and what flows to the internet, all at the packet level. A lightweight agent runs on each monitored host and reports to a central WYN Server, which drives a browser-based graph visualization.

---

## How it looks

```
  [ web-01 ] ──────────────── [ db-01 ]
      │  yellow dots →                │
      │                               │
  [ app-01 ]            [ ● Internet ]
      │                     ↑
      └─────────────────────┘
```

Each node is a colored circle. Packets appear as small bright-yellow dots that fly along the connection line from source to destination in real time. Connections to unknown IPs automatically route to the **Internet** node.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     WYN Server                          │
│  ┌─────────────┐   ┌───────────────┐   ┌────────────┐  │
│  │ Agent WS    │   │ Node Registry │   │ Web WS     │  │
│  │ Listener    │──▶│ + Topology    │──▶│ Broadcaster│  │
│  │ :8765       │   │ Manager       │   │ :8766      │  │
│  └─────────────┘   └───────────────┘   └────────────┘  │
│                                              │           │
│                                      Static Web UI :80   │
└──────────────────────────────────────────────────────────┘
         ▲                                    │
         │ WebSocket (agent events)           │ WebSocket (topology+packets)
         │                                    ▼
┌──────────────────┐                  ┌──────────────────┐
│  WYN Agent       │                  │  Browser         │
│  (each server)   │                  │  Animated Graph  │
└──────────────────┘                  └──────────────────┘
```

### Components

| Component | Location | Role |
|-----------|----------|------|
| `wyn-server/` | Central server | Receives agent data, manages topology, serves UI |
| `wyn-agent/` | Each monitored host | Captures packets, streams events to server |
| `wyn-ui/` | Served by WYN Server | Animated browser visualization |

---

## Technology Stack

| Layer | Technology |
|-------|-----------|
| Agent | Python 3.10+, Scapy (packet capture), websockets |
| Server | Python 3.10+, FastAPI, WebSockets, asyncio |
| Frontend | HTML5 Canvas, Vanilla JS (no framework dependency) |
| Protocol | JSON over WebSocket |

---

## Quick Start

### 1 — Install the WYN Server

```bash
git clone https://github.com/yourusername/WatchYourNetwork.git
cd WatchYourNetwork/wyn-server
pip install -r requirements.txt
cp config.example.yaml config.yaml
# edit config.yaml if needed
python server.py
```

The web UI is available at `http://<server-ip>:80`.

### 2 — Install the WYN Agent on each host

```bash
cd WatchYourNetwork/wyn-agent
pip install -r requirements.txt
cp wyn-agent.example.conf wyn-agent.conf
nano wyn-agent.conf   # set server IP, node name, interface
sudo python agent.py  # requires root for raw packet capture
```

See [AGENT.md](AGENT.md) for full configuration reference and systemd unit setup.

---

## Configuration — WYN Server (`config.yaml`)

```yaml
server:
  agent_port: 8765        # agents connect here
  ui_port: 8766           # browser WebSocket
  http_port: 80           # serves the web UI

topology:
  connection_ttl: 1800    # seconds before idle connection fades (30 min)
  node_colors:            # optional: override auto-assigned colors
    web-01: "#4A90D9"
    db-01:  "#E67E22"

internet_node:
  label: "Internet"
  color: "#95A5A6"
```

---

## Configuration — WYN Agent (`wyn-agent.conf`)

```yaml
server:
  host: "192.168.1.100"  # WYN Server IP
  port: 8765

node:
  id: "web-01"            # unique node identifier
  name: "Web Server 01"   # display name on the graph
  color: null             # null = auto-assigned by server

capture:
  interfaces:             # network interfaces to monitor
    - eth0
  bpf_filter: ""          # optional BPF filter string
  track_processes: true   # annotate packets with process name
  ignore_loopback: true   # skip 127.0.0.1 traffic

report:
  batch_interval_ms: 50   # send batch every N ms (lower = smoother animation)
  heartbeat_interval_s: 5 # keep-alive ping to server
```

---

## Visualization Behavior

| Event | Visual |
|-------|--------|
| Node comes online | Node circle appears with assigned color |
| Node goes offline | Node circle dims/greyed out |
| Packet A → B | Yellow dot animates along A–B line |
| Packet A → unknown IP | Yellow dot animates to Internet node |
| New connection | Line drawn between nodes |
| Connection idle 30 min | Line fades out |
| Application tracked | Sub-circle on node, same color as node |

---

## Security Notes

- The WYN Agent requires **root / CAP_NET_RAW** to capture raw packets.
- Agent↔Server communication is plain WebSocket by default. For production, put the server behind a reverse proxy with TLS.
- The agent never sends payload data — only IP headers (src/dst IP, port, protocol, byte count, optional process name).
- Restrict agent port (8765) to your internal network via firewall rules.

---

## Roadmap

- [ ] v0.1 — Core agent packet capture + server node registry + basic canvas UI
- [ ] v0.2 — Process tracking per node, sub-node visualization
- [ ] v0.3 — TLS support for agent↔server channel
- [ ] v0.4 — Historical replay mode
- [ ] v0.5 — Alert rules (threshold-based bandwidth or new-connection alerts)
- [ ] v1.0 — Stable release, packaged installers

---

## License

MIT — see [LICENSE](LICENSE).
