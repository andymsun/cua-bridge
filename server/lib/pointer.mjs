// Session-owned desktop cursors. Nothing here moves or clicks the real pointer.
import { execFile } from "node:child_process";
import * as fs from "node:fs";
import { atomicWrite, config, paths } from "./config.mjs";
import { hudApp } from "./hud.mjs";

const finite = (v) => typeof v === "number" && Number.isFinite(v);
const unit = (v) => finite(v) && v >= -0.05 && v <= 1.05;
const label = (text) => (text == null ? "" : String(text).replace(/\s+/g, " ").trim().slice(0, 120));
const states = new Set(["idle", "thinking", "pointing", "waiting", "acting", "done", "error"]);

export function cleanTarget(t) {
  if (t?.screenRect) {
    const { x, y, w, h } = t.screenRect;
    if (![x, y, w, h].every(finite) || w <= 0 || h <= 0 || w > 100000 || h > 100000) throw new Error("screen rect needs finite coordinates and positive dimensions");
    if (Math.abs(x) > 1000000 || Math.abs(y) > 1000000) throw new Error("screen rect coordinates are out of range");
    return { screenRect: { x, y, w, h } };
  }
  if (t?.screen) {
    const [x, y] = t.screen;
    if (!finite(x) || !finite(y)) throw new Error("screen point needs finite x and y");
    if (Math.abs(x) > 1000000 || Math.abs(y) > 1000000) throw new Error("screen coordinates are out of range");
    return { screen: [x, y] };
  }
  if (!Number.isInteger(t?.windowId) || t.windowId <= 0) throw new Error("pointer target needs a screen point or a windowId");
  if (t.rect) {
    const { x, y, w, h } = t.rect;
    if (![x, y].every(unit) || !finite(w) || !finite(h) || w < 0 || h < 0 || w > 1.1 || h > 1.1) throw new Error("rect must be normalised to the window");
    return { windowId: t.windowId, rect: { x, y, w, h } };
  }
  if (!unit(t.x) || !unit(t.y)) throw new Error("window point must be normalised to the window");
  return { windowId: t.windowId, x: t.x, y: t.y };
}

export function cleanOrigin(origin) {
  if (origin === undefined) return null;
  const [x, y] = cleanTarget({ screen: [origin?.x, origin?.y] }).screen;
  return { x, y };
}

export function cleanAnnotation(value) {
  if (!["circle", "highlight", "arrow", "draw"].includes(value?.kind)) throw new Error("unknown annotation kind");
  const out = { kind: value.kind, label: label(value.label), durationMs: 900 };
  if (value.durationMs !== undefined) {
    if (!finite(value.durationMs) || value.durationMs < 0 || value.durationMs > 5000) throw new Error("durationMs must be between 0 and 5000");
    out.durationMs = value.durationMs;
  }
  if (["arrow", "draw"].includes(value.kind)) {
    if (!Array.isArray(value.points) || value.points.length < 2 || value.points.length > 512) throw new Error("a stroke needs 2 to 512 points");
    out.points = value.points.map(point => {
      if (!Array.isArray(point) || point.length !== 2) throw new Error("stroke points need two finite coordinates");
      return cleanTarget({ screen: point }).screen;
    });
  } else {
    out.target = cleanTarget(value.target ?? { screenRect: value.rect });
    if (!out.target.rect && !out.target.screenRect) throw new Error("circle and highlight need a rectangle");
  }
  return out;
}

export class Pointers {
  #cursors = new Map();
  #next = 0;
  #lastLaunch = 0;
  #annotation = 0;
  #demo = null;

  warm() {
    if (!config().pointer.enabled) return false;
    this.#write(); this.launch(); return true;
  }

  session({ name = "" } = {}) {
    const colors = config().pointer.colors;
    const id = `agent-${++this.#next}`;
    this.#cursors.set(id, { name: label(name || `Agent ${this.#next}`), color: colors[(this.#next - 1) % colors.length], target: null, label: "", kind: "point", state: "idle", persistent: false, annotations: [], motion: null, t: 0 });
    return id;
  }

  move(id, target, { text, kind = "point", persistent = false, origin } = {}) {
    const c = this.#cursors.get(id);
    if (!c || !config().pointer.enabled) return false;
    if (!["point", "rect", "spotlight", "click", "move"].includes(kind)) throw new Error(`unknown pointer kind ${kind}`);
    Object.assign(c, { target: cleanTarget(target), origin: cleanOrigin(origin), label: label(text), kind, persistent: !!persistent, motion: null, state: "pointing", t: Date.now() });
    this.#write(); this.launch();
    return true;
  }

