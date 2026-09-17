// Streams frames from a cua target (Tab or App) into the floating viewer.
//
// Constraint: cua RPC calls only work INSIDE a js tool call ("node_repl exec
// context not found" otherwise), so we cannot capture from a background timer
// between calls. Instead frames are captured during actions:
//   snap(t)          - one frame now
//   watch(t)         - Proxy that auto-snaps after every action on the target
//   streamWhile(t,f) - smooth interval streaming for the duration of one cell
import { createRequire } from "node:module";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

const CUA_NODE = process.env.CUA_NODE_HOME
  ?? "/Applications/ChatGPT.app/Contents/Resources/cua_node";
const require = createRequire(`${CUA_NODE}/lib/node_modules/`);
const sharp = require("sharp");

const DIR = process.env.CUA_BRIDGE_HOME
  ? path.join(process.env.CUA_BRIDGE_HOME, "stream")
  : path.join(os.homedir(), ".claude/cua-bridge/stream");
const OUT = "/tmp/cua-preview";
const FRAME = path.join(OUT, "frame.jpg");
const STATUS = path.join(DIR, "status.txt");
const TARGET = path.join(DIR, "target.json");
let WIDTH = 440;

// Point the panel's ScreenCaptureKit stream at a window (live 30fps capture).
// { app: "Helium" } or { app: "Helium", title: "Wikipedia" }; {} clears it.
export function setTarget(spec = {}) {
  fs.mkdirSync(DIR, { recursive: true });
  fs.writeFileSync(TARGET, JSON.stringify(spec));
  return spec;
}
export function clearTarget() { return setTarget({}); }

export function setStatus(text) {
  fs.mkdirSync(DIR, { recursive: true });
  fs.writeFileSync(STATUS, String(text ?? ""));
}

export async function snap(target, width = WIDTH) {
  fs.mkdirSync(OUT, { recursive: true });
  const png = await target.getScreenshot({ emit: false });
  const out = await sharp(Buffer.from(png))
    .resize({ width, withoutEnlargement: true })
    .jpeg({ quality: 72 })
    .toBuffer();
  const tmp = FRAME + ".tmp";
  fs.writeFileSync(tmp, out);
  fs.renameSync(tmp, FRAME);   // atomic: viewer never sees a partial frame
  return true;
}

// Write an already-captured PNG buffer (used by the built-in browser).
export async function snapPng(buf, width = WIDTH) {
  fs.mkdirSync(OUT, { recursive: true });
  const out = await sharp(Buffer.from(buf))
    .resize({ width, withoutEnlargement: true })
    .jpeg({ quality: 72 }).toBuffer();
  const tmp = FRAME + ".tmp";
  fs.writeFileSync(tmp, out);
  fs.renameSync(tmp, FRAME);
  return true;
}

// Actions that change what's on screen and so deserve a fresh frame.
const ACTIONS = new Set([
  "click", "type", "typeText", "setValue", "pressKey", "scroll", "drag",
  "paste", "selectText", "performSecondaryAction", "goto", "back", "forward",
  "reload",
]);

// Native app / whole window: let the capture daemon stream it live via SCK.
export function watchApp(appName, { status } = {}) {
  if (status) setStatus(status);
  setTarget({ app: appName });
  return appName;
}

// Browser tab: the daemon must NOT window-capture, or the HUD shows the wrong
// tab. Clear the target so it idles, and drive frames from the tab itself.
export function watchTab(tab, opts = {}) {
  clearTarget();
  return watch(tab, { ...opts, app: undefined });
}

export function watch(target, { width = WIDTH, status, app } = {}) {
  if (status) setStatus(status);
  if (app) setTarget({ app });   // live SCK capture of that app's window
  return new Proxy(target, {
    get(obj, prop, recv) {
      const v = Reflect.get(obj, prop, recv);
      if (typeof v === "function" && ACTIONS.has(prop)) {
        return async (...args) => {
          const r = await v.apply(obj, args);
          try { await snap(obj, width); } catch {}
          return r;
        };
      }
      return typeof v === "function" ? v.bind(obj) : v;
    },
  });
}

// Smooth streaming for the duration of one cell (context is alive here).
export async function streamWhile(target, fn, { width = WIDTH, intervalMs = 700 } = {}) {
  let busy = false, stop = false;
  const loop = (async () => {
    while (!stop) {
      if (!busy) {
        busy = true;
        try { await snap(target, width); } catch {} finally { busy = false; }
      }
      await new Promise((r) => setTimeout(r, intervalMs));
    }
  })();
  try { return await fn(); } finally { stop = true; await loop.catch(() => {}); }
}
