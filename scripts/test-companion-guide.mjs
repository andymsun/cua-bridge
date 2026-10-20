import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test, after, mock } from "node:test";

const dir = fs.mkdtempSync(path.join(process.argv[2] ?? os.tmpdir(), "companion-guide-"));
process.env.CUA_RUN_DIR = dir;
process.env.CUA_CONFIG = path.join(dir, "config.json");
const fixture = path.join(dir, "backend.mjs"), record = path.join(dir, "launch.json"), release = path.join(dir, "release");
fs.writeFileSync(fixture, `
import fs from 'node:fs';
const args=process.argv.slice(2),model=args[args.indexOf('--model')+1],mcp=JSON.parse(args[args.indexOf('--mcp-config')+1]);
let prompt='';process.stdin.setEncoding('utf8');process.stdin.on('data',x=>prompt+=x);
process.stdin.on('end',()=>{
 fs.writeFileSync(${JSON.stringify(record)},JSON.stringify({args,prompt,key:mcp.mcpServers.barista.env.CUA_COMPANION_KEY}));
 console.log(JSON.stringify({type:'stream_event',event:{type:'message_start',message:{model}}}));
 const timer=setInterval(()=>{if(fs.existsSync(${JSON.stringify(release)})){
  clearInterval(timer);const error=fs.readFileSync(${JSON.stringify(release)},'utf8')==='error';
  console.log(JSON.stringify({type:'result',is_error:error,result:error?'Fixture provider failed':'Fixture reply'}));
 }},10);
});
`);
const { Companion } = await import("../server/lib/companion.mjs");
const { Pointers } = await import("../server/lib/pointer.mjs");
const { NativeClient } = await import("../server/lib/native.mjs");
const { saveConfig } = await import("../server/lib/config.mjs");
const tick = () => new Promise(r => setImmediate(r));
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
async function until(check) {
  const deadline = Date.now() + 5000;
  while (!check()) { assert(Date.now() < deadline, "Fixture did not reach its expected state"); await new Promise(r => setTimeout(r, 10)); }
}
function setup() {
  for (const file of [record, release, path.join(dir, "companion-history.json")]) fs.rmSync(file, { force: true });
  saveConfig({ companion: { command: process.execPath, args: [fixture] } });
  const pointers = new Pointers(); pointers.launch = () => {};
  const native = new NativeClient(), calls = [];
  const desktop = { pid: 4242, process: "4242:1", windows: [{ windowId: 41, title: "Lesson" }], content: "Step not complete", generation: 0 };
  native.req = async (command, args = {}, _timeout, options = {}) => {
    options.beforeSend?.(); calls.push({ command, args });
    if (command === "apps") return [{ pid: desktop.pid, process: desktop.process, name: "Study Fixture", bundleId: "local.cua.StudyFixture" }];
    if (args.pid !== undefined) assert.equal(args.process, desktop.process, "no old process identity reaches a fresh read");
    if (command === "windows") { if (desktop.windowGate) await desktop.windowGate.promise; return desktop.windows; }
    if (command === "snapshot") {
      if (desktop.readGate) return desktop.readGate.promise;
      const window = desktop.windows.find(w => w.windowId === args.windowId) ?? (args.windowId === undefined && desktop.windows.length === 1 ? desktop.windows[0] : null);
      assert(window, "an exact live fixture window must be selected");
      return { generation: String(++desktop.generation), windowId: window.windowId, title: window.title, entries: [{ text: `text ${JSON.stringify(desktop.content)}`, indent: 0, ref: 0 }] };
    }
    if (command === "locate") return { windowId: args.windowId, rect: { x: 0.2, y: 0.3, w: 0.2, h: 0.1 } };
    if (command === "releaseSnapshot") return {};
    throw new Error("Unexpected native input: " + command);
  };
  const companion = new Companion({ pointers, native }), session = companion.create();
  const f = { companion, session, pointers, native, calls, desktop, state: () => companion.snapshot().sessions.find(s => s.id === session.id),
    async begin(prompt = "Help me with this lesson", mode = "guide") {
      fs.rmSync(release, { force: true });
      companion.send(session.id, { prompt, mode }); await f.launched(); return session.key;
    },
    async launched() { await until(() => fs.existsSync(record) && JSON.parse(fs.readFileSync(record, "utf8")).key === session.key); },
    async read(windowId, app = "4242") { return companion.tool(session.id, session.key, "read", { app, ...(windowId ? { windowId } : {}) }); },
    async finish(error = false) { fs.writeFileSync(release, error ? "error" : "done"); await until(() => session.status !== "thinking"); },
    async pause() {
      await f.begin(); await f.read();
      await companion.tool(session.id, session.key, "point", { app: "4242", index: 1, label: "Complete the first exercise" });
      mock.timers.enable({ apis: ["setTimeout", "Date"] });
      try {
        const waiting = companion.tool(session.id, session.key, "wait", { app: "4242", contains: "Exercise complete" });
        await tick();
        assert.throws(() => companion.resume(session.id, f.state().guide.id), /current turn/i, "Continue cannot restart the original active wait");
        mock.timers.tick(30000); await waiting;
      } finally { mock.timers.reset(); }
      await f.finish(); return f.state().guide;
    },
    close() { mock.timers.reset(); companion.close(); pointers.shutdown(); }
  };
  return f;
}
after(() => fs.rmSync(dir, { recursive: true, force: true }));