  annotate(id, value, { origin } = {}) {
    const c = this.#cursors.get(id);
    if (!c || !config().pointer.enabled) return false;
    const annotation = { ...cleanAnnotation(value), id: `mark-${++this.#annotation}`, t: Date.now() };
    c.origin = cleanOrigin(origin);
    c.annotations = [...c.annotations, annotation].slice(-12);
    c.target = annotation.target ?? { screen: annotation.points.at(-1) };
    c.label = annotation.label; c.kind = "point"; c.persistent = true; c.state = "pointing"; c.motion = annotation.id; c.t = annotation.t;
    this.#write(); this.launch(); return annotation.id;
  }

  demo({ bounds, start }, done = () => {}) {
    const { screenRect: b } = cleanTarget({ screenRect: bounds });
    const origin = cleanTarget({ screen: start });
    if (b.w < 240 || b.h < 200) throw new Error("Demo needs a display area of at least 240 × 200 points");
    this.stopDemo();
    const id = this.session({ name: "Andy · Local demo" }), timers = [];
    this.#demo = { id, timers, done };
    const x = b.x + b.w * 0.25, y = b.y + b.h * 0.25, w = Math.min(200, b.w * 0.22), h = Math.min(90, b.h * 0.12);
    const tail = Math.min(b.y + b.h - 24, y + h + 130);
    const later = (ms, action) => timers.push(setTimeout(() => { if (this.#demo?.id === id) action(); }, ms));
    this.move(id, origin, { text: "Local demo · no mouse input", persistent: true });
    later(300, () => this.move(id, { screen: [x, y] }, { text: "Move", persistent: true }));
    later(1100, () => this.annotate(id, { kind: "circle", rect: { x, y, w, h }, label: "Circle", durationMs: 800 }));
    later(2600, () => this.annotate(id, { kind: "highlight", rect: { x: x + w + 50, y: y + 30, w, h: h * 0.5 }, label: "Highlight", durationMs: 550 }));
    later(3900, () => this.annotate(id, { kind: "arrow", points: [[x + w, Math.min(tail - 40, y + h + 35)], [x + w * 2, Math.min(tail - 20, y + h + 70)]], label: "Point the way", durationMs: 650 }));
    later(5200, () => this.annotate(id, { kind: "draw", points: Array.from({ length: 40 }, (_, i) => [x + i * w / 20, tail + Math.sin(i / 5) * 12]), label: "Draw", durationMs: 900 }));
    later(6400, () => this.describe(id, { state: "done", text: "Move your mouse · I’ll follow" }));
    later(13000, () => this.stopDemo());
    return { durationMs: 13000 };
  }
  stopDemo() {
    const demo = this.#demo; if (!demo) return;
    this.#demo = null; demo.timers.forEach(clearTimeout); this.end(demo.id); demo.done();
  }

  describe(id, { name, text, state } = {}) {
    const c = this.#cursors.get(id);
    if (!c) return false;
    if (state !== undefined && !states.has(state)) throw new Error(`unknown cursor state ${state}`);
    if (name !== undefined) c.name = label(name);
    if (text !== undefined) c.label = label(text);
    if (state !== undefined) c.state = state;
    c.t = Date.now(); if (c.target) this.#write();
    return true;
  }

  hide(id) {
    const c = this.#cursors.get(id);
    if (!c?.target) return;
    c.target = null; c.annotations = []; c.motion = null; c.t = Date.now(); this.#write();
  }
  end(id) { if (this.#cursors.delete(id)) this.#write(); }
  snapshot() {
    const { labelSeconds, idleSeconds, scale } = config().pointer;
    const cursors = {};
    for (const [id, c] of this.#cursors) if (c.target) cursors[id] = { ...c };
    return { labelSeconds, idleSeconds, scale, cursors };
  }
  #write() { atomicWrite(paths.pointers, JSON.stringify(this.snapshot())); }
  launch() {
    if (Date.now() - this.#lastLaunch < 10000) return;
    this.#lastLaunch = Date.now();
    execFile("open", ["-n", "-g", "--env", `CUA_RUN_DIR=${paths.run}`, "--env", `CUA_CONFIG=${paths.config}`, hudApp, "--args", "--pointer"], () => {});
  }
  shutdown() { this.stopDemo(); try { fs.rmSync(paths.pointers, { force: true }); } catch {} }
}
