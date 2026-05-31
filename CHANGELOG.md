# Changelog

All notable changes to WatchYourNetwork are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) · Versioning: [Semantic Versioning](https://semver.org/)

---

## [Unreleased]

---

## [0.2.0] — 2026-06-01

### Added — UI
- **Settings panel** (⚙ gear icon, top-right) with live color pickers and layout toggle
- **Node color overrides** — color picker per node in settings; saved to localStorage; changes sent to server via `POST /api/node-color`
- **Traffic dot colors** by direction: Inbound (Internet→Node), Outbound (Node→Internet), Internal (Node↔Node), Unknown — all configurable
- **Line layout mode** — nodes sorted alphabetically in a left column; connections rendered as arcs; switch between Net and Line with toolbar buttons
- **Inside Net mode** — toolbar button + settings toggle; replaces single Internet node with individual external IP nodes inside a dashed Internet Zone box; IPs expire after 60 s
- **Application filter panel** — appears bottom-right when `track_processes` is active; checkbox per detected process to show/hide its traffic
- **Process labels on connection lines** — when app tracking is active, the most recently seen process name is drawn at the midpoint of each connection
- **Per-process colored packet dots** — each application gets a unique color from a palette

### Added — Server
- `POST /api/node-color` — change a node's color at runtime; broadcasts `node_update` to all UI clients
- `POST /api/inside_net` — enable/disable Inside Net mode at runtime
- `GET /api/settings` — returns current server settings (inside_net, version)
- **Inside Net mode** — `TopologyManager` tracks individual external IPs with 60 s TTL; sends `external_ip_new` / `external_ip_expired` WebSocket events to the UI
- `PacketRateLimiter` — throttles packet animation events (20/s node→node, ~7/s internet) to prevent UI overload
- **No-cache HTTP headers** on `GET /` to prevent browser from serving stale HTML
- CORS middleware for API endpoints
- `--ui-dir` CLI argument to explicitly set the path to `wyn-ui/` (fixes systemd service path)

### Added — Agent & Config
- `change-conf.sh` — interactive YAML config editor:
  - BPF filter presets (8 options: web-only, web+SSH, no-WireGuard, services-only, custom, …)
  - Multi-interface selector with numbered list and IPs
  - Process/app tracking toggle with description of what it shows in the UI
  - Service restart from within the menu
- `--test-capture` mode — captures 10 packets and prints them without connecting to server (for debugging)
- `--verbose` flag for debug-level logging

### Added — CLI
- `wyn` command installed to `/usr/local/bin/wyn` by `install-server.sh`
  - `wyn status` — shows service state and web UI URL
  - `wyn start / stop / restart [server|agent|all]`
  - `wyn logs [server|agent] [-n N]`
  - `wyn update` — downloads latest from GitHub, updates files, restarts services
  - `wyn uninstall [server|agent|all]`
  - `wyn config` — opens `change-conf.sh`
  - `wyn open` — prints + opens web UI URL
  - `wyn version`

### Fixed
- **Scapy `snaplen` crash** — removed unsupported `snaplen=` parameter from `AsyncSniffer` (Scapy's L2Socket backend rejects it; the sniffer would crash silently on start)
- **Agent IP registration** — agent now registers IPs from ALL non-loopback interfaces (not just the monitored ones); fixes traffic not appearing when packets enter on a different interface
- **UI served as JSON** — added `--ui-dir` to service ExecStart; server now correctly finds `index.html` in the installed path
- **pip install failure on Debian/Ubuntu** — `--break-system-packages --ignore-installed` flags added to installer `pip_install()` function to handle PEP 668 system package conflicts
- **`pip3: command not found`** — installer now tries `python3 -m pip` first, then `pip3`, and installs `python3-pip` via package manager if neither is found

### Changed
- Server port architecture simplified: merged to **2 ports only** — `8080` (HTTP + browser WebSocket) and `8765` (agent WebSocket); removed the old third WebSocket port
- `index.html` is now fully self-contained (all CSS and JS inlined); no external static files needed
- Node color assignment moved server-side; UI can override via localStorage and API

---

## [0.1.0] — 2026-05-31

### Added — Agent (`wyn-agent/agent.py`)
- Raw packet capture using Scapy `AsyncSniffer` on configurable network interfaces
- BPF filter support (passed directly to Scapy)
- Batch-based JSON-over-WebSocket reporting to WYN Server
- Heartbeat keep-alive messages
- Optional process name resolution via `psutil.net_connections()` (maps port tuples to process names)
- IP filtering: loopback, multicast, ARP all configurable
- YAML configuration file (`wyn-agent.conf`) with deep-merge defaults
- CLI flag overrides (`--server`, `--port`, `--node-id`, `--iface`)
- Automatic reconnect with configurable interval
- `systemd` unit file template (`wyn-agent.service`)

### Added — Server (`wyn-server/server.py`)
- Agent WebSocket listener on port 8765 (raw `websockets` library)
- Browser WebSocket broadcaster on port 8080 (`/ws/ui` via FastAPI)
- HTTP server for UI on port 8080 (`GET /`, `GET /api/topology`)
- `TopologyManager` — node registry, IP→nodeID mapping, connection TTL tracking
- `UIClients` — async broadcast to all connected browser tabs
- Internet node for unresolved external IPs
- Auto color palette assignment per node
- Connection TTL with configurable fade (default 30 min)
- YAML config file with deep-merge defaults
- `systemd` unit file (`wyn-server.service`)

### Added — UI (`wyn-ui/index.html`)
- HTML5 Canvas-based network graph (no framework)
- Force-directed physics layout (repulsion + spring attraction + damping)
- Animated yellow packet dots along connection lines
- Dashed connection lines with fade-out on idle
- Internet node displayed as globe icon (circle + equator + meridian)
- Node online/offline visual state (glow vs. dimmed with ×)
- Draggable nodes; Internet node pinned
- Hover tooltip (node name, IPs, online status)
- Node legend panel (top-right)
- pkt/s counter and node count (bottom-left)
- Auto-reconnect WebSocket with status indicator

### Added — Installers
- `install-server.sh` — multi-distro server installer (apt/dnf/yum/pacman/apk/zypper)
- `install-agent.sh` — multi-distro agent installer with multi-interface selection

### Added — Documentation
- `README.md` — project overview, architecture, quick start, config reference
- `AGENT.md` — agent installation, config reference, protocol spec
- `CHANGELOG.md` — this file

---

## Roadmap

- [ ] v0.3 — TLS support for agent↔server WebSocket (`wss://`)
- [ ] v0.4 — Historical replay mode (SQLite event log + timeline scrubber in UI)
- [ ] v0.5 — Alert rules (threshold bandwidth, new unexpected connections, webhooks)
- [ ] v1.0 — Stable release, Docker Compose setup, full test suite
