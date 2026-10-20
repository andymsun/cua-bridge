import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test, after } from "node:test";

const dir = fs.mkdtempSync(path.join(process.argv[2] ?? os.tmpdir(), "companion-model-"));
process.env.CUA_RUN_DIR = dir;
process.env.CUA_CONFIG = path.join(dir, "config.json");
const fixture = path.join(dir, "backend.mjs");
const record = path.join(dir, "launch.json");
const release = path.join(dir, "release");
fs.writeFileSync(fixture, `
import fs from 'node:fs';
const args = process.argv.slice(2), model = args[args.indexOf('--model') + 1];
fs.writeFileSync(${JSON.stringify(record)}, JSON.stringify({args,env:{
  noFallback:process.env.CLAUDE_CODE_NO_MODEL_FALLBACK,
  noAccessFallback:process.env.CLAUDE_CODE_DISABLE_MODEL_ACCESS_FALLBACK,
  noRefusalFallback:process.env.CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK,
  small:process.env.ANTHROPIC_SMALL_FAST_MODEL
}}));
let prompt='';process.stdin.setEncoding('utf8');process.stdin.on('data', x=>prompt+=x);
process.stdin.on('end',()=>{
 const send=x=>process.stdout.write(JSON.stringify(x)+'\\n');
 const reported=prompt.includes('mismatch')?'claude-unapproved':prompt.includes('bare')?model.replace('codex/',''):model;
 if(!prompt.includes('unreported')) send({type:'stream_event',event:{type:'message_start',message:{model:reported}}});
 const finish=()=>{send({type:'stream_event',event:{delta:{type:'text_delta',text:'Fixture answer'}}});send({type:'result',is_error:false,result:'Fixture answer'});};
 if(prompt.includes('hold')) {const timer=setInterval(()=>{if(fs.existsSync(${JSON.stringify(release)})){clearInterval(timer);finish();}},10);return;}
 finish();
});
`);
const { Companion } = await import("../server/lib/companion.mjs");
const { Pointers } = await import("../server/lib/pointer.mjs");
const { saveConfig } = await import("../server/lib/config.mjs");
async function until(predicate) {
  const deadline = Date.now() + 5000;
  while (!predicate()) { if (Date.now() > deadline) throw new Error("Fixture did not complete"); await new Promise(r => setTimeout(r, 10)); }
}
function setup(options = {}) {
  fs.rmSync(path.join(dir, "companion-history.json"), { force: true });
  fs.rmSync(release, { force: true }); fs.rmSync(record, { force: true });
  saveConfig({ companion: { command: process.execPath, args: [fixture], ...options } });
  const pointers = new Pointers(); pointers.launch = () => { throw new Error("Model text cannot open a GUI"); };
  const companion = new Companion({ pointers, native: {} }), session = companion.create();
  return { companion, session, state: () => companion.snapshot().sessions[0], close() { companion.close(); pointers.shutdown(); } };
}
after(() => fs.rmSync(dir, { recursive: true, force: true }));

test("unsupported goals explicitly pin Astra and disable all fallback before spawn", async () => {
  const f = setup();
  try {
    const initial = f.companion.send(f.session.id, { prompt: "explain this screen" });
    assert.equal(initial.sessions[0].route, "model");
    assert.equal(initial.sessions[0].requestedModel, "codex/gpt-6-astra");
    assert.equal(initial.sessions[0].reportedModel, null);
    await until(() => ["done", "error"].includes(f.session.status));
    assert.equal(f.session.status, "done");
    const launch = JSON.parse(fs.readFileSync(record, "utf8"));
    assert.equal(launch.args[launch.args.indexOf("--model") + 1], "codex/gpt-6-astra");
    assert.equal(launch.args[launch.args.indexOf("--fallback-model") + 1], "");
    assert.deepEqual(launch.env, { noFallback: "1", noAccessFallback: "1", noRefusalFallback: "1", small: "codex/gpt-6-astra" });
    assert.equal(f.state().reportedModel, "codex/gpt-6-astra");
    assert.equal(f.state().presentation, "text");
    assert.ok(Number.isFinite(f.state().timings.spawnMs));
    assert.ok(Number.isFinite(f.state().timings.firstTextMs));
  } finally { f.close(); }
});

