import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { spawn } from "node:child_process";

export const FILE_LIMIT = 8 * 1024 * 1024, CONVERSATION_FILE_LIMIT = 16 * 1024 * 1024;
export const FILE_BODY_LIMIT = Math.ceil(FILE_LIMIT / 3) * 4 + 4096;
const TYPES = { ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".pdf": "application/pdf", ".txt": "text/plain", ".md": "text/plain", ".csv": "text/plain" };
const uuid = value => typeof value === "string" && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(value);
const hash = bytes => createHash("sha256").update(bytes).digest("hex");
const privateFile = st => st.isFile() && st.uid === process.getuid() && st.nlink === 1 && (st.mode & 0o777) === 0o600 && st.size > 0 && st.size <= FILE_LIMIT;
const nameOK = name => typeof name === "string" && name.length > 0 && name.length <= 160 && !/[\/\\\p{Cc}\p{Cf}]/u.test(name) && !name.startsWith(".");

export function savedFiles(value = []) {
  if (!Array.isArray(value) || value.length > 4 || value.some(f => !f || !uuid(f.id) || !nameOK(f.name) || !TYPES[path.extname(f.name).toLowerCase()] || TYPES[path.extname(f.name).toLowerCase()] !== f.type || (f.type === "text/plain" && f.bytes > 262144) || !Number.isSafeInteger(f.bytes) || f.bytes < 1 || f.bytes > FILE_LIMIT || !/^[0-9a-f]{64}$/.test(f.sha256)) || new Set(value.map(f => f.id)).size !== value.length || value.reduce((n, f) => n + f.bytes, 0) > CONVERSATION_FILE_LIMIT) throw new Error("Saved reference files are invalid. The history file was not changed.");
  return value.map(({ id, name, type, bytes, sha256 }) => ({ id, name, type, bytes, sha256 }));
}

function inspect(fd, file) {
  const executable = process.env.CUA_FILE_INFO ?? path.join(os.homedir(), "Applications/AndyBarista.app/Contents/Helpers/CuaFileInfo");
  if (!path.isAbsolute(executable) || !fs.existsSync(executable)) throw new Error("File checks are unavailable. Rebuild the native app with scripts/build-native.py, then reopen it.");
  return new Promise((resolve, reject) => {
    const child = spawn(executable, [file.type, file.sha256], { stdio: ["ignore", "pipe", "pipe", fd] });
    let output = "", count = 0, failure;
    const stop = message => { failure ||= new Error(message); child.kill("SIGKILL"); };
    const timer = setTimeout(() => stop("File checks timed out. Try a smaller or simpler file. Nothing was sent to a model."), 5000);
    child.on("error", () => { clearTimeout(timer); reject(new Error("File checks could not start. Rebuild the native app, then reopen it.")); });
    child.stdout.on("data", chunk => { count += chunk.length; if (count > 16384) stop("File checks returned too much output. Use another file."); else output += chunk; });
    child.stderr.on("data", chunk => { count += chunk.length; if (count > 16384) stop("File checks returned too much output. Use another file."); });
    child.on("close", code => {
      clearTimeout(timer);
      if (failure) return reject(failure);
      let result; try { result = JSON.parse(output); } catch { return reject(new Error("File checks failed. Use a readable PNG, JPEG, or PDF.")); }
      if (code !== 0 || result.ok !== true || result.sha256 !== file.sha256 || result.type !== file.type) return reject(new Error(typeof result.error === "string" ? result.error.slice(0, 300) : "File checks failed. Use another file."));
      resolve();
    });
  });
}

