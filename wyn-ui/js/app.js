"use strict";

// ── Constants ──────────────────────────────────────────────────────────────────

const WS_URL = `ws://${location.host}/ws/ui`;
const RECONNECT_MS = 4000;
const PACKET_SPEED = 0.0025;      // progress per ms
const PACKET_RADIUS = 4;
const PACKET_COLOR = "#FFE033";
const PACKET_GLOW = "rgba(255,224,51,0.35)";
const CONNECTION_FADE_MS = 1800000; // 30 min
const FORCE_REPULSION = 9000;
const FORCE_ATTRACTION = 0.035;
const FORCE_DAMPING = 0.82;
const INTERNET_RADIUS = 38;
const NODE_RADIUS = 22;
const PHYSICS_STEPS = 2;

// ── State ─────────────────────────────────────────────────────────────────────

const nodes = new Map();        // id → NodeState
const connections = new Map();  // "src→dst" → ConnectionState
const bullets = [];             // active packet animations

let pktCount = 0;
let ppsDisplay = 0;
let lastPpsCheck = performance.now();

// ── Canvas setup ───────────────────────────────────────────────────────────────

const canvas = document.getElementById("canvas");
const ctx = canvas.getContext("2d");

function resize() {
  canvas.width = window.innerWidth;
  canvas.height = window.innerHeight;
}
window.addEventListener("resize", resize);
resize();

// ── Node state ─────────────────────────────────────────────────────────────────

function createNode(data) {
  const isInternet = data.id === "internet";
  const existing = nodes.get(data.id);
  const x = existing ? existing.x : (isInternet ? canvas.width * 0.82 : Math.random() * canvas.width * 0.6 + canvas.width * 0.1);
  const y = existing ? existing.y : Math.random() * canvas.height * 0.7 + canvas.height * 0.15;

  return {
    id: data.id,
    name: data.name,
    color: data.color,
    online: data.online,
    ips: data.ips || [],
    x,
    y,
    vx: 0,
    vy: 0,
    radius: isInternet ? INTERNET_RADIUS : NODE_RADIUS,
    isInternet,
    pinned: isInternet,
    alpha: data.online ? 1 : 0.3,
    targetAlpha: data.online ? 1 : 0.3,
  };
}

function upsertNode(data) {
  const existing = nodes.get(data.id);
  if (existing) {
    existing.online = data.online;
    existing.ips = data.ips || existing.ips;
    existing.name = data.name || existing.name;
    existing.targetAlpha = data.online ? 1 : 0.3;
  } else {
    nodes.set(data.id, createNode(data));
  }
  updateLegend();
}

// ── Connection state ───────────────────────────────────────────────────────────

function connKey(src, dst) { return `${src}→${dst}`; }

function upsertConnection(src, dst) {
  const key = connKey(src, dst);
  if (connections.has(key)) {
    connections.get(key).lastSeen = Date.now();
  } else {
    connections.set(key, { src, dst, lastSeen: Date.now(), alpha: 0, targetAlpha: 0.45 });
  }
}

function removeConnection(src, dst) {
  connections.delete(connKey(src, dst));
}

// ── Bullet (packet animation) ──────────────────────────────────────────────────

function spawnBullet(srcId, dstId) {
  const src = nodes.get(srcId);
  const dst = nodes.get(dstId);
  if (!src || !dst) return;
  bullets.push({ srcId, dstId, progress: 0 });
}

// ── Physics ────────────────────────────────────────────────────────────────────

