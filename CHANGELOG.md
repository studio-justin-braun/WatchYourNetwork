# Changelog

All notable changes to WatchYourNetwork will be documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

### Planned for v0.1.0
- WYN Agent: packet capture via Scapy, batch reporting over WebSocket
- WYN Server: agent registry, node topology tracking, WebSocket broadcaster
- WYN UI: HTML5 Canvas graph with animated packet dots and node circles
- Auto color assignment per node
- Internet node for unknown IPs
- Connection TTL (30 min fade-out)
- Basic systemd unit file for the agent
- Example config files for agent and server

---

## [0.1.0] — Planned

### Added
- Initial project structure (`wyn-agent/`, `wyn-server/`, `wyn-ui/`)
- WYN Agent
  - Raw packet capture on configurable interfaces (Scapy / libpcap)
  - BPF filter support
  - Batch-based JSON-over-WebSocket reporting to WYN Server
  - Heartbeat keep-alive
  - Optional process name resolution via `/proc/net/tcp`
  - YAML configuration file (`wyn-agent.conf`)
  - CLI flag overrides for quick testing
  - Systemd unit file template
- WYN Server
  - Async WebSocket listener for agents (port 8765)
  - Async WebSocket broadcaster for UI clients (port 8766)
  - HTTP server for static UI files (port 80)
  - Node registry: tracks online/offline state per node ID
  - IP-to-node resolution: maps IP addresses to known node IDs
  - Connection tracker: records active src→dst node pairs with last-seen timestamp
  - Automatic Internet node for unresolved IPs
  - Auto color palette assignment for new nodes
  - YAML server config (`config.yaml`)
- WYN UI
  - HTML5 Canvas-based network graph
  - Force-directed layout for node positioning
  - Node circles with color coding
  - Sub-circles for tracked applications (inheriting node color)
  - Animated yellow packet dots along connection lines
  - Connection lines drawn on first packet, fading after 30 min idle
  - Internet node displayed as a large distinct globe icon
  - Node online/offline visual state
  - Responsive layout
- Documentation
  - `README.md` — project overview, architecture, quick start
  - `AGENT.md` — agent installation, config reference, protocol spec
  - `CHANGELOG.md` — this file

---

## [0.2.0] — Planned

### Planned
- Process-level sub-node visualization (application bubbles inside node)
- UI: click a node to inspect active connections and bandwidth in a sidebar
- UI: connection bandwidth label (bytes/s) on hover
- Agent: UDP and ICMP tracking
- Server: REST API endpoint for topology snapshot (`GET /api/topology`)

---

## [0.3.0] — Planned

### Planned
- TLS support for agent↔server WebSocket channel (wss://)
- Agent client certificate authentication
- Server-side allowlist of accepted node IDs

---

## [0.4.0] — Planned

### Planned
- Historical replay mode: store events to SQLite, replay timeline in the UI
- UI: timeline scrubber widget

---

## [0.5.0] — Planned

### Planned
- Alert rules: trigger notification when bandwidth exceeds threshold or new unexpected connection appears
- Webhook integration for alerts (Slack, generic HTTP)

---

## [1.0.0] — Planned

### Planned
- Stable public release
- Packaged one-line installers for Debian/Ubuntu and RHEL/Rocky
- Docker Compose setup for WYN Server
- Full test suite for server and agent
