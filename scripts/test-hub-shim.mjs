import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import http from "node:http";
import { spawn, execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root=path.dirname(path.dirname(fileURLToPath(import.meta.url))),previous=process.cwd();
const dir=fs.realpathSync(fs.mkdtempSync(path.join(process.argv[2]??os.tmpdir(),"cua-hub-shim-")));
process.chdir(dir);
const children=new Set();
const wait=async predicate=>{const deadline=Date.now()+3000;while(!predicate()){assert.ok(Date.now()<deadline,"shim condition timed out");await new Promise(r=>setTimeout(r,10))}};
function shim(){
  const child=spawn(process.execPath,[path.join(root,"server/shim.mjs")],{cwd:dir,env:{...process.env,CUA_RUN_DIR:".",CUA_CONFIG:path.join(dir,"config.json")},stdio:["pipe","pipe","pipe"]});
  children.add(child);child.once("exit",()=>children.delete(child));
  const replies=[];let buffer="",errors="";
  child.stdout.setEncoding("utf8");child.stderr.setEncoding("utf8");
  child.stdout.on("data",chunk=>{buffer+=chunk;let at;while((at=buffer.indexOf("\n"))>=0){const line=buffer.slice(0,at);buffer=buffer.slice(at+1);replies.push(JSON.parse(line))}});
  child.stderr.on("data",chunk=>errors+=chunk);
  return {child,replies,send:(id,method,params)=>child.stdin.write(JSON.stringify({jsonrpc:"2.0",id,method,params})+"\n"),
    reply:async id=>{await wait(()=>replies.some(r=>r.id===id));return replies.find(r=>r.id===id)},
    exit:async()=>{await wait(()=>child.exitCode!==null);assert.equal(child.exitCode,0,errors)}};
}
let server;
try{
  const raw=execFileSync(process.execPath,[path.join(root,"server/cli.mjs"),"mcp-config"],{cwd:dir,env:{...process.env,CUA_RUN_DIR:".",CUA_CONFIG:path.join(dir,"config.json")},encoding:"utf8"});
  let connection;assert.doesNotThrow(()=>{connection=JSON.parse(raw)},"mcp-config returns a per-session connection without starting services");
  const definition=connection.mcpServers.cua;
  assert.equal(definition.command,process.execPath);assert.deepEqual(definition.args,[path.join(root,"server/shim.mjs")]);
  assert.equal(definition.env.CUA_RUN_DIR,dir);assert.equal(definition.env.CUA_CONFIG,path.join(dir,"config.json"));
  assert.ok(path.isAbsolute(definition.env.CUA_AGENT_APP)&&path.isAbsolute(definition.env.CUA_HUD_APP));
  assert.equal(fs.existsSync("daemon.sock"),false);assert.equal(fs.existsSync("config.json"),false);
  const absent=shim();absent.send(1,"initialize",{clientInfo:{name:"No daemon"}});
  assert.equal((await absent.reply(1)).result.serverInfo.name,"cua");absent.child.stdin.end();await absent.exit();
  assert.equal(fs.existsSync("daemon.sock"),false);assert.equal(fs.existsSync("daemon.log"),false,"initialize must not launch a daemon");
  let requests=[],registrations=[],release=null,delay=true,old=false,delayHealth=false,healthRelease=null;
  server=http.createServer((req,res)=>{
    let raw="";req.setEncoding("utf8");req.on("data",chunk=>raw+=chunk);req.on("end",()=>{
      const body=JSON.parse(raw||"{}");requests.push({route:req.url,body});
      const reply=(value,code=200)=>{res.writeHead(code,{"content-type":"application/json"});res.end(JSON.stringify(value))};
      if(req.url==="/agent/register"){
        registrations.push(body);
        if(delay){release=()=>{requests.push({route:"registration-finished"});reply({ok:true})};return}
        return reply(old?{error:"unknown"}:{ok:true},old?404:200);
      }
      if(req.url==="/health"&&delayHealth){healthRelease=()=>reply({ok:true});return}
      reply(req.url==="/call"?{content:[{type:"text",text:"2"}],isError:false}:{ok:true});
    });
  });
  await new Promise(resolve=>server.listen("daemon.sock",resolve));
  const delayed=shim();delayed.send(1,"initialize",{clientInfo:{name:"Café fixture",version:"1",secret:"must-not-forward"}});
  assert.equal((await delayed.reply(1)).result.serverInfo.name,"cua","initialize acknowledges before registration finishes");
  await wait(()=>release);assert.equal(registrations[0].client.name,"Café fixture");assert.equal(JSON.stringify(registrations).includes("must-not-forward"),false);
  delayed.child.stdin.end();await new Promise(r=>setTimeout(r,40));assert.equal(requests.some(r=>r.route==="/end"),false,"end drains the bounded registration first");
  release();await delayed.exit();assert.ok(requests.findIndex(r=>r.route==="/end")>requests.findIndex(r=>r.route==="registration-finished"));
  delay=false;old=true;requests=[];registrations=[];
  const retry=shim();retry.send(1,"initialize",{clientInfo:{name:"N".repeat(200),version:"V".repeat(200)}});await retry.reply(1);await wait(()=>registrations.length===1);
  old=false;retry.send(2,"tools/call",{name:"js",arguments:{code:"1+1"}});
  assert.equal((await retry.reply(2)).result.content[0].text,"2");assert.equal(registrations.length,2,"real tool calls retry registration after ensureDaemon");
  assert.equal(registrations[1].client.name.length,80);assert.equal(registrations[1].client.version.length,80);
  retry.child.stdin.end();await retry.exit();
  requests=[];registrations=[];delayHealth=true;
  const closing=shim();closing.send(1,"initialize",{clientInfo:{name:"Closing fixture"}});await closing.reply(1);await wait(()=>registrations.length===1);
  closing.send(2,"tools/call",{name:"js",arguments:{code:"1+1"}});await wait(()=>healthRelease);closing.child.stdin.end();await closing.exit();healthRelease();
  assert.equal(requests.some(r=>r.route==="/call"),false,"EOF during ensureDaemon must prevent later tool dispatch");
  assert.equal(new Set([registrations[0].session,...requests.filter(r=>r.route==="/end").map(r=>r.body.session)]).size,1);
  console.log("PASS MCP initialize without startup, bounded metadata, registration retry, EOF ordering, and closed-client dispatch guard");
}finally{
  for(const child of children){child.kill("SIGTERM");await new Promise(resolve=>{const timer=setTimeout(()=>{child.kill("SIGKILL");resolve()},3500);child.once("exit",()=>{clearTimeout(timer);resolve()})})}
  if(server){server.closeAllConnections();await new Promise(resolve=>server.close(resolve))}
  process.chdir(previous);fs.rmSync(dir,{recursive:true,force:true});
}
