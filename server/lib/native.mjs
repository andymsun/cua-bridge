// Client for CuaAgent.app, the Swift helper that holds the Accessibility and
// Screen Recording grants. Talks JSON lines over a unix socket. The agent acts
// through the Accessibility API and process-targeted events only - it never
// moves the user's cursor or sends global input.
import { execFile } from "node:child_process";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";
import { config, paths } from "./config.mjs";
import { render, diff } from "./snapshot.mjs";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export const agentApp = process.env.CUA_AGENT_APP ?? path.join(os.homedir(), "Applications/CuaAgent.app");

export class NativeClient {
  #sock = null; #buf = ""; #id = 0; #pending = new Map(); #connecting = null;

  constructor(hooks = {}) { this.hooks = hooks; }

  get connected() { return !!this.#sock && !this.#sock.destroyed; }

  async ensure() {
    if (this.#sock && !this.#sock.destroyed) return;
    this.#connecting ??= this.#connect().finally(() => { this.#connecting = null; });
    return this.#connecting;
  }

  async #connect() {
    for (let attempt = 0; attempt < 60; attempt++) {
      try { await this.#open(); return; } catch {}
      if (attempt === 0) execFile("open", ["-g", "-j", agentApp], () => {});   // background, never activates
      await sleep(150);
    }
    throw new Error(`CuaAgent is not reachable. Is ${agentApp} installed?`);
  }

  #open() {
    return new Promise((res, rej) => {
      const s = net.createConnection(paths.agentSock);
      s.once("connect", () => { this.#sock = s; res(); });
      s.once("error", rej);
      s.on("data", (d) => this.#onData(d));
      s.on("close", () => {
        for (const p of this.#pending.values()) p.rej(new Error("CuaAgent disconnected"));
        this.#pending.clear();
        this.#sock = null;
      });
    });
  }

  #onData(d) {
    this.#buf += d.toString();
    let i;
    while ((i = this.#buf.indexOf("\n")) >= 0) {
      const line = this.#buf.slice(0, i); this.#buf = this.#buf.slice(i + 1);
      if (!line.trim()) continue;
      const msg = JSON.parse(line);
      const p = this.#pending.get(msg.id);
      if (!p) continue;
      this.#pending.delete(msg.id);
      msg.ok ? p.res(msg.result) : p.rej(new Error(msg.error));
    }
  }

  async req(cmd, args = {}, timeoutMs = 20000) {
    await this.ensure();
    const id = ++this.#id;
    return new Promise((res, rej) => {
      const t = setTimeout(() => { this.#pending.delete(id); rej(new Error(`CuaAgent ${cmd}: timed out`)); }, timeoutMs);
      this.#pending.set(id, { res: (v) => { clearTimeout(t); res(v); }, rej: (e) => { clearTimeout(t); rej(e); } });
      this.#sock.write(JSON.stringify({ id, cmd, ...args }) + "\n");
    });
  }

  /** Report on the agent without launching it (launching triggers permission prompts). */
  async status() {
    if (!this.connected) { try { await this.#open(); } catch { return { reachable: false }; } }
    return { reachable: true, ...(await this.req("status")) };
  }
  apps() { return this.req("apps"); }
  async app(query) {
    if (!config().native.enabled) throw new Error("Native app control is disabled in settings");
    const info = await this.req("resolve", { query: String(query) });
    return new App(this, info);
  }
}

export class App {
  #client; #baseline = null; #gen = 0;
  constructor(client, info) { this.#client = client; this.info = info; }
  get pid() { return this.info.pid; }
  get name() { return this.info.name; }

  #touch(center, kind = "click") {
    this.#client.hooks.onActive?.(this);
    if (center) this.#client.hooks.onCursor?.({ ...center, kind, app: this.pid });
  }

  async #snap() {
    const cfg = config().native;
    const r = await this.#client.req("snapshot", { pid: this.pid, maxDepth: cfg.maxDepth });
    this.#gen = r.generation;
    return r;
  }

  async read({ full = false } = {}) {
    this.#touch();
    const cfg = config().native;
    const r = await this.#snap();
    const header = `App ${this.name} (pid ${this.pid}) · window "${r.title ?? ""}"`;
    const rendered = render(r.entries, { maxLines: cfg.maxLines, header, focused: r.focused });
    const d = !full && config().snapshot.diff ? diff(this.#baseline, r.entries, { maxLines: cfg.maxLines }) : null;
    this.#baseline = r.entries.map((e) => e.text);
    return d ? `${header}\n${d}` : rendered.text;
  }

  async find(query) {
    const r = await this.#snap();
    const re = query instanceof RegExp ? query : new RegExp(String(query).replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "i");
    return r.entries.map((e, i) => `${i + 1} ${e.text}`).filter((l) => re.test(l)).join("\n") || "(no match)";
  }

  async #act(cmd, args, kind) {
    const r = await this.#client.req(cmd, { pid: this.pid, generation: this.#gen, ...args });
    this.#touch(r?.center, kind);
    return r?.result;
  }

  // element index -> AX press; [x, y] (window points) -> AX hit-test, then press
  click(target) {
    return Array.isArray(target)
      ? this.#act("pressAt", { x: target[0], y: target[1] }, "click")
      : this.#act("press", { index: target }, "click");
  }
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
  async screenshot() {
    const r = await this.#client.req("screenshot", { pid: this.pid }, 30000);
    return Buffer.from(r.jpeg, "base64");
  }
}
