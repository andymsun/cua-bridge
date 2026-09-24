// Playwright on cua's browser: a second CDP client on the same Chrome, so locators
// get Playwright's exact semantics (getByRole, frames, actionability waits). Input
// still goes to the page through CDP - never to the OS.
import * as fs from "node:fs";
import * as path from "node:path";
import { config, expandHome } from "./config.mjs";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let chromium = null;

export class PlaywrightBridge {
  #browser = null; #wsUrl = null; #connecting = null;
  #targets = new WeakMap();          // Page -> targetId

  constructor(engine) { this.engine = engine; }

  async #connect() {
    await this.engine.ensure();
    chromium ??= (await import("playwright-core")).chromium;
    const b = await chromium.connectOverCDP(this.engine.wsUrl, { timeout: 15000 });
    b.on("disconnected", () => { if (this.#browser === b) this.#browser = null; });
    const ctx = b.contexts()[0];
    for (const p of ctx.pages()) this.#watch(p);
    ctx.on("page", (p) => this.#watch(p));
    this.#browser = b; this.#wsUrl = this.engine.wsUrl;
  }

  // Playwright routes downloads into its own temp dir; move each to the configured folder.
  #watch(page) {
    page.on("dialog", () => {});   // a listener stops Playwright auto-dismissing; the engine reports dialogs
    page.on("download", async (d) => {
      const dir = expandHome(config().browser.downloadsDir);
      if (!dir) return;
      const dest = unique(path.join(dir, d.suggestedFilename()));
      d.savedTo = d.saveAs(dest).then(() => dest).catch(() => null);
    });
  }

  async browser() {
    const stale = !this.#browser?.isConnected() || this.#wsUrl !== this.engine.wsUrl;
    if (stale) { this.#connecting ??= this.#connect().finally(() => { this.#connecting = null; }); await this.#connecting; }
    return this.#browser;
  }

  /** The Playwright Page for a cua tab. */
  async page(tab) {
    const ctx = (await this.browser()).contexts()[0];
    for (let i = 0; i < 40; i++) {
      for (const p of ctx.pages()) {
        if (p.isClosed()) continue;
        let id = this.#targets.get(p);
        if (!id) {
          const s = await ctx.newCDPSession(p).catch(() => null);
          if (!s) continue;
          id = (await s.send("Target.getTargetInfo").catch(() => null))?.targetInfo?.targetId;
          await s.detach().catch(() => {});
          if (id) this.#targets.set(p, id);
        }
        if (id === tab.id) return p;
      }
      await sleep(50);
    }
    throw new Error("This tab isn't available to Playwright (it may have closed). Get a fresh tab.");
  }

  async context() { return (await this.browser()).contexts()[0]; }
}

export function unique(file) {
  if (!fs.existsSync(file)) return file;
  const { dir, name, ext } = path.parse(file);
  for (let i = 2; ; i++) { const f = path.join(dir, `${name} (${i})${ext}`); if (!fs.existsSync(f)) return f; }
}
