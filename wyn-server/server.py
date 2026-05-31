#!/usr/bin/env python3
"""WYN Server — topology manager, agent listener, UI broadcaster."""

import asyncio
import json
import logging
import os
import sys
import time
from pathlib import Path
from typing import Any

import yaml
import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse

VERSION = "0.1.0"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("wyn-server")

# ── Config ─────────────────────────────────────────────────────────────────────

DEFAULT_CONFIG = {
    "server": {"agent_port": 8765, "ui_port": 8766, "http_port": 8080},
    "topology": {"connection_ttl": 1800, "node_colors": {}},
    "internet_node": {"label": "Internet", "color": "#95A5A6"},
    "logging": {"level": "INFO"},
}

COLOR_PALETTE = [
    "#4A90D9", "#E67E22", "#2ECC71", "#E74C3C", "#9B59B6",
    "#1ABC9C", "#F1C40F", "#E91E63", "#00BCD4", "#8BC34A",
    "#FF5722", "#3F51B5", "#795548", "#607D8B", "#FF9800",
]


def load_config(path: str | None) -> dict:
    cfg = DEFAULT_CONFIG.copy()
    if path and Path(path).exists():
        with open(path) as f:
            loaded = yaml.safe_load(f) or {}
        _deep_merge(cfg, loaded)
    return cfg


def _deep_merge(base: dict, override: dict) -> None:
    for k, v in override.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            _deep_merge(base[k], v)
        else:
            base[k] = v


# ── Node / Topology state ──────────────────────────────────────────────────────

class NodeInfo:
    __slots__ = ("id", "name", "color", "online", "ips", "last_seen")

    def __init__(self, node_id: str, name: str, color: str, ips: list[str]):
        self.id = node_id
        self.name = name
        self.color = color
        self.online = True
        self.ips = ips
        self.last_seen = time.time()

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "color": self.color,
            "online": self.online,
            "ips": self.ips,
        }


class TopologyManager:
    def __init__(self, cfg: dict):
        self._cfg = cfg
        self._nodes: dict[str, NodeInfo] = {}
        self._ip_to_node: dict[str, str] = {}
        self._connections: dict[tuple[str, str], float] = {}
        self._color_index = 0
        self._lock = asyncio.Lock()

        self._internet_id = "internet"
        self._internet_node = NodeInfo(
            self._internet_id,
            cfg["internet_node"]["label"],
            cfg["internet_node"]["color"],
            [],
        )
        self._internet_node.online = True

    def _next_color(self, node_id: str) -> str:
        override = self._cfg["topology"]["node_colors"].get(node_id)
        if override:
            return override
        color = COLOR_PALETTE[self._color_index % len(COLOR_PALETTE)]
        self._color_index += 1
        return color

    async def register_node(self, node_id: str, name: str, color: str | None, ips: list[str]) -> NodeInfo:
        async with self._lock:
            if node_id not in self._nodes:
                assigned_color = color or self._next_color(node_id)
                node = NodeInfo(node_id, name, assigned_color, ips)
                self._nodes[node_id] = node
                log.info("New node registered: %s (%s)", node_id, assigned_color)
            else:
                node = self._nodes[node_id]
                node.online = True
                node.last_seen = time.time()
                node.ips = ips

            for ip in ips:
                self._ip_to_node[ip] = node_id

            return node

    async def mark_offline(self, node_id: str) -> None:
        async with self._lock:
            if node_id in self._nodes:
                self._nodes[node_id].online = False
                log.info("Node offline: %s", node_id)

    def resolve_ip(self, ip: str) -> str:
        return self._ip_to_node.get(ip, self._internet_id)

    async def record_connection(self, src_node: str, dst_node: str) -> bool:
        """Returns True if this is a new connection."""
        key = (src_node, dst_node)
        async with self._lock:
            is_new = key not in self._connections
            self._connections[key] = time.time()
        return is_new

    async def expire_connections(self) -> list[tuple[str, str]]:
        ttl = self._cfg["topology"]["connection_ttl"]
        now = time.time()
        expired = []
        async with self._lock:
            for key, ts in list(self._connections.items()):
                if now - ts > ttl:
                    del self._connections[key]
                    expired.append(key)
        return expired

    def snapshot(self) -> dict:
        nodes = [self._internet_node.to_dict()]
        nodes += [n.to_dict() for n in self._nodes.values()]
        conns = [
            {"src": src, "dst": dst, "last_seen": ts}
            for (src, dst), ts in self._connections.items()
        ]
        return {"nodes": nodes, "connections": conns}


# ── Connection managers ────────────────────────────────────────────────────────

class UIClients:
    def __init__(self):
        self._clients: set[WebSocket] = set()
        self._lock = asyncio.Lock()

    async def add(self, ws: WebSocket) -> None:
        async with self._lock:
            self._clients.add(ws)

    async def remove(self, ws: WebSocket) -> None:
        async with self._lock:
            self._clients.discard(ws)

    async def broadcast(self, msg: dict) -> None:
        payload = json.dumps(msg)
        dead = []
        async with self._lock:
            targets = list(self._clients)
        for ws in targets:
            try:
                await ws.send_text(payload)
            except Exception:
                dead.append(ws)
        for ws in dead:
            await self.remove(ws)

    async def send_one(self, ws: WebSocket, msg: dict) -> None:
        try:
            await ws.send_text(json.dumps(msg))
        except Exception:
            pass


