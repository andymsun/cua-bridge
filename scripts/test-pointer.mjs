import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

// Isolated run dir and a HUD path that does not exist, so no overlay is launched for real.
const temporary = fs.mkdtempSync(path.join(process.argv[2] ?? os.tmpdir(), "cua-pointer-test-"));
process.env.CUA_RUN_DIR = temporary;
process.env.CUA_CONFIG = path.join(temporary, "config.json");
process.env.CUA_HUD_APP = path.join(temporary, "missing.app");
const { Pointers, cleanTarget } = await import("../server/lib/pointer.mjs");
const { makeApiFactory } = await import("../server/lib/api.mjs");
const file = path.join(temporary, "pointers.json");
const read = () => JSON.parse(fs.readFileSync(file, "utf8"));

assert.deepEqual(cleanTarget({ screen: [10, 20] }), { screen: [10, 20] });
assert.deepEqual(cleanTarget({ windowId: 7, x: 0.5, y: 0.25 }), { windowId: 7, x: 0.5, y: 0.25 });
assert.throws(() => cleanTarget({ windowId: 7, x: 3, y: 0 }), /normalised/, "window points are fractions of the window");
assert.throws(() => cleanTarget({ windowId: -1, x: 0, y: 0 }), /windowId/);
assert.throws(() => cleanTarget({ screen: [NaN, 1] }), /finite/);

const p = new Pointers();
const a = p.session(), b = p.session();
assert.notEqual(a, b);
p.move(a, { screen: [1, 2] }, { text: "  the   save\nbutton " });
p.move(b, { windowId: 9, rect: { x: 0.1, y: 0.1, w: 0.2, h: 0.1 } }, { kind: "rect", text: "x".repeat(500) });
let doc = read();
assert.equal(doc.cursors[a].label, "the save button", "labels are one line");
assert.equal(doc.cursors[b].label.length, 120, "labels are bounded");
assert.notEqual(doc.cursors[a].color, doc.cursors[b].color, "each session gets its own colour");
assert.throws(() => p.move(a, { screen: [1, 2] }, { kind: "teleport" }), /kind/);
p.hide(a);
assert.equal(read().cursors[a], undefined, "a hidden cursor is not drawn");
p.end(b);
assert.deepEqual(read().cursors, {}, "a finished session's cursor goes away");

// The session API: pointing at an element centres on it; highlighting rings its frame; actions follow.
const fakeApp = {
  name: "Fixture",
  async locate(at) { return Array.isArray(at) ? { windowId: 4, x: 0.5, y: 0.5 } : { windowId: 4, rect: { x: 0.2, y: 0.4, w: 0.2, h: 0.2 } }; },
};
const pointers = new Pointers();
const { cua } = makeApiFactory({ engine: {}, native: {}, hud: {}, urls: () => ({}), pw: {}, pointers })({ write() {}, image() {} });
assert.match(await cua.point(fakeApp, 3, "Save"), /element 3 in Fixture: Save/);
let [mine] = Object.values(read().cursors);
assert.equal(mine.kind, "point");
assert.ok(Math.abs(mine.target.x - 0.3) < 1e-9 && Math.abs(mine.target.y - 0.5) < 1e-9, "points at the element's centre");
await cua.highlight(fakeApp, 3, "this panel");
[mine] = Object.values(read().cursors);
assert.deepEqual(mine.target.rect, { x: 0.2, y: 0.4, w: 0.2, h: 0.2 });
await cua.point({ x: 100, y: 200 }, "menu bar");
[mine] = Object.values(read().cursors);
assert.deepEqual(mine.target, { screen: [100, 200] });
await assert.rejects(cua.point("nope"), /point\(app/);
await cua.__dispose();
assert.deepEqual(read().cursors, {}, "disposing the session removes its cursor");
pointers.shutdown();
assert.equal(fs.existsSync(file), false, "daemon shutdown removes the feed, which ends the overlay");
console.log("PASS pointer");
fs.rmSync(temporary, { recursive: true, force: true });

// Guide mode and waiting for the person: real App objects over a fake helper.
{
  const { App } = await import("../server/lib/native.mjs");
  let snaps = 0, sent = [];
  const client = { hooks: {}, async req(cmd, args) {
    if (cmd === "snapshot") { snaps++; return { generation: `g${snaps}`, windowId: 5, title: "Fixture",
      // snapshot 3 is a transient shrink (the tree regrowing), not something the person did
      entries: snaps === 3 ? [] : [{ indent: 0, text: snaps < 5 ? 'button "Create pull request"' : 'text "Pull request opened"', ref: 0 }] }; }
    if (cmd !== "releaseSnapshot") sent.push(cmd); return { center: { x: 0.5, y: 0.5 } };
  } };
  const g = new Pointers();
  const { cua } = makeApiFactory({ engine: {}, native: { app: async () => new App(client, { pid: 1, process: "1:x", name: "Fixture" }) },
    hud: {}, urls: () => ({}), pw: {}, pointers: g })({ write() {}, image() {} });
  const app = await cua.app("Fixture");
  await app.read({ emit: false });
  cua.guide.start();
  await assert.rejects(app.click(0), /guide mode/, "guide mode refuses input");
  await assert.rejects(app.window(5).click(0), /guide mode/, "including on a chosen window");
  assert.deepEqual(sent, [], "nothing reached the helper");
  const changed = await app.waitForChange({ timeoutMs: 5000, intervalMs: 200 });
  assert.match(changed, /Pull request opened/, "a transient shrink is not a step; a lasting change is");
  assert.ok(snaps >= 6, "the change was confirmed by a second read");
  assert.equal(await app.waitForChange({ timeoutMs: 300, intervalMs: 200 }), "(timed out)");
  cua.guide.stop();
  await app.read({ emit: false });
  await app.click(0);
  assert.deepEqual(sent, ["press"], "input works again after guide mode");
  g.shutdown();
  console.log("PASS guide mode");
}