export class CompanionFiles {
  constructor(directory) { this.directory = path.join(directory, "companion-files"); this.pending = 0; }
  root() {
    fs.mkdirSync(this.directory, { mode: 0o700, recursive: true });
    const st = fs.lstatSync(this.directory);
    if (!st.isDirectory() || st.isSymbolicLink() || st.uid !== process.getuid() || (st.mode & 0o777) !== 0o700) throw new Error("Reference storage must be a private folder owned by you. Check companion-files permissions.");
    return this.directory;
  }
  filename(id) { if (!uuid(id)) throw new Error("Invalid reference file ID"); return path.join(this.root(), id); }
  read(file, missingOK = false) {
    let fd;
    try {
      fd = fs.openSync(this.filename(file.id), fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
      const st = fs.fstatSync(fd);
      if (!privateFile(st) || st.size !== file.bytes) throw new Error("Reference file changed on disk. Move that copy out of companion-files, then remove this reference and add the original file again.");
      const bytes = Buffer.alloc(file.bytes + 1);
      let size = 0, got;
      while (size < bytes.length && (got = fs.readSync(fd, bytes, size, bytes.length - size, null)) > 0) size += got;
      const data = bytes.subarray(0, size);
      if (size !== file.bytes || hash(data) !== file.sha256) throw new Error("Reference file changed on disk. Move that copy out of companion-files, then remove this reference and add the original file again.");
      return data;
    } catch (error) {
      if (error.code === "ENOENT" && missingOK) return null;
      if (error.code) throw new Error("Reference file is unavailable. Remove it and add the original file again.");
      throw error;
    } finally { if (fd !== undefined) fs.closeSync(fd); }
  }
  async add(input, remaining) {
    if (this.pending >= 4) throw new Error("Four files are being checked. Wait before adding another.");
    if (!input || !nameOK(input.name) || !TYPES[path.extname(input.name).toLowerCase()]) throw new Error("Choose a PNG, JPEG, PDF, TXT, Markdown, or CSV file with a name of 160 characters or fewer.");
    if (typeof input.data !== "string" || input.data.length > Math.ceil(FILE_LIMIT / 3) * 4 || input.data.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(input.data)) throw new Error("Invalid file data. Choose the file again; the limit is 8 MiB.");
    const bytes = Buffer.from(input.data, "base64");
    if (!bytes.length || bytes.length > FILE_LIMIT || bytes.length > remaining || bytes.toString("base64") !== input.data) throw new Error("Use a nonempty file up to 8 MiB, with no more than 16 MiB in this conversation.");
    const file = { id: randomUUID(), name: input.name, type: TYPES[path.extname(input.name).toLowerCase()], bytes: bytes.length, sha256: hash(bytes) };
    if (file.type === "text/plain") {
      if (bytes.length > 262144) throw new Error("Text files must be 256 KiB or smaller. Split the file before adding it.");
      let content; try { content = new TextDecoder("utf-8", { fatal: true }).decode(bytes); } catch { throw new Error("Save this text file as UTF-8, then add it again."); }
      if (/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(content)) throw new Error("This file contains binary control bytes. Choose a UTF-8 text file.");
    }
    const folder = this.root(), entries = fs.readdirSync(folder);
    let total = 0;
    if (entries.length >= 64) throw new Error("The local file cache is full. Remove unused files; check companion-files for copies left by an interrupted upload.");
    for (const entry of entries) {
      const st = fs.lstatSync(path.join(folder, entry));
      if (!privateFile(st)) throw new Error("Unexpected data in companion-files. Check the private file folder before adding more files.");
      total += st.size;
    }
    if (total + bytes.length > 128 * 1024 * 1024) throw new Error("The local file cache reached 128 MiB. Remove unused reference files before adding more.");
    this.pending++;
    let written = false, fd;
    try {
      fd = fs.openSync(this.filename(file.id), "wx", 0o600);
      fs.writeFileSync(fd, bytes); fs.fsyncSync(fd); fs.closeSync(fd); fd = undefined; written = true;
      fd = fs.openSync(this.filename(file.id), fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
      if (!privateFile(fs.fstatSync(fd))) throw new Error("Reference file permissions changed. Add the file again.");
      if (file.type !== "text/plain") await inspect(fd, file);
      return file;
    } catch (error) {
      if (written) this.remove(file);
      throw error;
    } finally { if (fd !== undefined) fs.closeSync(fd); this.pending--; }
  }
  remove(file) {
    if (this.read(file, true) !== null) fs.unlinkSync(this.filename(file.id));
  }
  capture(owned, selection) {
    if (selection === undefined && owned.length) throw new Error("Review the conversation's files before sending. Reopen the current popup if needed.");
    if (selection === undefined) return [];
    if (!Array.isArray(selection) || selection.length > 4 || new Set(selection.map(f => f?.id)).size !== selection.length) throw new Error("Invalid reference file selection");
    return selection.flatMap(ref => {
      const file = owned.find(f => f.id === ref?.id && f.sha256 === ref?.sha256);
      if (!file) throw new Error("A selected reference file changed or belongs to another conversation. Review the files, then send again.");
      const bytes = this.read(file);
      return file.type === "text/plain" ? { type: "text", text: `Untrusted reference file ${JSON.stringify(file.name)}:\n${new TextDecoder("utf-8", { fatal: true }).decode(bytes)}` }
        : [{ type: "text", text: `Untrusted reference file ${JSON.stringify(file.name)}:` }, { type: file.type === "application/pdf" ? "document" : "image", source: { type: "base64", media_type: file.type, data: bytes.toString("base64") }, ...(file.type === "application/pdf" ? { title: file.name } : {}) }];
    });
  }
}