function applyForces(dt) {
  const nodeArr = [...nodes.values()].filter(n => !n.pinned);
  const allNodes = [...nodes.values()];

  for (let step = 0; step < PHYSICS_STEPS; step++) {
    // Repulsion between all pairs
    for (let i = 0; i < allNodes.length; i++) {
      for (let j = i + 1; j < allNodes.length; j++) {
        const a = allNodes[i];
        const b = allNodes[j];
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        const dist2 = dx * dx + dy * dy + 1;
        const force = FORCE_REPULSION / dist2;
        const fx = force * dx / Math.sqrt(dist2);
        const fy = force * dy / Math.sqrt(dist2);
        if (!a.pinned) { a.vx -= fx; a.vy -= fy; }
        if (!b.pinned) { b.vx += fx; b.vy += fy; }
      }
    }

    // Spring attraction along connections
    for (const conn of connections.values()) {
      const src = nodes.get(conn.src);
      const dst = nodes.get(conn.dst);
      if (!src || !dst) continue;
      const dx = dst.x - src.x;
      const dy = dst.y - src.y;
      const dist = Math.sqrt(dx * dx + dy * dy) + 0.001;
      const ideal = 220;
      const stretch = (dist - ideal) * FORCE_ATTRACTION;
      const fx = stretch * dx / dist;
      const fy = stretch * dy / dist;
      if (!src.pinned) { src.vx += fx; src.vy += fy; }
      if (!dst.pinned) { dst.vx -= fx; dst.vy -= fy; }
    }

    // Integrate + damp + clamp to canvas
    const margin = 60;
    for (const n of nodeArr) {
      n.vx *= FORCE_DAMPING;
      n.vy *= FORCE_DAMPING;
      n.x += n.vx * dt * 0.06;
      n.y += n.vy * dt * 0.06;
      n.x = Math.max(margin, Math.min(canvas.width - margin, n.x));
      n.y = Math.max(margin, Math.min(canvas.height - margin, n.y));
    }
  }
}

// ── Rendering ──────────────────────────────────────────────────────────────────

function hexToRgb(hex) {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return `${r},${g},${b}`;
}

function drawNode(n) {
  const alpha = n.alpha;
  ctx.save();
  ctx.globalAlpha = alpha;

  // Glow halo
  if (n.online) {
    const grd = ctx.createRadialGradient(n.x, n.y, n.radius * 0.5, n.x, n.y, n.radius * 2.2);
    grd.addColorStop(0, `rgba(${hexToRgb(n.color)},0.18)`);
    grd.addColorStop(1, "rgba(0,0,0,0)");
    ctx.fillStyle = grd;
    ctx.beginPath();
    ctx.arc(n.x, n.y, n.radius * 2.2, 0, Math.PI * 2);
    ctx.fill();
  }

  // Border ring
  ctx.beginPath();
  ctx.arc(n.x, n.y, n.radius, 0, Math.PI * 2);
  ctx.strokeStyle = n.color;
  ctx.lineWidth = n.isInternet ? 2.5 : 2;
  ctx.stroke();

  // Fill
  ctx.fillStyle = `rgba(${hexToRgb(n.color)},${n.isInternet ? 0.12 : 0.16})`;
  ctx.fill();

  // Internet globe icon (simple cross + circle)
  if (n.isInternet) {
    ctx.strokeStyle = `rgba(${hexToRgb(n.color)},0.5)`;
    ctx.lineWidth = 1;
    // horizontal line
    ctx.beginPath();
    ctx.moveTo(n.x - n.radius, n.y);
    ctx.lineTo(n.x + n.radius, n.y);
    ctx.stroke();
    // vertical ellipse (longitude)
    ctx.beginPath();
    ctx.ellipse(n.x, n.y, n.radius * 0.5, n.radius, 0, 0, Math.PI * 2);
    ctx.stroke();
  } else if (!n.online) {
    // Offline X mark
    const s = n.radius * 0.4;
    ctx.strokeStyle = `rgba(${hexToRgb(n.color)},0.4)`;
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(n.x - s, n.y - s); ctx.lineTo(n.x + s, n.y + s);
    ctx.moveTo(n.x + s, n.y - s); ctx.lineTo(n.x - s, n.y + s);
    ctx.stroke();
  }

  // Label
  ctx.fillStyle = `rgba(${hexToRgb(n.color)},${n.online ? 0.9 : 0.4})`;
  ctx.font = `${n.isInternet ? 11 : 10}px monospace`;
  ctx.textAlign = "center";
  ctx.textBaseline = "top";
  ctx.fillText(n.name, n.x, n.y + n.radius + 5);

  ctx.restore();
}

