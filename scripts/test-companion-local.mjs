import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import childProcess from "node:child_process";
import { syncBuiltinESMExports } from "node:module";
import { test, after, mock } from "node:test";

const dir = fs.mkdtempSync(path.join(process.argv[2] ?? os.tmpdir(), "companion-local-"));
process.env.CUA_RUN_DIR = dir;
process.env.CUA_CONFIG = path.join(dir, "config.json");
let spawned = 0;
mock.method(childProcess, "spawn", () => { spawned++; throw new Error("Local route started a model"); });
syncBuiltinESMExports();
const { Companion } = await import("../server/lib/companion.mjs");
const { Pointers } = await import("../server/lib/pointer.mjs");
const { saveConfig } = await import("../server/lib/config.mjs");
const { App } = await import("../server/lib/native.mjs");
const context = { pid: 412, process: "412:1792440000.125", windowId: 91, app: "Notes", bundleId: "test.notes", cursorOrigin: { x: -900.5, y: 42.25 } };
const matched = { status: "matched", name: "Save", role: "button", windowId: 91, target: { windowId: 91, rect: { x: 0.2, y: 0.4, w: 0.2, h: 0.1 } } };
const tick = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
function setup(native = {}) {
  fs.rmSync(path.join(dir, "companion-history.json"), { force: true });
  const pointers = new Pointers();
  let launches = 0;
  pointers.launch = () => { launches++; };
  const calls = [];
  const companion = new Companion({ pointers, native: {
    ensure: async () => {},
    apps: async options => { calls.push(["apps", options]); return [{ name: "Notes", bundleId: "test.notes", pid: 412, process: context.process, active: true }]; },
    lookup: async (query, options) => { calls.push(["lookup", query, options]); return structuredClone(matched); },
    app: async () => { throw new Error("Auto-launching resolver is forbidden"); },
    ...native,
  } });
  const session = companion.create();
  return { companion, pointers, session, calls, launches: () => launches,
    state: () => companion.snapshot().sessions.find(s => s.id === session.id),
    close() { companion.close(); pointers.shutdown(); } };
}
after(() => { mock.restoreAll(); syncBuiltinESMExports(); fs.rmSync(dir, { recursive: true, force: true }); });

test("exact spatial request reserves its synchronous turn and publishes only a normalized cursor", async () => {
  const f = setup();
  try {
    f.companion.setModel(f.session.id, "codex/gpt-5.6-sol");
    const start = f.companion.send(f.session.id, { prompt: "point at the Save button", context });
    assert.equal(typeof start.then, "undefined", "send keeps the synchronous snapshot contract");
    assert.equal(start.sessions[0].status, "thinking");
    assert.equal(start.sessions[0].route, "local");
    assert.throws(() => f.companion.send(f.session.id, { prompt: "again" }), /current turn/);
    assert.equal(f.calls.length, 0, "the turn is reserved before the first await");
    await tick();
    const state = f.state();
    assert.equal(state.status, "done");
    assert.equal(state.presentation, "cursor");
    assert.equal(state.requestedModel, null);
    assert.equal(state.reportedModel, null);
    assert.equal(spawned, 0);
    assert.deepEqual(f.calls.map(c => c[0]), ["lookup"], "fresh identity does not trigger app discovery or snapshot reads");
    assert.deepEqual(f.calls[0][1], { pid: 412, process: context.process, windowId: 91, name: "Save", role: "button" });
    const feed = JSON.parse(fs.readFileSync(path.join(dir, "pointers.json"), "utf8"));
    const cursor = feed.cursors[f.session.cursor];
    assert.ok(Math.abs(cursor.target.x - 0.3) < 1e-9);
    assert.equal(cursor.target.y, 0.45);
    assert.equal(cursor.target.windowId, 91);
    assert.deepEqual(cursor.origin, context.cursorOrigin);
    assert.equal(cursor.label, "Save", "completion must not replace the spatial label with chat boilerplate");
    for (const stage of ["parseMs", "lookupMs", "pointerPublishMs", "totalMs"]) assert.ok(Number.isFinite(state.timings[stage]), stage);
    assert.ok(state.timings.pointerPublishMs <= state.timings.totalMs);
    assert.equal(state.timings.spawnMs, undefined);
    assert.equal(state.timings.visibleMs, undefined, "file publication is not rendered arrival");
    assert.equal(f.session.key, null);
  } finally { f.close(); }
});

