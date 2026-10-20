import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const dir=fs.mkdtempSync(path.join(process.argv[2]??os.tmpdir(),"cua-hub-web-"));
process.env.CUA_RUN_DIR=dir;process.env.CUA_CONFIG=path.join(dir,"config.json");
fs.writeFileSync(process.env.CUA_CONFIG,JSON.stringify({web:{port:0}}));
const {startWeb}=await import("../server/lib/web.mjs");
const companion=new EventEmitter(),hub=new EventEmitter();
let clients=[],warmCalls=0;
companion.snapshot=()=>({sessions:[],backend:"fixture"});
companion.warm=()=>{warmCalls++};
hub.snapshot=()=>({clients,providers:[{id:"andy",name:"Andy Code",available:true}]});
const web=startWeb({engine:{running:false},native:{},hud:{},token:"fixture-token",status:async()=>({}),companion,agentHub:hub});
const {port}=await web.listen(),base=`http://127.0.0.1:${port}`;
const headers={"x-cua-token":"fixture-token"},abort=new AbortController();
let reader,buffer="";
async function event(){
  const deadline=Date.now()+3000;
  while(!buffer.includes("\n\n")){
    let timer;
    const part=await Promise.race([reader.read(),new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error("SSE timed out")),Math.max(1,deadline-Date.now()))})]).finally(()=>clearTimeout(timer));
    assert.equal(part.done,false);buffer+=new TextDecoder().decode(part.value);
  }
  const end=buffer.indexOf("\n\n"),frame=buffer.slice(0,end);buffer=buffer.slice(end+2);
  return JSON.parse(frame.slice("data: ".length));
}
try{
  assert.equal((await fetch(base+"/api/companion")).status,401);
  const initial=await (await fetch(base+"/api/companion",{headers})).json();
  assert.deepEqual(initial.hub,hub.snapshot(),"companion state includes bounded hub metadata");
  assert.equal(typeof initial.version.instance,"string");assert.equal(Number.isInteger(initial.version.revision),true);
  const stream=await fetch(base+"/api/companion/events",{headers,signal:abort.signal});reader=stream.body.getReader();
  const first=await event();
  clients=[{id:"client-1",name:"Fixture client",status:"busy"}];hub.emit("change",hub.snapshot());
  const changed=await event();
  assert.deepEqual(changed.hub.clients,clients,"hub changes reach the existing SSE channel");
  assert.equal(changed.version.instance,first.version.instance);assert.ok(changed.version.revision>first.version.revision);
  companion.emit("change",companion.snapshot());
  const next=await event();assert.ok(next.version.revision>changed.version.revision,"all state producers share a revision sequence");
  const response=await fetch(base+"/api/companion/warm",{method:"POST",headers:{...headers,"content-type":"application/json"},body:"{}"});
  assert.equal(response.status,200);const warmed=await response.json();
  assert.equal(warmCalls,1);assert.deepEqual(warmed.hub.clients,clients);assert.equal(warmed.version.revision,next.version.revision);
  abort.abort();await reader.cancel().catch(()=>{});
  web.server.closeAllConnections();await new Promise(resolve=>web.server.close(resolve));
  const cleanupDeadline=Date.now()+1000;
  while((companion.listenerCount("change")||hub.listenerCount("change"))&&Date.now()<cleanupDeadline)await new Promise(resolve=>setTimeout(resolve,10));
  assert.equal(companion.listenerCount("change"),0);assert.equal(hub.listenerCount("change"),0);
  console.log("PASS authenticated hub state, ordered SSE, passive warm route, and listener cleanup");
}finally{
  abort.abort();web.server.closeAllConnections();if(web.server.listening)await new Promise(resolve=>web.server.close(resolve));
  fs.rmSync(dir,{recursive:true,force:true});
}
