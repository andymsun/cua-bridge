import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import http from "node:http";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const root=path.dirname(path.dirname(fileURLToPath(import.meta.url))),previous=process.cwd();
const dir=fs.mkdtempSync(path.join(process.argv[2]??os.tmpdir(),"cua-hub-protocol-"));
fs.writeFileSync(path.join(dir,"config.json"),JSON.stringify({web:{port:0},hud:{enabled:false},pointer:{enabled:false},native:{enabled:false}}));
// Relative socket names avoid macOS's short Unix-path limit. Every test process shares this cwd.
process.chdir(dir);
const env={...process.env,CUA_RUN_DIR:".",CUA_CONFIG:path.join(dir,"config.json")};
const daemon=spawn(process.execPath,[path.join(root,"server/daemon.mjs")],{cwd:dir,env,stdio:["ignore","ignore","pipe"]});
let errors="";daemon.stderr.setEncoding("utf8");daemon.stderr.on("data",chunk=>errors=(errors+chunk).slice(-8000));
const post=(route,body={})=>new Promise((resolve,reject)=>{
  const request=http.request({socketPath:"daemon.sock",path:route,method:"POST"},response=>{
    let raw="";response.setEncoding("utf8");response.on("data",chunk=>raw+=chunk);response.on("end",()=>{try{resolve({status:response.statusCode,data:JSON.parse(raw)})}catch(error){reject(error)}});
  });
  request.setTimeout(3000,()=>request.destroy(new Error("control request timed out")));request.on("error",reject);request.end(JSON.stringify(body));
});
try{
  const deadline=Date.now()+10000;
  while(true){
    try{if((await post("/health")).data.ok)break}catch{}
    if(daemon.exitCode!==null||Date.now()>deadline)throw new Error("daemon startup failed: "+errors);
    await new Promise(resolve=>setTimeout(resolve,20));
  }
  const status=(await post("/status")).data;
  const url=status.urls.companion.replace("/companion?","/api/companion?");
  const snapshot=async()=>{const response=await fetch(url);assert.equal(response.status,200);return response.json()};
  const registered=await post("/agent/register",{session:"protocol-fixture",client:{name:"Protocol fixture",version:"1"},host:{ancestors:[123],bundleId:"example.fixture"}});
  assert.equal(registered.status,200,"control socket accepts bounded MCP client registration");
  let state=await snapshot();assert.equal(state.hub.clients[0].name,"Protocol fixture");assert.equal(state.hub.clients[0].status,"idle");
  const initialRevision=state.version.revision;
  const result=await post("/call",{session:"protocol-fixture",code:"1+1"});assert.equal(result.status,200);
  assert.ok(result.data.content.some(item=>item.type==="text"&&item.text.includes("2")));
  state=await snapshot();assert.equal(state.hub.clients[0].status,"idle");assert.ok(state.version.revision>=initialRevision+2,"call start and completion both update shared state");
  const first=post("/call",{session:"protocol-fixture",code:"await new Promise(r=>setTimeout(r,80)); 1"});
  const second=post("/call",{session:"protocol-fixture",code:"await new Promise(r=>setTimeout(r,200)); 2"});
  assert.equal((await first).data.isError,false);assert.equal((await snapshot()).hub.clients[0].status,"busy","a queued call keeps the client busy");
  assert.equal((await second).data.isError,false);assert.equal((await snapshot()).hub.clients[0].status,"idle");
  await post("/call",{session:"protocol-fixture",code:"let = ;"});
  assert.equal((await snapshot()).hub.clients[0].status,"error","thrown compilation failures update activity");
  await post("/call",{session:"protocol-fixture",code:"throw new Error('fixture failure')"});
  assert.equal((await snapshot()).hub.clients[0].status,"error","failed CUA calls update activity without claiming model state");
  const ending=post("/call",{session:"protocol-fixture",code:"await new Promise(r=>setTimeout(r,150)); 3"});
  const busyDeadline=Date.now()+1000;
  while((await snapshot()).hub.clients[0].status!=="busy"){assert.ok(Date.now()<busyDeadline);await new Promise(r=>setTimeout(r,10))}
  await post("/end",{session:"protocol-fixture"});assert.equal((await snapshot()).hub.clients.length,0);
  await ending;assert.equal((await snapshot()).hub.clients.length,0,"late call completion cannot restore an ended client");
  await post("/agent/register",{session:"protocol-fixture",client:{name:"late"}});assert.equal((await snapshot()).hub.clients.length,0);
  assert.equal((await post("/agent/register",{session:"../bad"})).status,500);
  assert.equal((await post("/agent/register",{session:"oversized",client:{name:"x".repeat(32768)}})).status,413);
  assert.equal((await snapshot()).hub.clients.length,0,"oversized metadata never enters the registry");
  console.log("PASS daemon registration, CUA activity, error state, end, and late-registration guard");
}finally{
  if(daemon.exitCode===null){await post("/shutdown").catch(()=>{});await new Promise(resolve=>{const timer=setTimeout(()=>daemon.kill("SIGTERM"),2000);daemon.once("exit",()=>{clearTimeout(timer);resolve()});if(daemon.exitCode!==null){clearTimeout(timer);resolve()}})}
  process.chdir(previous);fs.rmSync(dir,{recursive:true,force:true});
}
