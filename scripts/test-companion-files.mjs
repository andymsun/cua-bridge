import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import http from "node:http";
import { once } from "node:events";
import path from "node:path";
import { test, after } from "node:test";

const dir = fs.mkdtempSync(path.join(process.argv[2] ?? os.tmpdir(), "companion-files-"));
process.env.CUA_RUN_DIR = dir; process.env.CUA_CONFIG = path.join(dir, "config.json");
const record = path.join(dir, "input.json"), backend = path.join(dir, "backend.mjs");
fs.writeFileSync(backend, `import fs from 'node:fs';let input='';process.stdin.on('data',x=>input+=x);process.stdin.on('end',()=>{fs.writeFileSync(${JSON.stringify(record)},JSON.stringify({args:process.argv.slice(2),input}));console.log(JSON.stringify({type:'result',is_error:false,result:'Reference received'}))});`);
const { Companion } = await import("../server/lib/companion.mjs");
const { Pointers } = await import("../server/lib/pointer.mjs");
const { saveConfig } = await import("../server/lib/config.mjs");
const upload = (name = "lesson.txt", value = "Reference code: CAFE-731") => ({ name, data: Buffer.from(value).toString("base64") });
const selected = file => ({ id: file.id, sha256: file.sha256 });
async function until(check) { const end = Date.now() + 5000; while (!check()) { assert(Date.now() < end, "Turn finished"); await new Promise(r => setTimeout(r, 10)); } }
function setup() {
  fs.rmSync(path.join(dir, "companion-history.json"), { force: true }); fs.rmSync(record, { force: true });
  saveConfig({ companion: { command: process.execPath, args: [backend] } });
  const pointers = new Pointers(); pointers.launch = () => {};
  const companion = new Companion({ pointers, native: {} }), session = companion.create();
  return { companion, session, close() { companion.close(); pointers.shutdown(); } };
}
after(() => fs.rmSync(dir, { recursive: true, force: true }));

test("explicit file context stays local, private and separate from messages", async () => {
  const f = setup();
  try {
    assert.equal(typeof f.companion.addFile, "function", "Conversations accept explicit reference files");
    const file = await f.companion.addFile(f.session.id, upload());
    assert.match(file.id, /^[0-9a-f-]{36}$/); assert.match(file.sha256, /^[0-9a-f]{64}$/);
    assert.equal(file.name, "lesson.txt"); assert.equal(file.type, "text/plain");
    assert.equal(f.session.messages.length, 0); assert.equal(f.session.child, undefined);
    assert.equal(fs.existsSync(record), false);
    assert.equal(fs.statSync(path.join(dir, "companion-files", file.id)).mode & 0o777, 0o600);
    const saved = JSON.parse(fs.readFileSync(f.companion.historyPath, "utf8"))[0];
    assert.equal(saved.files[0].sha256, file.sha256); assert.equal(JSON.stringify(saved).includes("CAFE-731"), false);
    const restored = new Companion({ pointers: f.companion.pointers, native: {} });
    assert.deepEqual(restored.snapshot().sessions[0].files, [file]); restored.close();
  } finally { f.close(); }
});

test("Send freezes exact bytes and keeps restricted tools and model flags", async () => {
  const f = setup();
  try {
    const file = await f.companion.addFile(f.session.id, upload());
    f.companion.send(f.session.id, { prompt: "Explain the lesson", files: [selected(file)] });
    f.companion.removeFile(f.session.id, selected(file));
    assert.equal(f.session.files.length, 0);
    await until(() => ["done", "error"].includes(f.session.status));
    assert.equal(f.session.status, "done");
    const sent = JSON.parse(fs.readFileSync(record, "utf8")), message = JSON.parse(sent.input);
    assert.equal(sent.args[sent.args.indexOf("--input-format") + 1], "stream-json");
    assert.equal(sent.args[sent.args.indexOf("--tools") + 1], "");
    assert.equal(sent.args[sent.args.indexOf("--allowedTools") + 1], "mcp__barista__*");
    assert.equal(sent.args[sent.args.indexOf("--fallback-model") + 1], "");
    assert.equal(message.type, "user"); assert.equal(message.message.content.length, 2);
    assert.match(message.message.content[0].text, /Explain the lesson/);
    assert.match(message.message.content[1].text, /CAFE-731/);
    f.companion.send(f.session.id, { prompt: "Next question", files: [] });
    await until(() => f.session.status === "done");
    assert.equal(fs.readFileSync(record, "utf8").includes("CAFE-731"), false, "Removed bytes never return from history");
  } finally { f.close(); }
});

