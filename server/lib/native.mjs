// Native input and capture share a process identity, window and snapshot.
import { execFile } from "node:child_process";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import { config, paths } from "./config.mjs";
import { render, diff } from "./snapshot.mjs";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export const agentApp = process.env.CUA_AGENT_APP ?? path.join(os.homedir(), "Applications/CuaAgent.app");

export class NativeClient {
  #sock = null; #id = 0; #pending = new Map(); #connecting = null;
  constructor(hooks = {}) { this.hooks = hooks; }
  get connected() { return !!this.#sock && !this.#sock.destroyed; }

  async ensure() {
    if (this.connected) return;
    this.#connecting ??= this.#connect().finally(() => { this.#connecting = null; });
    return this.#connecting;
  }
  async #connect() {
    for (let attempt = 0; attempt < 60; attempt++) {
      try { await this.#open(); return; } catch {}
      if (attempt === 0) execFile("open", ["-g", "-j", agentApp], () => {});
      await sleep(150);
    }
    throw new Error(`CuaAgent is not reachable. Is ${agentApp} installed?`);
  }
  #open() {
    return new Promise((resolve, reject) => {
      const socket = net.createConnection(paths.agentSock);
      let buffer = "";
      socket.setEncoding("utf8");
      socket.once("connect", () => { this.#sock = socket; resolve(); });
      socket.on("error", reject);
      socket.on("data", (data) => {
        buffer += data;
        if (buffer.length > (32 << 20)) { socket.destroy(new Error("Oversized CuaAgent response")); return; }
        let end;
        while ((end = buffer.indexOf("\n")) >= 0) {
          const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
          if (!line.trim()) continue;
          let msg;
          try { msg = JSON.parse(line); } catch { socket.destroy(new Error("Invalid CuaAgent response")); return; }
          const pending = this.#pending.get(msg.id);
          if (!pending || pending.socket !== socket) continue;
          this.#pending.delete(msg.id);
          msg.ok ? pending.resolve(msg.result) : pending.reject(Object.assign(new Error(msg.error), { code: msg.code ?? "native_error" }));
        }
      });
      socket.on("close", () => {
        for (const [id, pending] of this.#pending) if (pending.socket === socket) {
          this.#pending.delete(id); pending.reject(new Error("CuaAgent disconnected; actions were not retried"));
        }
        if (this.#sock === socket) this.#sock = null;
      });
    });
  }
  async req(cmd, args = {}, timeoutMs = 20000) {
    await this.ensure();
    return this.#request(cmd, args, timeoutMs);
  }
  #request(cmd, args, timeoutMs) {
    const id = ++this.#id, socket = this.#sock;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        socket.destroy();
        reject(new Error(`CuaAgent ${cmd}: timed out; an in-flight action may have occurred and was not retried`));
      }, timeoutMs);
      this.#pending.set(id, { socket,
        resolve: (value) => { clearTimeout(timer); resolve(value); },
        reject: (error) => { clearTimeout(timer); reject(error); },
      });
      socket.write(JSON.stringify({ ...args, id, cmd }) + "\n");
    });
  }
  /** Passive: never launches a helper, even when a connection fails mid-request. */
  async status() {
    if (!this.connected) { try { await this.#open(); } catch { return { reachable: false }; } }
    return { reachable: true, ...(await this.#request("status", {}, 3000)) };
  }
  close() { this.#sock?.destroy(); }
  views() { return this.req("views"); }
  detach(viewId) { return this.req("detach", { viewId }); }
  apps() { return this.req("apps"); }
  async app(query, { windowId } = {}) {
    if (!config().native.enabled) throw new Error("Native app control is disabled in settings");
    if (windowId != null && (!Number.isInteger(windowId) || windowId <= 0)) throw new Error("windowId must be a positive integer");
    const info = await this.req("resolve", { query: String(query) });
    return new App(this, { ...info, windowId });
  }
}

export class App {
  #client; #baseline = null; #gen = null;
  constructor(client, info) { this.#client = client; this.info = { ...info }; }
  get pid() { return this.info.pid; }
  get name() { return this.info.name; }
  get target() { return { pid: this.pid, process: this.info.process, windowId: this.info.windowId, generation: this.#gen }; }
  windows() { return this.#client.req("windows", this.target); }
  window(windowId) {
    if (!Number.isInteger(windowId) || windowId <= 0) throw new Error("windowId must be a positive integer");
    return new App(this.#client, { ...this.info, windowId });
  }
  #touch(center, kind = "click") {
    this.#client.hooks.onActive?.(this);
    if (center) this.#client.hooks.onCursor?.({ ...center, kind, app: this.pid, windowId: this.info.windowId });
  }
  async #snap() {
    const previous = this.#gen;
    const result = await this.#client.req("snapshot", { ...this.target, maxDepth: config().native.maxDepth });
    this.#gen = result.generation;
    this.info.windowId = result.windowId;
    if (previous) this.#client.req("releaseSnapshot", { generation: previous }).catch(() => {});
    return result;
  }
  async read({ full = false } = {}) {
    const result = await this.#snap();
    this.#touch();
    const header = `App ${this.name} (pid ${this.pid}) · window ${result.windowId} "${result.title ?? ""}"`;
    const rendered = render(result.entries, { maxLines: config().native.maxLines, header, focused: result.focused });
    const delta = !full && config().snapshot.diff ? diff(this.#baseline, result.entries, { maxLines: config().native.maxLines }) : null;
    this.#baseline = result.entries.map((entry) => entry.text);
    return delta ? `${header}\n${delta}` : rendered.text;
  }
  async find(query) {
    const result = await this.#snap();
    const re = query instanceof RegExp ? query : new RegExp(String(query).replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "i");
    return result.entries.map((entry, index) => `${index + 1} ${entry.text}`).filter((line) => re.test(line)).join("\n") || "(no match)";
  }
  async #act(cmd, args, kind) {
    if (!this.#gen) throw new Error("Read the selected window before acting (and read again after each action)");
    const target = this.target;
    this.lastActionAt = Date.now();
    // Never replay input, and invalidate indices even when an action partially fails.
    this.#gen = null;
    try {
      const result = await this.#client.req(cmd, { ...target, ...args });
      if (result?.center) this.#client.hooks.onCursor?.({ ...result.center, kind, app: this.pid, windowId: this.info.windowId });
      return result?.result;
    } finally { this.#client.req("releaseSnapshot", { generation: target.generation }).catch(() => {}); }
  }
  click(target, { button = "left", count = 1 } = {}) {
    return Array.isArray(target)
      ? this.#act("pressAt", { x: target[0], y: target[1], button, count }, "click")
      : this.#act("press", { index: target, button, count }, "click");
  }
  scrollAt(x, y, direction = "down", pages = 1) { return this.#act("scrollAt", { x, y, direction, pages }, "scroll"); }
  selectText(index, text, { prefix = "", suffix = "", selectionType = "text" } = {}) {
    return this.#act("selectText", { index, text: String(text), prefix, suffix, selectionType }, "move");
  }
  drag(from, to) { return this.#act("drag", { fromX: from[0], fromY: from[1], toX: to[0], toY: to[1] }, "click"); }
  setValue(index, value) { return this.#act("setValue", { index, value: String(value) }, "move"); }
  focus(index) { return this.#act("focus", { index }, "move"); }
  action(index, name) { return this.#act("action", { index, name }, "click"); }
  scroll(index, direction = "down", pages = 1) { return this.#act("scroll", { index, direction, pages }, "scroll"); }
  typeText(index, text) {
    return this.#act("typeText", { index: index ?? null, text: String(text), allowKeyEvents: config().native.allowKeyEvents }, "move");
  }
  pressKey(index, combo) {
    if (!config().native.allowKeyEvents) throw new Error("Key events are disabled in settings (native.allowKeyEvents)");
    return this.#act("pressKey", { index: index ?? null, combo }, "move");
  }
  async attach({ host } = {}) {
    if (!this.#gen) await this.#snap();
    return this.#client.req("attach", { ...this.target, ...(host ? { host } : {}) }, 30000);
  }
  async screenshot() {
    if (!this.#gen) await this.#snap();
    const result = await this.#client.req("screenshot", this.target, 30000);
    return Buffer.from(result.jpeg, "base64");
  }
}
