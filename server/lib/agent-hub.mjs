import { EventEmitter } from "node:events";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { cleanHost } from "./host.mjs";

const text = (value, length) => typeof value === "string" ? value.replace(/\s+/g, " ").trim().slice(0, length) : "";
const validID = value => typeof value === "string" && /^[\w][\w:.-]{0,127}$/.test(value);
const states = new Set(["unknown", "idle", "busy", "awaiting_user", "error", "exited"]);
const capabilities = (observe = false, openHost = false) => ({ observe, openHost, resume: false, attach: false, send: false, interrupt: false });

function providers(env, home) {
  const find = names => {
    for (const name of names) for (const folder of (env.PATH ?? "").split(path.delimiter).filter(Boolean)) {
      const candidate = path.resolve(folder, name);
      try { if (fs.statSync(candidate).isFile()) { fs.accessSync(candidate, fs.constants.X_OK); return candidate; } } catch {}
    }
    return null;
  };
  const rows = [
    ["andy", "Andy Code", ["andy"]], ["claude", "Claude Code", ["claude"]],
    ["codex", "Codex", ["codex"]], ["agy", "Antigravity", ["agy"]],
    ["opencode", "OpenCode", ["opencode"]], ["cursor", "Cursor Agent", ["cursor-agent", "agent"]],
  ].map(([id, name, commands]) => {
    const executable = find(commands);
    return { id, name, available: !!executable, executable, capabilities: capabilities(), detail: executable ? "Installed CLI; not attached to a conversation." : "CLI not found on PATH." };
  });
  for (const [id, name, bundle] of [["cursor-ide", "Cursor IDE", "Cursor.app"], ["clicky", "HeyClicky", "Clicky.app"]]) {
    const location = [path.join(home, "Applications", bundle), path.join("/Applications", bundle)].find(p => {
      try { return fs.statSync(p).isDirectory(); } catch { return false; }
    });
    rows.push({ id, name, available: !!location, capabilities: capabilities(), detail: location ? "Installed app; no conversation connection." : "App not found." });
  }
  rows.push({ id: "cua", name: "CUA bridge", available: true, capabilities: capabilities(), detail: "Bundled computer-use tools; native permissions are separate." });
  return rows;
}

export class AgentHub extends EventEmitter {
  #clients = new Map();
  #ended = new Set();
  #closed = false;
  constructor({ now = Date.now, ttlMs = 120000, env = process.env, home = os.homedir() } = {}) {
    super();
    this.now = now;
    this.ttlMs = ttlMs;
    this.providers = providers(env, home);
    this.timer = setInterval(() => {
      let changed = false;
      for (const client of this.#clients.values()) if (!client.stale && this.now() - client.updatedAt >= this.ttlMs) { client.stale = true; changed = true; }
      if (changed) this.changed();
    }, Math.max(250, Math.min(30000, ttlMs / 2)));
    this.timer.unref?.();
  }
  changed() { this.emit("change", this.snapshot()); }
  register(id, metadata = {}) {
    if (!validID(id)) throw new Error("Invalid agent session ID");
    if (this.#closed || this.#ended.has(id)) return false;
    const previous = this.#clients.get(id);
    if (!previous && this.#clients.size >= 64) throw new Error("Too many connected CUA clients");
    const client = { name: text(metadata?.client?.name, 80) || "CUA client", version: text(metadata?.client?.version, 80) };
    this.#clients.set(id, { id, name: client.name, client, host: cleanHost(metadata?.host), status: previous && !previous.stale ? previous.status : "idle", updatedAt: this.now(), stale: false, source: "mcp" });
    this.changed(); return true;
  }
  activity(id, status) {
    const client = this.#clients.get(id);
    if (this.#closed || !client) return false;
    if (!states.has(status)) throw new Error("Invalid agent activity state");
    client.status = status; client.updatedAt = this.now(); client.stale = false;
    this.changed(); return true;
  }
  end(id) {
    if (!validID(id) || this.#closed) return false;
    this.#ended.add(id);
    if (this.#ended.size > 256) this.#ended.delete(this.#ended.values().next().value);
    const removed = this.#clients.delete(id);
    if (removed) this.changed();
    return removed;
  }
  snapshot() {
    const now = this.now();
    return {
      clients: [...this.#clients.values()].map(client => {
        const stale = client.stale || now - client.updatedAt >= this.ttlMs;
        const host = client.host ? { ancestors: [...client.host.ancestors], bundleId: client.host.bundleId } : null;
        return { ...client, client: { ...client.client }, host, stale, status: stale ? "unknown" : client.status,
          capabilities: capabilities(true, !stale && !!host?.bundleId && host.ancestors.length > 0) };
      }),
      providers: this.providers.map(provider => ({ ...provider, capabilities: { ...provider.capabilities } })),
    };
  }
  close() {
    if (this.#closed) return;
    this.#closed = true; clearInterval(this.timer); this.#clients.clear(); this.#ended.clear(); this.emit("close");
  }
}
