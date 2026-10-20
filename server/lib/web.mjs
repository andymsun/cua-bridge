// Local web UI: the live built-in browser (Codex-style in-app browser you can open
// in any browser pane - including the Claude app's) and the settings page.
// Bound to 127.0.0.1 and gated by a per-install token.
import { createHash, randomUUID } from "node:crypto";
import * as fs from "node:fs";
import * as http from "node:http";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { config, defaults, saveConfig } from "./config.mjs";
import { applyMode, currentMode } from "./harness.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const page = (name) => fs.readFileSync(path.join(here, "..", "web", name), "utf8");
const SEARCH = { google: "https://www.google.com/search?q=%s", bing: "https://www.bing.com/search?q=%s",
  brave: "https://search.brave.com/search?q=%s", duckduckgo: "https://duckduckgo.com/?q=%s" };
const searchUrl = (e) => SEARCH[e] ?? (/^https?:\/\/[^"<>\s]+%s/.test(String(e)) ? e : SEARCH.google);
const safeColor = (c) => (/^#[0-9a-f]{3,8}$|^[a-z]+$/i.test(String(c)) ? c : "#339cff");

export function startWeb({ engine, native, hud, token, status, companion, agentHub }) {
  const instance = randomUUID();
  let revision = 0;
  const changed = () => { revision++; };
  companion?.on("change", changed); agentHub?.on("change", changed);
  const companionState = () => ({ ...companion.snapshot(), ...(agentHub ? { hub: agentHub.snapshot() } : {}), version: { instance, revision } });
  const viewers = new Set();      // MJPEG responses
  const sockets = new Set();      // WebSocket live-view clients
  const listeners = new Set();    // SSE responses
  let latest = null;
  let lastCursor = null;

  const authed = (req, url) => url.searchParams.get("t") === token || req.headers["x-cua-token"] === token;
  const json = (res, code, body) => { res.writeHead(code, { "content-type": "application/json" }); res.end(JSON.stringify(body)); };
  const body = (req) => new Promise((r) => { let b = ""; req.on("data", (c) => (b += c)); req.on("end", () => { try { r(JSON.parse(b || "{}")); } catch { r({}); } }); });
  const sse = (ev) => { const line = `data: ${JSON.stringify(ev)}\n\n`; for (const l of listeners) l.write(line); };

  const state = () => ({
    type: "state", running: engine.running, tabs: engine.running ? engine.list() : [],
    active: engine.active?.id ?? null, source: hud.source, sessionName: engine.sessionName ?? null,
  });

  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, "http://x");
    if (!authed(req, url)) { res.writeHead(401); return res.end("Missing or wrong token. Open the URL from cua.ui() or the settings command."); }
    try {
      if (url.pathname.startsWith("/api/companion")) {
        res.setHeader("cache-control", "no-store");
        if (req.method === "GET" && url.pathname === "/api/companion/events") {
          res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-store" });
          const write = () => res.write(`data: ${JSON.stringify(companionState())}\n\n`);
          write(); companion.on("change", write); agentHub?.on("change", write);
          const heartbeat = setInterval(() => res.write(": keepalive\n\n"), 20000);
          const end = () => res.end(); companion.once("close", end);
          res.once("close", () => {
            clearInterval(heartbeat); companion.off("change", write); companion.off("close", end); agentHub?.off("change", write);
          }); return;
        }
        if (req.method === "GET") return json(res, 200, companionState());
        if (req.method !== "POST" || !req.headers["content-type"]?.startsWith("application/json")) return json(res, 415, { error: "Send JSON" });
        const origin = req.headers.origin;
        if (origin && origin !== `http://${req.headers.host}`) return json(res, 403, { error: "Wrong origin" });
        let raw = "";
        for await (const chunk of req) { raw += chunk; if (Buffer.byteLength(raw) > 32768) return json(res, 413, { error: "Request too large" }); }
        const data = JSON.parse(raw || "{}");
        switch (url.pathname) {
          case "/api/companion/permissions": {
            if (data.permission !== "accessibility") return json(res, 400, { error: "Only app accessibility is needed by this companion" });
            const permission = await native.req("requestPermission", { permission: "accessibility" });
            return json(res, 200, { ...companionState(), permission });
          }
          case "/api/companion/new": { const s = companion.create(data); return json(res, 200, { id: s.id, ...companionState() }); }
          case "/api/companion/send": companion.send(data.id, data); break;
          case "/api/companion/model": companion.setModel(data.id, data.model); break;
          case "/api/companion/continue": companion.resume(data.id, data.guideId, data.context); break;
          case "/api/companion/end-guide": companion.endGuide(data.id, data.guideId); break;
          case "/api/companion/stop": companion.stop(data.id); break;
          case "/api/companion/stop-all": for (const s of companion.sessions.values()) companion.stop(s.id); break;
          case "/api/companion/remove": companion.remove(data.id); break;
          case "/api/companion/warm": companion.warm(); break;
          case "/api/companion/demo": companion.demo(data); break;
          case "/api/companion/demo-stop": companion.stopDemo(); break;
          case "/api/companion/annotate": companion.annotate(data.id, data.shape); break;
          case "/api/companion/select": companion.select(data.id, data.rect, data.style); break;
          case "/api/companion/clear": companion.clear(data.id); break;
          case "/api/companion/approve": await companion.approve(data.id, data.approvalId, data.allow); break;
          default: return json(res, 404, { error: "Unknown companion command" });
        }
        return json(res, 200, companionState());
      }
      switch (`${req.method} ${url.pathname}`) {
        case "GET /companion":
          res.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "referrer-policy": "no-referrer", "content-security-policy": "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'" });
          return res.end(page("companion.html").replaceAll("{{TOKEN}}", token));
        case "GET /":
          res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
          return res.end(page("browser.html").replaceAll("{{TOKEN}}", token).replaceAll("{{CURSOR_COLOR}}", safeColor(config().hud.cursorColor))
            .replaceAll("{{SEARCH_URL}}", searchUrl(config().web.searchEngine)));
        case "GET /cursor.js":
          res.writeHead(200, { "content-type": "text/javascript; charset=utf-8" });
          return res.end(page("cursor.js"));
        case "GET /settings":
          res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
          return res.end(page("settings.html").replaceAll("{{TOKEN}}", token));
        case "GET /stream": {
          res.writeHead(200, { "content-type": "multipart/x-mixed-replace; boundary=f", "cache-control": "no-store" });
          res.write("--f\r\n");
          viewers.add(res);
          engine.consumers++; engine.syncStreaming();
          if (latest) writeFrame(res, latest);
          // static pages emit no screencast frames; give a new viewer a picture right away
          engine.active?.screenshot({ format: "jpeg", quality: config().stream.quality })
            .then((buf) => { latest = buf; writeFrame(res, buf); }).catch(() => {});
          req.on("close", () => { viewers.delete(res); engine.consumers--; engine.syncStreaming(); });
          return;
        }
        case "GET /events":
          res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-store" });
          listeners.add(res);
          res.write(`data: ${JSON.stringify(state())}\n\n`);
          if (lastCursor) res.write(`data: ${JSON.stringify(lastCursor)}\n\n`);   // show where the agent is pointing now
          req.on("close", () => listeners.delete(res));
          return;
        case "GET /api/state": return json(res, 200, state());
        case "GET /api/status": return json(res, 200, await status());
        case "GET /api/config": return json(res, 200, { config: config(), defaults });
        case "POST /api/config": return json(res, 200, { config: saveConfig(await body(req)) });
        case "POST /api/nav": {
          await navigate(await body(req));
          return json(res, 200, state());
        }
        case "POST /api/input": {
          const tab = engine.active;
          if (!tab) return json(res, 409, { error: "no active tab" });
          await tab.userInput(await body(req));
          return json(res, 200, { ok: true });
        }
        case "POST /api/browser/restart":
          await engine.shutdown(); await engine.ensure(); return json(res, 200, state());
        case "GET /api/mode": return json(res, 200, { mode: currentMode() });
        case "POST /api/mode": {
          const { mode } = await body(req);
          return json(res, 200, { mode, report: applyMode(mode) });
        }
        case "POST /api/hud/show":
          hud.launch(true); return json(res, 200, { ok: true });
        default:
          res.writeHead(404); return res.end("not found");
      }
    } catch (e) { return json(res, 500, { error: e.message }); }
  });

  // ---- WebSocket transport: one socket per viewer carries frames, cursor, state and input ----
  const wsSend = (sock, data, binary) => {
    const payload = Buffer.isBuffer(data) ? data : Buffer.from(data);
    const len = payload.length;
    const head = len < 126 ? Buffer.from([binary ? 0x82 : 0x81, len])
      : len < 65536 ? Buffer.from([binary ? 0x82 : 0x81, 126, len >> 8, len & 255])
      : (() => { const b = Buffer.alloc(10); b[0] = binary ? 0x82 : 0x81; b[1] = 127; b.writeBigUInt64BE(BigInt(len), 2); return b; })();
    sock.write(Buffer.concat([head, payload]));
  };
  const wsJson = (sock, obj) => { try { wsSend(sock, JSON.stringify(obj), false); } catch {} };

  server.on("upgrade", (req, sock) => {
    const url = new URL(req.url, "http://x");
    if (url.pathname !== "/ws" || url.searchParams.get("t") !== token) { sock.destroy(); return; }
    const accept = createHash("sha1").update(req.headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
    sock.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    sock.setNoDelay(true);
    sockets.add(sock);
    engine.consumers++; engine.syncStreaming();
    wsJson(sock, state());
    if (lastCursor) wsJson(sock, lastCursor);
    if (latest) wsSend(sock, latest, true);
    engine.active?.screenshot({ format: "jpeg", quality: config().stream.quality })
      .then((buf) => { latest = buf; wsSend(sock, buf, true); }).catch(() => {});

    let buf = Buffer.alloc(0);
    sock.on("data", (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      while (buf.length >= 2) {
        const op = buf[0] & 0x0f, masked = buf[1] & 0x80;
        let len = buf[1] & 0x7f, off = 2;
        if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); off = 4; }
        else if (len === 127) { if (buf.length < 10) return; len = Number(buf.readBigUInt64BE(2)); off = 10; }
        const need = off + (masked ? 4 : 0) + len;
        if (buf.length < need) return;
        let payload = buf.subarray(off + (masked ? 4 : 0), need);
        if (masked) { const m = buf.subarray(off, off + 4); payload = Buffer.from(payload.map((b, i) => b ^ m[i & 3])); }
        buf = buf.subarray(need);
        if (op === 0x8) { sock.end(); return; }
        if (op === 0x9) { sock.write(Buffer.concat([Buffer.from([0x8a, payload.length]), payload])); continue; }
        if (op === 0x1) { try { onViewerMessage(JSON.parse(payload.toString()), sock); } catch {} }
      }
    });
    const close = () => {
      if (!sockets.delete(sock)) return;
      engine.consumers--;
      if (sock.animates) engine.animatedViewers--;
      // fall back to the most recent remaining viewer's size, or the configured size
      const rest = [...sockets].filter((s) => s.vp).sort((a, b) => a.vp.at - b.vp.at).pop();
      if (rest || sockets.size === 0) { clearTimeout(vpTimer); engine.setViewport(rest ? rest.vp : null).catch(() => {}); }
      else engine.syncStreaming();
    };
    sock.on("close", close); sock.on("error", close);
  });

  let vpTimer = null;
  async function onViewerMessage(m, sock) {
    if (m.type === "hello") { if (m.animatesCursor && !sock.animates) { sock.animates = true; engine.animatedViewers++; } return; }
    if (m.type === "arrived") { engine.cursorArrived(m.seq); return; }
    if (m.type === "viewport") {
      sock.vp = { w: m.w, h: m.h, dpr: Math.min(m.dpr || 1, 2), at: Date.now() };
      clearTimeout(vpTimer);
      vpTimer = setTimeout(() => engine.setViewport(sock.vp).catch(() => {}), 120);
      return;
    }
    if (m.type === "nav") { await navigate(m).catch(() => {}); return; }
    await engine.active?.userInput(m).catch(() => {});
  }

  async function navigate(b) {
    if (b.action === "new") return engine.newTab(b.url || "about:blank");
    const tab = await engine.tab(b.tabId);
    if (b.action === "goto") await tab.goto(b.url);
    if (b.action === "back") await tab.back();
    if (b.action === "forward") await tab.forward();
    if (b.action === "reload") await tab.reload();
    if (b.action === "close") await tab.close();
  }

  // each part ends with the next boundary so the browser paints it immediately,
  // instead of waiting for a following frame that a static page never sends
  const writeFrame = (res, buf) => {
    res.write(`Content-Type: image/jpeg\r\nContent-Length: ${buf.length}\r\n\r\n`);
    res.write(buf); res.write("\r\n--f\r\n");
  };

  server.once("close", () => { companion?.off("change", changed); agentHub?.off("change", changed); });

  return {
    server,
    listen: () => new Promise((resolve) => {
      server.once("error", (e) => resolve({ error: e.message }));
      server.listen(config().web.port, "127.0.0.1", () => resolve({ port: server.address().port }));
    }),
    frame(buf) {
      latest = buf;
      for (const v of viewers) writeFrame(v, buf);
      for (const s of sockets) if (s.writableLength < 1_500_000) wsSend(s, buf, true);   // drop frames for slow clients
    },
    cursor(c) {
      lastCursor = { type: "cursor", ...c, kind: "move" };
      sse({ type: "cursor", ...c });
      for (const s of sockets) wsJson(s, { type: "cursor", ...c });
    },
    tabs() { const st = state(); sse(st); for (const s of sockets) wsJson(s, st); },
  };
}