test("a timed-out manual wait saves inert context and finishes paused, not done", async () => {
  const f = setup();
  try {
    const step = await f.pause();
    assert.equal(f.state().status, "paused");
    assert.equal(step.contains, "Exercise complete");
    assert.equal(step.label, "Complete the first exercise");
    assert.deepEqual(step.app, { name: "Study Fixture", bundleId: "local.cua.StudyFixture" });
    assert.equal(step.windowTitle, "Lesson");
    assert.equal(typeof step.id, "string");
    const saved = JSON.parse(fs.readFileSync(f.companion.historyPath, "utf8"))[0];
    assert.deepEqual(saved.guide, step);
    for (const key of ["pid", "process", "windowId", "generation", "key", "approval", "target"]) assert(!Object.hasOwn(step, key), key + " is not checkpoint authority");
    assert.equal(f.session.key, null);
    assert.equal(f.pointers.snapshot().cursors[f.session.cursor].state, "done", "a paused step releases the active pointer after its normal hold");
  } finally { f.close(); }
});

test("two successful current reads clear the checkpoint, while one read does not", async () => {
  const f = setup();
  try {
    await f.begin(); await f.read(); f.desktop.content = "Exercise complete";
    mock.timers.enable({ apis: ["setTimeout", "Date"] });
    const waiting = f.companion.tool(f.session.id, f.session.key, "wait", { app: "4242", contains: "Exercise complete" });
    await tick(); assert(f.state().guide);
    mock.timers.tick(750); await waiting; mock.timers.reset();
    assert.equal(f.state().guide, null);
    await f.finish(); assert.equal(f.state().status, "done");
  } finally { f.close(); }
});

test("Stop during wait registration cannot install a late checkpoint", async () => {
  const f = setup();
  try {
    await f.begin(); await f.read(); f.desktop.windowGate = deferred();
    const waiting = f.companion.tool(f.session.id, f.session.key, "wait", { app: "4242", contains: "Exercise complete" });
    const rejected = assert.rejects(waiting, /stopped|expired/);
    await tick(); f.companion.stop(f.session.id); f.desktop.windowGate.resolve(); await rejected;
    assert.equal(f.state().status, "stopped"); assert.equal(f.state().guide, null);
  } finally { f.close(); }
});

test("late expected text after Stop cannot clear a newer manual step", async () => {
  const f = setup();
  try {
    await f.begin(); await f.read(); f.desktop.readGate = deferred();
    const oldKey = f.session.key, waiting = f.companion.tool(f.session.id, oldKey, "wait", { app: "4242", contains: "Exercise complete" });
    const rejected = assert.rejects(waiting, /stopped|expired/);
    await tick(); assert(f.state().guide); const pending = f.desktop.readGate; delete f.desktop.readGate;
    f.companion.stop(f.session.id); await f.begin("Help with the next exercise"); await f.read();
    mock.timers.enable({ apis: ["setTimeout", "Date"] });
    const next = f.companion.tool(f.session.id, f.session.key, "wait", { app: "4242", contains: "Second exercise complete" });
    await tick(); const fresh = structuredClone(f.state().guide);
    pending.resolve({ generation: "old", windowId: 41, title: "Lesson", entries: [{ text: 'text "Exercise complete"', indent: 0, ref: 0 }] });
    await rejected; assert.deepEqual(f.state().guide, fresh);
    mock.timers.tick(30000); await next; mock.timers.reset();
    await f.finish(); assert.deepEqual(f.state().guide, fresh);
  } finally { f.close(); }
});