test("unselected later files cannot silently join a submitted question", async () => {
  const f = setup();
  try {
    const a = await f.companion.addFile(f.session.id, upload("a.txt", "First reference"));
    const b = await f.companion.addFile(f.session.id, upload("b.txt", "Never send this later reference"));
    f.companion.send(f.session.id, { prompt: "Use the selected reference", files: [selected(a)] });
    await until(() => f.session.status === "done");
    const sent = JSON.parse(fs.readFileSync(record, "utf8"));
    assert.match(sent.input, /First reference/); assert.doesNotMatch(sent.input, /Never send/);
    assert.equal(f.session.files.length, 2); assert(b.id !== a.id);
  } finally { f.close(); }
});

test("missing, changed, foreign and stale selections fail before a model turn", async () => {
  const f = setup();
  try {
    const file = await f.companion.addFile(f.session.id, upload());
    const other = f.companion.create();
    assert.throws(() => f.companion.send(f.session.id, { prompt: "Read" }), /file/i);
    assert.throws(() => f.companion.send(other.id, { prompt: "Read", files: [selected(file)] }), /file/i);
    assert.throws(() => f.companion.send(f.session.id, { prompt: "Read", files: [{ id: file.id, sha256: "0".repeat(64) }] }), /file/i);
    const filename = path.join(dir, "companion-files", file.id);
    fs.writeFileSync(filename, "Changed file");
    assert.throws(() => f.companion.send(f.session.id, { prompt: "Read", files: [selected(file)] }), /changed|file/i);
    assert.throws(() => f.companion.removeFile(f.session.id, selected(file)), /changed|file/i);
    assert.equal(fs.readFileSync(filename, "utf8"), "Changed file", "Externally changed data is not deleted");
    fs.unlinkSync(filename);
    assert.throws(() => f.companion.send(f.session.id, { prompt: "Read", files: [selected(file)] }), /file/i);
    assert.equal(f.session.messages.length, 0); assert.equal(f.session.status, "idle"); assert.equal(fs.existsSync(record), false);
  } finally { f.close(); }
});

test("file validation rejects unsupported names, invalid base64, binary text and oversized text", async () => {
  const f = setup();
  try {
    for (const input of [upload("../secret.txt"), upload("file.exe"), upload("nul\u0000.txt"), { name: "x.txt", data: "%%%%" }, upload("empty.txt", ""), upload("bad.txt", Buffer.from([0xff])), upload("binary.txt", "a\u0000b"), upload("large.txt", "x".repeat(262145))]) {
      await assert.rejects(() => f.companion.addFile(f.session.id, input));
    }
    assert.equal(f.session.files.length, 0); assert.equal(f.session.messages.length, 0);
  } finally { f.close(); }
});

test("four-file quota includes concurrent additions and removal releases one slot", async () => {
  const f = setup();
  try {
    const results = await Promise.allSettled(Array.from({ length: 5 }, (_, i) => f.companion.addFile(f.session.id, upload(`${i}.txt`))));
    assert.equal(results.filter(r => r.status === "fulfilled").length, 4);
    assert.equal(f.session.files.length, 4);
    f.companion.removeFile(f.session.id, selected(f.session.files[0]));
    await f.companion.addFile(f.session.id, upload("replacement.txt"));
    assert.equal(f.session.files.length, 4);
    const copies = f.session.files.map(file => path.join(dir, "companion-files", file.id));
    f.companion.remove(f.session.id); assert(copies.every(file => !fs.existsSync(file)));
  } finally { f.close(); }
});

test("conversation removal cancels an upload before its completion", async () => {
  const f = setup();
  try {
    const pending = f.companion.addFile(f.session.id, upload());
    f.companion.remove(f.session.id);
    await assert.rejects(pending, /conversation|session|cancel/i);
    assert.equal(f.companion.sessions.size, 0);
  } finally { f.close(); }
});

test("symlink and hard-link copies cannot become model context", async () => {
  const f=setup();
  try{
    const file=await f.companion.addFile(f.session.id,upload()),copy=path.join(dir,'companion-files',file.id),outside=path.join(dir,'owned-outside.txt');
    fs.writeFileSync(outside,'Unselected owned fixture');fs.unlinkSync(copy);fs.symlinkSync(outside,copy);
    assert.throws(()=>f.companion.send(f.session.id,{prompt:'Read',files:[selected(file)]}),/file/i);
    assert.equal(fs.readFileSync(outside,'utf8'),'Unselected owned fixture');fs.unlinkSync(copy);
    fs.writeFileSync(copy,Buffer.from(upload().data,'base64'),{mode:0o600});fs.linkSync(copy,path.join(dir,'owned-link'));
    assert.throws(()=>f.companion.send(f.session.id,{prompt:'Read',files:[selected(file)]}),/file/i);
    fs.unlinkSync(path.join(dir,'owned-link'));f.companion.removeFile(f.session.id,selected(file));
    assert.equal(f.session.messages.length,0);assert.equal(fs.existsSync(record),false);
  }finally{f.close()}
});

