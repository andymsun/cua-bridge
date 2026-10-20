#!/usr/bin/env node
// Restricted companion tools. Never exposes the full REPL to an autonomous desktop turn.
import http from "node:http";
import { COMPANION_TOOLS } from "./lib/companion.mjs";
import { paths } from "./lib/config.mjs";

const send = (id, result) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
const call = (name, args) => new Promise((resolve, reject) => {
  const data = JSON.stringify({ id: process.env.CUA_COMPANION_ID, key: process.env.CUA_COMPANION_KEY, name, args });
  const req = http.request({ socketPath: paths.daemonSock, path: "/companion/tool", method: "POST", headers: { "content-type": "application/json", "content-length": Buffer.byteLength(data) } }, res => {
    let body = ""; res.setEncoding("utf8");
    res.on("data", c => { body += c; if (body.length > 1024 * 1024) req.destroy(new Error("Tool response too large")); });
    res.on("end", () => { try { const result = JSON.parse(body); if (result.error) reject(new Error(result.error)); else resolve(result); } catch (e) { reject(e); } });
  });
  req.setTimeout(150000, () => req.destroy(new Error("Companion tool timed out")));
  req.on("error", reject); req.end(data);
});
async function handle({ id, method, params }) {
  if (id === undefined) return;
  if (method === "initialize") return send(id, { protocolVersion: params?.protocolVersion ?? "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "barista", version: "1.0.0" } });
  if (method === "ping") return send(id, {});
  if (method === "tools/list") return send(id, { tools: COMPANION_TOOLS });
  if (method !== "tools/call") return send(id, {});
  try {
    const result = await call(params.name, params.arguments ?? {});
    send(id, { content: [{ type: "text", text: typeof result === "string" ? result : JSON.stringify(result) }] });
  } catch (e) { send(id, { isError: true, content: [{ type: "text", text: e.message }] }); }
}
let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => {
  buffer += chunk;
  if (buffer.length > 256000) { process.stderr.write("Companion request too large\n"); process.exit(1); }
  let end;
  while ((end = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
    try { handle(JSON.parse(line)).catch(e => process.stderr.write(e.message + "\n")); } catch {}
  }
});
process.stdin.on("end", () => process.exit(0));
