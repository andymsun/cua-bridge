// Local web UI: the live built-in browser (Codex-style in-app browser you can open
// in any browser pane - including the Claude app's) and the settings page.
// Bound to 127.0.0.1 and gated by a per-install token.
import * as fs from "node:fs";
import * as http from "node:http";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { config, defaults, saveConfig } from "./config.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const page = (name) => fs.readFileSync(path.join(here, "..", "web", name), "utf8");

export function startWeb({ engine, native, hud, token, status }) {
  const viewers = new Set();      // MJPEG responses
  const listeners = new Set();    // SSE responses
  let latest = null;
  let lastCursor = null;

  const authed = (req, url) => url.searchParams.get("t") === token || req.headers["x-cua-token"] === token;
  const json = (res, code, body) => { res.writeHead(code, { "content-type": "application/json" }); res.end(JSON.stringify(body)); };
  const body = (req) => new Promise((r) => { let b = ""; req.on("data", (c) => (b += c)); req.on("end", () => { try { r(JSON.parse(b || "{}")); } catch { r({}); } }); });
  const sse = (ev) => { const line = `data: ${JSON.stringify(ev)}\n\n`; for (const l of listeners) l.write(line); };

  const state = () => ({
    type: "state", running: engine.running, tabs: engine.running ? engine.list() : [],
    active: engine.active?.id ?? null, source: hud.source,
  });

  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, "http://x");
    if (!authed(req, url)) { res.writeHead(401); return res.end("Missing or wrong token. Open the URL from cua.ui() or the settings command."); }
    try {
      switch (`${req.method} ${url.pathname}`) {
        case "GET /":
          res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
          return res.end(page("browser.html").replaceAll("{{TOKEN}}", token));
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
          const b = await body(req);
          if (b.action === "new") await engine.newTab(b.url || "about:blank");
          else {
            const tab = await engine.tab(b.tabId);
            if (b.action === "goto") await tab.goto(b.url);
            if (b.action === "back") await tab.back();
            if (b.action === "forward") await tab.forward();
            if (b.action === "reload") await tab.reload();
            if (b.action === "close") await tab.close();
          }
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
        case "POST /api/hud/show":
          hud.launch(true); return json(res, 200, { ok: true });
        default:
          res.writeHead(404); return res.end("not found");
      }
    } catch (e) { return json(res, 500, { error: e.message }); }
  });

  // each part ends with the next boundary so the browser paints it immediately,
  // instead of waiting for a following frame that a static page never sends
  const writeFrame = (res, buf) => {
    res.write(`Content-Type: image/jpeg\r\nContent-Length: ${buf.length}\r\n\r\n`);
    res.write(buf); res.write("\r\n--f\r\n");
  };

  return {
    server,
    listen: () => new Promise((resolve) => {
      server.once("error", (e) => resolve({ error: e.message }));
      server.listen(config().web.port, "127.0.0.1", () => resolve({ port: server.address().port }));
    }),
    frame(buf) { latest = buf; for (const v of viewers) writeFrame(v, buf); },
    cursor(c) { lastCursor = { type: "cursor", ...c, kind: "move" }; sse({ type: "cursor", ...c }); },
    tabs() { sse(state()); },
  };
}
