import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import http from "node:http";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";

const repo=path.dirname(path.dirname(fileURLToPath(import.meta.url)));
assert(process.argv[2],"Pass a private scratch directory");
const dir=fs.mkdtempSync(path.join(path.resolve(process.argv[2]),"barista-reconnect-")),cwd=process.cwd();
process.env.CUA_RUN_DIR=dir;process.env.CUA_CONFIG=path.join(dir,"config.json");process.env.CUA_HUD_APP=path.join(dir,"missing.app");
const backend=path.join(dir,"backend.mjs"),record=path.join(dir,"unexpected-turn.txt");
fs.writeFileSync(backend,`import fs from 'node:fs';fs.writeFileSync(${JSON.stringify(record)},'Unexpected provider start');process.stdin.resume();process.stdin.on('end',()=>console.log(JSON.stringify({type:'result',result:'Unexpected turn'})));`);
fs.writeFileSync(process.env.CUA_CONFIG,JSON.stringify({web:{port:0},hud:{enabled:false},companion:{command:process.execPath,args:[backend]}}));
const {Pointers}=await import("../server/lib/pointer.mjs");
const {Companion}=await import("../server/lib/companion.mjs");
const {startWeb}=await import("../server/lib/web.mjs");
const {findExecutable}=await import("../server/lib/browser.mjs");
const {config,saveConfig}=await import("../server/lib/config.mjs");
let web,companion,pointers,url,restartError,restarting=false,child,browser,watch,statusCount=0;
const handled=new Set();
async function start(token,port=0){
 saveConfig({...config(),web:{...config().web,port}});
 pointers=new Pointers();pointers.launch=()=>{};
 companion=new Companion({pointers,native:{}});
 web=startWeb({engine:{running:false},native:{},hud:{},token,status:async()=>({}),companion});
 const listening=await web.listen();url=`http://127.0.0.1:${listening.port}/companion?t=${token}`;
}
async function closeWeb(){
 companion?.close();pointers?.shutdown();
 if(web){web.server.closeAllConnections();await new Promise(r=>web.server.close(r));web=null}
}
async function run(command,args){
 await new Promise((resolve,reject)=>{
  const p=spawn(command,args,{stdio:"inherit"});p.on("error",reject);p.on("exit",code=>code===0?resolve():reject(Error(command+" exited "+code)));
 });
}
const control=http.createServer((req,res)=>{
 req.resume();if(req.method!=="POST"||req.url!=="/status"){res.writeHead(404);res.end();return}
 fs.writeFileSync(path.join(dir,"probe.json"),JSON.stringify({count:++statusCount}));
 const target=fs.existsSync(path.join(dir,"stale-probe"))?url.replace(/t=.*/,"t=owned-stale-token"):url;
 setTimeout(()=>{if(!res.destroyed){res.writeHead(200,{"content-type":"application/json"});res.end(JSON.stringify({urls:{companion:target}}))}},500);
});
try{
 await start("owned-before-token");
 const a=companion.create({name:"Owned recovery A"}).id,b=companion.create({name:"Owned recovery B"}).id;companion.save();
 fs.writeFileSync(path.join(dir,"fixture.json"),JSON.stringify({a,b,url}));
 // A relative socket stays below macOS's path limit, inside this private directory.
 process.chdir(dir);
 await new Promise((resolve,reject)=>{control.once("error",reject);control.listen("daemon.sock",resolve)});
 watch=fs.watch(dir,()=>{
  const action=["restart","rotate"].find(name=>!handled.has(name)&&fs.existsSync(path.join(dir,name)));
  if(restarting||!action)return;restarting=true;handled.add(action);
  (async()=>{
   const port=action==="rotate"?Number(new URL(url).port):0;
   await closeWeb();await start(action==="rotate"?"owned-rotated-token":"owned-after-token",port);
   fs.writeFileSync(path.join(dir,action==="rotate"?"rotated.json":"next.json"),JSON.stringify({url}));restarting=false;
  })().catch(e=>{restartError=e;child?.kill("SIGTERM")});
 });
 const binary=path.join(dir,"native-reconnect-check");
 await run("swiftc",["-D","COMPANION_TEST","-swift-version","5",...['hud/CuaPreview.swift','hud/Companion.swift','hud/CompanionComposer.swift','hud/CompanionDrafts.swift','hud/CompanionHub.swift','hud/PointerGeometry.swift','hud/CompanionVoice.swift','scripts/test-companion-reconnect.swift'].map(p=>path.join(repo,p)),"-o",binary]);
 for(const mode of ["--initial", "--drafts"]){
  const code=await new Promise((resolve,reject)=>{
   child=spawn(binary,[dir,mode],{stdio:"inherit"});
   const timer=setTimeout(()=>{child.kill("SIGTERM");reject(Error("Owned native recovery check timed out"))},90000);
   child.on("error",e=>{clearTimeout(timer);reject(e)});child.on("exit",code=>{clearTimeout(timer);resolve(code)});
  });
  if(restartError)throw restartError;assert.equal(code,0,"Actual native recovery check passed");
 }
 assert.equal(handled.size,2);
 browser=await chromium.launch({executablePath:findExecutable(),headless:true});
 const page=await browser.newPage();
 await page.addInitScript(()=>{window.nativeMessages=[];window.webkit={messageHandlers:{barista:{postMessage:value=>nativeMessages.push(value)}}}});
 await page.goto(url);await page.waitForFunction(()=>online);
 await page.evaluate(a=>baristaRestoreDrafts({epoch:1,activeSessionID:a,drafts:{[a]:{text:"Keep this request",revision:1,edit:1}}}),a);
 assert.equal(await page.evaluate(()=>baristaPrepareReconnect({epoch:1})),false,"Online pages do not reload");
 await page.evaluate(()=>{online=false;paint()});
 assert.equal(await page.evaluate(()=>baristaPrepareReconnect({epoch:0})),false,"Old epochs cannot prepare navigation");
 await page.locator('#prompt').dispatchEvent('compositionstart');
 assert.equal(await page.evaluate(()=>baristaPrepareReconnect({epoch:1})),false,"Browser composition defers navigation");
 await page.locator('#prompt').dispatchEvent('compositionend');
 await page.evaluate(()=>{online=true;paint()});
 const binding=await page.evaluate(a=>baristaFilesPrepare({id:a,epoch:1,requestID:"owned-picker"}),a);assert(binding);
 await page.evaluate(()=>{online=false;paint()});
 assert.equal(await page.evaluate(()=>baristaPrepareReconnect({epoch:1})),false,"A pending picker defers navigation");
 await page.evaluate(binding=>baristaFilesCancel(binding),binding);
 await page.evaluate(()=>{online=true;paint()});
 await page.clock.install();
 let resolveRoute,requests=0;const intercepted=new Promise(resolve=>resolveRoute=resolve);
 await page.route('**/api/companion/send',route=>{requests++;resolveRoute(route)});
 const sending=page.evaluate(a=>baristaNativeSubmit({id:a,epoch:1,text:"Keep this request",edit:2}),a);
 const held=await intercepted;
 await page.evaluate(()=>{online=false;paint()});
 assert.equal(await page.evaluate(()=>baristaPrepareReconnect({epoch:1})),false,"An unconfirmed Send defers navigation");
 await page.clock.fastForward(30001);assert.equal(await sending,false);
 await held.abort().catch(error=>{if(!/closed|cancel/i.test(error.message))throw error});
 assert.equal(requests,1,"A timed-out request is not retried");
 assert.equal(await page.locator('#prompt').inputValue(),"Keep this request");
 assert.match(await page.locator('#error').textContent(),/not confirmed.*history/);
 assert.equal(await page.evaluate(()=>pendingRequests.size),0,"A failed request cannot block recovery forever");
 assert.equal(await page.evaluate(()=>baristaPrepareReconnect({epoch:1})),true);
 assert.match(await page.evaluate(()=>api('/warm').then(()=>"unexpected",e=>e.message)),/reconnect/);
 assert.equal(await page.evaluate(()=>baristaPrepareReconnect({epoch:1,cancel:true})),true);
 assert.equal(fs.existsSync(record),false,"Recovery never starts a provider");
 assert(companion.snapshot().sessions.every(s=>s.messages.length===0));
 console.log("PASS initial page failure, port/token recovery, request/IME/picker guards, timeout without replay; evidence: "+dir);
}finally{
 watch?.close();if(child?.exitCode===null&&!child.killed)child.kill("SIGTERM");
 await browser?.close();await closeWeb();control.closeAllConnections();
 if(control.listening)await new Promise(r=>control.close(r));process.chdir(cwd);
}