test("an explicit approved Sol configuration and legacy model args are honored exactly once", async () => {
  for (const options of [
    { model: "codex/gpt-5.6-sol" },
    { args: [fixture, "--model", "codex/gpt-5.6-sol"] },
    { args: [fixture, "--model=codex/gpt-5.6-sol"] },
  ]) {
    const f = setup(options);
    try {
      f.companion.send(f.session.id, { prompt: "bare model metadata" });
      await until(() => ["done", "error"].includes(f.session.status));
      assert.equal(f.session.status, "done");
      assert.equal(f.state().requestedModel, "codex/gpt-5.6-sol");
      assert.equal(f.state().reportedModel, "gpt-5.6-sol", "reported spelling remains distinct from requested identity");
      const launch = JSON.parse(fs.readFileSync(record, "utf8"));
      assert.equal(launch.args.filter(arg => arg === "--model").length, 1);
      assert.equal(launch.env.small, "codex/gpt-5.6-sol");
    } finally { f.close(); }
  }
});

test("model selection and fallback conflicts are rejected before spawning or consuming a turn", () => {
  for (const options of [
    { model: "auto" }, { model: "claude-unapproved" }, { model: "gpt-6-astra" },
    { args: [fixture, "--model", "claude-unapproved"] },
    { args: [fixture, "--model"] },
    { args: [fixture, "--"] },
    { args: [fixture, "--model", "codex/gpt-6-astra", "--model", "codex/gpt-5.6-sol"] },
    { args: [fixture, "--fallback-model", "codex/gpt-5.6-sol"] },
    { args: [fixture, "--fallback-model=claude-unapproved"] },
  ]) {
    const f = setup(options);
    try {
      assert.throws(() => f.companion.send(f.session.id, { prompt: "hello" }), /model|fallback/i);
      assert.equal(f.session.status, "idle");
      assert.equal(f.session.messages.length, 0);
      assert.equal(f.session.child, undefined);
    } finally { f.close(); }
  }
});

test("conversation model selection reaches the backend without changing the configured default", async () => {
  const f = setup({ args: [fixture, "--model", "codex/gpt-6-astra"] });
  try {
    const other = f.companion.create(), configBefore = fs.readFileSync(process.env.CUA_CONFIG, "utf8");
    f.companion.setModel(f.session.id, "codex/gpt-5.6-sol");
    assert.equal(f.state().model, "codex/gpt-5.6-sol");
    assert.equal(f.companion.snapshot().sessions.find(s => s.id === other.id).model, null);
    f.companion.send(f.session.id, { prompt: "selected conversation model" });
    await until(() => ["done", "error"].includes(f.session.status));
    assert.equal(f.session.status, "done");
    assert.equal(f.state().requestedModel, "codex/gpt-5.6-sol");
    assert.equal(f.state().reportedModel, "codex/gpt-5.6-sol");
    const launch = JSON.parse(fs.readFileSync(record, "utf8"));
    assert.equal(launch.args[launch.args.indexOf("--model") + 1], "codex/gpt-5.6-sol");
    assert.equal(launch.args.filter(arg => arg === "--model").length, 1);
    assert.equal(fs.readFileSync(process.env.CUA_CONFIG, "utf8"), configBefore);
    f.companion.setModel(f.session.id, null);
    assert.equal(f.state().model, null);
    assert.equal(f.companion.snapshot().defaultModel, "codex/gpt-6-astra");
    assert.equal(f.state().requestedModel, "codex/gpt-5.6-sol", "next-turn selection does not rewrite the last turn");
  } finally { f.close(); }
});

test("changing the next model cannot redirect a reserved or active turn", async () => {
  const f = setup();
  try {
    f.companion.setModel(f.session.id, "codex/gpt-5.6-sol");
    f.companion.send(f.session.id, { prompt: "hold this turn" });
    f.companion.setModel(f.session.id, "codex/gpt-6-astra");
    await until(() => f.state().reportedModel !== null);
    assert.equal(f.state().model, "codex/gpt-6-astra");
    assert.equal(f.state().requestedModel, "codex/gpt-5.6-sol");
    assert.equal(f.state().reportedModel, "codex/gpt-5.6-sol");
    assert.equal(f.session.status, "thinking");
    fs.writeFileSync(release, "finish");
    await until(() => f.session.status === "done");
    f.companion.send(f.session.id, { prompt: "next turn" });
    await until(() => ["done", "error"].includes(f.session.status));
    assert.equal(f.session.status, "done");
    assert.equal(f.state().requestedModel, "codex/gpt-6-astra");
    assert.equal(f.state().reportedModel, "codex/gpt-6-astra");
  } finally { f.close(); }
});

