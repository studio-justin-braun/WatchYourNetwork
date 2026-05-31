#!/usr/bin/env python3
"""WYN Server
  HTTP + UI WebSocket  →  http_port  (default 8080)
  Agent WebSocket      →  agent_port (default 8765)
"""

import argparse
import asyncio
import json
import logging
import time
from pathlib import Path
from typing import Any

import uvicorn
import websockets
import yaml
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse, Response
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

VERSION = "0.2.0"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("wyn-server")

# ── Config ─────────────────────────────────────────────────────────────────────

DEFAULT_CONFIG: dict = {
    "server":        {"http_port": 8080, "agent_port": 8765},
    "topology":      {"connection_ttl": 1800, "node_colors": {}, "inside_net": False},
    "internet_node": {"label": "Internet", "color": "#95A5A6"},
    "logging":       {"level": "INFO"},
}

COLOR_PALETTE = [
    "#4A90D9", "#E67E22", "#2ECC71", "#E74C3C", "#9B59B6",
    "#1ABC9C", "#F1C40F", "#E91E63", "#00BCD4", "#8BC34A",
    "#FF5722", "#3F51B5", "#795548", "#607D8B", "#FF9800",
]

EXTERNAL_IP_TTL = 60  # seconds


def load_config(path: str | None) -> dict:
    cfg: dict = {}
    _deep_merge(cfg, DEFAULT_CONFIG)
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


# ── Topology state ─────────────────────────────────────────────────────────────

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
        return {"id": self.id, "name": self.name, "color": self.color,
                "online": self.online, "ips": self.ips}


class TopologyManager:
    def __init__(self, cfg: dict):
        self._cfg = cfg
        self._nodes: dict[str, NodeInfo] = {}
        self._ip_to_node: dict[str, str] = {}
        self._connections: dict[tuple[str, str], float] = {}
        self._external_ips: dict[str, float] = {}  # ip → last_seen (inside_net mode)
        self._color_index = 0
        self._lock = asyncio.Lock()
        self._inside_net: bool = cfg["topology"].get("inside_net", False)
        self._internet = NodeInfo(
            "internet",
            cfg["internet_node"]["label"],
            cfg["internet_node"]["color"],
            [],
        )

    # ── Node management ────────────────────────────────────────────────────────

    def _next_color(self, node_id: str) -> str:
        override = self._cfg["topology"]["node_colors"].get(node_id)
        if override:
            return override
        color = COLOR_PALETTE[self._color_index % len(COLOR_PALETTE)]
        self._color_index += 1
        return color

    async def register_node(self, node_id: str, name: str,
                            color: str | None, ips: list[str]) -> NodeInfo:
        async with self._lock:
            if node_id not in self._nodes:
                node = NodeInfo(node_id, name, color or self._next_color(node_id), ips)
                self._nodes[node_id] = node
                log.info("Node registered: %s  color=%s", node_id, node.color)
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

    def set_node_color(self, node_id: str, color: str) -> bool:
        """Returns True if the node exists."""
        if node_id == "internet":
            self._cfg["internet_node"]["color"] = color
            self._internet.color = color
            return True
        node = self._nodes.get(node_id)
        if node:
            node.color = color
            self._cfg["topology"]["node_colors"][node_id] = color
            return True
        return False

    # ── IP resolution ──────────────────────────────────────────────────────────

    def resolve_ip(self, ip: str) -> str:
        known = self._ip_to_node.get(ip)
        if known:
            return known
        if self._inside_net:
            return ip  # individual external IP node
        return "internet"

    # ── Inside Net ─────────────────────────────────────────────────────────────

    def set_inside_net(self, enabled: bool) -> None:
        self._inside_net = enabled
        if not enabled:
            self._external_ips.clear()
        log.info("Inside Net mode: %s", "on" if enabled else "off")

    async def touch_external_ip(self, ip: str) -> bool:
        """Register/refresh an external IP. Returns True if new."""
        async with self._lock:
            is_new = ip not in self._external_ips
            self._external_ips[ip] = time.time()
        return is_new

    async def expire_external_ips(self) -> list[str]:
        now = time.time()
        expired: list[str] = []
        async with self._lock:
            for ip, ts in list(self._external_ips.items()):
                if now - ts > EXTERNAL_IP_TTL:
                    del self._external_ips[ip]
                    expired.append(ip)
        return expired

    # ── Connections ────────────────────────────────────────────────────────────

    async def record_connection(self, src: str, dst: str) -> bool:
        key = (src, dst)
        async with self._lock:
            is_new = key not in self._connections
            self._connections[key] = time.time()
        return is_new

    async def expire_connections(self) -> list[tuple[str, str]]:
        ttl = self._cfg["topology"]["connection_ttl"]
        now = time.time()
        expired: list[tuple[str, str]] = []
        async with self._lock:
            for key, ts in list(self._connections.items()):
                if now - ts > ttl:
                    del self._connections[key]
                    expired.append(key)
        return expired

    # ── Snapshot ───────────────────────────────────────────────────────────────

    def snapshot(self) -> dict:
        nodes = [self._internet.to_dict()] + [n.to_dict() for n in self._nodes.values()]
        if self._inside_net:
            for ip in self._external_ips:
                nodes.append({
                    "id": ip, "name": ip, "color": "#95A5A6",
                    "online": True, "ips": [ip], "is_external": True,
                })
        conns = [{"src": s, "dst": d, "last_seen": ts}
                 for (s, d), ts in self._connections.items()]
        return {
            "nodes": nodes,
            "connections": conns,
            "inside_net": self._inside_net,
        }