# ── FastAPI app ────────────────────────────────────────────────────────────────

def create_app(cfg: dict) -> FastAPI:
    topo = TopologyManager(cfg)
    ui_clients = UIClients()
    app = FastAPI(title="WatchYourNetwork Server")

    # Serve UI static files
    ui_dir = Path(__file__).parent.parent / "wyn-ui"
    if ui_dir.exists():
        app.mount("/static", StaticFiles(directory=str(ui_dir)), name="static")

    @app.get("/")
    async def root():
        index = ui_dir / "index.html"
        if index.exists():
            return FileResponse(str(index))
        return {"status": "WYN Server running", "version": VERSION}

    @app.get("/api/topology")
    async def api_topology():
        return topo.snapshot()

    # ── Agent WebSocket ────────────────────────────────────────────────────────

    @app.websocket("/ws/agent")
    async def agent_ws(ws: WebSocket):
        await ws.accept()
        node_id = None
        try:
            raw = await asyncio.wait_for(ws.receive_text(), timeout=15)
            msg = json.loads(raw)

            if msg.get("type") != "hello":
                await ws.close(code=4000)
                return

            node_id = msg["node_id"]
            node = await topo.register_node(
                node_id,
                msg.get("node_name", node_id),
                msg.get("color"),
                msg.get("ip_addresses", []),
            )

            await ui_clients.broadcast({
                "type": "node_update",
                "node": node.to_dict(),
            })
            log.info("Agent connected: %s", node_id)

            async for raw_msg in ws.iter_text():
                msg = json.loads(raw_msg)
                msg_type = msg.get("type")

                if msg_type == "packets":
                    await _handle_packets(msg, topo, ui_clients)
                elif msg_type == "heartbeat":
                    pass  # keep-alive handled by WebSocket layer

        except (WebSocketDisconnect, asyncio.TimeoutError, json.JSONDecodeError):
            pass
        finally:
            if node_id:
                await topo.mark_offline(node_id)
                node_info = topo._nodes.get(node_id)
                if node_info:
                    await ui_clients.broadcast({
                        "type": "node_update",
                        "node": node_info.to_dict(),
                    })
                log.info("Agent disconnected: %s", node_id)

    # ── UI WebSocket ───────────────────────────────────────────────────────────

    @app.websocket("/ws/ui")
    async def ui_ws(ws: WebSocket):
        await ws.accept()
        await ui_clients.add(ws)
        try:
            snapshot = topo.snapshot()
            await ui_clients.send_one(ws, {"type": "topology", **snapshot})
            async for _ in ws.iter_text():
                pass  # UI is receive-only for now
        except WebSocketDisconnect:
            pass
        finally:
            await ui_clients.remove(ws)

    # ── Background: TTL cleanup ────────────────────────────────────────────────

    @app.on_event("startup")
    async def startup():
        asyncio.create_task(_ttl_loop(topo, ui_clients))

    return app


async def _handle_packets(msg: dict, topo: TopologyManager, ui_clients: UIClients) -> None:
    node_id = msg.get("node_id", "unknown")
    events: list[dict] = msg.get("events", [])

    for event in events:
        src_ip = event.get("src_ip", "")
        dst_ip = event.get("dst_ip", "")

        src_node = topo.resolve_ip(src_ip)
        dst_node = topo.resolve_ip(dst_ip)

        if src_node == "internet" and dst_node == "internet":
            # Neither endpoint is a known node — use reporting node as src
            src_node = node_id

        if src_node == dst_node:
            continue

        is_new = await topo.record_connection(src_node, dst_node)

        packet_msg: dict[str, Any] = {
            "type": "packet",
            "src": src_node,
            "dst": dst_node,
            "proto": event.get("proto", "OTHER"),
            "bytes": event.get("bytes", 0),
        }
        if "process" in event:
            packet_msg["process"] = event["process"]

        await ui_clients.broadcast(packet_msg)

        if is_new:
            await ui_clients.broadcast({
                "type": "connection_new",
                "src": src_node,
                "dst": dst_node,
            })


async def _ttl_loop(topo: TopologyManager, ui_clients: UIClients) -> None:
    while True:
        await asyncio.sleep(60)
        expired = await topo.expire_connections()
        for src, dst in expired:
            await ui_clients.broadcast({"type": "connection_expired", "src": src, "dst": dst})
            log.debug("Connection expired: %s → %s", src, dst)


# ── Entry point ────────────────────────────────────────────────────────────────

def main() -> None:
    import argparse
    parser = argparse.ArgumentParser(description="WYN Server")
    parser.add_argument("--config", "-c", default="config.yaml")
    parser.add_argument("--port", type=int, help="HTTP/WebSocket port override")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    cfg = load_config(args.config)
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    if args.port:
        cfg["server"]["http_port"] = args.port

    log.info("WYN Server v%s starting on port %d", VERSION, cfg["server"]["http_port"])

    app = create_app(cfg)
    uvicorn.run(app, host="0.0.0.0", port=cfg["server"]["http_port"], log_level="warning")


if __name__ == "__main__":
    main()
