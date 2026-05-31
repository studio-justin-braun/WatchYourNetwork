#!/usr/bin/env python3
"""WYN Agent — packet capture and reporting daemon."""

import argparse
import asyncio
import json
import logging
import os
import socket
import sys
import threading
import time
from pathlib import Path

import psutil
import yaml
import websockets
from scapy.all import AsyncSniffer, IP, IPv6, TCP, UDP, ARP, conf as scapy_conf

scapy_conf.verb = 0

VERSION = "0.1.0"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("wyn-agent")

# ── Config ────────────────────────────────────────────────────────────────────

DEFAULT_CONFIG = {
    "server": {"host": "127.0.0.1", "port": 8765, "reconnect_interval_s": 10},
    "node": {"id": socket.gethostname(), "name": socket.gethostname(), "color": None},
    "capture": {
        "interfaces": ["eth0"],
        "bpf_filter": "",
        "ignore_loopback": True,
        "ignore_multicast": True,
        "ignore_arp": True,
        "track_processes": False,
    },
    "report": {
        "batch_interval_ms": 50,
        "heartbeat_interval_s": 5,
        "max_batch_size": 500,
    },
}


def load_config(path: str | None, args: argparse.Namespace) -> dict:
    cfg = DEFAULT_CONFIG.copy()
    if path and Path(path).exists():
        with open(path) as f:
            loaded = yaml.safe_load(f) or {}
        _deep_merge(cfg, loaded)
    if args.server:
        cfg["server"]["host"] = args.server
    if args.port:
        cfg["server"]["port"] = args.port
    if args.node_id:
        cfg["node"]["id"] = args.node_id
    if args.iface:
        cfg["capture"]["interfaces"] = [args.iface]
    return cfg


def _deep_merge(base: dict, override: dict) -> None:
    for k, v in override.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            _deep_merge(base[k], v)
        else:
            base[k] = v


# ── Local IP detection ─────────────────────────────────────────────────────────

def get_local_ips(interfaces: list[str]) -> list[str]:
    """Return IPs from ALL non-loopback interfaces so the server can match traffic
    regardless of which interface a packet enters/leaves on."""
    ips: list[str] = []
    seen: set[str] = set()
    for iface, addrs in psutil.net_if_addrs().items():
        if iface == "lo":
            continue
        for addr in addrs:
            if addr.family not in (socket.AF_INET, socket.AF_INET6):
                continue
            ip = addr.address.split("%")[0]
            if ip.startswith("127.") or ip == "::1":
                continue
            if ip not in seen:
                seen.add(ip)
                ips.append(ip)
    return ips


# ── Process resolution ─────────────────────────────────────────────────────────

class ProcessResolver:
    """Maps (local_ip, local_port, remote_ip, remote_port) → process name via psutil."""

    def __init__(self):
        self._cache: dict[tuple, str] = {}
        self._last_refresh = 0.0
        self._refresh_interval = 0.5

    def refresh(self) -> None:
        now = time.monotonic()
        if now - self._last_refresh < self._refresh_interval:
            return
        self._last_refresh = now
        new_cache: dict[tuple, str] = {}
        try:
            for conn in psutil.net_connections(kind="inet"):
                if conn.pid is None or conn.raddr is None or not conn.raddr:
                    continue
                key = (
                    conn.laddr.ip,
                    conn.laddr.port,
                    conn.raddr.ip,
                    conn.raddr.port,
                )
                try:
                    new_cache[key] = psutil.Process(conn.pid).name()
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    pass
        except psutil.AccessDenied:
            pass
        self._cache = new_cache

    def resolve(self, src_ip: str, src_port: int, dst_ip: str, dst_port: int) -> str | None:
        self.refresh()
        return self._cache.get((src_ip, src_port, dst_ip, dst_port)) or \
               self._cache.get((dst_ip, dst_port, src_ip, src_port))


# ── Packet parsing ─────────────────────────────────────────────────────────────

_LOOPBACK = {"127.0.0.1", "::1"}
_MULTICAST_PREFIX = ("224.", "239.", "ff0", "ff2")