# ── UI client manager ──────────────────────────────────────────────────────────

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
        dead: list[WebSocket] = []
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


# ── Packet animation rate limiter ─────────────────────────────────────────────

class PacketRateLimiter:
    NODE_INTERVAL     = 0.05   # 20 events/s for known node pairs
    INTERNET_INTERVAL = 0.15   # ~7 events/s for internet connections

    def __init__(self):
        self._last: dict[tuple[str, str], float] = {}

    def should_emit(self, src: str, dst: str) -> bool:
        involves_internet = src == "internet" or dst == "internet"
        interval = self.INTERNET_INTERVAL if involves_internet else self.NODE_INTERVAL
        key = (src, dst)
        now = time.time()
        if now - self._last.get(key, 0.0) >= interval:
            self._last[key] = now
            return True
        return False


_rate_limiter = PacketRateLimiter()


# ── Packet handling ────────────────────────────────────────────────────────────

async def handle_packet_batch(msg: dict, topo: TopologyManager,
                               ui_clients: UIClients) -> None:
    node_id: str = msg.get("node_id", "unknown")
    for event in msg.get("events", []):
        src_ip = event.get("src_ip", "")
        dst_ip = event.get("dst_ip", "")
        src_node = topo.resolve_ip(src_ip)
        dst_node = topo.resolve_ip(dst_ip)

        if src_node == "internet" and dst_node == "internet":
            src_node = node_id
        if src_node == dst_node:
            continue

        # Register individual external IPs in Inside Net mode
        if topo._inside_net:
            for ip, nid in ((src_ip, src_node), (dst_ip, dst_node)):
                if nid not in topo._nodes and nid != "internet" and ip:
                    is_new = await topo.touch_external_ip(nid)
                    if is_new:
                        await ui_clients.broadcast({
                            "type": "external_ip_new",
                            "node": {
                                "id": nid, "name": nid, "color": "#95A5A6",
                                "online": True, "ips": [ip], "is_external": True,
                            },
                        })
                    else:
                        await topo.touch_external_ip(nid)

        is_new = await topo.record_connection(src_node, dst_node)
        if is_new:
            await ui_clients.broadcast({"type": "connection_new",
                                        "src": src_node, "dst": dst_node})

        if _rate_limiter.should_emit(src_node, dst_node):
            pkt: dict[str, Any] = {
                "type": "packet",
                "src": src_node, "dst": dst_node,
                "proto": event.get("proto", "OTHER"),
                "bytes": event.get("bytes", 0),
            }
            if "process" in event:
                pkt["process"] = event["process"]
            await ui_clients.broadcast(pkt)


# ── Agent WebSocket server  (port 8765) ────────────────────────────────────────

def make_agent_handler(topo: TopologyManager, ui_clients: UIClients):
    async def handler(websocket) -> None:
        node_id: str | None = None
        try:
            raw = await asyncio.wait_for(websocket.recv(), timeout=15)
            msg = json.loads(raw)
            if msg.get("type") != "hello":
                return

            node_id = msg["node_id"]
            node = await topo.register_node(
                node_id,
                msg.get("node_name", node_id),
                msg.get("color"),
                msg.get("ip_addresses", []),
            )
            await ui_clients.broadcast({"type": "node_update", "node": node.to_dict()})
            log.info("Agent connected: %s  from %s", node_id, websocket.remote_address)

            async for raw_msg in websocket:
                msg = json.loads(raw_msg)
                if msg.get("type") == "packets":
                    await handle_packet_batch(msg, topo, ui_clients)

        except (json.JSONDecodeError, KeyError, asyncio.TimeoutError,
                websockets.exceptions.ConnectionClosed):
            pass
        finally:
            if node_id:
                await topo.mark_offline(node_id)
                node_info = topo._nodes.get(node_id)
                if node_info:
                    await ui_clients.broadcast({"type": "node_update",
                                                "node": node_info.to_dict()})
                log.info("Agent disconnected: %s", node_id)
    return handler


# ── FastAPI app  (port 8080) ───────────────────────────────────────────────────

class NodeColorRequest(BaseModel):
    node_id: str
    color: str

class InsideNetRequest(BaseModel):
    enabled: bool


