// Background browser engine. Launches (or reattaches to) a Chromium-family
// browser with its own profile and drives it entirely over CDP. All input is
// page-level (Input.dispatch*), so the user's real cursor and keyboard are never
// involved - with the default headless mode there is no window at all.
import { execFile, spawn } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import { CDP } from "./cdp.mjs";
import { config, expandHome, paths } from "./config.mjs";
import { parseCombo } from "./keys.mjs";
import { fromCdpAx, render, diff } from "./snapshot.mjs";

const CANDIDATES = [
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/Applications/Chromium.app/Contents/MacOS/Chromium",
  "/Applications/Helium.app/Contents/MacOS/Helium",
  "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const EDIT_COMMANDS = { a: "selectAll", c: "copy", v: "paste", x: "cut", z: "undo" };

export function findExecutable() {
  const cfg = config().browser.executable;
  if (cfg && cfg !== "auto") return cfg;
  const hit = CANDIDATES.find((p) => fs.existsSync(p));
  if (!hit) throw new Error("No Chromium-family browser found. Set browser.executable in settings.");
  return hit;
}

export class BrowserEngine {
  cdp = null;
  proc = null;
  tabs = new Map();          // targetId -> Tab
  active = null;             // Tab the agent last drove; the HUD follows it
  #starting = null;
  #streamingTab = null;
  consumers = 0;             // live-view clients + HUD; screencast runs only when > 0
  viewport = null;           // { w, h, dpr } requested by the live view; null = config viewport

  constructor(hooks = {}) { this.hooks = hooks; }

  get running() { return !!this.cdp && !this.cdp.closed; }

  async ensure() {
    if (this.running) return this;
    this.#starting ??= this.#start().finally(() => { this.#starting = null; });
    await this.#starting;
    return this;
  }

  async #start() {
    const cfg = config().browser;
    let wsUrl;
    if (cfg.attach) {
      wsUrl = await this.#wsFromHttp(cfg.attach);
    } else {
      const profile = path.join(paths.profiles, cfg.profile || "default");
      fs.mkdirSync(profile, { recursive: true });
      wsUrl = await this.#reuse(profile) ?? await this.#launch(profile, cfg);
    }
    this.cdp = await CDP.connect(wsUrl);
    this.cdp.on("__close", () => { this.tabs.clear(); this.active = null; this.hooks.onClosed?.(); });
    this.cdp.on("Target.targetCreated", ({ targetInfo: t }) => this.#onCreated(t));
    this.cdp.on("Target.targetDestroyed", ({ targetId }) => this.#onDestroyed(targetId));
    this.cdp.on("Target.targetInfoChanged", ({ targetInfo: t }) => {
      const tab = this.tabs.get(t.targetId);
      if (tab) { tab.info = t; this.hooks.onTabs?.(); }
    });
    await this.cdp.send("Target.setDiscoverTargets", { discover: true });
    const dl = expandHome(cfg.downloadsDir);
    if (dl) await this.cdp.send("Browser.setDownloadBehavior", { behavior: "allow", downloadPath: dl, eventsEnabled: true }).catch(() => {});
    const { targetInfos } = await this.cdp.send("Target.getTargets");
    for (const t of targetInfos.filter((t) => t.type === "page")) await this.#attach(t);
  }

  async #wsFromHttp(base) {
    const url = base.replace(/\/$/, "") + "/json/version";
    const r = await fetch(url).catch(() => null);
    if (!r?.ok) throw new Error(`Cannot reach browser at ${base}. Is it running with --remote-debugging-port?`);
    return (await r.json()).webSocketDebuggerUrl;
  }

  async #reuse(profile) {
    try {
      const [port] = fs.readFileSync(path.join(profile, "DevToolsActivePort"), "utf8").split("\n");
      return await this.#wsFromHttp(`http://127.0.0.1:${port}`);
    } catch { return null; }
  }

  async #launch(profile, cfg) {
    const exe = findExecutable();
    try { fs.unlinkSync(path.join(profile, "DevToolsActivePort")); } catch {}
    const { width, height } = cfg.viewport;
    const args = [
      "--remote-debugging-port=0", `--user-data-dir=${profile}`,
      "--no-first-run", "--no-default-browser-check", "--disable-features=Translate",
      "--hide-crash-restore-bubble", `--window-size=${width},${height}`,
      // keep rendering (and screencasting) while hidden or covered
      "--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding",
      "--disable-background-timer-throttling",
      ...(cfg.headless ? ["--headless=new"] : []),
      "about:blank",
    ];
    if (cfg.headless) {
      this.proc = spawn(exe, args, { stdio: "ignore", detached: false });
      this.proc.on("exit", () => { this.proc = null; });
    } else {
      // A real browser, launched hidden (-j) and without activation (-g): it never
      // takes focus or shows a window, but has a genuine browser fingerprint.
      const appBundle = exe.replace(/\/Contents\/MacOS\/[^/]+$/, "");
      execFile("open", ["-n", "-g", "-j", "-a", appBundle, "--args", ...args], () => {});
    }
    for (let i = 0; i < 100; i++) {
      await sleep(100);
      const ws = await this.#reuse(profile);
      if (ws) return ws;
    }
    throw new Error(`Browser did not start: ${exe}`);
  }

  async #attach(info) {
    if (this.tabs.has(info.targetId)) return this.tabs.get(info.targetId);
    const { sessionId } = await this.cdp.send("Target.attachToTarget", { targetId: info.targetId, flatten: true });
    const tab = new Tab(this, info, sessionId);
    tab.ready = tab.init();            // callers await this before driving the tab
    this.tabs.set(info.targetId, tab);
    await tab.ready;
    this.hooks.onTabs?.();
    return tab;
  }

  async #onCreated(t) {
    if (t.type !== "page" || this.tabs.has(t.targetId)) return;
    const tab = await this.#attach(t).catch(() => null);
    // popups opened by the tab we're driving become the driven tab, like Codex
    if (tab && t.openerId && t.openerId === this.active?.id) this.setActive(tab);
  }

  #onDestroyed(targetId) {
    const tab = this.tabs.get(targetId);
    if (!tab) return;
    this.tabs.delete(targetId);
    if (this.active === tab) this.setActive([...this.tabs.values()].pop() ?? null);
    if (this.#streamingTab === tab) this.#streamingTab = null;
    this.hooks.onTabs?.();
  }

  setActive(tab) {
    if (this.active === tab) return;
    this.active = tab;
    // headless: foregrounding is invisible and keeps the tab rendering. headed: never
    // raise the window - that would steal focus from the user.
    if (tab && config().browser.headless) tab.send("Page.bringToFront").catch(() => {});
    this.hooks.onActive?.(tab);
    tab?.applyViewport().catch(() => {});
    this.syncStreaming();
    this.hooks.onTabs?.();
  }

  /** Match page size to the live view so it fills the pane, like Codex's in-app browser. */
  async setViewport(vp) {
    this.viewport = vp;
    await this.active?.applyViewport().catch(() => {});
    await this.syncStreaming(true);
  }

  async syncStreaming(restart = false) {
    const want = this.consumers > 0 ? this.active : null;
    if (this.#streamingTab === want && !restart) return;
    const prev = this.#streamingTab;
    this.#streamingTab = want;
    if (prev) await prev.send("Page.stopScreencast").catch(() => {});
    if (want) {
      const s = config().stream;
      const vp = this.viewport, dpr = vp?.dpr ?? 1;
      await want.send("Page.startScreencast", {
        format: "jpeg", quality: s.quality,
        maxWidth: Math.round(vp ? vp.w * dpr : s.maxWidth),
        maxHeight: Math.round(vp ? vp.h * dpr : s.maxWidth),
        everyNthFrame: 1,          // every compositor frame; screencast is change-driven anyway
      }).catch(() => {});
    }
  }

  list() {
    return [...this.tabs.values()].map((t) => ({
      id: t.id, title: t.info.title, url: t.info.url, active: t === this.active,
    }));
  }

  async newTab(url = "about:blank") {
    await this.ensure();
    const headless = config().browser.headless;
    const { targetId } = await this.cdp.send("Target.createTarget", {
      url: "about:blank", background: true, newWindow: !headless,
    });
    for (let i = 0; i < 50 && !this.tabs.has(targetId); i++) await sleep(20);
    const tab = this.tabs.get(targetId) ?? await this.#attach({ targetId, type: "page", title: "", url: "about:blank" });
    await tab.ready;
    this.setActive(tab);
    if (url && url !== "about:blank") await tab.goto(url);
    return tab;
  }

  async tab(id) {
    await this.ensure();
    const tab = id ? this.tabs.get(id) : (this.active ?? [...this.tabs.values()][0]);
    if (!tab) return this.newTab();
    this.setActive(tab);
    return tab;
  }

  async shutdown() {
    try { await this.cdp?.send("Browser.close"); } catch {}
    this.cdp?.close();
    this.proc?.kill();
  }
}