test("invalid model updates leave the choice and history untouched", () => {
  const f = setup();
  try {
    f.companion.setModel(f.session.id, "codex/gpt-5.6-sol");
    const before = fs.readFileSync(f.companion.historyPath, "utf8");
    for (const model of [undefined, "", "auto", "gpt-6-astra", "claude-unapproved", {}, 1]) {
      assert.throws(() => f.companion.setModel(f.session.id, model), /model/i);
      assert.equal(f.state().model, "codex/gpt-5.6-sol");
      assert.equal(fs.readFileSync(f.companion.historyPath, "utf8"), before);
    }
    assert.throws(() => f.companion.setModel("missing", "codex/gpt-6-astra"), /session/i);
    assert.equal(f.session.messages.length, 0);
  } finally { f.close(); }
});

test("saved model choices survive restart and unsupported choices never silently fall back", () => {
  const f = setup(); let restored;
  try {
    f.companion.setModel(f.session.id, "codex/gpt-5.6-sol");
    f.companion.close();
    const rows = JSON.parse(fs.readFileSync(f.companion.historyPath, "utf8"));
    rows.push({ id: "legacy", name: "Legacy", messages: [{ role: "user", text: "Keep this message" }] });
    rows.push({ id: "unsupported", name: "Unsupported", model: "retired/model", messages: [] });
    rows.push({ id: "empty-model", name: "Invalid", model: "", messages: [] });
    fs.writeFileSync(f.companion.historyPath, JSON.stringify(rows));
    const before = fs.readFileSync(f.companion.historyPath, "utf8");
    restored = new Companion({ pointers: f.companion.pointers, native: {} });
    const sessions = restored.snapshot().sessions;
    assert.equal(sessions.find(s => s.id === f.session.id).model, "codex/gpt-5.6-sol");
    assert.equal(sessions.find(s => s.id === "legacy").model, null);
    assert.equal(sessions.find(s => s.id === "unsupported").model, "retired/model");
    assert.equal(sessions.find(s => s.id === "empty-model").model, "Invalid saved model", "an empty saved ID is not displayed as the default");
    assert.equal(fs.readFileSync(restored.historyPath, "utf8"), before, "loading history does not rewrite it");
    assert.throws(() => restored.send("unsupported", { prompt: "hello" }), /model/i);
    assert.equal(restored.get("unsupported").messages.length, 0);
    restored.setModel("unsupported", "codex/gpt-6-astra");
    assert.deepEqual(restored.get("legacy").messages, [{ role: "user", text: "Keep this message" }]);
  } finally { if (restored) restored.close(); else f.companion.close(); f.companion.pointers.shutdown(); }
});

test("model-produced spatial output remains cursor-first after streaming and completion", async () => {
  const f = setup();
  f.companion.pointers.launch = () => {};
  f.companion.native = { app: async () => ({ name: "Notes", read: async () => '1 button "Save"', locate: async () => ({ windowId: 91, rect: { x: 0.2, y: 0.4, w: 0.2, h: 0.1 } }) }) };
  try {
    f.companion.send(f.session.id, { prompt: "hold and help me save" });
    await until(() => fs.existsSync(record));
    const key = f.session.key;
    await f.companion.tool(f.session.id, key, "read", { app: "Notes" });
    await f.companion.tool(f.session.id, key, "point", { app: "Notes", index: 1, label: "Save here" });
    assert.equal(f.state().presentation, "cursor");
    assert.ok(Number.isFinite(f.state().timings.firstToolMs));
    assert.ok(Number.isFinite(f.state().timings.pointerPublishMs));
    fs.writeFileSync(release, "finish");
    await until(() => f.session.status === "done");
    assert.equal(f.state().presentation, "cursor");
    assert.equal(f.companion.pointers.snapshot().cursors[f.session.cursor].label, "Save here");
  } finally { f.close(); }
});

test("missing reported identity is not invented and unexpected model output is stopped", async () => {
  for (const prompt of ["unreported", "mismatch"]) {
    const f = setup();
    try {
      f.companion.send(f.session.id, { prompt });
      await until(() => ["done", "error"].includes(f.session.status));
      if (prompt === "unreported") {
        assert.equal(f.state().reportedModel, null);
        assert.equal(f.session.status, "done");
      } else {
        assert.equal(f.session.status, "error");
        assert.equal(f.state().presentation, "prompt");
        assert.equal(f.state().reportedModel, "claude-unapproved");
        assert.match(f.state().error, /model/i);
        assert.notEqual(f.state().messages.at(-1).text, "Fixture answer", "unapproved output is not shown as a successful reply");
      }
      assert.equal(f.state().requestedModel, "codex/gpt-6-astra");
    } finally { f.close(); }
  }
});
