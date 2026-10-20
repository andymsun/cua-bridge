#!/usr/bin/env node
// MCP stdio shim - the only thing a harness registers. Works with any MCP client
// (Claude Code, Antigravity, Gemini CLI, Cursor, Codex...). Starts the shared
// daemon if needed and forwards `js` calls to this session's REPL there.
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import * as fs from "node:fs";
import * as http from "node:http";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { ensureDirs, paths } from "./lib/config.mjs";
import { hostInfo } from "./lib/host.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const SESSION = randomUUID();
const HOST = hostInfo();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let closing = false, clientInfo = {}, registration = null;

function post(route, body, timeoutMs = 600000) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body ?? {});
    const req = http.request({ socketPath: paths.daemonSock, path: route, method: "POST",
      headers: { "content-type": "application/json", "content-length": Buffer.byteLength(data) } }, (res) => {
      let b = ""; res.setEncoding("utf8"); res.on("data", (c) => (b += c));
      res.on("end", () => { try { resolve(JSON.parse(b)); } catch (e) { reject(e); } });
      res.on("error", reject);
    });
    const timer = setTimeout(() => req.destroy(new Error("daemon request timed out")), timeoutMs);
    req.once("close", () => clearTimeout(timer));
    req.on("error", reject);
    req.end(data);
  });
}

function register() {
  if (closing) return Promise.resolve(false);
  if (!registration) registration = post("/agent/register", { session: SESSION, client: clientInfo, host: HOST }, 750)
    .then(result => result.ok === true).catch(() => false).finally(() => { registration = null; });
  return registration;
}

async function ensureDaemon() {
  if (closing) return;
  try { await post("/health", {}, 2000); return; } catch {}
  if (closing) return;
  ensureDirs();
  const out = fs.openSync(paths.log, "a");
  spawn(process.execPath, [path.join(here, "daemon.mjs")], { detached: true, stdio: ["ignore", out, out] }).unref();
  for (let i = 0; i < 50; i++) {
    await sleep(100); if (closing) return;
    try { await post("/health", {}, 1000); return; } catch {}
  }
  throw new Error(`cua daemon failed to start; see ${paths.log}`);
}

const INSTRUCTIONS = fs.readFileSync(path.join(here, "tool-description.md"), "utf8");

const TOOLS = [
  {
    name: "js",
    description: INSTRUCTIONS,
    inputSchema: {
      type: "object", additionalProperties: false, required: ["code"],
      properties: {
        code: { type: "string", description: "JavaScript to run. Top-level await works; `const x = ...` at the top level persists to later calls." },
        timeout_ms: { type: "integer", minimum: 1, description: "Timeout in ms (default from settings, 30000)." },
        title: { type: "string", maxLength: 80, description: "Short user-facing description of what the code does." },
      },
    },
  },
  {
    name: "js_reset",
    description: "Discard this session's JavaScript bindings. Browser tabs and apps are left as they are.",
    inputSchema: { type: "object", additionalProperties: false, properties: {} },
  },
];

const send = (msg) => { if (!closing) process.stdout.write(JSON.stringify(msg) + "\n"); };

async function handle(msg) {
  const { id, method, params } = msg;
  if (closing || id === undefined) return;            // notification or closed transport
  try {
    if (method === "initialize") {
      const field = value => typeof value === "string" ? value.slice(0, 80) : "";
      clientInfo = { name: field(params?.clientInfo?.name), version: field(params?.clientInfo?.version) };
      send({ jsonrpc: "2.0", id, result: {
        protocolVersion: params?.protocolVersion ?? "2025-06-18",
        capabilities: { tools: {} },
        serverInfo: { name: "cua", version: "2.0.0" },
        instructions: "Background browser and computer use through one persistent `js` tool. Your cursor-free, window-free control surface: see the js tool description.",
      } });
      void register();
      return;
    }
    if (method === "ping") return send({ jsonrpc: "2.0", id, result: {} });
    if (method === "tools/list") return send({ jsonrpc: "2.0", id, result: { tools: TOOLS } });
    if (method === "tools/call") {
      await ensureDaemon();
      if (closing) return;
      await register();
      if (closing) return;
      if (params.name === "js_reset") {
        await post("/reset", { session: SESSION });
        return send({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: "session reset" }] } });
      }
      if (params.name === "js") {
        const a = params.arguments ?? {};
        const r = await post("/call", { session: SESSION, code: a.code, timeout_ms: a.timeout_ms, host: HOST });
        return send({ jsonrpc: "2.0", id, result: r });
      }
      return send({ jsonrpc: "2.0", id, error: { code: -32602, message: `unknown tool ${params.name}` } });
    }
    send({ jsonrpc: "2.0", id, error: { code: -32601, message: `method not found: ${method}` } });
  } catch (e) {
    send({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: `cua error: ${e.message}` }], isError: true } });
  }
}

let buf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (d) => {
  buf += d;
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
    if (line) { try { handle(JSON.parse(line)); } catch {} }
  }
});
// End this session's REPL and cursor however the harness stops us: closed stdin or a signal.
const end = async () => {
  if (closing) return;
  closing = true;
  await registration;
  try { await post("/end", { session: SESSION }, 2000); } catch {}
  process.exit(0);
};
process.stdin.on("end", end);
for (const signal of ["SIGTERM", "SIGHUP", "SIGINT"]) process.on(signal, end);