export class Tab {
  #engine; #refs = new Map(); #baseline = null; #baselineUrl = null;
  logs = []; requests = []; dialog = null; cursor = null; #viewport = null;

  constructor(engine, info, sessionId) {
    this.#engine = engine; this.info = info; this.sessionId = sessionId;
  }
  get id() { return this.info.targetId; }

  send(method, params = {}, timeoutMs) {
    timeoutMs ??= method.startsWith("Input.") ? 8000 : 30000;
    return this.#engine.cdp.send(method, params, this.sessionId, timeoutMs);
  }

  async init() {
    const on = (m, fn) => this.#engine.cdp.on(m, (p, sid) => { if (sid === this.sessionId) fn(p); });
    on("Page.screencastFrame", (f) => {
      this.send("Page.screencastFrameAck", { sessionId: f.sessionId }).catch(() => {});
      this.#engine.hooks.onFrame?.(Buffer.from(f.data, "base64"), f.metadata, this);
    });
    on("Runtime.consoleAPICalled", (e) => this.#log(e.type, e.args.map((a) => a.value ?? a.description ?? "").join(" ")));
    on("Runtime.exceptionThrown", (e) => this.#log("error", e.exceptionDetails?.exception?.description ?? e.exceptionDetails?.text));
    on("Log.entryAdded", ({ entry }) => this.#log(entry.level, entry.text));
    on("Network.requestWillBeSent", (e) => this.#req({ id: e.requestId, method: e.request.method, url: e.request.url, type: e.type }));
    on("Network.responseReceived", (e) => this.#req({ id: e.requestId, status: e.response.status, mime: e.response.mimeType }));
    on("Network.loadingFailed", (e) => this.#req({ id: e.requestId, failed: e.errorText }));
    on("Page.javascriptDialogOpening", async (d) => {
      const mode = config().browser.dialogs;
      if (mode === "accept" || mode === "dismiss") {
        await this.send("Page.handleJavaScriptDialog", { accept: mode === "accept" }).catch(() => {});
        this.#log("info", `[dialog auto-${mode}ed] ${d.type}: ${d.message}`);
      } else {
        this.dialog = { type: d.type, message: d.message, defaultPrompt: d.defaultPrompt };
      }
    });
    on("Page.javascriptDialogClosed", () => { this.dialog = null; });
    await Promise.all([
      this.send("Page.enable"), this.send("Runtime.enable"), this.send("DOM.enable"),
      this.send("Accessibility.enable"), this.send("Log.enable"), this.send("Network.enable"),
      this.send("Emulation.setFocusEmulationEnabled", { enabled: true }),
    ].map((p) => p.catch(() => {})));
  }

  #log(level, message) {
    this.logs.push({ level, message: String(message ?? ""), t: new Date().toISOString() });
    if (this.logs.length > 300) this.logs.shift();
  }
  #req(patch) {
    const hit = this.requests.find((r) => r.id === patch.id);
    hit ? Object.assign(hit, patch) : this.requests.push(patch);
    if (this.requests.length > 300) this.requests.shift();
  }

  #touch() { this.#engine.setActive(this); this.#engine.hooks.onTouch?.(this); }

  async viewportSize() { return this.#viewport ?? this.#viewportSize(); }

  async applyViewport() {
    const vp = this.#engine.viewport;
    if (!vp) { await this.send("Emulation.clearDeviceMetricsOverride").catch(() => {}); this.#viewport = null; return; }
    await this.send("Emulation.setDeviceMetricsOverride", {
      width: Math.round(vp.w), height: Math.round(vp.h), deviceScaleFactor: vp.dpr ?? 1, mobile: false,
    });
    this.#viewport = null;   // re-measure on next use
  }

  /** Input from a human in the live view (normalized coords). Not agent input,
   *  so it does not move the agent's cursor. */
  async userInput(ev) {
    const vp = await this.#viewportSize();
    const p = { x: (ev.nx ?? 0) * vp.w, y: (ev.ny ?? 0) * vp.h };
    const mods = (ev.alt ? 1 : 0) | (ev.ctrl ? 2 : 0) | (ev.meta ? 4 : 0) | (ev.shift ? 8 : 0);
    switch (ev.type) {
      case "move": return this.send("Input.dispatchMouseEvent", { type: "mouseMoved", ...p, modifiers: mods });
      case "down": return this.send("Input.dispatchMouseEvent", { type: "mousePressed", ...p, button: ev.button ?? "left", clickCount: ev.clickCount ?? 1, buttons: 1, modifiers: mods });
      case "up": return this.send("Input.dispatchMouseEvent", { type: "mouseReleased", ...p, button: ev.button ?? "left", clickCount: ev.clickCount ?? 1, modifiers: mods });
      case "wheel": return this.send("Input.dispatchMouseEvent", { type: "mouseWheel", ...p, deltaX: ev.dx ?? 0, deltaY: ev.dy ?? 0, modifiers: mods });
      case "text": return this.send("Input.insertText", { text: String(ev.text ?? "") });
      case "key": {
        const base = { key: ev.key, code: ev.code, windowsVirtualKeyCode: ev.keyCode, modifiers: mods };
        const cmd = ev.meta && EDIT_COMMANDS[String(ev.key).toLowerCase()];
        await this.send("Input.dispatchKeyEvent", { ...base, type: "rawKeyDown", ...(cmd ? { commands: [cmd] } : {}) });
        return this.send("Input.dispatchKeyEvent", { ...base, type: "keyUp" });
      }
    }
  }

  // ---------- navigation ----------
  async #waitLoad(timeoutMs = 20000) {
    await new Promise((res) => {
      let settle, finished = false;
      const done = () => { if (finished) return; finished = true; offLoad(); offDom(); clearTimeout(t); clearTimeout(settle); clearInterval(poll); res(); };
      // backup for a missed event: poll readiness directly
      const started = Date.now();
      const poll = setInterval(async () => {
        if (Date.now() - started < 400) return;
        const r = await this.send("Runtime.evaluate", { expression: "document.readyState", returnByValue: true }, 2000).catch(() => null);
        if (r?.result?.value === "complete") done();
        else if (r?.result?.value === "interactive" && !settle) settle = setTimeout(done, 700);
      }, 300);
      const offLoad = this.#engine.cdp.on("Page.loadEventFired", (_, sid) => { if (sid === this.sessionId) done(); });
      const offDom = this.#engine.cdp.on("Page.domContentEventFired", (_, sid) => {
        if (sid === this.sessionId) settle = setTimeout(done, 700);
      });
      const t = setTimeout(done, timeoutMs);
    });
  }
  async goto(url) {
    this.#touch();
    if (!/^[a-z][a-z0-9+.-]*:/i.test(url)) url = "https://" + url;
    const wait = this.#waitLoad();
    const r = await this.send("Page.navigate", { url });
    if (r.errorText) throw new Error(`Navigation failed: ${r.errorText}`);
    await wait;
    this.#baseline = null;
    return this.url();
  }
  async #history(delta) {
    this.#touch();
    const h = await this.send("Page.getNavigationHistory");
    const entry = h.entries[h.currentIndex + delta];
    if (!entry) return this.url();
    const wait = this.#waitLoad(10000);
    await this.send("Page.navigateToHistoryEntry", { entryId: entry.id });
    await wait;
    return this.url();
  }
  back() { return this.#history(-1); }
  forward() { return this.#history(1); }
  async reload() { this.#touch(); const w = this.#waitLoad(); await this.send("Page.reload"); await w; return this.url(); }
  async close() { await this.#engine.cdp.send("Target.closeTarget", { targetId: this.id }); }
  async url() { return (await this.evaluate("location.href")) ?? this.info.url; }
  async title() { return (await this.evaluate("document.title")) ?? this.info.title; }

  // ---------- reading ----------
  async #snapshot() {
    const { nodes } = await this.send("Accessibility.getFullAXTree", {});
    return fromCdpAx(nodes, { maxTextLength: config().snapshot.maxTextLength });
  }

  /** Indexed accessibility view. Diff vs the previous read by default. */
  async read({ full = false } = {}) {
    this.#touch();
    const cfg = config().snapshot;
    const { entries, focused } = await this.#snapshot();
    const url = await this.url();
    const header = `Tab ${this.id.slice(0, 8)} · ${await this.title()} · ${url}`;
    const rendered = render(entries, { maxLines: cfg.maxLines, header, focused });
    this.#refs = rendered.refs;
    const d = !full && cfg.diff && this.#baselineUrl === url ? diff(this.#baseline, entries, cfg) : null;
    this.#baseline = entries.map((e) => e.text);
    this.#baselineUrl = url;
    return d ? `${header}\n${d}` : rendered.text;
  }

  /** Lines of the current tree matching text/regex, with live indices. */
  async find(query) {
    const { entries } = await this.#snapshot();
    const re = query instanceof RegExp ? query : new RegExp(String(query).replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "i");
    const { refs } = render(entries, { maxLines: config().snapshot.maxLines });
    this.#refs = refs;
    return entries.map((e, i) => `${i + 1} ${e.text}`).filter((l) => re.test(l)).join("\n") || "(no match)";
  }

  async text() { return this.evaluate("document.body?.innerText ?? ''"); }

  async screenshot({ fullPage = false, format = "png", quality } = {}) {
    const { data } = await this.send("Page.captureScreenshot", { format, quality, captureBeyondViewport: fullPage });
    return Buffer.from(data, "base64");
  }

  // ---------- targeting ----------
  async #backendId(target) {
    if (typeof target === "number") {
      const ref = this.#refs.get(target);
      if (ref === undefined) throw new Error(`Element ${target} is not in the last read. Call read() again.`);
      return ref;
    }
    if (typeof target === "string") {
      const { result } = await this.send("Runtime.evaluate", { expression: `document.querySelector(${JSON.stringify(target)})` });
      if (!result.objectId) throw new Error(`No element matches selector ${target}`);
      const { node } = await this.send("DOM.describeNode", { objectId: result.objectId });
      return node.backendNodeId;
    }
    throw new Error("Target must be an element index, a CSS selector, or an [x, y] point");
  }

  async #point(target) {
    if (Array.isArray(target)) return { x: target[0], y: target[1] };
    const backendNodeId = await this.#backendId(target);
    await this.send("DOM.scrollIntoViewIfNeeded", { backendNodeId }).catch(() => {});
    let quads;
    try { ({ quads } = await this.send("DOM.getContentQuads", { backendNodeId })); } catch {}
    if (!quads?.length) {
      const { model } = await this.send("DOM.getBoxModel", { backendNodeId }).catch(() => ({}));
      if (!model) throw new Error(`Element ${target} has no layout box (hidden or stale). Re-read and retry.`);
      quads = [model.content];
    }
    const q = quads[0];
    return { x: (q[0] + q[2] + q[4] + q[6]) / 4, y: (q[1] + q[3] + q[5] + q[7]) / 4 };
  }

  async #viewportSize() {
    const m = await this.send("Page.getLayoutMetrics");
    this.#viewport = { w: m.cssVisualViewport.clientWidth, h: m.cssVisualViewport.clientHeight };
    return this.#viewport;
  }

  async #moveCursor(p, kind) {
    this.cursor = { ...p, kind };
    const vp = this.#viewport ?? await this.#viewportSize();
    this.#engine.hooks.onCursor?.({ x: p.x / vp.w, y: p.y / vp.h, kind, tab: this.id });
  }

  // ---------- acting ----------
  async click(target, { button = "left", clickCount = 1 } = {}) {
    this.#touch();
    const p = await this.#point(target);
    await this.#moveCursor(p, "click");
    await this.send("Input.dispatchMouseEvent", { type: "mouseMoved", ...p });
    await this.send("Input.dispatchMouseEvent", { type: "mousePressed", ...p, button, clickCount, buttons: 1 });
    await this.send("Input.dispatchMouseEvent", { type: "mouseReleased", ...p, button, clickCount });
  }

  async hover(target) {
    this.#touch();
    const p = await this.#point(target);
    await this.#moveCursor(p, "move");
    await this.send("Input.dispatchMouseEvent", { type: "mouseMoved", ...p });
  }

  async #focus(target) {
    if (target === null || target === undefined) return;
    const backendNodeId = await this.#backendId(target);
    await this.send("DOM.focus", { backendNodeId }).catch(async () => this.click(target));
    const p = await this.#point(target).catch(() => null);
    if (p) await this.#moveCursor(p, "move");
  }

