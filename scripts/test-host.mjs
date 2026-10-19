import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

// Isolated run dir: setHost writes host.json there, never into the real install.
const temporary = fs.mkdtempSync(path.join(process.argv[2] ?? os.tmpdir(), "cua-host-test-"));
process.env.CUA_RUN_DIR = temporary;
process.env.CUA_CONFIG = path.join(temporary, "config.json");
const { ancestry, cleanHost, hostInfo } = await import("../server/lib/host.mjs");
const { Hud } = await import("../server/lib/hud.mjs");

const parents = new Map([[50, 40], [40, 30], [30, 1]]);
assert.deepEqual(ancestry(parents, 50), [50, 40, 30], "nearest first, stops at launchd");
assert.deepEqual(ancestry(new Map([[5, 6], [6, 5]]), 5), [5, 6], "a cycle ends the walk");
assert.equal(ancestry(new Map(Array.from({ length: 99 }, (_, i) => [i + 2, i + 3])), 2).length, 32, "bounded");

assert.equal(cleanHost({}), null);
assert.equal(cleanHost({ ancestors: ["1; rm", 1, -4, 2.5] }), null, "only real pids survive");
assert.deepEqual(cleanHost({ ancestors: [9, 8], bundleId: "com.microsoft.VSCode" }), { ancestors: [9, 8], bundleId: "com.microsoft.VSCode" });
assert.equal(cleanHost({ ancestors: [], bundleId: "../evil" }), null, "bundle ids are identifiers");

const live = hostInfo();
assert.equal(live.ancestors[0], process.ppid, "the walk starts at the harness");

const hud = new Hud();
hud.setHost({ ancestors: [9, 8], bundleId: null });
const file = path.join(temporary, "host.json");
assert.deepEqual(JSON.parse(fs.readFileSync(file, "utf8")), { ancestors: [9, 8], bundleId: null });
hud.setHost({ ancestors: "garbage" });
assert.deepEqual(JSON.parse(fs.readFileSync(file, "utf8")).ancestors, [9, 8], "unusable input keeps the last host");
console.log("PASS host capture");
fs.rmSync(temporary, { recursive: true, force: true });