test("circle and highlight use normalized rectangles and retain cursor-first completion", async () => {
  for (const kind of ["circle", "highlight"]) {
    const f = setup();
    try {
      f.companion.send(f.session.id, { prompt: `${kind} the Save button`, context });
      await tick();
      assert.equal(f.state().presentation, "cursor");
      const mark = f.pointers.snapshot().cursors[f.session.cursor].annotations[0];
      assert.equal(mark.kind, kind);
      assert.deepEqual(mark.target, matched.target);
    } finally { f.close(); }
  }
});

test("a submitted lookup prepares its helper without reading or launching a target app", async () => {
  let ready = false;
  const f = setup({ ensure: async () => { ready = true; }, lookup: async () => {
    if (!ready) throw new Error("Native helper is not running");
    return structuredClone(matched);
  } });
  try {
    f.companion.warm(); assert.equal(ready, false, "popup warm does not start native access");
    f.companion.send(f.session.id, { prompt: "point to Save", context }); await tick();
    assert.equal(f.state().status, "done"); assert.equal(f.state().presentation, "cursor"); assert.equal(spawned, 0);
  } finally { f.close(); }
});

test("stop during helper preparation prevents lookup and cursor publication", async () => {
  const gate = deferred(); let lookups = 0;
  const f = setup({ ensure: () => gate.promise, lookup: async () => { lookups++; return structuredClone(matched); } });
  try {
    f.companion.send(f.session.id, { prompt: "point to Save", context }); await tick();
    f.companion.stop(f.session.id); gate.resolve(); await tick();
    assert.equal(lookups, 0); assert.equal(f.state().status, "stopped"); assert.deepEqual(f.pointers.snapshot().cursors, {});
  } finally { gate.resolve(); f.close(); }
});

test("legacy app context resolves exact current running metadata without resolve or inference", async () => {
  for (const legacy of [{ app: "Notes" }, { app: "412" }, { bundleId: "test.notes" }, { pid: 412 }, {}]) {
    const f = setup();
    try {
      f.companion.send(f.session.id, { prompt: 'circle "Save"', context: legacy });
      await tick();
      assert.equal(f.state().status, "done");
      assert.equal(f.state().presentation, "cursor");
      assert.equal(f.calls[0][0], "apps");
      assert.equal(f.calls[0][1].passive, true);
      assert.equal(typeof f.calls[0][1].beforeSend, "function");
      assert.equal(f.calls[1][1].process, context.process);
      assert.equal(f.calls[1][1].windowId, undefined);
    } finally { f.close(); }
  }
});

test("running app discovery refuses ambiguous, substring, stale and missing identities", async () => {
  const notes = { name: "Notes", bundleId: "test.notes", pid: 412, process: context.process, active: true };
  const cases = [
    [[], { app: "Notes" }],
    [[notes, { ...notes, pid: 413, process: "413:1792440001" }], { app: "Notes" }],
    [[notes], { app: "Note" }],
    [[{ ...notes, process: "" }], { app: "Notes" }],
    [[notes], { pid: 999 }],
    [[{ ...notes, active: false }], {}],
  ];
  for (const [apps, selected] of cases) {
    const f = setup({ apps: async () => apps });
    try {
      f.companion.send(f.session.id, { prompt: "point to Save", context: selected });
      await tick();
      assert.equal(f.state().presentation, "prompt");
      assert.ok(f.state().messages.at(-1).text);
      assert.equal(f.calls.length, 0, "an unresolved process never reaches lookup");
      assert.deepEqual(f.pointers.snapshot().cursors, {});
    } finally { f.close(); }
  }
  assert.equal(spawned, 0);
});

