// The agent's own cursors on the real screen, Clicky-style: each agent session gets a
// coloured cursor that glides to what it points at, says why in a label, can ring a region,
// and follows native actions. Drawn by `CuaPreview --pointer`, a click-through overlay that
// reads run/pointers.json. Nothing here moves or clicks the user's cursor.
import { execFile } from "node:child_process";
import * as fs from "node:fs";
import { atomicWrite, config, paths } from "./config.mjs";
import { hudApp } from "./hud.mjs";

const finite = (v) => typeof v === "number" && Number.isFinite(v);
const unit = (v) => finite(v) && v >= -0.05 && v <= 1.05;
const label = (text) => (text == null ? "" : String(text).replace(/\s+/g, " ").trim().slice(0, 120));

/** A target as the overlay reads it: a screen point, or a point/rect normalised to a window. */
export function cleanTarget(t) {
  if (t?.screen) {
    const [x, y] = t.screen;
    if (!finite(x) || !finite(y)) throw new Error("screen point needs finite x and y");
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

export class Pointers {
  #cursors = new Map();   // id -> { color, target, label, kind, t }
  #next = 0;
  #lastLaunch = 0;

  /** A new cursor for one agent session, with the next colour in the palette. */
  session() {
    const colors = config().pointer.colors;
    const id = `agent-${++this.#next}`;
    this.#cursors.set(id, { color: colors[(this.#next - 1) % colors.length], target: null, label: "", kind: "point", t: 0 });
    return id;
  }

  /** kind: "point" (arrow + label), "rect" (ring a region), "click" or "move" (follows an action). */
  move(id, target, { text, kind = "point" } = {}) {
    const c = this.#cursors.get(id);
    if (!c || !config().pointer.enabled) return false;
    if (!["point", "rect", "click", "move"].includes(kind)) throw new Error(`unknown pointer kind ${kind}`);
    Object.assign(c, { target: cleanTarget(target), label: label(text), kind, t: Date.now() });
    this.#write();
    this.launch();
    return true;
  }

  hide(id) {
    const c = this.#cursors.get(id);
    if (!c?.target) return;
    c.target = null; c.t = Date.now();
    this.#write();
  }

  end(id) { if (this.#cursors.delete(id)) this.#write(); }

  snapshot() {
    const { labelSeconds, idleSeconds, scale } = config().pointer;
    const cursors = {};
    for (const [id, c] of this.#cursors) if (c.target) cursors[id] = { ...c };
    return { labelSeconds, idleSeconds, scale, cursors };
  }

  #write() { try { atomicWrite(paths.pointers, JSON.stringify(this.snapshot())); } catch {} }

  launch() {
    if (Date.now() - this.#lastLaunch < 10000) return;
    this.#lastLaunch = Date.now();
    // -n: a second instance of the HUD app in overlay mode; it exits if one is already running
    execFile("open", ["-n", "-g", hudApp, "--args", "--pointer"], () => {});
  }

  shutdown() { try { fs.rmSync(paths.pointers, { force: true }); } catch {} }
}
