import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "playwright-core";

const dir = fs.mkdtempSync(path.join(process.argv[2] ?? os.tmpdir(), "draft-ui-"));
process.env.CUA_RUN_DIR = dir; process.env.CUA_CONFIG = path.join(dir, "config.json"); process.env.CUA_HUD_APP = path.join(dir, "missing.app");
const backend = path.join(dir, "backend.mjs");
fs.writeFileSync(backend, "process.stdin.resume();process.stdin.on('end',()=>console.log(JSON.stringify({type:'result',is_error:false,result:'Fixture reply'})));");
fs.writeFileSync(process.env.CUA_CONFIG, JSON.stringify({ web: { port: 0 }, companion: { command: process.execPath, args: [backend] } }));
const { Pointers } = await import("../server/lib/pointer.mjs");
const { Companion } = await import("../server/lib/companion.mjs");
const { startWeb } = await import("../server/lib/web.mjs");
const { findExecutable } = await import("../server/lib/browser.mjs");
const pointers = new Pointers(), companion = new Companion({ pointers, native: {} });
const a = companion.create({ name: "First" }).id, b = companion.create({ name: "Second" }).id;
const web = startWeb({ engine: { running: false }, native: {}, hud: {}, token: "fixture-token", status: async () => ({}), companion });
const { port } = await web.listen(), origin = `http://127.0.0.1:${port}`;
const browser = await chromium.launch({ executablePath: findExecutable(), headless: true });
const page = await browser.newPage();
const errors = []; page.on("pageerror", error => errors.push(error.message));
await page.addInitScript(() => { window.nativeMessages = []; window.webkit = { messageHandlers: { barista: { postMessage: value => nativeMessages.push(value) } } }; });
try {
  await page.goto(origin + "/companion?t=fixture-token"); await page.waitForFunction(() => online);
  assert.equal(await page.evaluate(() => nativeMessages.some(m => m.action === "composerState")), false, "initial empty state cannot overwrite saved native drafts before restore");
  const restored = { epoch: 1, activeSessionID: a, drafts: { [a]: { text: "  First draft\n日本語 ☕", revision: 10, edit: 0 }, [b]: { text: "Second draft", revision: 20, edit: 0 } } };
  assert.equal(await page.evaluate(value => baristaRestoreDrafts(value), restored), true);
  await page.waitForFunction(() => nativeMessages.some(m => m.action === "draftsRestored"));
  assert.equal(await page.evaluate(() => active), a);
  assert.equal(await page.locator("#prompt").inputValue(), restored.drafts[a].text);
  const acknowledgment = await page.evaluate(() => nativeMessages.find(m => m.action === "draftsRestored"));
  assert.equal(acknowledgment.epoch, 1);
  assert.equal(await page.evaluate(() => nativeMessages.filter(m => m.action === "composerState").at(-1).epoch), 1);
  await page.evaluate(id => chooseSession(id), b);
  assert.equal(await page.locator("#prompt").inputValue(), "Second draft");
  assert.equal(await page.evaluate(({ a }) => baristaNativeDraft({ epoch: 0, id: a, text: "Stale page", edit: 99 }), { a }), false);
  assert.equal(await page.evaluate(({ a }) => baristaNativeDraft({ epoch: 1, id: a, text: "Committed IME text for the first draft", edit: 1 }), { a }), true, "native composition can finish under its original conversation after the web selection changes");
  assert.equal(await page.evaluate(() => active), b);
  assert.equal(await page.locator("#prompt").inputValue(), "Second draft", "the old owner's composition cannot enter the new destination");
  assert.equal(await page.evaluate(({ a }) => baristaNativeSubmit({ epoch: 1, id: a, text: "Do not send from the inactive editor", edit: 2 }), { a }), false);
  await page.evaluate(id => chooseSession(id), a);
  assert.equal(await page.locator("#prompt").inputValue(), "Committed IME text for the first draft");
  await page.route("**/api/companion/send", async route => {
    const response = await route.fetch();
    await page.evaluate(({ a }) => baristaNativeDraft({ epoch: 1, id: a, text: "New text after Submit", edit: 12 }), { a });
    await route.fulfill({ response });
  });
  await page.evaluate(({ a }) => baristaNativeSubmit({ epoch: 1, id: a, text: "First submitted question", edit: 11 }), { a });
  assert.equal(await page.locator("#prompt").inputValue(), "New text after Submit");
  const fresh = await page.evaluate(() => nativeMessages.filter(m => m.action === "composerState").at(-1));
  assert.equal(fresh.draft, "New text after Submit"); assert.equal(fresh.edit, 12);
  await page.unroute("**/api/companion/send"); await page.waitForFunction(() => current()?.status === "done");

  await page.route("**/api/companion/send", async route => {
    const response = await route.fetch();
    await page.evaluate(({ b }) => { chooseSession(b); baristaNativeDraft({ epoch: 1, id: b, text: "Keep the second draft", edit: 15 }); }, { b });
    await route.fulfill({ response });
  });
  await page.evaluate(({ a }) => baristaNativeSubmit({ epoch: 1, id: a, text: "Second submitted question", edit: 14 }), { a });
  assert.equal(await page.evaluate(() => active), b);
  assert.equal(await page.locator("#prompt").inputValue(), "Keep the second draft");
  const cleared = await page.evaluate(({ a }) => nativeMessages.filter(m => m.action === "draftChanged" && m.id === a).at(-1), { a });
  assert.equal(cleared.text, "", "an inactive conversation's acknowledged send also updates its native cache");
  assert.equal(cleared.edit, 14); assert.equal(cleared.epoch, 1);
  await page.unroute("**/api/companion/send");

  assert.equal(await page.evaluate(value => baristaRestoreDrafts(value), restored), true, "a repeated restore acknowledgment is harmless");
  assert.equal(await page.locator("#prompt").inputValue(), "Keep the second draft", "the same restore epoch cannot replay old text");
  const next = { epoch: 2, activeSessionID: b, drafts: { [a]: { text: "", revision: 12, edit: 14 }, [b]: { text: "Recovered after reload", revision: 21, edit: 15 } } };
  assert.equal(await page.evaluate(value => baristaRestoreDrafts(value), next), true);
  assert.equal(await page.evaluate(value => baristaRestoreDrafts(value), restored), false, "an old page's delayed restore cannot replace a new epoch");
  assert.equal(await page.evaluate(({ b }) => baristaNativeDraft({ epoch: 1, id: b, text: "Old page input", edit: 999 }), { b }), false);
  assert.equal(await page.locator("#prompt").inputValue(), "Recovered after reload");
  assert.equal(await page.evaluate(value => baristaRestoreDrafts(value), { epoch: 3, drafts: { [b]: { text: "x".repeat(8001), edit: 0, revision: 1 } } }), false);
  assert.equal(await page.locator("#prompt").inputValue(), "Recovered after reload", "invalid restore input is atomic");

  await page.evaluate(() => baristaNativeAdvanced({ visible: true }));
  await page.getByRole("button", { name: "Remove", exact: true }).click();
  await page.getByRole("button", { name: "Confirm removal", exact: true }).click();
  await page.waitForFunction(({ b }) => !state.sessions.some(s => s.id === b), { b });
  assert.equal(await page.evaluate(({ b }) => nativeMessages.filter(m => m.action === "draftForgotten" && m.id === b).length, { b }), 1, "only confirmed removal asks the cache to forget a conversation");
  for (const session of [...companion.sessions.values()]) companion.remove(session.id);
  await page.reload(); await page.waitForFunction(() => online);
  await page.evaluate(() => baristaRestoreDrafts({ epoch: 1, drafts: {} }));
  await page.waitForFunction(() => nativeDraftReady && active && state.sessions.length === 1);
  assert.equal(companion.snapshot().sessions[0].messages.length, 0, "the first native draft gets a local conversation without a model turn");
  assert.equal(companion.snapshot().sessions[0].status, "idle");
  assert.deepEqual(errors, []);
  console.log("PASS native draft restore handshake, epochs, delayed send acknowledgments, conversation isolation, and confirmed deletion");
} finally {
  await browser.close(); companion.close(); pointers.shutdown(); web.server.closeAllConnections(); await new Promise(resolve => web.server.close(resolve));
  fs.rmSync(dir, { recursive: true, force: true });
}
