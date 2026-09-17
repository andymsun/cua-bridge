// Continuous per-TAB streaming via CDP Page.startScreencast.
//
// Window capture is wrong for browsers: it shows whichever tab the user is
// looking at, not the tab being driven. Screencast is bound to the page target,
// so it stays correct even if the tab is backgrounded or the browser hidden.
//
// Runs standalone (not inside the cua REPL), so frames keep flowing between
// tool calls. Usage: node tabstream.mjs [cdpURL] [width]
import { createRequire } from "node:module";
import * as fs from "node:fs";
const CUA_NODE = process.env.CUA_NODE_HOME
  ?? "/Applications/ChatGPT.app/Contents/Resources/cua_node";
const require = createRequire(`${CUA_NODE}/lib/node_modules/`);
const { chromium } = require("playwright");

const CDP = process.argv[2] || "http://127.0.0.1:9333";
const WIDTH = Number(process.argv[3] || 460);
const OUT = "/tmp/cua-preview";
const FRAME = OUT + "/frame.jpg";
fs.mkdirSync(OUT, { recursive: true });

function write(buf) {
  const tmp = FRAME + ".tmp";
  fs.writeFileSync(tmp, buf);
  fs.renameSync(tmp, FRAME);   // atomic: UI never reads a half-written frame
}

const browser = await chromium.connectOverCDP(CDP);
const ctx = browser.contexts()[0];
let page = ctx.pages().find((p) => !p.url().startsWith("devtools://")) ?? ctx.pages()[0];
if (!page) { console.error("no page"); process.exit(1); }

async function attach(p) {
  const cdp = await ctx.newCDPSession(p);
  cdp.on("Page.screencastFrame", async (f) => {
    try {
      write(Buffer.from(f.data, "base64"));
      await cdp.send("Page.screencastFrameAck", { sessionId: f.sessionId });
    } catch {}
  });
  await cdp.send("Page.startScreencast", {
    format: "jpeg", quality: 70, maxWidth: WIDTH, everyNthFrame: 1,
  });
  console.error("screencasting:", p.url());
  return cdp;
}
let session = await attach(page);

// follow newly opened tabs, so the HUD tracks whatever is being driven
ctx.on("page", async (p) => {
  try {
    await p.waitForLoadState("domcontentloaded").catch(() => {});
    try { await session.send("Page.stopScreencast"); } catch {}
    page = p; session = await attach(p);
  } catch {}
});