def _is_loopback(ip: str) -> bool:
    return ip in _LOOPBACK


def _is_multicast(ip: str) -> bool:
    return any(ip.startswith(p) for p in _MULTICAST_PREFIX)


def parse_packet(pkt, cfg: dict, resolver: ProcessResolver | None) -> dict | None:
    if ARP in pkt and cfg["capture"]["ignore_arp"]:
        return None

    ip_layer = None
    if IP in pkt:
        ip_layer = pkt[IP]
    elif IPv6 in pkt:
        ip_layer = pkt[IPv6]

    if ip_layer is None:
        return None

    src_ip = str(ip_layer.src)
    dst_ip = str(ip_layer.dst)

    if cfg["capture"]["ignore_loopback"] and (_is_loopback(src_ip) or _is_loopback(dst_ip)):
        return None
    if cfg["capture"]["ignore_multicast"] and (_is_multicast(src_ip) or _is_multicast(dst_ip)):
        return None

    src_port = dst_port = 0
    proto = "OTHER"

    if TCP in pkt:
        proto = "TCP"
        src_port = pkt[TCP].sport
        dst_port = pkt[TCP].dport
    elif UDP in pkt:
        proto = "UDP"
        src_port = pkt[UDP].sport
        dst_port = pkt[UDP].dport

    process = None
    if resolver:
        process = resolver.resolve(src_ip, src_port, dst_ip, dst_port)

    event: dict = {
        "src_ip": src_ip,
        "dst_ip": dst_ip,
        "src_port": src_port,
        "dst_port": dst_port,
        "proto": proto,
        "bytes": len(pkt),
    }
    if process:
        event["process"] = process

    return event


# ── Agent core ────────────────────────────────────────────────────────────────

class WYNAgent:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self._buffer: list[dict] = []
        self._lock = threading.Lock()
        self._sniffer: AsyncSniffer | None = None
        self._resolver = ProcessResolver() if cfg["capture"]["track_processes"] else None
        self._local_ips = get_local_ips(cfg["capture"]["interfaces"])
        self._running = False

    def _on_packet(self, pkt) -> None:
        event = parse_packet(pkt, self.cfg, self._resolver)
        if event:
            with self._lock:
                self._buffer.append(event)
                total = len(self._buffer)
            if total == 1 or total % 500 == 0:
                log.debug("Buffer: %d packets queued", total)

    def _start_sniffer(self) -> None:
        ifaces = self.cfg["capture"]["interfaces"]
        bpf = self.cfg["capture"]["bpf_filter"] or None
        try:
            self._sniffer = AsyncSniffer(
                iface=ifaces,
                filter=bpf,
                prn=self._on_packet,
                store=False,
                # snaplen omitted — not supported by Scapy's L2Socket (raw-socket backend)
            )
            self._sniffer.start()
            log.info("Sniffer started on %s  (bpf=%r)", ifaces, bpf or "none")
        except Exception as exc:
            log.error("Sniffer FAILED to start: %s", exc)
            raise

    def _stop_sniffer(self) -> None:
        if self._sniffer:
            try:
                if self._sniffer.running:
                    self._sniffer.stop(join=True)
            except Exception as exc:
                log.debug("Sniffer stop: %s", exc)
            self._sniffer = None

    def _drain_buffer(self) -> list[dict]:
        max_size = self.cfg["report"]["max_batch_size"]
        with self._lock:
            batch = self._buffer[:max_size]
            self._buffer = self._buffer[max_size:]
        return batch

    def _hello_message(self) -> str:
        return json.dumps({
            "type": "hello",
            "node_id": self.cfg["node"]["id"],
            "node_name": self.cfg["node"]["name"],
            "color": self.cfg["node"]["color"],
            "agent_version": VERSION,
            "interfaces": self.cfg["capture"]["interfaces"],
            "ip_addresses": self._local_ips,
        })

    async def _send_loop(self, ws) -> None:
        interval = self.cfg["report"]["batch_interval_ms"] / 1000
        node_id = self.cfg["node"]["id"]
        total_sent = 0
        while self._running:
            await asyncio.sleep(interval)
            batch = self._drain_buffer()
            if batch:
                try:
                    await ws.send(json.dumps({
                        "type": "packets",
                        "node_id": node_id,
                        "ts": time.time(),
                        "events": batch,
                    }))
                    total_sent += len(batch)
                    if total_sent % 100 < len(batch):
                        log.debug("Sent %d packets total to server", total_sent)
                except Exception as exc:
                    log.warning("Send failed: %s", exc)
                    break

    async def _heartbeat_loop(self, ws) -> None:
        interval = self.cfg["report"]["heartbeat_interval_s"]
        node_id = self.cfg["node"]["id"]
        while self._running:
            await asyncio.sleep(interval)
            try:
                await ws.send(json.dumps({
                    "type": "heartbeat",
                    "node_id": node_id,
                    "ts": time.time(),
                }))
            except Exception:
                break

    async def _run_connection(self) -> None:
        host = self.cfg["server"]["host"]
        port = self.cfg["server"]["port"]
        uri = f"ws://{host}:{port}/ws/agent"

        log.info("Connecting to WYN Server at %s …", uri)
        try:
            async with websockets.connect(uri, ping_interval=20, ping_timeout=10) as ws:
                await ws.send(self._hello_message())
                log.info("Connected to server. Node=%s  local_ips=%s",
                         self.cfg["node"]["id"], self._local_ips)
                self._start_sniffer()
                try:
                    await asyncio.gather(
                        self._send_loop(ws),
                        self._heartbeat_loop(ws),
                    )
                finally:
                    self._stop_sniffer()
        except (OSError, websockets.exceptions.WebSocketException) as exc:
            log.warning("Connection error: %s — will retry", exc)
        except Exception as exc:
            log.error("Unexpected agent error: %s", exc, exc_info=True)

    async def run(self) -> None:
        self._running = True
        reconnect = self.cfg["server"]["reconnect_interval_s"]
        while self._running:
            await self._run_connection()
            if self._running:
                log.info("Reconnecting in %ds…", reconnect)
                await asyncio.sleep(reconnect)

    def stop(self) -> None:
        self._running = False
        self._stop_sniffer()


