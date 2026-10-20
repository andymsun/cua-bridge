import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const dir = fs.mkdtempSync(path.join(process.argv[2] ?? os.tmpdir(), "cua-companion-test-"));
process.env.CUA_RUN_DIR = dir;
process.env.CUA_CONFIG = path.join(dir, "config.json");
process.env.CUA_HUD_APP = path.join(dir, "missing.app");
const { Pointers, cleanTarget } = await import("../server/lib/pointer.mjs");
const pointers = new Pointers();
try {
  assert.deepEqual(cleanTarget({ screenRect: { x: -1600, y: 40, w: 300, h: 200 } }),
    { screenRect: { x: -1600, y: 40, w: 300, h: 200 } });
  assert.throws(() => cleanTarget({ screenRect: { x: 0, y: 0, w: -1, h: 2 } }), /rect/);
  assert.throws(() => cleanTarget({ screen: [1e100, 0] }), /range/, "screen coordinates cannot overflow native animation math");
  const id = pointers.session({ name: "Andy · Barista" });
  pointers.move(id, { screen: [-1200, 50] }, { text: "Here", persistent: true });
  pointers.describe(id, { text: "Here is the next step", state: "waiting" });
  let cursor = pointers.snapshot().cursors[id];
  assert.equal(cursor.name, "Andy · Barista");
  assert.equal(cursor.label, "Here is the next step");
  assert.equal(cursor.persistent, true);
  assert.equal(cursor.state, "waiting");
  const before = JSON.stringify(cursor);
  assert.throws(() => pointers.describe(id, { state: "unknown" }), /state/);
  assert.equal(JSON.stringify(pointers.snapshot().cursors[id]), before, "invalid updates are atomic");
  pointers.end(id);
  assert.equal(pointers.describe(id, { text: "late" }), false, "late output cannot revive a cursor");
  assert.deepEqual(pointers.snapshot().cursors, {});
  console.log("PASS named cursors, area targets, streamed labels, and cleanup");

  const { Companion } = await import("../server/lib/companion.mjs");
  const { App, NativeClient } = await import("../server/lib/native.mjs");
  const delayed = new NativeClient();
  let connected;
  delayed.ensure = () => new Promise(resolve => { connected = resolve; });
  let cancelled = false;
  const dispatch = delayed.req("press", {}, 1000, { beforeSend: () => { if (cancelled) throw new Error("session stopped"); } });
  cancelled = true; connected();
  await assert.rejects(dispatch, /session stopped/, "stop is checked after connection, immediately before input dispatch");
  const delivered = [];
  const client = { hooks: {}, async req(cmd, args) {
    if (cmd === "snapshot") return { generation: "snapshot-1", windowId: 4, title: "Fixture", entries: [{ text: 'button "Continue"', indent: 0, ref: 0 }] };
    if (cmd === "locate") return { windowId: 4, rect: { x: 0.2, y: 0.3, w: 0.1, h: 0.1 } };
    if (cmd === "press") { delivered.push(args.index); return { result: "pressed" }; }
    return {};
  } };
  const native = { apps: async () => [], app: async (_query, options) => {
    assert.equal(options.runningOnly, true, "companion tools never auto-launch a target app");
    return new App(client, { pid: 1, process: "fixture", name: "Fixture" });
  } };
  const companion = new Companion({ pointers, native });
  const guide = companion.create({ name: "Guide", mode: "guide" });
  const guideState = () => companion.snapshot().sessions.find(s => s.id === guide.id);
  assert.equal(guideState().hasMarks, false, "an empty conversation has no desktop marks to clear");
  companion.annotate(guide.id, {kind:"circle",rect:{x:100,y:100,w:120,h:60}});
  assert.equal(guideState().hasMarks, true, "the UI exposes a way to clear completed marks");
  assert.equal(pointers.snapshot().cursors[guide.cursor].state,"done","manual marks release an idle cursor after the display pause");
  companion.clear(guide.id);
  assert.equal(guideState().hasMarks, false, "clearing marks updates the UI without deleting the conversation");
  assert.equal(guideState().name, "Guide");
  await assert.rejects(companion.tool(guide.id, guide.key, "act", { app: "Fixture", index: 1, action: "click" }), /Guide mode/);
  assert.equal(delivered.length, 0);
  await companion.tool(guide.id, guide.key, "read", { app: "Fixture" });
  await companion.tool(guide.id, guide.key, "point", { app: "Fixture", index: 1, label: "Continue here", style: "spotlight" });
  cursor = Object.values(pointers.snapshot().cursors).find(c => c.name === "Guide");
  assert.equal(cursor.kind, "spotlight");
  assert.equal(cursor.persistent, true);
  await assert.rejects(companion.tool(guide.id, "wrong", "apps", {}), /session/);
  assert.ok(!JSON.stringify(companion.snapshot()).includes(guide.key), "private tool keys never reach the UI");

  const actor = companion.create({ name: "Helper", mode: "act" });
  await companion.tool(actor.id, actor.key, "read", { app: "Fixture" });
  const oversized = companion.tool(actor.id, actor.key, "act", { app: "Fixture", index: 1, action: "type", text: "x".repeat(2001) });
  const tooLong = assert.rejects(oversized, /2000/, "an approval must show the complete text that will be typed");
  await new Promise(r => setImmediate(r));
  const unexpected = companion.snapshot().sessions.find(s => s.id === actor.id).approval;
  if (unexpected) await companion.approve(actor.id, unexpected.id, false);
  await tooLong;
  const pending = companion.tool(actor.id, actor.key, "act", { app: "Fixture", index: 1, action: "click", reason: "Continue" });
  await new Promise(r => setImmediate(r));
  assert.equal(delivered.length, 0, "actions wait for approval");
  const approval = companion.snapshot().sessions.find(s => s.id === actor.id).approval;
  assert.equal(approval.action, "click");
  assert.equal(companion.snapshot().sessions.find(s => s.id === actor.id).presentation, "prompt", "approval stays accessible even after cursor output");
  await assert.rejects(companion.approve(actor.id, "stale", true), /approval/);
  await companion.approve(actor.id, approval.id, true);
  await pending;
  assert.deepEqual(delivered, [1]);

  await companion.tool(actor.id, actor.key, "read", { app: "Fixture" });
  const stopped = companion.tool(actor.id, actor.key, "act", { app: "Fixture", index: 1, action: "click" });
  const rejection = assert.rejects(stopped, /stopped/);
  await new Promise(r => setImmediate(r));
  companion.stop(actor.id);
  await rejection;
  assert.deepEqual(delivered, [1], "stop rejects an approval without sending input");
  await assert.rejects(companion.tool(actor.id, actor.key, "point", { app: "Fixture", index: 1 }), /session/);
  companion.stop(guide.id);
  assert.deepEqual(pointers.snapshot().cursors, {});
  companion.close();
  console.log("PASS guide restrictions, native targets, approval, stale keys, and stop");
} finally {
  pointers.shutdown();
  fs.rmSync(dir, { recursive: true, force: true });
}