  async typeText(target, text) {
    this.#touch();
    await this.#focus(target);
    await this.send("Input.insertText", { text: String(text) });
  }

  async setValue(target, value) {
    this.#touch();
    const backendNodeId = await this.#backendId(target);
    const { object } = await this.send("DOM.resolveNode", { backendNodeId });
    await this.send("Runtime.callFunctionOn", {
      objectId: object.objectId, arguments: [{ value: String(value) }],
      functionDeclaration: `function (v) {
        this.focus?.();
        if (this.isContentEditable) { this.textContent = v; }
        else {
          const proto = this instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
            : this instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
          const set = Object.getOwnPropertyDescriptor(proto, "value")?.set;
          set ? set.call(this, v) : (this.value = v);
        }
        this.dispatchEvent(new Event("input", { bubbles: true }));
        this.dispatchEvent(new Event("change", { bubbles: true }));
      }`,
    });
    const p = await this.#point(target).catch(() => null);
    if (p) await this.#moveCursor(p, "move");
  }

  async pressKey(target, combo) {
    this.#touch();
    await this.#focus(target);
    const k = parseCombo(combo);
    const cmd = k.modifiers & 4 && EDIT_COMMANDS[k.key.toLowerCase()];
    const base = { key: k.key, code: k.code, windowsVirtualKeyCode: k.windowsVirtualKeyCode, modifiers: k.modifiers };
    await this.send("Input.dispatchKeyEvent", {
      ...base, type: k.text ? "keyDown" : "rawKeyDown", text: k.text, unmodifiedText: k.text,
      ...(cmd ? { commands: [cmd] } : {}),
    });
    await this.send("Input.dispatchKeyEvent", { ...base, type: "keyUp" });
  }

