// Config and filesystem layout. One config file, shared by the daemon, the web
// settings page, and the native HUD. Hot-reloaded: callers read `config()` each
// time rather than caching.
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const home = os.homedir();

export const paths = {
  config: process.env.CUA_CONFIG ?? path.join(home, ".config/cua/config.json"),
  support: path.join(home, "Library/Application Support/cua"),
  get run() { return process.env.CUA_RUN_DIR ?? path.join(this.support, "run"); },
  get profiles() { return path.join(this.support, "profiles"); },
  get daemonSock() { return path.join(this.run, "daemon.sock"); },
  get agentSock() { return path.join(this.run, "agent.sock"); },
  get token() { return path.join(this.run, "token"); },
  get frame() { return path.join(this.run, "frame.jpg"); },
  get cursor() { return path.join(this.run, "cursor.json"); },
  get state() { return path.join(this.run, "state.json"); },
  get status() { return path.join(this.run, "status.txt"); },
  get target() { return path.join(this.run, "target.json"); },
  get log() { return path.join(this.run, "daemon.log"); },
};

export const defaults = {
  browser: {
    executable: "auto",          // auto | absolute path to a Chromium-family binary
    headless: true,              // true = fully in the background. false shows a window and Chrome takes focus when it launches
    attach: "",                  // CDP URL of an already-running browser to drive instead
    profile: "default",          // named profile under ~/Library/Application Support/cua/profiles
    viewport: { width: 1280, height: 800 },
    downloadsDir: "~/Downloads",
    dialogs: "report",           // report | accept | dismiss
    closeTabsOnSessionEnd: true, // agent tabs are ephemeral unless tab.keep() is called
  },
  snapshot: { diff: true, maxLines: 500, maxTextLength: 120 },
  native: { enabled: true, allowKeyEvents: true, maxDepth: 30, maxLines: 500 },
  stream: { fps: 30, quality: 72, maxWidth: 1280 },
  hud: {
    enabled: true,
    mode: "attached",            // attached | overlay | normal
    attachTo: "Claude",
    anchor: "bottom-right",
    hideWhenHostInactive: true,
    margin: 16,
    width: 460,
    opacity: 1.0,
    cornerRadius: 10,
    clickThrough: false,
    showAgentCursor: true,
    cursorColor: "#339cff",      // glow around the agent's cursor (live view and HUD)
    controlsCorner: "top-left",
    glyphClose: "xmark",
    glyphAction: "hand.raised",
    glyphSize: 20,
    glyphInset: 14,
    glyphGap: 26,
    glyphTint: "auto",
    scrimOpacity: 0.38,
    hoverFadeIn: 0.12,
    hoverFadeOut: 0.25,
  },
  web: { port: 47821, searchEngine: "google" },   // address-bar searches: google | bing | brave | duckduckgo | a URL with %s
  repl: { timeoutMs: 30000, maxOutputChars: 20000 },
};

function merge(base, over) {
  if (Array.isArray(base) || typeof base !== "object" || base === null) return over ?? base;
  const out = { ...base };
  for (const [k, v] of Object.entries(over ?? {})) {
    out[k] = (v && typeof v === "object" && !Array.isArray(v) && typeof base[k] === "object")
      ? merge(base[k], v) : v;
  }
  return out;
}

let cache = { mtime: 0, value: defaults };

export function config() {
  try {
    const m = fs.statSync(paths.config).mtimeMs;
    if (m !== cache.mtime) {
      cache = { mtime: m, value: merge(defaults, JSON.parse(fs.readFileSync(paths.config, "utf8"))) };
    }
  } catch { cache = { mtime: 0, value: defaults }; }
  return cache.value;
}

// Values equal to the default are not stored, so improving a default later reaches
// existing installs instead of being pinned by a copy saved on day one.
function overrides(base, value) {
  const out = {};
  for (const [k, v] of Object.entries(value ?? {})) {
    const d = base?.[k];
    if (v && typeof v === "object" && !Array.isArray(v) && d && typeof d === "object") {
      const sub = overrides(d, v);
      if (Object.keys(sub).length) out[k] = sub;
    } else if (JSON.stringify(v) !== JSON.stringify(d)) out[k] = v;
  }
  return out;
}

export function saveConfig(value) {
  fs.mkdirSync(path.dirname(paths.config), { recursive: true });
  const tmp = paths.config + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(overrides(defaults, value), null, 2) + "\n");
  fs.renameSync(tmp, paths.config);
  cache.mtime = 0;
  return config();
}

// one-time: drop values the first release wrote that equal its old defaults
const STALE = { stream: { fps: 12, quality: 70 } };
export function migrateConfig() {
  try {
    const raw = JSON.parse(fs.readFileSync(paths.config, "utf8"));
    for (const [sec, vals] of Object.entries(STALE)) {
      for (const [k, v] of Object.entries(vals)) if (raw[sec]?.[k] === v) delete raw[sec][k];
    }
    saveConfig(merge(defaults, raw));
  } catch {}
}

export function ensureDirs() {
  for (const d of [paths.run, paths.profiles, path.dirname(paths.config)]) {
    fs.mkdirSync(d, { recursive: true, mode: 0o700 });
  }
  if (!fs.existsSync(paths.config)) saveConfig({}); else migrateConfig();
}

export const expandHome = (p) => (p?.startsWith("~/") ? path.join(home, p.slice(2)) : p);

export function atomicWrite(file, data) {
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, data);
  fs.renameSync(tmp, file);
}
