import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { once } from "node:events";

const dir = fs.mkdtempSync(path.join(process.argv[2] ?? os.tmpdir(), "barista-process-"));
process.env.CUA_RUN_DIR = dir;
process.env.CUA_CONFIG = path.join(dir, "config.json");
process.env.CUA_HUD_APP = path.join(dir, "missing.app");
const fixture = path.join(dir, "backend.mjs");
fs.writeFileSync(fixture, `
let prompt=''; process.stdin.setEncoding('utf8');process.stdin.on('data', c=>prompt+=c);
process.stdin.on('end',()=>{
 const args=process.argv.slice(2);
 if(!args.includes('--strict-mcp-config') || args[args.indexOf('--tools')+1] !== '') process.exit(2);
 const send=x=>process.stdout.write(JSON.stringify(x)+'\\n');
 if(prompt.includes('FAIL')) {process.stderr.write('fixture login required');process.exit(4);}
 if(prompt.includes('WAIT')) {setInterval(()=>send({type:'stream_event',event:{delta:{type:'text_delta',text:'waiting'}}}),20);return;}
 send({type:'stream_event',event:{delta:{type:'text_delta',text:'Café ready'}}});
 send({type:'assistant',message:{content:[{type:'text',text:'Café ready'}]}});
 send({type:'result',is_error:false,result:'Café ready'});
});
`);
fs.writeFileSync(process.env.CUA_CONFIG, JSON.stringify({ companion: { command: process.execPath, args: [fixture] } }));
const { Pointers } = await import("../server/lib/pointer.mjs");
const { Companion } = await import("../server/lib/companion.mjs");
const pointers = new Pointers(), companion = new Companion({ pointers, native: {} });
async function until(predicate) {
  const deadline = Date.now() + 8000;
  while (!predicate()) { if (Date.now() > deadline) throw new Error("State change timed out"); await new Promise(r=>setTimeout(r,20)); }
}
try {
  const first = companion.create();
  companion.send(first.id, { prompt: "hello" });
  await until(()=>companion.get(first.id).status === "done");
  assert.equal(companion.snapshot().sessions[0].messages.at(-1).text, "Café ready", "stream and final output are not duplicated");
  assert.equal(companion.get(first.id).key, null, "a completed turn loses its tool capability");
  assert.ok(fs.readFileSync(path.join(dir,"companion-history.json"),"utf8").includes("Café ready"));
  assert.equal(fs.statSync(path.join(dir,"companion-history.json")).mode & 0o777, 0o600);

  const waiting = companion.create();
  companion.send(waiting.id, { prompt: "WAIT" });
  const oldKey = companion.get(waiting.id).key;
  await until(()=>companion.get(waiting.id).messages.at(-1).text.length>0);
  const child = companion.get(waiting.id).child;
  const closed = once(child, "close");
  companion.stop(waiting.id); await closed;
  assert.equal(companion.get(waiting.id).status, "stopped");
  await assert.rejects(companion.tool(waiting.id, oldKey, "apps", {}), /session/);
  const stable = companion.get(waiting.id).messages.at(-1).text;
  await new Promise(r=>setTimeout(r,80));
  assert.equal(companion.get(waiting.id).messages.at(-1).text, stable, "late output is ignored after cancellation");

  const interrupted = companion.create();
  const pendingApps = [];
  companion.native.apps = () => new Promise(resolve => pendingApps.push(resolve));
  companion.send(interrupted.id, { prompt: "WAIT" });
  const interruptedKey = interrupted.key;
  const oldRead = assert.rejects(companion.tool(interrupted.id, interruptedKey, "apps"), /session/);
  companion.stop(interrupted.id);
  companion.send(interrupted.id, { prompt: "WAIT again" });
  const nextKey = interrupted.key;
  const nextRead = companion.tool(interrupted.id, nextKey, "apps");
  pendingApps[0]([{ name: "stale app" }]);
  await oldRead;
  assert.equal(interrupted.busy, nextKey, "an old request cannot release the new turn's tool lock");
  await assert.rejects(companion.tool(interrupted.id, nextKey, "say", { text: "overlap" }), /previous tool/);
  pendingApps[1]([{ name: "current app" }]);
  assert.deepEqual(await nextRead, [{ name: "current app" }]);
  assert.equal(interrupted.busy, false);
  companion.stop(interrupted.id);

  const failure = companion.create(); companion.send(failure.id, { prompt: "FAIL" });
  await until(()=>companion.get(failure.id).status === "error");
  assert.match(companion.get(failure.id).error, /fixture login required/);
  companion.close();
  const restored = new Companion({ pointers, native: {} });
  assert.equal(restored.snapshot().sessions[0].messages.at(-1).text, "Café ready");
  assert.ok(restored.snapshot().sessions.every(s=>s.mode==='guide'&&s.status==='idle'));
  restored.close();
  console.log("PASS real child-process stream, failure, cancellation, capability expiry, and local history");
} finally { companion.close(); pointers.shutdown(); fs.rmSync(dir,{recursive:true,force:true}); }