test("unresolved native results and malformed matches stay local with no stale pointer", async () => {
  const results = [
    ...["ambiguous", "not_found", "incomplete", "unavailable"].map(status => ({ status, message: `Fixture ${status}` })),
    { ...matched, name: "Save as" }, { ...matched, role: "link" }, { ...matched, windowId: 92 },
    { ...matched, target: { windowId: 92, rect: matched.target.rect } },
    { ...matched, target: { windowId: 91, rect: { x: 200, y: 100, w: 50, h: 40 } } },
    { ...matched, target: { windowId: 91, rect: { x: 0.9, y: 0.1, w: 0.2, h: 0.1 } } },
    { ...matched, target: { windowId: 91, rect: { x: 0, y: 0, w: 0, h: 0.1 } } },
    null,
  ];
  for (const result of results) {
    const f = setup({ lookup: async () => result });
    try {
      f.pointers.move(f.session.cursor, { screen: [200, 100] }, { text: "old output" });
      f.companion.send(f.session.id, { prompt: "point at Save button", context });
      await tick();
      assert.equal(f.state().route, "local");
      assert.equal(f.state().presentation, "prompt");
      assert.ok(f.state().messages.at(-1).text);
      assert.deepEqual(f.pointers.snapshot().cursors, {});
      assert.equal(f.state().timings.pointerPublishMs, undefined);
    } finally { f.close(); }
  }
  assert.equal(spawned, 0);
});

test("explicit app selection never reuses a different app's window or refreshes a stale identity", async () => {
  const f = setup({ apps: async () => [{ name: "Editor", bundleId: "test.editor", pid: 777, process: "777:1792440100" }] });
  try {
    f.companion.send(f.session.id, { prompt: "circle Save in Editor", context });
    await tick();
    assert.deepEqual(f.calls[0][1], { pid: 777, process: "777:1792440100", name: "Save" });
    assert.equal(f.state().presentation, "cursor");
    f.companion.send(f.session.id, { prompt: "circle Save in Editor", context: { ...context, app: "Editor", bundleId: "test.editor" } });
    await tick();
    assert.equal(f.state().presentation, "prompt");
    assert.match(f.state().messages.at(-1).text, /identity changed/);
    assert.equal(f.calls.length, 1, "a stale supplied identity cannot be silently replaced");
  } finally { f.close(); }
});

test("every turn looks up fresh geometry and copies context before async work", async () => {
  let lookups = 0;
  const f = setup({ lookup: async query => {
    assert.equal(query.process, context.process);
    return { ...matched, target: { windowId: 91, rect: { x: ++lookups / 10, y: 0.4, w: 0.2, h: 0.1 } } };
  } });
  try {
    for (let turn = 1; turn <= 2; turn++) {
      const mutable = structuredClone(context);
      f.companion.send(f.session.id, { prompt: "circle Save", context: mutable });
      mutable.process = "412:9"; mutable.cursorOrigin.x = 0;
      await tick();
      const cursor = f.pointers.snapshot().cursors[f.session.cursor];
      assert.equal(cursor.target.rect.x, turn / 10);
      assert.deepEqual(cursor.origin, context.cursorOrigin);
      assert.equal(cursor.annotations.length, 1, "a new turn does not retain stale marks");
    }
    assert.equal(lookups, 2);
  } finally { f.close(); }
});