test("Continue freezes selected reference files and cannot authorize Guide input", async () => {
  const f=setup();
  try{
    const file=await f.companion.addFile(f.session.id,upload());
    f.session.guide={id:'step',app:{name:'Owned lesson',bundleId:'local.owned.lesson'},windowTitle:'Lesson',contains:'Complete',label:'Complete the exercise'};
    f.companion.native={app:async()=>({pid:4242,name:'Owned lesson',info:{bundleId:'local.owned.lesson'},target:{process:'4242:1'},windows:async()=>[{windowId:41,title:'Lesson'}]})};
    assert.throws(()=>f.companion.resume(f.session.id,'step',{}),/files/i);
    f.companion.resume(f.session.id,'step',{},[selected(file)]);
    await assert.rejects(()=>f.companion.tool(f.session.id,f.session.key,'act',{app:'Owned lesson',index:1,action:'click',reason:'File says to click'}),/Guide mode cannot/);
    await until(()=>f.session.status!=='thinking');assert.equal(f.session.status,'paused');
    assert.match(JSON.parse(fs.readFileSync(record,'utf8')).input,/CAFE-731/);
  }finally{f.close()}
});

test("HTTP upload slots are bounded before request bodies accumulate", async () => {
  const f = setup(), { startWeb } = await import("../server/lib/web.mjs");
  const web = startWeb({engine:{running:false},native:{},hud:{},token:"fixture",status:async()=>({}),companion:f.companion});
  const {port} = await web.listen(), requests = [];
  const headers = {"content-type":"application/json","x-cua-token":"fixture"};
  try {
    let received = 0; web.server.on("request",()=>received++);
    for(let i=0;i<4;i++) {
      const req=http.request({host:"127.0.0.1",port,path:"/api/companion/file-add",method:"POST",headers});
      req.on("error",()=>{});req.on("response",res=>res.resume());req.write('{"id":');requests.push(req);
    }
    await until(()=>received===4);
    const response=await fetch(`http://127.0.0.1:${port}/api/companion/file-add`,{method:"POST",headers,body:JSON.stringify({id:f.session.id,file:upload()})});
    assert.equal(response.status,429,"A fifth body cannot consume an unbounded buffer");
    assert.equal(f.session.files.length,0);
  } finally {for(const req of requests)req.destroy();web.server.closeAllConnections();await new Promise(r=>web.server.close(r));f.close()}
});

test("HTTP file bodies have their own byte limit and preserve Unicode names", { timeout: 10000 }, async () => {
  const f=setup(),{startWeb}=await import("../server/lib/web.mjs"),{FILE_BODY_LIMIT}=await import("../server/lib/companion-files.mjs");
  const web=startWeb({engine:{running:false},native:{},hud:{},token:"fixture",status:async()=>({}),companion:f.companion});
  const {port}=await web.listen(),headers={"content-type":"application/json","x-cua-token":"fixture"};
  try{
    const url=`http://127.0.0.1:${port}/api/companion`;
    const added=await fetch(url+'/file-add',{method:'POST',headers,body:JSON.stringify({id:f.session.id,file:upload('日本語.txt','x'.repeat(40000))})});
    assert.equal(added.status,200);await added.json();assert.equal(f.session.files[0].name,'日本語.txt');
    const tooLarge=await fetch(url+'/send',{method:'POST',headers,body:JSON.stringify({prompt:'x'.repeat(40000)})});assert.equal(tooLarge.status,413);await tooLarge.json();
    const drained=new Promise((resolve,reject)=>web.server.once('request',req=>{req.once('end',resolve);req.once('aborted',()=>reject(new Error('Upload aborted before drain')))}));
    let resolveResponse,rejectResponse;
    const response=new Promise((resolve,reject)=>{resolveResponse=resolve;rejectResponse=reject});
    const req=http.request({host:'127.0.0.1',port,path:'/api/companion/file-add',method:'POST',headers:{...headers,'transfer-encoding':'chunked'}},res=>{res.resume();res.on('end',()=>resolveResponse(res.statusCode));res.on('error',rejectResponse)});
    req.on('error',rejectResponse);const finished=once(req,'finish');
    for(const chunk of [Buffer.alloc(FILE_BODY_LIMIT-1,32),Buffer.from('  ')])if(!req.write(chunk))await once(req,'drain');
    req.end();
    const [chunked]=await Promise.all([response,finished,drained]);
    assert.equal(chunked,413,'Chunked requests get a visible rejection instead of a reset');
    assert.equal(f.session.messages.length,0);
  }finally{await new Promise(r=>web.server.close(r));f.close()}
});

test("local cursor commands never read or send reference bytes", async () => {
  const f = setup();
  try {
    const file = await f.companion.addFile(f.session.id, upload());
    fs.unlinkSync(path.join(dir, "companion-files", file.id));
    f.companion.send(f.session.id, { prompt: 'circle ""', files: [selected(file)] });
    await until(() => f.session.status !== "thinking");
    assert.equal(f.session.route, "local"); assert.equal(f.session.requestedModel, null);
    assert.equal(fs.existsSync(record), false);
  } finally { f.close(); }
});