  async scroll(target = null, direction = "down", pages = 1) {
    this.#touch();
    const vp = await this.#viewportSize();
    const p = target === null ? { x: vp.w / 2, y: vp.h / 2 } : await this.#point(target);
    const amount = vp.h * 0.85 * pages;
    const d = { down: [0, amount], up: [0, -amount], right: [amount, 0], left: [-amount, 0] }[direction[0] === "u" ? "up" : direction[0] === "d" ? "down" : direction[0] === "l" ? "left" : "right"];
    await this.#moveCursor(p, "scroll");
    await this.send("Input.dispatchMouseEvent", { type: "mouseWheel", ...p, deltaX: d[0], deltaY: d[1] });
    await sleep(120);
  }

  async drag(from, to, steps = 12) {
    this.#touch();
    const a = await this.#point(from), b = await this.#point(to);
    await this.#moveCursor(a, "move");
    await this.send("Input.dispatchMouseEvent", { type: "mouseMoved", ...a });
    await this.send("Input.dispatchMouseEvent", { type: "mousePressed", ...a, button: "left", clickCount: 1, buttons: 1 });
    for (let i = 1; i <= steps; i++) {
      const p = { x: a.x + (b.x - a.x) * i / steps, y: a.y + (b.y - a.y) * i / steps };
      await this.send("Input.dispatchMouseEvent", { type: "mouseMoved", ...p, buttons: 1 });
    }
    await this.#moveCursor(b, "click");
    await this.send("Input.dispatchMouseEvent", { type: "mouseReleased", ...b, button: "left", clickCount: 1 });
  }

