// Minimal Chrome DevTools Protocol client over Node's built-in WebSocket.
// Flattened sessions: one browser connection, each tab addressed by sessionId.

export class CDP {
  #ws; #id = 0; #pending = new Map(); #handlers = new Map(); #any = new Set();
  closed = false;

  static async connect(url) {
    const c = new CDP();
    c.#ws = new WebSocket(url);
    await new Promise((res, rej) => {
      c.#ws.addEventListener("open", res, { once: true });
      c.#ws.addEventListener("error", () => rej(new Error(`CDP connect failed: ${url}`)), { once: true });
    });
    c.#ws.addEventListener("message", (e) => c.#onMessage(e.data));
    c.#ws.addEventListener("close", () => {
      c.closed = true;
      for (const { rej } of c.#pending.values()) rej(new Error("CDP connection closed"));
      c.#pending.clear();
      c.#emit("__close", {});
    });
    return c;
  }

  #onMessage(raw) {
    const msg = JSON.parse(typeof raw === "string" ? raw : raw.toString());
    if (msg.id !== undefined) {
      const p = this.#pending.get(msg.id);
      if (!p) return;
      this.#pending.delete(msg.id);
      msg.error ? p.rej(new Error(`${p.method}: ${msg.error.message}`)) : p.res(msg.result);
    } else if (msg.method) {
      this.#emit(msg.method, msg.params, msg.sessionId);
    }
  }

  #emit(method, params, sessionId) {
    for (const h of this.#any) { try { h(method, params, sessionId); } catch {} }
    for (const h of this.#handlers.get(method) ?? []) {
      try { h(params, sessionId); } catch {}
    }
  }

  send(method, params = {}, sessionId, timeoutMs = 30000) {
    if (this.closed) return Promise.reject(new Error("CDP connection closed"));
    const id = ++this.#id;
    const msg = { id, method, params };
    if (sessionId) msg.sessionId = sessionId;
    return new Promise((res, rej) => {
      const t = setTimeout(() => {
        this.#pending.delete(id);
        rej(new Error(`${method}: timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      this.#pending.set(id, {
        method,
        res: (v) => { clearTimeout(t); res(v); },
        rej: (e) => { clearTimeout(t); rej(e); },
      });
      this.#ws.send(JSON.stringify(msg));
    });
  }

  on(method, handler) {
    if (!this.#handlers.has(method)) this.#handlers.set(method, new Set());
    this.#handlers.get(method).add(handler);
    return () => this.#handlers.get(method)?.delete(handler);
  }

  /** Every event, for raw-CDP event buffers. Returns an unsubscribe function. */
  onAny(handler) { this.#any.add(handler); return () => this.#any.delete(handler); }

  close() { try { this.#ws.close(); } catch {} }
}