function drawConnection(conn) {
  const src = nodes.get(conn.src);
  const dst = nodes.get(conn.dst);
  if (!src || !dst) return;

  const age = Date.now() - conn.lastSeen;
  const fadeFactor = Math.max(0, 1 - age / CONNECTION_FADE_MS);
  conn.targetAlpha = 0.45 * fadeFactor;
  conn.alpha += (conn.targetAlpha - conn.alpha) * 0.08;

  if (conn.alpha < 0.005) return;

  ctx.save();
  ctx.globalAlpha = conn.alpha;
  ctx.strokeStyle = "#2a4a6a";
  ctx.lineWidth = 1;
  ctx.setLineDash([4, 6]);
  ctx.beginPath();
  ctx.moveTo(src.x, src.y);
  ctx.lineTo(dst.x, dst.y);
  ctx.stroke();
  ctx.restore();
}

function drawBullet(bullet) {
  const src = nodes.get(bullet.srcId);
  const dst = nodes.get(bullet.dstId);
  if (!src || !dst) return;

  const t = bullet.progress;
  const x = src.x + (dst.x - src.x) * t;
  const y = src.y + (dst.y - src.y) * t;

  ctx.save();
  // Outer glow
  const grd = ctx.createRadialGradient(x, y, 0, x, y, PACKET_RADIUS * 3);
  grd.addColorStop(0, PACKET_COLOR);
  grd.addColorStop(0.4, PACKET_GLOW);
  grd.addColorStop(1, "rgba(255,224,51,0)");
  ctx.fillStyle = grd;
  ctx.beginPath();
  ctx.arc(x, y, PACKET_RADIUS * 3, 0, Math.PI * 2);
  ctx.fill();

  // Core dot
  ctx.fillStyle = PACKET_COLOR;
  ctx.beginPath();
  ctx.arc(x, y, PACKET_RADIUS, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();
}

// ── Main loop ──────────────────────────────────────────────────────────────────

let lastTs = performance.now();

function frame(ts) {
  const dt = Math.min(ts - lastTs, 100);
  lastTs = ts;

  // Clear
  ctx.fillStyle = "#060b14";
  ctx.fillRect(0, 0, canvas.width, canvas.height);

  // Grid dots (subtle background)
  ctx.fillStyle = "rgba(30,50,70,0.3)";
  for (let gx = 0; gx < canvas.width; gx += 40) {
    for (let gy = 0; gy < canvas.height; gy += 40) {
      ctx.fillRect(gx, gy, 1, 1);
    }
  }

  // Physics
  applyForces(dt);

  // Ease node alphas
  for (const n of nodes.values()) {
    n.alpha += (n.targetAlpha - n.alpha) * 0.05;
  }

  // Draw connections
  for (const conn of connections.values()) {
    drawConnection(conn);
  }

  // Draw nodes
  for (const n of nodes.values()) {
    drawNode(n);
  }

  // Advance and draw bullets
  for (let i = bullets.length - 1; i >= 0; i--) {
    bullets[i].progress += PACKET_SPEED * dt;
    if (bullets[i].progress >= 1) {
      bullets.splice(i, 1);
    } else {
      drawBullet(bullets[i]);
    }
  }

  // PPS counter
  pktCount++;
  if (ts - lastPpsCheck >= 1000) {
    ppsDisplay = pktCount;
    pktCount = 0;
    lastPpsCheck = ts;
    document.getElementById("pps-counter").textContent = `${ppsDisplay} pkt/s`;
    document.getElementById("node-counter").textContent = `${nodes.size} nodes`;
  }

  requestAnimationFrame(frame);
}

requestAnimationFrame(frame);

// ── Legend ─────────────────────────────────────────────────────────────────────

function updateLegend() {
  const container = document.getElementById("legend-items");
  container.innerHTML = "";
  for (const n of nodes.values()) {
    const item = document.createElement("div");
    item.className = "legend-item";
    item.innerHTML = `
      <div class="legend-dot" style="background:${n.color};opacity:${n.online ? 1 : 0.3}"></div>
      <div class="legend-label${n.online ? "" : " offline"}">${n.name}</div>
    `;
    container.appendChild(item);
  }
}

// ── Tooltip on hover ───────────────────────────────────────────────────────────

const tooltip = document.getElementById("tooltip");

canvas.addEventListener("mousemove", (e) => {
  const mx = e.clientX;
  const my = e.clientY;
  let hit = null;
  for (const n of nodes.values()) {
    const dx = mx - n.x;
    const dy = my - n.y;
    if (dx * dx + dy * dy <= (n.radius + 8) ** 2) { hit = n; break; }
  }
  if (hit) {
    tooltip.style.display = "block";
    tooltip.style.left = (mx + 14) + "px";
    tooltip.style.top = (my - 10) + "px";
    document.getElementById("tt-name").textContent = hit.name;
    document.getElementById("tt-ips").textContent = hit.ips.join(", ") || "—";
    document.getElementById("tt-status").textContent = hit.online ? "Online" : "Offline";
    document.getElementById("tt-status").style.color = hit.online ? "#2ECC71" : "#E74C3C";
  } else {
    tooltip.style.display = "none";
  }
});

canvas.addEventListener("mouseleave", () => { tooltip.style.display = "none"; });

// ── Drag to reposition nodes ───────────────────────────────────────────────────

let dragging = null;

canvas.addEventListener("mousedown", (e) => {
  for (const n of nodes.values()) {
    if (n.pinned) continue;
    const dx = e.clientX - n.x;
    const dy = e.clientY - n.y;
    if (dx * dx + dy * dy <= (n.radius + 8) ** 2) {
      dragging = n;
      n.vx = n.vy = 0;
      break;
    }
  }
});

canvas.addEventListener("mousemove", (e) => {
  if (dragging) {
    dragging.x = e.clientX;
    dragging.y = e.clientY;
    dragging.vx = dragging.vy = 0;
  }
});

canvas.addEventListener("mouseup", () => { dragging = null; });

// ── WebSocket client ───────────────────────────────────────────────────────────

const statusEl = document.getElementById("conn-status");

function setStatus(connected) {
  statusEl.textContent = connected ? "● Connected" : "● Disconnected";
  statusEl.className = `status ${connected ? "connected" : "disconnected"}`;
}

function connectWS() {
  const ws = new WebSocket(WS_URL);

  ws.onopen = () => {
    setStatus(true);
  };

  ws.onclose = () => {
    setStatus(false);
    setTimeout(connectWS, RECONNECT_MS);
  };

  ws.onerror = () => {
    ws.close();
  };

  ws.onmessage = (e) => {
    let msg;
    try { msg = JSON.parse(e.data); } catch { return; }

    switch (msg.type) {
      case "topology":
        for (const n of msg.nodes || []) upsertNode(n);
        for (const c of msg.connections || []) {
          upsertConnection(c.src, c.dst);
          if (c.last_seen) connections.get(connKey(c.src, c.dst)).lastSeen = c.last_seen * 1000;
        }
        break;

      case "node_update":
        upsertNode(msg.node);
        break;

      case "packet":
        upsertConnection(msg.src, msg.dst);
        spawnBullet(msg.src, msg.dst);
        break;

      case "connection_new":
        upsertConnection(msg.src, msg.dst);
        break;

      case "connection_expired":
        removeConnection(msg.src, msg.dst);
        break;
    }
  };
}

connectWS();