# ── Entry point ────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="WYN Agent")
    parser.add_argument("--config", "-c", default="wyn-agent.conf", help="Config file path")
    parser.add_argument("--server", "-s", help="WYN Server host override")
    parser.add_argument("--port", "-p", type=int, help="WYN Server port override")
    parser.add_argument("--node-id", help="Node ID override")
    parser.add_argument("--iface", "-i", help="Interface override")
    parser.add_argument("--verbose", "-v", action="store_true")
    parser.add_argument("--test-capture", action="store_true",
                        help="Capture 10 packets, print them, then exit (no server needed)")
    args = parser.parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    if os.geteuid() != 0:
        log.warning("Not running as root — packet capture may fail without CAP_NET_RAW")

    cfg = load_config(args.config, args)

    if args.test_capture:
        ifaces = cfg["capture"]["interfaces"]
        print(f"\nCapture test on {ifaces} — waiting for 10 packets (Ctrl+C to stop early)…\n")
        from scapy.all import sniff as scapy_sniff
        def show(pkt):
            event = parse_packet(pkt, cfg, None)
            if event:
                print(f"  {event['src_ip']}:{event['src_port']}  →  "
                      f"{event['dst_ip']}:{event['dst_port']}  [{event['proto']}]  "
                      f"{event['bytes']}B")
            else:
                print(f"  (filtered) {pkt.summary()}")
        scapy_sniff(iface=ifaces, count=10, prn=show)
        local_ips = get_local_ips(ifaces)
        print(f"\nLocal IPs that will be registered: {local_ips}")
        return

    agent = WYNAgent(cfg)
    try:
        asyncio.run(agent.run())
    except KeyboardInterrupt:
        log.info("Shutting down.")
        agent.stop()


if __name__ == "__main__":
    main()