  async upload(target, files) {
    this.#touch();
    const backendNodeId = await this.#backendId(target);
    await this.send("DOM.setFileInputFiles", { backendNodeId, files: [].concat(files).map(expandHome) });
  }

  async handleDialog(accept = true, promptText) {
    for (let i = 0; i < 20 && !this.dialog; i++) await sleep(100);
    if (!this.dialog) throw new Error("No dialog is open");
    await this.send("Page.handleJavaScriptDialog", { accept, promptText });
    this.dialog = null;
  }

  // ---------- scripting ----------
  /** Evaluate against the LIVE page (typed values included). */
  async evaluate(fnOrExpr, arg) {
    const expression = typeof fnOrExpr === "function" ? `(${fnOrExpr})(${JSON.stringify(arg)})` : String(fnOrExpr);
    const r = await this.send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
    return r.result.value;
  }

  async waitFor(cond, timeoutMs = 10000) {
    const t0 = Date.now();
    const check = typeof cond === "function" ? cond
      : `(() => { const s = ${JSON.stringify(cond)};
          if ((document.body?.innerText ?? "").includes(s)) return true;
          try { return !!document.querySelector(s); } catch { return false; } })()`;
    while (Date.now() - t0 < timeoutMs) {
      if (await this.evaluate(check).catch(() => false)) return true;
      await sleep(250);
    }
    throw new Error(`waitFor timed out after ${timeoutMs}ms: ${String(cond).slice(0, 80)}`);
  }

  cdp(method, params) { return this.send(method, params); }
  getLogs({ level, limit = 50 } = {}) { return this.logs.filter((l) => !level || l.level === level).slice(-limit); }
  getRequests({ filter, limit = 50 } = {}) { return this.requests.filter((r) => !filter || r.url?.includes(filter)).slice(-limit); }
}
