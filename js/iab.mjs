// "Built-in browser": a dedicated headless Chromium under full Playwright/CDP
// control, isolated from the user's own profile. It has no visible window of
// its own - its only visual presence is the floating preview panel.
import { createRequire } from "node:module";
import * as path from "node:path";
import * as os from "node:os";

const CUA_NODE = process.env.CUA_NODE_HOME
  ?? "/Applications/ChatGPT.app/Contents/Resources/cua_node";
const require = createRequire(`${CUA_NODE}/lib/node_modules/`);
const { chromium } = require("playwright");

const PROFILE = path.join(process.env.CUA_BRIDGE_HOME ?? path.join(os.homedir(), ".claude/cua-bridge"), "iab-profile");
const CHROME = process.env.CUA_IAB_CHROME
  ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
export const DEBUG_PORT = Number(process.env.CUA_IAB_PORT ?? 9333);   // lets tabstream.mjs screencast this tab

let ctx = null, page = null, cdp = null;

export async function openIAB(url, { width = 1280, height = 800, headless = true } = {}) {
  if (!ctx) {
    ctx = await chromium.launchPersistentContext(PROFILE, {
      executablePath: CHROME,
      headless,
      viewport: { width, height },
      args: ["--no-first-run", "--no-default-browser-check",
             `--remote-debugging-port=${DEBUG_PORT}`],
    });
    page = ctx.pages()[0] ?? (await ctx.newPage());
    cdp = await ctx.newCDPSession(page);
  }
  if (url) await page.goto(url, { waitUntil: "domcontentloaded" });
  return page;
}

export function iabPage() { return page; }
export function iabCDP() { return cdp; }          // raw CDP: cdp.send("Page.navigate", ...)

export async function closeIAB() {
  if (ctx) { await ctx.close().catch(() => {}); ctx = null; page = null; cdp = null; }
  return "iab closed";
}

// Stream the built-in browser into the floating panel for the duration of fn.
export async function streamIAB(fn, { width = 460, intervalMs = 600, status } = {}) {
  const P = await import(new URL("./preview.mjs", import.meta.url).href);
  if (status) P.setStatus(status);
  let stop = false, busy = false;
  const loop = (async () => {
    while (!stop) {
      if (!busy && page) {
        busy = true;
        try { await P.snapPng(await page.screenshot(), width); } catch {} finally { busy = false; }
      }
      await new Promise((r) => setTimeout(r, intervalMs));
    }
  })();
  try { return await fn(page, cdp); } finally { stop = true; await loop.catch(() => {}); }
}
