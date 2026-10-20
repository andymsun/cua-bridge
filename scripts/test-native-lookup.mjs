import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import childProcess from "node:child_process";
import { once } from "node:events";
import { syncBuiltinESMExports } from "node:module";
import { test, after, mock } from "node:test";

const dir = fs.realpathSync(fs.mkdtempSync(path.join(process.argv[2] ?? os.tmpdir(), "native-lookup-")));
const cwd = process.cwd();
process.chdir(dir);
process.env.CUA_RUN_DIR = ".";
process.env.CUA_CONFIG = path.join(dir, "config.json");
let launches = 0;
mock.method(childProcess, "execFile", () => { launches++; throw new Error("Passive lookup launched an app"); });
syncBuiltinESMExports();
const { NativeClient } = await import("../server/lib/native.mjs");
const { saveConfig } = await import("../server/lib/config.mjs");
const query = { pid: 412, process: "412:1792440000.125", windowId: 91, name: "Save", role: "button" };
const calls = [], sockets = new Set();
let connections = 0;
const server = net.createServer(socket => {
  connections++;
  sockets.add(socket); socket.on("close", () => sockets.delete(socket));
  let buffer = ""; socket.setEncoding("utf8");
  socket.on("data", chunk => {
    buffer += chunk;
    let end;
    while ((end = buffer.indexOf("\n")) >= 0) {
      const request = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1); calls.push(request);
      socket.write(JSON.stringify({ id: request.id, ok: true, result: request.cmd === "apps"
        ? [{ name: "Notes", pid: 412, process: query.process, active: true }]
        : { status: "matched", name: "Save", role: "button", windowId: 91, target: { windowId: 91, rect: { x: 0.2, y: 0.4, w: 0.2, h: 0.1 } } } }) + "\n");
    }
  });
});
after(() => {
  for (const socket of sockets) socket.destroy();
  server.close(); mock.restoreAll(); syncBuiltinESMExports(); process.chdir(cwd); fs.rmSync(dir, { recursive: true, force: true });
});

test("local lookup and discovery never launch a missing helper or target app", async () => {
  const client = new NativeClient();
  try {
    assert.equal(typeof client.lookup, "function");
    await assert.rejects(client.lookup(query), /ENOENT|connect|reachable/);
    await assert.rejects(client.apps({ passive: true }), /ENOENT|connect|reachable/);
    assert.equal(launches, 0);
  } finally { client.close(); }
});

test("explicit cold preparation starts only the selected helper with isolated runtime paths", async () => {
  childProcess.execFile.mock.mockImplementation((command, args, callback) => {
    launches++;
    assert.equal(command, "open"); assert.ok(args.includes("-n") && args.includes("-g"));
    assert.ok(args.includes(`CUA_RUN_DIR=${dir}`)); assert.ok(args.includes(`CUA_CONFIG=${path.join(dir, "config.json")}`));
    assert.ok(args.some(arg => arg.startsWith("CUA_HUD_APP=/")));
    server.listen("agent.sock"); callback(null);
  });
  const client = new NativeClient();
  try {
    await Promise.all([client.ensure(), client.ensure()]);
    assert.equal(launches, 1); assert.equal(calls.length, 0, "preparation reads no app contents and requests no permissions");
  } finally {
    client.close(); launches = 0;
    childProcess.execFile.mock.mockImplementation(() => { launches++; throw new Error("Unexpected app launch"); });
  }
});

test("passive lookup speaks the exact native protocol without resolve, snapshot, focus or input", async () => {
  if (!server.listening) { server.listen("agent.sock"); await once(server, "listening"); }
  const client = new NativeClient();
  try {
    assert.equal(typeof client.lookup, "function");
    const result = await client.lookup(query);
    assert.deepEqual(calls.at(-1), { ...query, id: calls.at(-1).id, cmd: "lookup" });
    assert.deepEqual(result.target, { windowId: 91, rect: { x: 0.2, y: 0.4, w: 0.2, h: 0.1 } });
    await client.apps({ passive: true });
    assert.deepEqual(calls.map(c => c.cmd), ["lookup", "apps"]);
    assert.equal(launches, 0);
  } finally { client.close(); }
});

test("cancellation during connection is checked before passive requests are sent", async () => {
  for (const operation of ["lookup", "apps"]) {
    const client = new NativeClient();
    let stopped = false;
    const before = calls.length;
    try {
      assert.equal(typeof client.lookup, "function");
      const options = { passive: true, beforeSend: () => { if (stopped) throw new Error("turn stopped"); } };
      const pending = operation === "lookup" ? client.lookup(query, options) : client.apps(options);
      stopped = true;
      await assert.rejects(pending, /turn stopped/);
      assert.equal(calls.length, before);
    } finally { client.close(); }
  }
});

test("concurrent passive lookups share one connection rather than leaking sockets", async () => {
  const client = new NativeClient(), before = connections;
  try {
    const results = await Promise.all([client.lookup(query), client.lookup(query)]);
    assert.equal(results.length, 2);
    assert.equal(connections - before, 1, "one transport per native client");
  } finally { client.close(); }
});

test("running-only app resolution never sends the launch-capable resolve command", async () => {
  const client = new NativeClient();
  try {
    const start = calls.length;
    const app = await client.app("412", { runningOnly: true, windowId: 91 });
    assert.equal(app.pid, 412); assert.equal(app.target.process, query.process); assert.equal(app.target.windowId, 91);
    assert.equal(calls.at(-1).includeAccessories, true, "menu-bar apps remain available without launching targets");
    await assert.rejects(client.app("Closed app", { runningOnly: true }), /running app/i);
    assert.ok(calls.slice(start).every(call => call.cmd === "apps"), "only running metadata is read");
  } finally { client.close(); }
});

test("lookup respects native.enabled without a native request", async () => {
  saveConfig({ native: { enabled: false } });
  const client = new NativeClient(), before = calls.length;
  try {
    assert.equal(typeof client.lookup, "function");
    await assert.rejects(client.lookup(query), /disabled/);
    assert.equal(calls.length, before);
    assert.equal(launches, 0);
  } finally { client.close(); saveConfig({}); }
});