test("bad context and parser ambiguity fail locally before native calls", async () => {
  const cases = [
    ["circle Save and Cancel", context],
    ['circle "Save" then click it', context],
    ["circle Save", { ...context, process: "412:old" }],
    ["circle Save", { ...context, process: "999:1792440000" }],
    ["circle Save", { ...context, pid: "412" }],
    ["circle Save", { ...context, windowId: 0 }],
    ["circle Save", { ...context, cursorOrigin: { x: Infinity, y: 1 } }],
    ["circle Save", { ...context, cursorOrigin: { x: 1e12, y: 1 } }],
  ];
  for (const [prompt, value] of cases) {
    const f = setup();
    try {
      f.companion.send(f.session.id, { prompt, context: value });
      await tick();
      assert.equal(f.state().presentation, "prompt");
      assert.equal(f.calls.length, 0);
      assert.equal(spawned, 0);
    } finally { f.close(); }
  }
});

test("cancellation at each local await cannot publish or finish a restarted turn", async () => {
  for (const stage of ["queued", "apps", "lookup"]) {
    const pending = deferred();
    let first = true;
    const f = setup({
      ...(stage === "apps" ? { apps: () => first ? (first = false, pending.promise) : Promise.resolve([{ name: "Notes", pid: 412, process: context.process }]) } : {}),
      ...(stage === "lookup" ? { lookup: () => first ? (first = false, pending.promise) : Promise.resolve(matched) } : {}),
    });
    try {
      const selected = stage === "apps" ? { app: "Notes" } : context;
      f.companion.send(f.session.id, { prompt: "point at Save button", context: selected });
      const oldKey = f.session.key;
      if (stage !== "queued") await tick();
      f.companion.stop(f.session.id);
      f.companion.send(f.session.id, { prompt: "circle Save button", context: selected });
      await tick();
      const stable = structuredClone(f.state());
      pending.resolve(stage === "apps" ? [{ name: "Notes", pid: 999, process: "999:1" }] : { ...matched, name: "stale" });
      await tick();
      assert.deepEqual(f.state(), stable, `${stage}: late completion cannot alter the new turn`);
      assert.equal(f.state().presentation, "cursor");
      assert.equal(f.pointers.snapshot().cursors[f.session.cursor].annotations.length, 1);
      await assert.rejects(f.companion.tool(f.session.id, oldKey, "apps"), /stopped|expired/);
    } finally { f.close(); }
  }
});

test("late rejection and removed sessions are ignored without unhandled rejections", async () => {
  for (const remove of [false, true]) {
    const pending = deferred();
    const f = setup({ lookup: () => pending.promise });
    f.companion.send(f.session.id, { prompt: "circle Save", context });
    await tick();
    if (remove) f.companion.remove(f.session.id); else f.companion.stop(f.session.id);
    pending.reject(new Error("late native failure"));
    await tick();
    assert.deepEqual(f.pointers.snapshot().cursors, {});
    if (!remove) assert.equal(f.state().error, null);
    f.close();
  }
});

test("stop during a guide wait's final sleep still rejects the expired turn", async () => {
  const client = { hooks: {}, req: async command => command === "windows" ? [{ windowId: 91, title: "Notes fixture" }]
    : command === "snapshot" ? { generation: "wait-snapshot", windowId: 91, title: "Notes fixture", entries: [{ text: 'text "Still waiting"', indent: 0, ref: 0 }] } : {} };
  const f = setup({ app: async () => new App(client, { pid: 412, process: context.process, name: "Notes", bundleId: "test.notes" }) });
  mock.timers.enable({ apis: ["setTimeout", "Date"] });
  try {
    const key = f.session.key;
    await f.companion.tool(f.session.id, key, "read", { app: "Notes" });
    const waiting = f.companion.tool(f.session.id, key, "wait", { app: "Notes", contains: "Finished" });
    const rejected = assert.rejects(waiting, /stopped|expired/);
    await tick();
    f.companion.stop(f.session.id);
    mock.timers.tick(30000);
    await rejected;
  } finally { mock.timers.reset(); f.close(); }
});

