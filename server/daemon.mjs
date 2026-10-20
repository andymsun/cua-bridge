#!/usr/bin/env node
// cua daemon: one per user. Owns the background browser, the native-app agent
// connection, the HUD feed and the local web UI. Harness shims (shim.mjs) talk to
// it over a unix socket; each shim gets its own persistent REPL session here.
import { randomBytes } from "node:crypto";
import * as fs from "node:fs";
import * as http from "node:http";
import { config, ensureDirs, paths } from "./lib/config.mjs";
import { BrowserEngine } from "./lib/browser.mjs";
import { NativeClient } from "./lib/native.mjs";
import { Hud } from "./lib/hud.mjs";
import { Pointers } from "./lib/pointer.mjs";
import { Companion } from "./lib/companion.mjs";
import { AgentHub } from "./lib/agent-hub.mjs";
import { Session } from "./lib/repl.mjs";
import { makeApiFactory } from "./lib/api.mjs";
import { startWeb } from "./lib/web.mjs";
import { PlaywrightBridge } from "./lib/pw.mjs";
import { currentMode } from "./lib/harness.mjs";

ensureDirs();
const log = (...a) => fs.appendFileSync(paths.log, `${new Date().toISOString()} ${a.join(" ")}\n`);

let token;
try { token = fs.readFileSync(paths.token, "utf8").trim(); } catch {}
if (!token) { token = randomBytes(16).toString("hex"); fs.writeFileSync(paths.token, token, { mode: 0o600 }); }

let web = null;
const hud = new Hud();
const pointers = new Pointers();
const engine = new BrowserEngine({
  onFrame: (buf) => { hud.frame(buf); web?.frame(buf); },
  onCursor: (c) => { hud.cursor(c); web?.cursor(c); },
  onTouch: () => hud.setSource("browser"),
  onTabs: () => web?.tabs(),
  onClosed: () => log("browser connection closed"),
});
const native = new NativeClient({
  onActive: (app) => hud.setSource("native", app),
  onCursor: (c) => { hud.cursor(c); web?.cursor(c); },
});
hud.attachNative(native);
// Companion reads must not activate the preview HUD or start automatic screen capture.
const companionNative = new NativeClient();
const companion = new Companion({ pointers, native: companionNative });
const agentHub = new AgentHub();
const calls = new Map();

// the HUD is a screencast consumer whenever it's enabled
let hudConsumer = false;
setInterval(() => {
  const want = !!config().hud.enabled;
  if (want !== hudConsumer) { engine.consumers += want ? 1 : -1; hudConsumer = want; engine.syncStreaming(); }
}, 1000).unref();

const urls = () => {
  const port = web?.port ?? config().web.port;
  return { browser: `http://127.0.0.1:${port}/?t=${token}`, settings: `http://127.0.0.1:${port}/settings?t=${token}`, companion: `http://127.0.0.1:${port}/companion?t=${token}` };
};
const pw = new PlaywrightBridge(engine);
const makeApi = makeApiFactory({ engine, native, hud, urls, pw, pointers });
const sessions = new Map();
const session = (id) => { if (!sessions.has(id)) sessions.set(id, new Session(id, makeApi)); return sessions.get(id); };

// The tab the agent last drove, for harness status lines (title and URL only).
function activeTab() {
  if (!engine.running || !engine.active) return null;
  const t = engine.list().find((x) => x.id === engine.active.id);
  return t ? { title: t.title, url: t.url } : null;
}

async function status() {
  let agent = { reachable: false };
  try { agent = await native.status(); } catch (e) { agent.error = e.message; }
  return {
    pid: process.pid, browser: { running: engine.running, tabs: engine.running ? engine.list().length : 0, active: activeTab() },
    hud: { enabled: !!config().hud.enabled, source: hud.source },
    agent, sessions: sessions.size, urls: urls(), config: paths.config, mode: currentMode(),
  };
}

// ---- control socket (shims) ----
try { fs.unlinkSync(paths.daemonSock); } catch {}
const control = http.createServer(async (req, res) => {
  let b = "", oversized = false;
  req.setEncoding("utf8"); req.on("data", (c) => {
    if (oversized) return;
    b += c;
    if (req.url === "/agent/register" && Buffer.byteLength(b) > 16384) { oversized = true; b = ""; }
  });
  await new Promise((r) => req.on("end", r));
  const reply = (code, body) => { res.writeHead(code, { "content-type": "application/json" }); res.end(JSON.stringify(body)); };
  try {
    if (oversized) return reply(413, { error: "Agent metadata is too large" });
    const msg = b ? JSON.parse(b) : {};
    if (req.url === "/agent/register") return reply(200, { ok: agentHub.register(msg.session, { client: msg.client, host: msg.host }) });
    if (req.url === "/companion/tool") return reply(200, await companion.tool(msg.id, msg.key, msg.name, msg.args));
    if (req.url === "/health") return reply(200, { ok: true, pid: process.pid });
    if (req.url === "/status") return reply(200, await status());
    if (req.url === "/call") {
      const active = calls.get(msg.session) ?? { tail: Promise.resolve(), pending: 0, error: false };
      calls.set(msg.session, active); active.pending++;
      agentHub.activity(msg.session, "busy");
      const run = active.tail.catch(() => {}).then(() => {
        if (calls.get(msg.session) !== active) throw new Error("CUA session ended");
        hud.setHost(msg.host);
        const cfg = config().repl;
        return session(msg.session).run(msg.code, { timeoutMs: msg.timeout_ms ?? cfg.timeoutMs, maxOutputChars: cfg.maxOutputChars });
      });
      active.tail = run;
      try {
        const r = await run;
        active.error ||= !!r.isError;
        return reply(200, r);
      } catch (error) { active.error = true; throw error; }
      finally {
        if (--active.pending === 0 && calls.get(msg.session) === active) {
          calls.delete(msg.session);
          agentHub.activity(msg.session, active.error ? "error" : "idle");
        }
      }
    }
    if (req.url === "/reset") { session(msg.session).reset(); return reply(200, { ok: true }); }
    if (req.url === "/end") { agentHub.end(msg.session); calls.delete(msg.session); await sessions.get(msg.session)?.dispose(); sessions.delete(msg.session); return reply(200, { ok: true }); }
    if (req.url === "/shutdown") { reply(200, { ok: true }); return shutdown(); }
    reply(404, { error: "unknown" });
  } catch (e) { reply(500, { error: e.message }); }
});
control.listen(paths.daemonSock, () => { fs.chmodSync(paths.daemonSock, 0o600); log(`daemon up pid ${process.pid}`); });

web = startWeb({ engine, native, hud, token, status, companion, agentHub });
web.listen().then((r) => {
  if (r.error) log(`web UI not started: ${r.error}`); else { web.port = r.port; log(`web UI on ${r.port}`); }
});

async function shutdown() {
  log("shutting down");
  await engine.shutdown().catch(() => {});
  agentHub.close(); calls.clear();
  companion.close(); companionNative.close();
  pointers.shutdown();
  try { fs.unlinkSync(paths.daemonSock); } catch {}
  process.exit(0);
}
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
process.on("uncaughtException", (e) => log("uncaught", e.stack ?? e));
process.on("unhandledRejection", (e) => log("unhandled", e?.stack ?? e));
