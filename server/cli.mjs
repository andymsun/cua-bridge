#!/usr/bin/env node
// cua CLI: status | start | stop | restart | ui | settings | doctor | use | toggle
import { execFile, execFileSync, spawn } from "node:child_process";
import * as fs from "node:fs";
import * as http from "node:http";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { config, ensureDirs, paths } from "./lib/config.mjs";
import { findExecutable } from "./lib/browser.mjs";
import { agentApp } from "./lib/native.mjs";
import { hudApp } from "./lib/hud.mjs";
import { MODES, applyMode, currentMode } from "./lib/harness.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function post(route, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const req = http.request({ socketPath: paths.daemonSock, path: route, method: "POST" }, (res) => {
      let b = ""; res.on("data", (c) => (b += c)); res.on("end", () => { try { resolve(JSON.parse(b)); } catch (e) { reject(e); } });
    });
    req.setTimeout(timeoutMs, () => req.destroy(new Error("timeout")));
    req.on("error", reject); req.end("{}");
  });
}
const up = () => post("/health", 1500).then(() => true, () => false);

async function start() {
  if (await up()) return;
  ensureDirs();
  const out = fs.openSync(paths.log, "a");
  spawn(process.execPath, [path.join(here, "daemon.mjs")], { detached: true, stdio: ["ignore", out, out] }).unref();
  for (let i = 0; i < 50; i++) { await sleep(100); if (await up()) return; }
  throw new Error(`daemon did not start; see ${paths.log}`);
}

const cmd = process.argv[2] ?? "status";
const ok = (b, s) => `${b ? "✓" : "✗"} ${s}`;

switch (cmd) {
  case "start": await start(); console.log("cua daemon running"); break;
  case "stop": if (await up()) await post("/shutdown").catch(() => {}); console.log("cua daemon stopped"); break;
  case "restart": if (await up()) { await post("/shutdown").catch(() => {}); await sleep(600); } await start(); console.log("cua daemon restarted"); break;
  case "ui": case "settings": {
    await start();
    const s = await post("/status");
    const url = cmd === "ui" ? s.urls.browser : s.urls.settings;
    execFile("open", [url]); console.log(url);
    break;
  }
  case "status": {
    if (!(await up())) { console.log("daemon: not running (starts automatically on first tool call; `cua start` to start now)"); break; }
    const s = await post("/status", 15000);
    console.log(`daemon: pid ${s.pid}, ${s.sessions} session(s)`);
    console.log(`browser: ${s.browser.running ? `running, ${s.browser.tabs} tab(s)` : "idle"}`);
    console.log(`native agent: ${s.agent.reachable ? `accessibility ${s.agent.accessibility ? "granted" : "NOT granted"}, screen recording ${s.agent.screenRecording ? "granted" : "NOT granted"}` : "not running"}`);
    console.log(`agents use: ${MODES[currentMode()]}`);
    console.log(`live browser: ${s.urls.browser}\nsettings: ${s.urls.settings}`);
    break;
  }
  case "use": case "toggle": {
    const arg = process.argv[3];
    const now = currentMode();
    if (cmd === "use" && !arg) {
      console.log(`agents use: ${MODES[now]}`);
      console.log("switch with: cua use cua | cua use builtin | cua toggle");
      break;
    }
    const next = cmd === "toggle" ? (now === "cua" ? "builtin" : "cua") : arg === "--apply" ? now : arg;
    for (const line of applyMode(next)) console.log("  " + line);
    console.log(`agents use: ${MODES[next]}. New agent sessions pick this up; restart open harness windows to apply it there.`);
    break;
  }
  case "doctor": {
    const node = Number(process.versions.node.split(".")[0]);
    console.log(ok(node >= 22, `node ${process.versions.node} (need 22+ for built-in WebSocket)`));
    let exe = null; try { exe = findExecutable(); } catch {}
    console.log(ok(!!exe, `browser: ${exe ?? "none found - set browser.executable"}`));
    console.log(ok(fs.existsSync(agentApp), `native agent: ${agentApp}`));
    console.log(ok(fs.existsSync(hudApp), `HUD: ${hudApp}`));
    console.log(ok(fs.existsSync(paths.config), `config: ${paths.config}`));
    const harnesses = [];
    try { if (execFileSync("claude", ["mcp", "get", "cua"], { stdio: ["ignore", "pipe", "ignore"] }).toString().includes("shim.mjs")) harnesses.push("Claude Code"); } catch {}
    for (const [name, f] of [["Antigravity", "~/.gemini/antigravity/mcp_config.json"], ["Antigravity IDE", "~/.gemini/antigravity-ide/mcp_config.json"],
      ["Gemini CLI", "~/.gemini/settings.json"], ["Cursor", "~/.cursor/mcp.json"]]) {
      try { if (JSON.parse(fs.readFileSync(f.replace("~", process.env.HOME), "utf8")).mcpServers?.cua) harnesses.push(name); } catch {}
    }
    console.log(ok(harnesses.length > 0, `registered in: ${harnesses.join(", ") || "no harness"}`));
    // permissions can only be read from a running agent - start it (in the background) if needed
    await start();
    let s = await post("/status", 15000);
    if (!s.agent.reachable && fs.existsSync(agentApp)) {
      execFile("open", ["-g", "-j", agentApp]);
      for (let i = 0; i < 30 && !s.agent.reachable; i++) { await sleep(200); s = await post("/status", 15000); }
    }
    if (!s.agent.reachable) console.log("✗ CuaAgent did not start - check it is installed");
    else {
      console.log(ok(s.agent.accessibility, "Accessibility granted to CuaAgent (native apps)"));
      console.log(ok(s.agent.screenRecording, "Screen Recording granted to CuaAgent (native screenshots, HUD for apps)"));
    }
    break;
  }
  default:
    console.log("usage: cua [status|start|stop|restart|ui|settings|doctor|use [cua|builtin]|toggle]");
}
process.exit(0);