test("Continue rejects busy and stale requests, then reserves one fresh chosen-model turn", async () => {
  const f = setup();
  try {
    const step = await f.pause(), oldRecord = JSON.parse(fs.readFileSync(record, "utf8"));
    f.companion.setModel(f.session.id, "codex/gpt-5.6-sol");
    const before = fs.readFileSync(f.companion.historyPath, "utf8");
    assert.throws(() => f.companion.resume(f.session.id, "stale"), /guide|step/i);
    assert.equal(fs.readFileSync(f.companion.historyPath, "utf8"), before);
    fs.rmSync(release, { force: true });
    const first = f.companion.resume(f.session.id, step.id);
    assert.equal(first.sessions[0].status, "thinking");
    assert.throws(() => f.companion.resume(f.session.id, step.id), /current turn/i);
    assert.notEqual(f.session.key, oldRecord.key);
    await f.launched();
    const launch = JSON.parse(fs.readFileSync(record, "utf8"));
    assert.equal(launch.args[launch.args.indexOf("--model") + 1], "codex/gpt-5.6-sol");
    assert.match(launch.prompt, /Continue/);
    const system = launch.args[launch.args.indexOf("--system-prompt") + 1];
    assert(system.includes(step.contains)); assert.match(system, /fresh|read/i);
    await assert.rejects(f.companion.tool(f.session.id, oldRecord.key, "apps"), /stopped|expired/);
    await f.finish(); assert.equal(f.state().status, "paused", "a reply alone cannot complete the step");
  } finally { f.close(); }
});

test("Continue resolves a restarted app and cannot accept expected text in another window", async () => {
  const f = setup();
  try {
    const step = await f.pause();
    f.desktop.pid = 5252; f.desktop.process = "5252:2";
    f.desktop.windows = [{ windowId: 51, title: "Other document" }, { windowId: 52, title: "Lesson" }];
    fs.rmSync(release, { force: true }); f.companion.resume(f.session.id, step.id); await f.launched();
    await f.read(51, "5252"); f.desktop.content = "Exercise complete";
    await assert.rejects(f.companion.tool(f.session.id, f.session.key, "wait", { app: "5252", windowId: 51, contains: step.contains }), /window|guide/i);
    assert.equal(f.state().guide.id, step.id);
    await f.read(52, "5252");
    mock.timers.enable({ apis: ["setTimeout", "Date"] });
    const waiting = f.companion.tool(f.session.id, f.session.key, "wait", { app: "5252", windowId: 52, contains: step.contains });
    await tick(); mock.timers.tick(750); await waiting; mock.timers.reset();
    await f.finish(); assert.equal(f.state().guide, null); assert.equal(f.state().status, "done");
  } finally { f.close(); }
});

test("an ambiguous saved window needs a current explicit choice before any backend starts", async () => {
  const f = setup();
  try {
    const step = await f.pause(), before = fs.readFileSync(record, "utf8");
    f.desktop.windows = [{ windowId: 51, title: "Lesson" }, { windowId: 52, title: "Lesson" }];
    fs.rmSync(release, { force: true }); f.companion.resume(f.session.id, step.id);
    await until(() => f.session.status === "error");
    assert.match(f.state().error, /window/i); assert.equal(f.state().guide.id, step.id);
    assert.equal(fs.readFileSync(record, "utf8"), before);
    assert.deepEqual(f.state().guideWindows.windows, f.desktop.windows);
    f.companion.resume(f.session.id, step.id, { app: "Study Fixture", pid: 4242, process: "4242:1", windowId: 52 });
    await f.launched(); await f.finish(); assert.equal(f.state().status, "paused");
  } finally { f.close(); }
});

test("Stop during Continue resolution keeps the checkpoint without a late backend launch", async () => {
  const f = setup();
  try {
    const step = await f.pause(), before = fs.readFileSync(record, "utf8");
    f.desktop.windowGate = deferred(); fs.rmSync(release, { force: true });
    f.companion.resume(f.session.id, step.id); await tick(); f.companion.stop(f.session.id);
    f.desktop.windowGate.resolve(); await tick();
    assert.equal(f.state().status, "stopped"); assert.equal(f.state().guide.id, step.id);
    assert.equal(fs.readFileSync(record, "utf8"), before);
  } finally { f.close(); }
});

