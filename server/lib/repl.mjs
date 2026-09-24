// Persistent JavaScript sessions. Each harness session gets its own vm context,
// so top-level bindings survive between tool calls, like Codex's node_repl.
import * as vm from "node:vm";

// vm contexts can't use import() without an experimental flag, so sessions get a
// loader function instead and `import(` in their code is routed to it
const loadModule = (specifier) => import(specifier);
const routeImports = (code) => code.replace(/(?<![\w$.])import\s*\(/g, "__import(");

// `const tab = ...` at the top level becomes a context global so the next call can
// use it. Applied at every top-level statement start, so `const a = 1; const b = 2`
// on one line works too. Destructuring and nested declarations stay local to a call.
function hoist(code) {
  const starts = [0, ...statementBoundaries(code)];
  let out = "", prev = 0;
  for (const at of starts) {
    if (at < prev) continue;               // "}" and the newline after it can mark the same statement
    out += code.slice(prev, at);
    const m = code.slice(at).match(/^(\s*)(?:(?:let|const|var)\s+([A-Za-z_$][\w$]*)\s*(=|;)|(async\s+)?function\s*(\*?)\s*([A-Za-z_$][\w$]*)|class\s+([A-Za-z_$][\w$]*))/);
    if (!m) { prev = at; continue; }
    const [whole, ws, name, eq, asyncKw, star, fname, cname] = m;
    out += ws + (name ? (eq === "=" ? `globalThis.${name} =` : `globalThis.${name} = undefined;`)
      : fname ? `globalThis.${fname} = ${asyncKw ?? ""}function${star} ${fname}` : `globalThis.${cname} = class ${cname}`);
    prev = at + whole.length;
  }
  return out + code.slice(prev);
}

export class Session {
  constructor(id, makeApi) {
    this.id = id;
    this.makeApi = makeApi;
    this.reset();
  }

  reset() {
    this.out = null;
    const self = this;
    const push = (item) => { self.out?.push(item); };
    const write = (v) => push({ type: "text", text: typeof v === "string" ? v : safeJson(v) });
    const image = (buf, mimeType = "image/png") => push({ type: "image", data: Buffer.from(buf).toString("base64"), mimeType });
    const console_ = Object.fromEntries(["log", "info", "warn", "error", "debug"].map((k) =>
      [k, (...a) => write(a.map((x) => (typeof x === "string" ? x : safeJson(x))).join(" "))]));
    this.context = vm.createContext({
      write, image, console: console_, sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
      __import: loadModule,
      setTimeout, clearTimeout, setInterval, clearInterval, Buffer, URL, URLSearchParams,
      TextEncoder, TextDecoder, fetch, AbortController, structuredClone, performance,
      ...this.makeApi({ write, image }),
    });
  }

  async dispose() { await this.context?.cua?.__dispose?.(); }

  async run(code, { timeoutMs, maxOutputChars }) {
    this.out = [];
    let isError = false;
    // a single bare expression returns its value, e.g. `typeof tab` or `tab.url()`
    const body = withReturn(hoist(routeImports(code)));
    const script = new vm.Script(`(async () => {\n${body}\n})()`, {
      filename: `cua-session-${this.id}.js`,
    });
    let timer;
    try {
      const value = await Promise.race([
        script.runInContext(this.context),
        new Promise((_, rej) => { timer = setTimeout(() => rej(new Error(`Timed out after ${timeoutMs}ms (pass timeout_ms for longer work)`)), timeoutMs); }),
      ]);
      const text = value === undefined ? null : typeof value === "string" ? value : safeJson(value);
      const already = this.out.some((o) => o.type === "text" && o.text === text);   // read() already emitted it
      if (text !== null && !already && !(Buffer.isBuffer(value))) this.out.push({ type: "text", text });
    } catch (e) {
      isError = true;
      this.out.push({ type: "text", text: `Error: ${e?.message ?? e}${e?.stack ? "\n" + e.stack.split("\n").slice(1, 4).join("\n") : ""}` });
    } finally {
      clearTimeout(timer);
    }
    const content = coalesce(this.out, maxOutputChars);
    this.out = null;
    if (!content.length) content.push({ type: "text", text: "(ok)" });
    return { content, isError };
  }
}

// Positions where a new top-level statement can start (after ; or newline or a
// closing top-level brace), skipping strings, template literals, comments and brackets.
function statementBoundaries(code) {
  const out = [];
  let depth = 0, i = 0;
  const n = code.length;
  while (i < n) {
    const c = code[i];
    if (c === "/" && code[i + 1] === "/") { const e = code.indexOf("\n", i); i = e < 0 ? n : e; continue; }
    if (c === "/" && code[i + 1] === "*") { const e = code.indexOf("*/", i + 2); i = e < 0 ? n : e + 2; continue; }
    if (c === '"' || c === "'" || c === "`") {
      i++;
      while (i < n && code[i] !== c) {
        if (code[i] === "\\") i++;
        else if (c === "`" && code[i] === "$" && code[i + 1] === "{") {   // skip ${ ... } inside templates
          let d = 1; i += 2;
          while (i < n && d) { if (code[i] === "{") d++; else if (code[i] === "}") d--; i++; }
          continue;
        }
        i++;
      }
      i++; continue;
    }
    if ("([{".includes(c)) depth++;
    else if (")]}".includes(c)) { depth--; if (depth === 0 && c === "}") out.push(i + 1); }
    else if ((c === ";" || c === "\n") && depth === 0) out.push(i + 1);
    i++;
  }
  return out;
}

// Split off the last top-level statement and return it if it's an expression, so
// `...; await tab.title()` yields the title.
function lastStatement(code) {
  const cut = statementBoundaries(code).pop() ?? 0;
  return { head: code.slice(0, cut), tail: code.slice(cut).trim() };
}

const STATEMENT = /^(const|let|var|if|for|while|do|return|throw|function|async\s+function|class|try|switch|import|export|break|continue|globalThis\.[\w$]+\s*=)\b/;
function withReturn(code) {
  const { head, tail } = lastStatement(code.replace(/[\s;]+$/, ""));
  if (!tail || STATEMENT.test(tail) || /^[{}]/.test(tail)) return code;
  const candidate = `${head}\nreturn (${tail.replace(/;$/, "")});`;
  try { new vm.Script(`(async () => {\n${candidate}\n})`); return candidate; }
  catch { return code; }
}

function safeJson(v) {
  try { return JSON.stringify(v, (_, x) => (typeof x === "bigint" ? String(x) : x), 2) ?? String(v); }
  catch { return String(v); }
}

// Merge adjacent text items and cap the total, keeping images intact.
function coalesce(items, max) {
  const out = [];
  let used = 0, truncated = false;
  for (const it of items) {
    if (it.type !== "text") { out.push(it); continue; }
    let text = it.text;
    if (used + text.length > max) { text = text.slice(0, Math.max(0, max - used)); truncated = true; }
    used += text.length;
    const last = out[out.length - 1];
    if (last?.type === "text") last.text += "\n" + text; else if (text) out.push({ type: "text", text });
    if (truncated) break;
  }
  if (truncated) out.push({ type: "text", text: `\n… output truncated at ${max} chars. Filter in code and write() only what you need.` });
  return out;
}
