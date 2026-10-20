import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { chromium } from "playwright-core";

assert(process.argv[2], "Pass a private scratch directory");
const dir = fs.mkdtempSync(path.join(path.resolve(process.argv[2]), "session-regex-"));
process.env.CUA_RUN_DIR = dir;
process.env.CUA_CONFIG = path.join(dir, "config.json");
fs.writeFileSync(process.env.CUA_CONFIG, '{"hud":{"enabled":false}}', { mode: 0o600 });
const { App } = await import("../server/lib/native.mjs");
const { Tab, findExecutable } = await import("../server/lib/browser.mjs");
const { Session } = await import("../server/lib/repl.mjs");
const { makeCodexApi } = await import("../server/lib/codex.mjs");
const browser = await chromium.launch({ executablePath: findExecutable(), headless: true });
let session, passed = 0, failed = 0, serial = 0;
async function check(name, fn) {
  try { await fn(); passed++; console.log("PASS", name); }
  catch (error) { failed++; console.error("FAIL", name, error); }
}
async function run(code) {
  const result = await session.run(code, { timeoutMs: 5000, maxOutputChars: 10000 });
  assert.equal(result.isError, false, result.content.map(c => c.text).join("\n"));
  return result.content.map(c => c.text).join("\n");
}
try {
  const page = await browser.newPage();
  await page.setContent('<button>Save</button><button>Cancel</button><button>a.b</button><button>axb</button>');
  const cdp = await page.context().newCDPSession(page);
  const { targetInfo } = await cdp.send("Target.getTargetInfo");
  const engine = { cdp: { send: (method, params) => cdp.send(method, params) }, tabs: new Map(), async ensure() {} };
  const tab = new Tab(engine, targetInfo, "owned-session");
  engine.tabs.set(tab.id, tab);
  // The native boundary supplies a snapshot only. No helper or native input starts.
  const app = new App({ hooks: {}, async req(cmd) {
    if (cmd === "releaseSnapshot") return {};
    assert.equal(cmd, "snapshot");
    return { generation: `owned-${++serial}`, windowId: 1,
      entries: ["Save", "Cancel", "a.b", "axb"].map((name, ref) => ({ indent: 0, ref, text: `button "${name}"` })) };
  } }, { pid: 100, process: "100:owned", windowId: 1, name: "Owned regex fixture" });
  session = new Session("owned-regex", ({ write, image }) => ({ app, tab,
    ...makeCodexApi({ engine, pw: { page: async () => page }, hud: {}, urls: () => ({}), write, image, opened: new Set(), hint() {} }) }));
  for (const api of ["app", "tab"]) {
    await check(`${api}.find accepts a regex literal from the Session VM`, async () => {
      const result = await run(`await ${api}.find(/button.*save/i)`);
      assert.match(result, /button.*Save/); assert.doesNotMatch(result, /Cancel/);
    });
    await check(`${api}.find keeps string punctuation literal`, async () => {
      const result = await run(`await ${api}.find("a.b")`);
      assert.match(result, /a\.b/); assert.doesNotMatch(result, /axb/);
    });
    await check(`${api}.find handles global patterns without changing caller state`, async () => {
      const result = JSON.parse(await run(`const expected = await ${api}.find(/button/i); const pattern = /button/gi; pattern.lastIndex = 5; const first = await ${api}.find(pattern); const second = await ${api}.find(pattern); JSON.stringify({same: expected.includes('"Save"') && expected.includes('"Cancel"') && first === expected && second === expected, lastIndex: pattern.lastIndex})`));
      assert.deepEqual(result, { same: true, lastIndex: 5 });
    });
    await check(`${api}.find keeps sticky flags and caller state`, async () => {
      const result = JSON.parse(await run(`const pattern = /^\\d+ button.*save/iy; pattern.lastIndex = 3; const found = await ${api}.find(pattern); JSON.stringify({found, lastIndex:pattern.lastIndex})`));
      assert.match(result.found, /button.*Save/); assert.doesNotMatch(result.found, /Cancel/);
      assert.equal(result.lastIndex, 3);
    });
  }
  await run(`const wrapped = await browser.tabs.get(${JSON.stringify(tab.id)})`);
  await check("Codex locators accept a direct regex from the Session VM", async () => {
    assert.equal(await run('await wrapped.playwright.getByText(/^save$/i).count()'), "1");
  });
  await check("Codex locator options keep nested regexes and timeout translation", async () => {
    assert.equal(await run('await wrapped.playwright.getByRole("button", {name:/^save$/i}).innerText({timeoutMs:1000})'), "Save");
    assert.equal(await run('await wrapped.playwright.getByRole("button").filter({hasText:/^cancel$/i}).count()'), "1");
  });
} finally {
  await session?.dispose();
  await browser.close();
}
console.log(`SESSION_REGEX_CHECKS passed=${passed} failed=${failed}`);
if (failed) process.exitCode = 1;