test("restart restores a paused checkpoint without reads, authority, or automatic work", async () => {
  const f = setup(); let restored;
  try {
    const step = await f.pause(); f.companion.stop(f.session.id);
    const before = fs.readFileSync(f.companion.historyPath, "utf8"), count = f.calls.length;
    restored = new Companion({ pointers: f.pointers, native: f.native });
    const session = restored.get(f.session.id);
    assert.equal(session.status, "paused"); assert.equal(session.key, null); assert.equal(session.cursor, null);
    assert.equal(session.child, undefined); assert.equal(session.guideTarget, undefined);
    assert.deepEqual(restored.snapshot().sessions[0].guide, step);
    await tick(); assert.equal(f.calls.length, count); assert.equal(fs.readFileSync(f.companion.historyPath, "utf8"), before);
  } finally { restored?.close(); f.close(); }
});

test("invalid saved checkpoints are unusable, while messages and the source file stay intact", async () => {
  const f = setup();
  try {
    const step = await f.pause(); f.companion.close();
    for (const invalid of [null, {}, { ...step, id: "" }, { ...step, app: { name: "4242" } }, { ...step, app: { name: "Study Fixture", bundleId: " 4242 " } }, { ...step, contains: "x".repeat(501) }, { ...step, windowTitle: [] }]) {
      const saved = [{ id: "restored", name: "Keep", messages: [{ role: "user", text: "Keep the lesson" }], guide: invalid }];
      fs.writeFileSync(f.companion.historyPath, JSON.stringify(saved));
      const before = fs.readFileSync(f.companion.historyPath, "utf8"), restored = new Companion({ pointers: f.pointers, native: f.native });
      assert.equal(restored.snapshot().sessions[0].guide, null);
      assert.throws(() => restored.resume("restored", step.id), /guide|step/i);
      assert.equal(restored.get("restored").messages[0].text, "Keep the lesson");
      assert.equal(fs.readFileSync(f.companion.historyPath, "utf8"), before);
    }
  } finally { f.close(); }
});

test("a closed guide window asks the person to open it without starting a backend", async () => {
  const f = setup();
  try {
    const step = await f.pause(), before = fs.readFileSync(record, "utf8");
    f.desktop.windows = []; fs.rmSync(release, { force: true });
    f.companion.resume(f.session.id, step.id); await until(() => f.session.status === "error");
    assert.match(f.state().error, /open.*window/i); assert.equal(f.state().guideWindows, null);
    assert.equal(f.state().guide.id, step.id); assert.equal(fs.readFileSync(record, "utf8"), before);
  } finally { f.close(); }
});

test("End guide cannot hide a failed desktop-mark cleanup", async () => {
  const f = setup(), feed = path.join(dir, "pointers.json");
  try {
    const step = await f.pause(); await f.begin("Explain the paused exercise");
    const exited = new Promise(resolve => f.session.child.once("close", resolve));
    fs.rmSync(feed); fs.mkdirSync(feed);
    f.companion.endGuide(f.session.id, step.id);
    await exited; await tick();
    assert.equal(f.state().guide, null);
    assert.equal(f.state().status, "error"); assert.match(f.state().error, /feed.*cleared/i);
  } finally { if (fs.existsSync(feed) && fs.statSync(feed).isDirectory()) fs.rmdirSync(feed); f.close(); }
});

test("Guide follow-ups and provider errors keep the step; End guide and submitted Act end it", async () => {
  const f = setup();
  try {
    const step = await f.pause(); await f.begin("Explain why this step matters"); await f.finish(true);
    assert.equal(f.state().status, "error"); assert.match(f.state().error, /Fixture provider failed/);
    assert.equal(f.state().guide.id, step.id);
    const messages = structuredClone(f.session.messages);
    assert.throws(() => f.companion.endGuide(f.session.id, "stale"), /guide|step/i);
    f.companion.endGuide(f.session.id, step.id);
    assert.equal(f.state().guide, null); assert.deepEqual(f.session.messages, messages);
    assert.equal(f.state().error, null); assert.equal(f.state().hasMarks, false);
    await f.pause(); await f.begin("Help me act on this task", "act");
    assert.equal(f.state().guide, null); await f.finish();
  } finally { f.close(); }
});
