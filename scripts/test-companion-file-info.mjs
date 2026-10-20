import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import { deflateSync } from "node:zlib";
import { spawnSync } from "node:child_process";

const [directory, executable] = process.argv.slice(2);
assert(directory && executable, "Pass a scratch directory and the compiled CuaFileInfo executable");
assert(fs.existsSync(executable), "The isolated file checker must exist");
const folder = fs.mkdtempSync(path.join(directory, "file-info-"));
function png(width = 2, height = 2) {
  const chunk = (type, data) => {
    const body = Buffer.concat([Buffer.from(type), data]); let crc = 0xffffffff;
    for (const byte of body) { crc ^= byte; for (let i = 0; i < 8; i++) crc = crc >>> 1 ^ (crc & 1 ? 0xedb88320 : 0); }
    const out = Buffer.alloc(body.length + 8); out.writeUInt32BE(data.length); body.copy(out, 4); out.writeUInt32BE((crc ^ 0xffffffff) >>> 0, body.length + 4); return out;
  };
  const header = Buffer.alloc(13); header.writeUInt32BE(width); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 2;
  return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]), chunk("IHDR", header), chunk("IDAT", deflateSync(Buffer.from([0,255,0,255,0,255,255,0,255,255,0,0,0,0]))), chunk("IEND", Buffer.alloc(0))]);
}
function pdf(pages = 1) {
  const objects = ["<< /Type /Catalog /Pages 2 0 R >>", `<< /Type /Pages /Count ${pages} /Kids [${Array.from({length:pages},(_,i)=>`${i+3} 0 R`).join(" ")}] >>`, ...Array.from({length:pages},()=>"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>")];
  let text = "%PDF-1.4\n", offsets = [0];
  objects.forEach((object,i)=>{offsets.push(Buffer.byteLength(text));text+=`${i+1} 0 obj\n${object}\nendobj\n`});
  const start = Buffer.byteLength(text); text += `xref\n0 ${offsets.length}\n0000000000 65535 f \n` + offsets.slice(1).map(n=>String(n).padStart(10,"0")+" 00000 n \n").join("") + `trailer\n<< /Size ${offsets.length} /Root 1 0 R >>\nstartxref\n${start}\n%%EOF\n`;
  return Buffer.from(text);
}
let count = 0;
function check(data, type, expected, expectedHash) {
  const filename = path.join(folder, String(count++)); fs.writeFileSync(filename, data, {mode:0o600});
  const fd = fs.openSync(filename, "r");
  try {
    const result = spawnSync(executable, [type, expectedHash ?? createHash("sha256").update(data).digest("hex")], {stdio:["ignore","pipe","pipe",fd], timeout:7000});
    const output = JSON.parse(result.stdout.toString());
    assert.equal(output.ok, expected, `${type}: ${JSON.stringify(output)}`); assert.equal(result.status === 0, expected);
    return output;
  } finally {fs.closeSync(fd)}
}
try {
  fs.writeFileSync(path.join(folder, "fixture.png"), png()); fs.writeFileSync(path.join(folder, "fixture.pdf"), pdf());
  const fixtureScript = path.join(folder, "fixtures.swift");
  fs.writeFileSync(fixtureScript, `import AppKit\nimport PDFKit\nlet root=URL(fileURLWithPath:CommandLine.arguments[1])\nlet image=NSBitmapImageRep(data:try Data(contentsOf:root.appendingPathComponent("fixture.png")))!\ntry image.representation(using:.jpeg,properties:[:])!.write(to:root.appendingPathComponent("fixture.jpg"))\nlet document=PDFDocument(url:root.appendingPathComponent("fixture.pdf"))!\nprecondition(document.write(to:root.appendingPathComponent("encrypted.pdf"),withOptions:[.userPasswordOption:"fixture",.ownerPasswordOption:"fixture-owner"]))\n`);
  const created = spawnSync("swift", [fixtureScript, folder], {encoding:"utf8",timeout:30000}); assert.equal(created.status,0,created.stderr);
  assert.equal(check(fs.readFileSync(path.join(folder,"fixture.jpg")), "image/jpeg", true).width,2);
  assert.match(check(fs.readFileSync(path.join(folder,"encrypted.pdf")), "application/pdf", false).error,/unencrypted/);
  assert.equal(check(png(), "image/png", true).width, 2);
  check(png(), "image/jpeg", false); check(png(100000, 100000), "image/png", false);
  check(Buffer.from("not an image"), "image/png", false); check(png().subarray(0, 40), "image/png", false);
  check(png(), "image/png", false, "0".repeat(64));
  assert.equal(check(pdf(), "application/pdf", true).pages, 1);
  check(pdf(101), "application/pdf", false); check(Buffer.from("%PDF-1.4 broken"), "application/pdf", false);
  check(Buffer.alloc(8 * 1024 * 1024 + 1), "image/png", false);
  console.log(`${count} native file checks passed`);
} finally { fs.rmSync(folder, {recursive:true,force:true}); }
