import assert from "node:assert/strict";
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import os from "node:os";
import { once } from "node:events";

// Isolated socket/config: these checks never start the real helper or request TCC access.
const cwd = process.cwd();
const temporary = fs.mkdtempSync(path.join(process.argv[2] ?? os.tmpdir(), "cua-native-test-"));
process.chdir(temporary);
process.env.CUA_RUN_DIR = ".";
process.env.CUA_CONFIG = path.join(temporary, "config.json");
fs.writeFileSync(process.env.CUA_CONFIG, '{"hud":{"enabled":false}}', { mode: 0o600 });
const { NativeClient, App } = await import("../server/lib/native.mjs");
const { makeSky } = await import("../server/lib/sky.mjs");
let count = 0;
async function check(name, fn) { await fn(); console.log("PASS", name); count++; }
const info = { pid: 100, process: "100:launch-one", windowId: 10, name: "Fixture" };
const calls = [];
let serial = 0;
const fake = { hooks: {}, async req(cmd, args) {
  calls.push({ cmd, args });
  if (cmd === "snapshot") return { generation: `snap-${++serial}`, windowId: args.windowId,
    entries: [{ indent: 0, text: "textbox café", ref: 0 }], title: "Fixture" };
  if (cmd === "screenshot") return { jpeg: Buffer.from("jpeg").toString("base64") };
  if (cmd === "press" && args.index === 99) throw new Error("partial action failed");
  return {};
}};
const sockets = new Set();
const server = net.createServer(socket => {
  sockets.add(socket); socket.on("close", () => sockets.delete(socket));
  let buffer = ""; socket.setEncoding("utf8");
  socket.on("data", data => {
    buffer += data;
    let end;
    while ((end = buffer.indexOf("\n")) >= 0) {
      const request = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
      if (request.cmd === "hang") continue;
      if (request.cmd === "malformed") { socket.write("not-json\n"); continue; }
      const message = Buffer.from(JSON.stringify({ id: request.id, ok: true,
        result: { unicode: "café ☕", padding: "x".repeat(1000) } }) + "\n");
      const split = message.indexOf(Buffer.from("é")) + 1;
      socket.write(message.subarray(0, split));
      setTimeout(() => socket.write(message.subarray(split)), 5);
    }
  });
});
try {
  await check("input requires a fresh read", async () => {
    const app = new App(fake, info);
    await assert.rejects(app.click(1), /Read the selected/);
    assert.equal(calls.length, 0);
  });
  await check("same-process clients retain independent windows and snapshots", async () => {
    const a = new App(fake, info), b = new App(fake, { ...info, windowId: 20 });
    await a.read(); await b.read();
    const ag = a.target.generation, bg = b.target.generation;
    assert.notEqual(ag, bg);
    await a.click(1); await b.click([15, 25]);
    const actions = calls.filter(c => c.cmd === "press" || c.cmd === "pressAt").slice(-2);
    assert.deepEqual(actions.map(c => [c.args.windowId, c.args.generation, c.args.process]),
      [[10, ag, info.process], [20, bg, info.process]]);
    await assert.rejects(a.click(1), /Read the selected/);
  });
  await check("failed input consumes its snapshot without replay", async () => {
    const app = new App(fake, info); await app.read();
    await assert.rejects(app.click(99), /partial/);
    await assert.rejects(app.click(1), /Read the selected/);
    assert.equal(calls.filter(c => c.cmd === "press" && c.args.index === 99).length, 1);
  });
  await check("capture and preview preserve exact targets", async () => {
    const app = new App(fake, info); await app.screenshot();
    const shot = calls.findLast(c => c.cmd === "screenshot");
    assert.equal(shot.args.windowId, 10); assert.ok(shot.args.generation);
    const host = { pid: 200, process: "200:host", windowId: 99 }; await app.attach({ host });
    assert.deepEqual(calls.findLast(c => c.cmd === "attach").args.host, host);
  });
  await check("sky isolates window caches and reports capture denial", async () => {
    const denied = { ...fake, async req(cmd, args) {
      if (cmd === "screenshot") throw Object.assign(new Error("permission denied"), { code: "permission_denied" });
      return fake.req(cmd, args);
    }};
    const sky = makeSky({ native: { app: async (q, { windowId }) => new App(denied, { ...info, windowId }) } });
    const one = await sky.get_app_state({ app: "Fixture", window_id: 10 });
    const two = await sky.get_app_state({ app: "Fixture", window_id: 20 });
    assert.equal(one.screenshot, null); assert.equal(one.screenshotError.code, "permission_denied");
    assert.equal(two.windowId, 20);
    await sky.click({ app: "Fixture", window_id: 10, element_index: 1 });
    assert.equal(calls.findLast(c => c.cmd === "press").args.windowId, 10);
  });
  await check("passive status does not launch a missing helper", async () => {
    const client = new NativeClient();
    assert.deepEqual(await client.status(), { reachable: false }); client.close();
  });
  server.listen("agent.sock"); await once(server, "listening");
  await check("fragmented UTF-8 and ordinary-sized responses", async () => {
    const client = new NativeClient();
    try { const result = await client.req("fixture"); assert.equal(result.unicode, "café ☕"); assert.equal(result.padding.length, 1000); }
    finally { client.close(); }
  });
  await check("timeouts close the transport without retrying", async () => {
    const client = new NativeClient();
    try { await assert.rejects(client.req("hang", {}, 25), /timed out/); assert.equal(client.connected, false); }
    finally { client.close(); }
  });
  await check("malformed responses reject rather than crash", async () => {
    const client = new NativeClient();
    try { await assert.rejects(client.req("malformed"), /disconnected/); }
    finally { client.close(); }
  });
  console.log(`${count} native protocol checks passed (not live input/capture tests)`);
} finally {
  for (const socket of sockets) socket.destroy();
  server.close();
  process.chdir(cwd);
  fs.rmSync(temporary, { recursive: true, force: true });
}
