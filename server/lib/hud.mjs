// Feeds CuaPreview.app: the latest frame of whatever the agent is driving, the
// agent's own cursor position, and a status line. The HUD reads these files;
// nothing here touches the user's real cursor.
import { execFile } from "node:child_process";
import * as os from "node:os";
import * as path from "node:path";
import { atomicWrite, config, paths } from "./config.mjs";
import { cleanHost } from "./host.mjs";

export const hudApp = process.env.CUA_HUD_APP ?? path.join(os.homedir(), "Applications/CuaPreview.app");

export class Hud {
  source = null;          // "browser" | "native"
  #lastFrame = 0;
  #lastLaunch = 0;
  #native = null;
  #nativePid = null;
  #host = null;

  attachNative(native) { this.#native = native; }

  /** Record the app the latest call came from, for hud.mode "auto". */
  setHost(host) {
    const clean = cleanHost(host);
    if (!clean) return;
    const json = JSON.stringify(clean);
    if (json === this.#host) return;
    this.#host = json;
    try { atomicWrite(paths.host, json); } catch {}
  }

  frame(buf) {
    if (this.source !== "browser" || !config().hud.enabled) return;
    const now = Date.now();
    if (now - this.#lastFrame < 1000 / Math.max(1, config().stream.fps)) return;
    this.#lastFrame = now;
    try { atomicWrite(paths.frame, buf); } catch {}
  }

  cursor(c) {
    if (!config().hud.showAgentCursor) return;
    try { atomicWrite(paths.cursor, JSON.stringify({ ...c, source: this.source, t: Date.now() })); } catch {}
  }

  status(text) {
    try { atomicWrite(paths.status, String(text ?? "")); } catch {}
  }

  /** Point the HUD at the browser, or at a native app window. */
  setSource(source, app) {
    const target = source === "native" ? app?.target : null;
    const key = target ? `${target.process}:${target.windowId}` : null;
    if (this.source === source && this.#nativePid === key) return;
    this.source = source;
    this.#nativePid = key;
    atomicWrite(paths.target, JSON.stringify(target ?? { source: "browser" }));
    // Explicit target: never choose another window when a capture fails.
    if (target || this.#native?.connected) this.#native?.req("stream", target ?? { pid: null }).catch((error) => {
      if (this.#nativePid === key) this.#nativePid = null;
      this.status(error.message);
    });
    this.launch();
  }

  showView(id) {
    return new Promise((resolve, reject) => execFile("open", ["-n", "-g", hudApp, "--args", "--view", id], (error) => error ? reject(error) : resolve()));
  }

  launch(force = false) {
    if (!config().hud.enabled && !force) return;
    if (!force && Date.now() - this.#lastLaunch < 30000) return;
    this.#lastLaunch = Date.now();
    // -g never activates or steals focus; -n because the pointer overlay is another instance
    // of the same app. The HUD holds a lock, so an extra launch exits at once.
    execFile("open", ["-n", "-g", hudApp], () => {});
  }
}
