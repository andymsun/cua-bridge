// Persistent JavaScript sessions. Each harness session gets its own vm context,
// so top-level bindings survive between tool calls, like Codex's node_repl.
import * as vm from "node:vm";

// `const tab = ...` at the top level becomes a context global so the next call
// can use it. Destructuring and nested declarations stay local to one call.
function hoist(code) {
  return code
    .replace(/^(?:let|const|var)\s+([A-Za-z_$][\w$]*)\s*=/gm, "globalThis.$1 =")
    .replace(/^(?:let|var)\s+([A-Za-z_$][\w$]*)\s*;/gm, "globalThis.$1 = undefined;")
    .replace(/^(async\s+)?function\s*(\*?)\s*([A-Za-z_$][\w$]*)/gm, "globalThis.$3 = $1function$2 $3")
    .replace(/^class\s+([A-Za-z_$][\w$]*)/gm, "globalThis.$1 = class $1");
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
    const push = (item) => self.out?.push(item);
    const write = (v) => push({ type: "text", text: typeof v === "string" ? v : safeJson(v) });
    const image = (buf, mimeType = "image/png") => push({ type: "image", data: Buffer.from(buf).toString("base64"), mimeType });
    const console_ = Object.fromEntries(["log", "info", "warn", "error", "debug"].map((k) =>
      [k, (...a) => write(a.map((x) => (typeof x === "string" ? x : safeJson(x))).join(" "))]));
    this.context = vm.createContext({
      write, image, console: console_, sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
      setTimeout, clearTimeout, setInterval, clearInterval, Buffer, URL, URLSearchParams,
      TextEncoder, TextDecoder, fetch, AbortController, structuredClone, performance,
      cua: this.makeApi({ write, image }),
    });
  }

  async dispose() { await this.context?.cua?.__dispose?.(); }

  async run(code, { timeoutMs, maxOutputChars }) {
    this.out = [];
    let isError = false;
    // a single bare expression returns its value, e.g. `typeof tab` or `tab.url()`
    const single = code.trim();
    const isExpr = !/[;\n]/.test(single) && !/^(const|let|var|if|for|while|return|throw|function|class|try|switch)\b/.test(single);
    const body = isExpr ? `return (${single});` : hoist(code);
    const script = new vm.Script(`(async () => {\n${body}\n})()`, {
      filename: `cua-session-${this.id}.js`,
      importModuleDynamically: vm.constants.USE_MAIN_CONTEXT_DEFAULT_IMPORT,
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