def create_fastapi_app(topo: TopologyManager, ui_clients: UIClients,
                        ui_dir: Path | None = None) -> FastAPI:
    app = FastAPI(title="WatchYourNetwork", docs_url=None, redoc_url=None)

    app.add_middleware(CORSMiddleware, allow_origins=["*"],
                       allow_methods=["*"], allow_headers=["*"])

    _here = Path(__file__).resolve().parent
    if ui_dir:
        html_path = ui_dir / "index.html"
    else:
        html_path = next(
            (p for p in [_here / "wyn-ui" / "index.html",
                         _here.parent / "wyn-ui" / "index.html"]
             if p.exists()),
            _here / "wyn-ui" / "index.html",
        )
    log.info("UI path: %s  (exists=%s)", html_path, html_path.exists())

    _NO_CACHE = {
        "Cache-Control": "no-cache, no-store, must-revalidate",
        "Pragma": "no-cache",
        "Expires": "0",
    }

    @app.get("/")
    async def root():
        if html_path.exists():
            return Response(
                content=html_path.read_text(encoding="utf-8"),
                media_type="text/html",
                headers=_NO_CACHE,
            )
        return JSONResponse({"status": "WYN Server running", "version": VERSION})

    @app.get("/api/topology")
    async def api_topology():
        return topo.snapshot()

    @app.post("/api/node-color")
    async def api_node_color(req: NodeColorRequest):
        ok = topo.set_node_color(req.node_id, req.color)
        if not ok:
            return JSONResponse({"error": "node not found"}, status_code=404)
        node = topo._nodes.get(req.node_id)
        if node:
            await ui_clients.broadcast({"type": "node_update", "node": node.to_dict()})
        elif req.node_id == "internet":
            await ui_clients.broadcast({
                "type": "node_update",
                "node": topo._internet.to_dict(),
            })
        return {"ok": True}

    @app.post("/api/inside_net")
    async def api_inside_net(req: InsideNetRequest):
        topo.set_inside_net(req.enabled)
        await ui_clients.broadcast({
            "type": "inside_net_changed",
            "enabled": req.enabled,
        })
        if not req.enabled:
            await ui_clients.broadcast({"type": "topology", **topo.snapshot()})
        return {"inside_net": req.enabled}

    @app.get("/api/settings")
    async def api_settings():
        return {
            "inside_net": topo._inside_net,
            "version": VERSION,
        }

    @app.websocket("/ws/ui")
    async def ui_ws(ws: WebSocket):
        await ws.accept()
        await ui_clients.add(ws)
        try:
            await ui_clients.send_one(ws, {"type": "topology", **topo.snapshot()})
            async for _ in ws.iter_text():
                pass
        except WebSocketDisconnect:
            pass
        finally:
            await ui_clients.remove(ws)

    @app.on_event("startup")
    async def startup():
        asyncio.create_task(_ttl_loop(topo, ui_clients))

    return app


async def _ttl_loop(topo: TopologyManager, ui_clients: UIClients) -> None:
    while True:
        await asyncio.sleep(10)
        for src, dst in await topo.expire_connections():
            await ui_clients.broadcast({"type": "connection_expired",
                                        "src": src, "dst": dst})
        if topo._inside_net:
            for ip in await topo.expire_external_ips():
                await ui_clients.broadcast({"type": "external_ip_expired", "ip": ip})


# ── Entry point ────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="WYN Server")
    parser.add_argument("--config", "-c", default="config.yaml")
    parser.add_argument("--http-port",  type=int)
    parser.add_argument("--agent-port", type=int)
    parser.add_argument("--ui-dir", type=Path, help="Path to wyn-ui directory")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    cfg = load_config(args.config)
    if args.http_port:  cfg["server"]["http_port"]  = args.http_port
    if args.agent_port: cfg["server"]["agent_port"] = args.agent_port

    logging.getLogger().setLevel("DEBUG" if args.verbose else cfg["logging"]["level"])

    http_port  = cfg["server"]["http_port"]
    agent_port = cfg["server"]["agent_port"]

    topo       = TopologyManager(cfg)
    ui_clients = UIClients()
    app        = create_fastapi_app(topo, ui_clients, ui_dir=args.ui_dir)
    handler    = make_agent_handler(topo, ui_clients)

    log.info("WYN Server v%s", VERSION)
    log.info("  Web UI  →  http://0.0.0.0:%d", http_port)
    log.info("  Agents  →  ws://0.0.0.0:%d", agent_port)

    async def run() -> None:
        ui_cfg = uvicorn.Config(app, host="0.0.0.0", port=http_port, log_level="warning")
        ui_srv = uvicorn.Server(ui_cfg)
        async with websockets.serve(handler, "0.0.0.0", agent_port):
            log.info("Agent listener ready on :%d", agent_port)
            await ui_srv.serve()

    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        log.info("Shutdown.")


if __name__ == "__main__":
    main()