test("local turns have a bounded timeout and late lookup cannot revive them", async () => {
  const pending = deferred();
  const f = setup({ lookup: () => pending.promise });
  mock.timers.enable({ apis: ["setTimeout"] });
  try {
    f.companion.send(f.session.id, { prompt: "circle Save", context });
    await tick();
    mock.timers.tick(15000);
    assert.equal(f.state().status, "error");
    assert.equal(f.state().presentation, "prompt");
    pending.resolve(matched);
    await tick();
    assert.equal(f.state().status, "error");
    assert.deepEqual(f.pointers.snapshot().cursors, {});
  } finally { mock.timers.reset(); f.close(); }
});

test("warm only prepares the pointer feed and leaves conversations and other cursors intact", () => {
  const f = setup();
  try {
    assert.equal(typeof f.companion.warm, "function");
    const before = structuredClone(f.companion.snapshot());
    f.companion.warm();
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(dir, "pointers.json"), "utf8")).cursors, {});
    assert.deepEqual(f.companion.snapshot(), before);
    assert.equal(f.launches(), 1);
    assert.equal(f.calls.length, 0);
    assert.equal(spawned, 0);
    const other = f.pointers.session({ name: "Other" });
    f.pointers.move(other, { screen: [10, 20] });
    f.companion.warm();
    assert.deepEqual(f.pointers.snapshot().cursors[other].target, { screen: [10, 20] });
    saveConfig({ pointer: { enabled: false } });
    const launches = f.launches();
    f.companion.warm();
    assert.equal(f.launches(), launches, "warming respects pointer.enabled");
  } finally { saveConfig({}); f.close(); }
});

test("a failed stale-feed clear does not reserve a turn, and stop still revokes the key", () => {
  const f = setup(), feed = path.join(dir, "pointers.json");
  try {
    f.pointers.move(f.session.cursor, { screen: [1, 2] });
    fs.rmSync(feed); fs.mkdirSync(feed);
    assert.throws(() => f.companion.send(f.session.id, { prompt: "circle Save", context }), /EISDIR|directory/);
    assert.equal(f.session.status, "idle");
    assert.equal(f.session.turn, undefined);
    assert.doesNotThrow(() => f.companion.stop(f.session.id));
    assert.equal(f.session.key, null);
    assert.equal(f.session.status, "stopped");
    assert.ok(f.state().error, "a failed feed clear remains visible as an error");
  } finally { fs.rmSync(feed, { recursive: true, force: true }); f.close(); }
});

test("a failed feed publication finishes locally without a cursor-success claim or unhandled error", async () => {
  const f = setup(), feed = path.join(dir, "pointers.json");
  fs.mkdirSync(feed);
  try {
    f.companion.send(f.session.id, { prompt: "circle Save", context });
    await tick();
    assert.equal(f.state().status, "error");
    assert.equal(f.state().presentation, "prompt");
    assert.match(f.state().messages.at(-1).text, /EISDIR|directory/);
    assert.equal(f.state().timings.pointerPublishMs, undefined);
    assert.equal(f.session.key, null);
    assert.deepEqual(f.pointers.snapshot().cursors, {});
  } finally { fs.rmSync(feed, { recursive: true, force: true }); f.close(); }
});

test("local success does not depend on model configuration; disabled output is not false success", async () => {
  saveConfig({ companion: { command: "", args: "invalid", model: "unapproved" } });
  const f = setup();
  try {
    f.companion.send(f.session.id, { prompt: "circle Save", context });
    await tick();
    assert.equal(f.state().presentation, "cursor");
    saveConfig({ pointer: { enabled: false } });
    f.companion.send(f.session.id, { prompt: "circle Save", context });
    await tick();
    assert.equal(f.state().presentation, "prompt");
    assert.match(f.state().messages.at(-1).text, /pointer.*(off|disabled)/i);
    assert.equal(f.state().timings.pointerPublishMs, undefined);
  } finally { saveConfig({}); f.close(); }
});
