// Feeds CuaPreview.app: the latest frame of whatever the agent is driving, the
// agent's own cursor position, and a status line. The HUD reads these files;
// nothing here touches the user's real cursor.
import { execFile } from "node:child_process";
import * as os from "node:os";
import * as path from "node:path";
import { atomicWrite, config, paths } from "./config.mjs";

export const hudApp = process.env.CUA_HUD_APP ?? path.join(os.homedir(), "Applications/CuaPreview.app");

export class Hud {
  source = null;          // "browser" | "native"
  #lastFrame = 0;
  #lastLaunch = 0;
  #native = null;
  #nativePid = null;

  attachNative(native) { this.#native = native; }

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
    const pid = source === "native" ? app?.pid ?? null : null;
    if (this.source === source && this.#nativePid === pid) return;
    this.source = source;
    this.#nativePid = pid;
    // native frames come from CuaAgent's window stream; browser frames come from CDP
    if (pid || this.#native?.connected) this.#native?.req("stream", { pid }).catch(() => {});
    this.launch();
  }

  launch(force = false) {
    if (!config().hud.enabled && !force) return;
    if (!force && Date.now() - this.#lastLaunch < 30000) return;
    this.#lastLaunch = Date.now();
    execFile("open", ["-g", hudApp], () => {});   // -g: never activates, never steals focus
  }
}
