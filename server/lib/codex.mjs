// Codex-compatible browser API: the `agent` / `browser` / `tab` surface the ChatGPT
// app gives its models (ax, playwright, cua, dom_cua, capabilities, ...), built on
// cua's engine. Code and habits written for Codex's in-app browser work unchanged.
import { createHash } from "node:crypto";
import * as fs from "node:fs";
import * as path from "node:path";
import { config, expandHome, paths } from "./config.mjs";
import { readDoc } from "./docs.mjs";
import { unique } from "./pw.mjs";
import { shortUrl } from "./browser.mjs";
import { VISIBLE_DOM_JS } from "./visible-dom.mjs";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const exportsDir = () => { const d = path.join(path.dirname(paths.run), "exports"); fs.mkdirSync(d, { recursive: true }); return d; };
const downloadsDir = () => { const d = expandHome(config().browser.downloadsDir) || exportsDir(); fs.mkdirSync(d, { recursive: true }); return d; };
const slug = (s) => String(s || "page").replace(/[^\w.-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 80) || "page";
const unsupported = (what) => async () => { throw new Error(`${what} isn't available in cua's browser - it only exists for Chrome-extension or cloud browsers.`); };
const withTimeout = (p, ms, what) => ms ? Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error(`${what} timed out after ${ms}ms`)), ms))]) : p;

// where each locator method takes its options argument (for the default timeout)
const OPTS_AT = { click: 0, dblclick: 0, hover: 0, check: 0, uncheck: 0, clear: 0, focus: 0, waitFor: 0, innerText: 0, innerHTML: 0,
  textContent: 0, inputValue: 0, boundingBox: 0, scrollIntoViewIfNeeded: 0, screenshot: 0, setChecked: 1, fill: 1, press: 1,
  pressSequentially: 1, selectOption: 1, setInputFiles: 1, getAttribute: 1 };

// Codex option names -> Playwright's
function pwOpts(o) {
  if (!o || typeof o !== "object" || Array.isArray(o) || o instanceof RegExp) return o;
  const { timeoutMs, ...rest } = o;
  return timeoutMs == null ? rest : { ...rest, timeout: timeoutMs };
}

// CUA-style key lists (["CTRL", "A"], ["ENTER"]) -> "ctrl+a" / "Return"
const CUA_MODS = { CTRL: "ctrl", CONTROL: "ctrl", ALT: "alt", OPTION: "alt", SHIFT: "shift", CMD: "super", COMMAND: "super", META: "super", SUPER: "super", WIN: "super" };
const CUA_NAMES = { ENTER: "Return", RETURN: "Return", ESC: "Escape", ESCAPE: "Escape", SPACE: "space", TAB: "Tab", BACKSPACE: "BackSpace",
  DELETE: "Delete", DEL: "Delete", ARROWUP: "Up", ARROWDOWN: "Down", ARROWLEFT: "Left", ARROWRIGHT: "Right", UP: "Up", DOWN: "Down",
  LEFT: "Left", RIGHT: "Right", PAGEUP: "Page_Up", PAGEDOWN: "Page_Down", HOME: "Home", END: "End" };
export function cuaCombo(keys) {
  return [].concat(keys).flatMap((k) => String(k).split("+")).map((k) => {
    const u = k.trim().toUpperCase();
    return CUA_MODS[u] ?? CUA_NAMES[u] ?? (/^F\d{1,2}$/.test(u) ? u : k.trim().length === 1 ? k.trim().toLowerCase() : k.trim());
  }).join("+");
}

// "type" presses Return for newlines, like a person typing
async function typeLikeKeys(tab, text) {
  const parts = String(text).split(/\r?\n/);
  for (let i = 0; i < parts.length; i++) {
    if (parts[i]) await tab.typeText(null, parts[i]);
    if (i < parts.length - 1) await tab.pressKey(null, "Return");
  }
}

function capabilityCollection(defs) {
  return {
    async list() { return Object.entries(defs).map(([id, d]) => ({ id, description: d.description })); },
    async get(id) {
      const d = defs[id];
      if (!d) throw new Error(`Unknown capability "${id}". Available: ${Object.keys(defs).join(", ")}`);
      return { ...d.make(), documentation: () => readDoc(d.doc) };
    },
  };
}

/**
 * Build the per-session globals: `agent`, and the helpers Codex code expects.
 * `opened` is the session's set of agent-created tabs (closed at session end).
 */
export function makeCodexApi({ engine, pw, hud, urls, write, image, opened, hint }) {
  const wrapped = new WeakMap();
  let sessionName = null;

  const wrapTab = (t) => {
    if (!t) return undefined;
    if (wrapped.has(t)) return wrapped.get(t);
    const w = makeTab(t);
    wrapped.set(t, w);
    return w;
  };
  const engineTab = (id) => {
    const t = engine.tabs.get(id) ?? [...engine.tabs.values()].find((x) => x.id.startsWith(String(id)));
    if (!t) throw new Error(`Tab ${id} is not open. Use browser.tabs.list() or browser.tabs.new().`);
    return t;
  };
  const alive = (t) => { if (t.closed) throw new Error(`Tab ${t.id.slice(0, 8)} was closed. Get a fresh tab from browser.tabs.`); return t; };

  // ---------------- Tab ----------------
  function makeTab(t) {
    const ctx = { page: () => pw.page(alive(t)) };
    let domMap = [];

    const locatorAction = async (loc, kind, fn) => {
      await loc.scrollIntoViewIfNeeded({ timeout: 5000 }).catch(() => {});
      const box = await loc.boundingBox({ timeout: 2000 }).catch(() => null);
      if (box) await t.showCursor({ x: box.x + box.width / 2, y: box.y + box.height / 2 }, kind);
      return fn();
    };

    // Locators are built synchronously (like Playwright) and resolved against the tab's page when used
    const makeLocator = (chain) => {
      const resolve = async () => {
        let cur = await ctx.page();
        for (const { m, a } of chain) cur = cur[m](...(await Promise.all(a.map(resolveArg))));
        return cur;
      };
      const resolveArg = async (x) => {
        if (x?.__chain) return x.__resolve();
        if (x && typeof x === "object" && !Array.isArray(x) && !(x instanceof RegExp)) {
          const o = {};
          for (const [k, v] of Object.entries(pwOpts(x))) o[k] = v?.__chain ? await v.__resolve() : v;
          return o;
        }
        return x;
      };
      const next = (m) => (...a) => makeLocator([...chain, { m, a }]);
      const act = (kind, m) => async (...a) => {
        const loc = await resolve();
        const args = a.map(pwOpts);
        // Playwright waits 30s by default; an agent is better served failing fast and re-inspecting
        const at = OPTS_AT[m];
        if (at !== undefined) args[at] = { timeout: 10000, ...(args[at] ?? {}) };
        return kind ? locatorAction(loc, kind, () => loc[m](...args)) : loc[m](...args);
      };
      return {
        __chain: chain, __resolve: resolve,
        locator: next("locator"), getByRole: next("getByRole"), getByText: next("getByText"), getByLabel: next("getByLabel"),
        getByPlaceholder: next("getByPlaceholder"), getByTestId: next("getByTestId"), getByAltText: next("getByAltText"),
        getByTitle: next("getByTitle"), filter: next("filter"), first: next("first"), last: next("last"), nth: next("nth"),
        and: next("and"), or: next("or"), frameLocator: next("frameLocator"), contentFrame: next("contentFrame"),
        async all() { const n = await (await resolve()).count(); return Array.from({ length: n }, (_, i) => makeLocator([...chain, { m: "nth", a: [i] }])); },
        click: act("click", "click"), dblclick: act("click", "dblclick"), hover: act("move", "hover"),
        check: act("click", "check"), uncheck: act("click", "uncheck"), setChecked: act("click", "setChecked"),
        fill: act("move", "fill"), clear: act("move", "clear"), press: act("move", "press"),
        pressSequentially: act("move", "pressSequentially"), type: act("move", "pressSequentially"),
        selectOption: act("click", "selectOption"), focus: act("move", "focus"), setInputFiles: act("move", "setInputFiles"),
        tap: act("click", "click"), scrollIntoViewIfNeeded: act(null, "scrollIntoViewIfNeeded"),
        count: act(null, "count"), isVisible: act(null, "isVisible"), isEnabled: act(null, "isEnabled"), isChecked: act(null, "isChecked"),
        isDisabled: act(null, "isDisabled"), isEditable: act(null, "isEditable"), isHidden: act(null, "isHidden"),
        innerText: act(null, "innerText"), innerHTML: act(null, "innerHTML"), textContent: act(null, "textContent"), inputValue: act(null, "inputValue"),
        allTextContents: act(null, "allTextContents"), allInnerTexts: act(null, "allInnerTexts"), getAttribute: act(null, "getAttribute"),
        boundingBox: act(null, "boundingBox"), waitFor: act(null, "waitFor"), ariaSnapshot: act(null, "ariaSnapshot"),
        screenshot: act(null, "screenshot"),
        async evaluate(fn, arg, o) { const loc = await resolve(); return withTimeout(loc.evaluate(fn, arg), o?.timeoutMs, "evaluate"); },
        async evaluateAll(fn, arg, o) { const loc = await resolve(); return withTimeout(loc.evaluateAll(fn, arg), o?.timeoutMs, "evaluateAll"); },
        async downloadMedia(o = {}) {
          const loc = await resolve();
          const url = await loc.first().evaluate(mediaUrlOf, null, { timeout: o.timeoutMs ?? 10000 });
          return downloadUrl(url);
        },
        toString() { return `locator(${chain.map((c) => `${c.m}(${c.a.map((x) => x?.__chain ? "locator" : JSON.stringify(x)).join(", ")})`).join(".")})`; },
      };
    };

    // element -> the media/file URL it represents (runs in the page)
    const mediaUrlOf = (el) => {
      const src = el.currentSrc || el.src || el.href || el.getAttribute?.("data-src");
      if (src) return src;
      const inner = el.querySelector?.("video, audio, img, source, a[href]");
      return inner ? inner.currentSrc || inner.src || inner.href : null;
    };
    const downloadUrl = async (url) => {
      if (!url) throw new Error("No media or file URL found on that element");
      const res = await (await pw.context()).request.get(url, { timeout: 60000 });
      if (!res.ok()) throw new Error(`Download failed: HTTP ${res.status()}`);
      const cd = res.headers()["content-disposition"] ?? "";
      const name = decodeURIComponent(cd.match(/filename\*?=(?:UTF-8'')?"?([^";]+)/i)?.[1] ?? path.basename(new URL(url).pathname) ?? "download");
      const file = unique(path.join(downloadsDir(), name || "download"));
      fs.writeFileSync(file, await res.body());
      write(`Downloaded ${path.basename(file)} → ${file}`);
      return file;
    };

    const pointOfNode = async (id) => {
      const entry = domMap[Number(id)];
      if (!entry) throw new Error(`Node ${id} isn't in the last get_visible_dom(). Call it again for fresh ids.`);
      const handle = await entry.frame.evaluateHandle((i) => window.__cuaNodes?.[i] ?? null, entry.local);
      const el = handle.asElement();
      if (!el || !(await el.evaluate((e) => e.isConnected))) throw new Error(`Node ${id} is gone from the page. Call get_visible_dom() again.`);
      await el.scrollIntoViewIfNeeded({ timeout: 3000 }).catch(() => {});
      const b = await el.boundingBox();
      if (!b) throw new Error(`Node ${id} has no visible box`);
      return { el, p: { x: b.x + b.width / 2, y: b.y + b.height / 2 } };
    };

    const tab = {
      get id() { return t.id; },
      async goto(url) { await alive(t).goto(url); },
      async back() { await alive(t).back(); },
      async forward() { await alive(t).forward(); },
      async reload() { await alive(t).reload(); },
      async close() { if (!t.closed) await t.close(); },
      url: () => alive(t).url(),
      title: () => alive(t).title(),
      screenshot: (o = {}) => alive(t).screenshot({ fullPage: o.fullPage, clip: o.clip }),
      async getJsDialog() {
        const d = alive(t).dialog;
        if (!d) return undefined;
        return { type: d.type, message: d.message, defaultPrompt: d.defaultPrompt,
          accept: (text) => t.handleDialog(true, text), dismiss: () => t.handleDialog(false) };
      },
      async markDeliverable() { t.kept = true; },
      async markHandoff() { t.kept = true; },
      requestManualHandoff: unsupported("requestManualHandoff (cloud browsers)"),

      ax: {
        async get(mode = "state", o = {}) {
          alive(t);
          if (mode === "screenshot") return t.screenshot();
          const state = await t.read({ full: !!o.disableDiffing });
          return mode === "both" ? { state, screenshot: await t.screenshot() } : state;
        },
        async write(mode = "state", o = {}) {
          const r = await this.get(mode, o);
          if (mode === "screenshot") image(r);
          else if (mode === "both") { write(r.state); image(r.screenshot); }
          else write(r);
        },
        click: (target, o = {}) => Array.isArray(target)
          ? alive(t).clickAt({ x: target[0], y: target[1] }, { button: o.mouseButton, clickCount: o.clickCount ?? 1 })
          : alive(t).click(target, { button: { l: "left", r: "right", m: "middle" }[o.mouseButton] ?? o.mouseButton ?? "left", clickCount: o.clickCount ?? 1 }),
        drag: (from, to) => alive(t).dragPath([{ x: from[0], y: from[1] }, { x: to[0], y: to[1] }]),
        paste: (index, text, o = {}) => alive(t).paste(index, text, { format: o.format ?? "text" }),
        performSecondaryAction: (index, action) => alive(t).secondaryAction(index, action),
        pressKey: (index, key) => alive(t).pressKey(index, key),
        scroll: (target, direction, pages = 1) => alive(t).scroll(target, direction, pages),
        selectText: (index, text, o = {}) => alive(t).selectText(index, text, o),
        setValue: (index, value) => alive(t).setValue(index, value),
        typeText: (index, text) => alive(t).typeText(index, text),
      },

      cua: {
        click: ({ x, y, button = 1, keypress = [] }) => alive(t).clickAt({ x, y }, { button, keys: keypress }),
        double_click: ({ x, y, keypress = [] }) => alive(t).clickAt({ x, y }, { clickCount: 2, keys: keypress }),
        drag: ({ path: pts, keys = [] }) => alive(t).dragPath(pts, { keys }),
        keypress: ({ keys }) => alive(t).pressKey(null, cuaCombo(keys)),
        move: ({ x, y, keys = [] }) => alive(t).moveTo({ x, y }, { keys }),
        scroll: ({ x, y, scrollX = 0, scrollY = 0, keypress = [] }) => alive(t).wheelAt({ x, y }, scrollX, scrollY, { keys: keypress }),
        type: ({ text }) => typeLikeKeys(alive(t), text),
        async downloadMedia({ x, y, timeoutMs }) {
          const page = await ctx.page();
          const url = await withTimeout(page.evaluate(([px, py]) => {
            for (const el of document.elementsFromPoint(px, py)) {
              const u = el.currentSrc || el.src || el.href || el.getAttribute("data-src")
                || el.querySelector?.("video, audio, img, source, a[href]")?.currentSrc || el.querySelector?.("source, a[href]")?.src || el.querySelector?.("a[href]")?.href;
              if (u) return u;
            }
            return null;
          }, [x, y]), timeoutMs ?? 10000, "downloadMedia");
          return downloadUrl(url);
        },
      },

      dom_cua: {
        async get_visible_dom() {
          const page = await ctx.page();
          await t.settle();
          domMap = [];
          const out = [`Tab ${t.id.slice(0, 8)} · ${await t.title()} · ${shortUrl(await t.url())}`];
          let below = 0;
          const run = async (frame, pad) => {
            const r = await frame.evaluate(`(${VISIBLE_DOM_JS})(${JSON.stringify({ maxText: 100 })})`).catch((e) => ({ error: e.message }));
            if (r.error) { out.push(`${pad}(frame not readable: ${r.error.split("\n")[0]})`); return; }
            if (frame === page.mainFrame()) below = r.below;
            for (const line of r.lines) {
              if (typeof line === "string") {
                out.push(pad + line.replace(/^(\s*)\[(\d+)\]/, (_, sp, n) => `${sp}[${domMap.push({ frame, local: Number(n) }) - 1}]`));
                continue;
              }
              for (const child of frame.childFrames()) {
                const el = await child.frameElement().catch(() => null);
                const idx = el && await frame.evaluate((e) => window.__cuaFrames?.indexOf(e) ?? -1, el).catch(() => -1);
                if (idx === line.frameIndex) { await run(child, pad + "  ".repeat(line.depth)); break; }
              }
            }
          };
          await run(page.mainFrame(), "");
          if (below) out.push(`(${below} more elements below the visible area - scroll to see them)`);
          return out.join("\n");
        },
        async click({ node_id }) { const { p } = await pointOfNode(node_id); await t.clickAt(p); },
        async double_click({ node_id }) { const { p } = await pointOfNode(node_id); await t.clickAt(p, { clickCount: 2 }); },
        keypress: ({ keys }) => alive(t).pressKey(null, cuaCombo(keys)),
        type: ({ text }) => typeLikeKeys(alive(t), text),
        async scroll({ node_id, x = 0, y = 0 }) {
          if (node_id == null) {
            const vp = await t.viewportSize();
            return t.wheelAt({ x: vp.w / 2, y: vp.h / 2 }, x, y);
          }
          const { el, p } = await pointOfNode(node_id);
          await t.showCursor(p, "scroll");
          await el.evaluate((e, [dx, dy]) => e.scrollBy(dx, dy), [x, y]);
        },
        async downloadMedia({ node_id, timeoutMs }) {
          const { el } = await pointOfNode(node_id);
          const url = await withTimeout(el.evaluate(mediaUrlOf), timeoutMs ?? 10000, "downloadMedia");
          return downloadUrl(url);
        },
      },

      playwright: {
        locator: (sel) => makeLocator([{ m: "locator", a: [sel] }]),
        getByRole: (role, o) => makeLocator([{ m: "getByRole", a: [role, o] }]),
        getByText: (text, o) => makeLocator([{ m: "getByText", a: [text, o] }]),
        getByLabel: (text, o) => makeLocator([{ m: "getByLabel", a: [text, o] }]),
        getByPlaceholder: (text, o) => makeLocator([{ m: "getByPlaceholder", a: [text, o] }]),
        getByTestId: (id) => makeLocator([{ m: "getByTestId", a: [id] }]),
        getByAltText: (text, o) => makeLocator([{ m: "getByAltText", a: [text, o] }]),
        getByTitle: (text, o) => makeLocator([{ m: "getByTitle", a: [text, o] }]),
        frameLocator: (sel) => makeLocator([{ m: "frameLocator", a: [sel] }]),
        async evaluate(fn, arg, o = {}) { const page = await ctx.page(); return withTimeout(page.evaluate(fn, arg), o.timeoutMs, "evaluate"); },
        async waitForTimeout(ms) { await sleep(ms); },
        async waitForLoadState(o = {}) { const page = await ctx.page(); await page.waitForLoadState(o.state ?? "load", pwOpts({ timeoutMs: o.timeoutMs })); },
        async waitForURL(url, o = {}) { const page = await ctx.page(); await page.waitForURL(url, pwOpts({ timeoutMs: o.timeoutMs, waitUntil: o.waitUntil })); },
        async expectNavigation(action, o = {}) {
          const page = await ctx.page();
          const timeout = o.timeoutMs ?? 30000;
          const nav = o.url
            ? page.waitForURL(o.url, { timeout, waitUntil: o.waitUntil ?? "load" })
            : page.waitForEvent("framenavigated", { predicate: (f) => f === page.mainFrame(), timeout })
              .then(() => page.waitForLoadState(o.waitUntil ?? "load", { timeout }));
          const [r] = await Promise.all([action(), nav]);
          return r;
        },
        async waitForEvent(event, o = {}) {
          const page = await ctx.page();
          const e = await page.waitForEvent(event, { timeout: o.timeoutMs ?? 30000 });
          if (event === "download") {
            return {
              url: () => e.url(), suggestedFilename: () => e.suggestedFilename(),
              async path(po = {}) {
                const saved = e.savedTo ?? e.saveAs(unique(path.join(downloadsDir(), e.suggestedFilename()))).then(() => null);
                return withTimeout(saved, po.timeoutMs ?? 120000, "download");
              },
            };
          }
          if (event === "filechooser") {
            return { isMultiple: () => e.isMultiple(), setFiles: (files, fo = {}) => e.setFiles([].concat(files).map(expandHome), pwOpts(fo)) };
          }
          return e;
        },
        async domSnapshot() {
          const page = await ctx.page();
          const blocks = [];
          const strip = (h) => h.replace(/<script\b[\s\S]*?<\/script>/gi, "").replace(/<style\b[\s\S]*?<\/style>/gi, "")
            .replace(/<!--[\s\S]*?-->/g, "").replace(/(<svg\b[^>]*>)[\s\S]*?<\/svg>/gi, "$1…</svg>").replace(/\s(style|srcset)="[^"]*"/gi, "");
          const walk = async (frame, trail) => {
            let html = await frame.content().catch(() => "");
            if (trail.length) {
              const owner = await (await frame.frameElement()).evaluate((e) => e.outerHTML.slice(0, e.outerHTML.indexOf(">") + 1)).catch(() => "<iframe>");
              blocks.push(`\n<!-- frame ${trail.join(" > ")}: owner ${owner} url ${frame.url()} -->`);
            }
            blocks.push(strip(html));
            let i = 0;
            for (const c of frame.childFrames()) await walk(c, [...trail, ++i]);
          };
          await walk(page.mainFrame(), []);
          const s = blocks.join("\n");
          return s.length > 400000 ? s.slice(0, 400000) + "\n<!-- truncated -->" : s;
        },
        async elementInfo({ x, y, includeNonInteractable = false }) { return elementInfo(await ctx.page(), x, y, includeNonInteractable, t); },
        async elementScreenshot({ x, y, includeNonInteractable = false }) {
          const page = await ctx.page();
          const infos = await elementInfo(page, x, y, includeNonInteractable, t);
          await page.evaluate(([boxes, px, py]) => {
            const layer = document.createElement("div");
            layer.id = "__cua_probe"; layer.style.cssText = "position:fixed;inset:0;pointer-events:none;z-index:2147483647";
            boxes.forEach((b, i) => { const d = document.createElement("div"); d.style.cssText = `position:fixed;left:${b.x}px;top:${b.y}px;width:${b.width}px;height:${b.height}px;outline:2px solid ${i ? "#f5a623" : "#e5484d"};outline-offset:-1px`; layer.append(d); });
            const dot = document.createElement("div"); dot.style.cssText = `position:fixed;left:${px - 5}px;top:${py - 5}px;width:10px;height:10px;border-radius:50%;background:#e5484d;box-shadow:0 0 0 2px #fff`;
            layer.append(dot); document.documentElement.append(layer);
          }, [infos.map((i) => i.boundingBox).filter(Boolean), x, y]);
          try { return await t.screenshot(); }
          finally { await page.evaluate(() => document.getElementById("__cua_probe")?.remove()).catch(() => {}); }
        },
      },

      clipboard: {
        async read() { return structuredClone(engine.clipboard); },
        async readText() { return engine.clipboard[0]?.entries.find((e) => e.mimeType === "text/plain")?.text ?? ""; },
        async write(items) { engine.clipboard = structuredClone(items); },
        async writeText(text) { engine.clipboard = [{ entries: [{ mimeType: "text/plain", text: String(text) }] }]; },
      },

      content: {
        async export() {
          const title = await t.title(), url = await t.url();
          const type = await t.evaluate("document.contentType").catch(() => "");
          if (type === "application/pdf" || /\.pdf($|\?)/i.test(url)) return downloadUrl(url);
          const text = await t.evaluate(() => (document.querySelector("article, main, [role=main]") ?? document.body)?.innerText ?? "");
          const file = unique(path.join(exportsDir(), `${slug(title)}.md`));
          fs.writeFileSync(file, `# ${title}\n\n<${url}>\n\n${text}\n`);
          return file;
        },
        async exportGsuite(type) {
          const u = new URL(await t.url());
          const m = u.pathname.match(/^\/(document|spreadsheets|presentation)\/d\/([^/]+)/);
          if (u.hostname !== "docs.google.com" || !m) throw new Error("This tab isn't a Google Docs, Sheets or Slides document");
          const allowed = { document: ["pdf", "md", "docx", "txt"], spreadsheets: ["pdf", "xlsx", "csv"], presentation: ["pdf", "pptx"] }[m[1]];
          if (!allowed.includes(type)) throw new Error(`${m[1]} exports as ${allowed.join(", ")}`);
          const gid = u.hash.match(/gid=(\d+)/)?.[1];
          const exportUrl = `https://docs.google.com/${m[1]}/d/${m[2]}/export?format=${type}${gid && type === "csv" ? `&gid=${gid}` : ""}`;
          const res = await (await pw.context()).request.get(exportUrl, { timeout: 60000 });
          if (!res.ok()) throw new Error(`Export failed: HTTP ${res.status()} (is this browser signed in to the document?)`);
          const file = unique(path.join(exportsDir(), `${slug(await t.title())}.${type}`));
          fs.writeFileSync(file, await res.body());
          return file;
        },
        async exportYouTubeTranscript() {
          const u = new URL(await t.url());
          if (!/^(www\.)?youtube\.com$/.test(u.hostname) || u.pathname !== "/watch") throw new Error("This tab isn't a YouTube /watch page");
          const r = await t.evaluate(async () => {
            const id = new URLSearchParams(location.search).get("v");
            let pr = window.ytInitialPlayerResponse;
            if (pr?.videoDetails?.videoId !== id) {          // stale after in-app navigation: re-read the page
              const html = await (await fetch(location.href)).text();
              const m = html.match(/ytInitialPlayerResponse\s*=\s*(\{.+?\});(?:var|<\/script>)/s);
              pr = m ? JSON.parse(m[1]) : null;
            }
            const tracks = pr?.captions?.playerCaptionsTracklistRenderer?.captionTracks ?? [];
            const track = tracks.find((x) => x.languageCode?.startsWith("en") && x.kind !== "asr") ?? tracks.find((x) => x.languageCode?.startsWith("en")) ?? tracks[0];
            if (!track) return { error: "This video has no captions" };
            const data = await (await fetch(track.baseUrl + "&fmt=json3")).json();
            const lines = (data.events ?? []).filter((e) => e.segs).map((e) => {
              const s = Math.floor((e.tStartMs ?? 0) / 1000);
              return `[${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}] ${e.segs.map((g) => g.utf8).join("").replace(/\n/g, " ").trim()}`;
            }).filter((l) => !/\]\s*$/.test(l));
            return { title: pr.videoDetails?.title, lines };
          });
          if (r.error) throw new Error(r.error);
          const file = unique(path.join(exportsDir(), `${slug(r.title)}.transcript.txt`));
          fs.writeFileSync(file, `${r.title}\n${u.href}\n\n${r.lines.join("\n")}\n`, "utf8");
          return file;
        },
      },

      dev: {
        async logs({ filter, levels, limit = 100 } = {}) {
          const want = levels?.map((l) => (l === "warning" ? "warn" : l));
          return alive(t).logs
            .filter((l) => (!want || want.includes(l.level === "warning" ? "warn" : l.level)) && (!filter || l.message.includes(filter)))
            .slice(-limit).map((l) => ({ level: l.level === "warning" ? "warn" : l.level, message: l.message, timestamp: l.t, url: l.url }));
        },
      },

      capabilities: capabilityCollection({
        cdp: {
          description: "Raw Chrome DevTools Protocol commands and buffered events for this tab.",
          doc: "capabilities/tab/cdp",
          make: () => ({
            send: (method, params = {}, o = {}) => o.target?.sessionId
              ? engine.cdp.send(method, params, o.target.sessionId, o.timeoutMs)
              : alive(t).send(method, params, o.timeoutMs),
            async readEvents({ afterSequence, limit = 100, methods, target, timeoutMs } = {}) {
              if (methods && !methods.length) throw new Error("methods must not be empty");
              if (afterSequence == null) return { cursor: t.eventSeq, events: [], hasMore: false, truncated: false };
              const match = (e) => e.sequence > afterSequence && (!methods || methods.includes(e.method))
                && (!target?.sessionId || e.source.sessionId === target.sessionId);
              const deadline = Date.now() + (timeoutMs ?? 0);
              let hits = t.events.filter(match);
              while (!hits.length && Date.now() < deadline) { await sleep(50); hits = t.events.filter(match); }
              const page = hits.slice(0, Math.min(1000, Math.max(1, limit)));
              const oldest = t.events[0]?.sequence ?? t.eventSeq + 1;
              return { cursor: page.length ? page[page.length - 1].sequence : afterSequence, events: page, hasMore: hits.length > page.length, truncated: afterSequence + 1 < oldest };
            },
          }),
        },
        pageAssets: {
          description: "Inventory the images, fonts, stylesheets, videos and inline SVGs on the current page, and export them to a folder.",
          doc: "capabilities/tab/pageAssets",
          make: () => pageAssets(t, pw),
        },
        webmcp: {
          description: "Tools the page registered through WebMCP (navigator.modelContext).",
          doc: "capabilities/tab/webmcp",
          make: () => ({
            async fetchTools() {
              const tools = await t.evaluate(() => (window.__cuaWebMcp?.list() ?? []));
              return {
                tools,
                invoke: (name, args = {}) => t.evaluate(`window.__cuaWebMcp.invoke(${JSON.stringify(name)}, ${JSON.stringify(args)})`),
              };
            },
          }),
        },
      }),
    };
    return tab;
  }

  // ---------------- Browser ----------------
  const tabs = {
    async new(url) {
      const t = await engine.newTab(url || "about:blank");
      opened.add(t);
      hint();
      return wrapTab(t);
    },
    async get(id) { await engine.ensure(); return wrapTab(engineTab(id)); },
    async list() { await engine.ensure(); return engine.list().map(({ id, title, url }) => ({ id, title, url, providerTabId: id })); },
    async selected() { await engine.ensure(); return wrapTab(engine.active); },
    async content({ urls: list, contentType = "text", timeoutMs = 30000 }) {
      const one = async (url) => {
        let t;
        try {
          t = await withTimeout(engine.newTab(url, { activate: false }), timeoutMs, "load");
          const content = contentType === "html" ? await t.evaluate("document.documentElement.outerHTML")
            : contentType === "domSnapshot" ? await wrapTab(t).playwright.domSnapshot()
            : await t.evaluate("document.body?.innerText ?? ''");
          return { url: await t.url(), title: await t.title(), content };
        } catch { return { url, title: null, content: null }; }
        finally { await t?.close().catch(() => {}); }
      };
      const out = [];
      for (let i = 0; i < list.length; i += 4) out.push(...await Promise.all(list.slice(i, i + 4).map(one)));
      return out;
    },
  };

  const browser = {
    browserId: "cua",
    tabs,
    user: { openTabs: unsupported("browser.user.openTabs"), claimTab: unsupported("browser.user.claimTab"), getTabContext: unsupported("browser.user.getTabContext") },
    history: unsupported("browser.history"),
    async nameSession(name) { sessionName = String(name); engine.sessionName = sessionName; engine.hooks.onTabs?.(); },
    documentation: () => readDoc("browser"),
    capabilities: capabilityCollection({
      visibility: {
        description: "Show or hide the live view of this browser.",
        doc: "capabilities/browser/visibility",
        make: () => ({
          async get() { return engine.animatedViewers > 0; },
          async set(visible) {
            if (visible) {
              hud.launch(true);
              write(`Live view: ${urls().browser}\nIf your harness has a browser pane (Claude app: mcp__Claude_Browser__preview_start with this url), open it there now.`);
            }
          },
        }),
      },
      viewport: {
        description: "Override the page viewport size, for responsive testing.",
        doc: "capabilities/browser/viewport",
        make: () => ({
          set: ({ width, height }) => engine.setExplicitViewport({ w: width, h: height }),
          reset: () => engine.setExplicitViewport(null),
        }),
      },
    }),
  };

  const agent = {
    browsers: {
      async list() { return [{ id: "cua", name: "cua browser", type: "iab" }]; },
      async get(id) {
        if (["cua", "iab", "default", "browser", "in-app"].includes(String(id))) return browser;
        throw new Error(`Browser "${id}" isn't available. cua drives its own background browser: use agent.browsers.get("iab") or getDefault().`);
      },
      async getDefault() { return browser; },
      async getForUrl() { return browser; },
    },
    documentation: { get: (name) => readDoc(name) },
  };
  return { agent, browser };
}

// ---------------- elementInfo ----------------
async function elementInfo(page, x, y, includeNonInteractable, t) {
  const infos = await page.evaluate(([px, py, all]) => {
    const INTER = "a[href],button,input,select,textarea,summary,[role=button],[role=link],[role=checkbox],[role=radio],[role=tab],[role=menuitem],[role=option],[role=switch],[contenteditable=true],[tabindex]";
    const IMPLICIT = { A: "link", BUTTON: "button", SELECT: "combobox", TEXTAREA: "textbox", H1: "heading", H2: "heading", H3: "heading", H4: "heading", IMG: "img", NAV: "navigation", MAIN: "main", SUMMARY: "button" };
    const clip = (s, n = 80) => { s = String(s ?? "").replace(/\s+/g, " ").trim(); return s.length > n ? s.slice(0, n - 1) + "…" : s; };
    const roleOf = (el) => el.getAttribute("role") ?? (el.tagName === "INPUT" ? ({ checkbox: "checkbox", radio: "radio", submit: "button", button: "button", search: "searchbox" }[el.type] ?? "textbox") : IMPLICIT[el.tagName] ?? null);
    const nameOf = (el) => clip(el.getAttribute("aria-label") || (el.getAttribute("aria-labelledby") && document.getElementById(el.getAttribute("aria-labelledby"))?.innerText)
      || el.labels?.[0]?.innerText || el.getAttribute("alt") || el.querySelector?.("img[alt]")?.alt || el.getAttribute("title")
      || el.getAttribute("placeholder") || el.innerText || el.querySelector?.("svg title")?.textContent, 80) || null;
    const q = (s) => JSON.stringify(s);
    const seen = new Set(), out = [];
    for (let el of document.elementsFromPoint(px, py)) {
      if (!all) el = el.closest(INTER);
      if (!el || seen.has(el) || el === document.documentElement || el === document.body) continue;
      seen.add(el);
      const r = el.getBoundingClientRect(), role = roleOf(el), name = nameOf(el), testId = el.getAttribute("data-testid");
      const candidates = [];
      if (testId) candidates.push(`[data-testid=${q(testId)}]`);
      if (role && name) candidates.push(`role=${role}[name=${q(clip(name, 60))}]`);
      if (el.id && !/\d{3,}|[:]/.test(el.id)) candidates.push(`#${CSS.escape(el.id)}`);
      if (el.getAttribute("name")) candidates.push(`${el.tagName.toLowerCase()}[name=${q(el.getAttribute("name"))}]`);
      const text = clip(el.innerText, 60);
      if (text && !["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName)) candidates.push(`text=${q(text)}`);
      const path = []; let n = el;
      while (n && n.nodeType === 1 && path.length < 5) { let s = n.tagName.toLowerCase(); const sib = n.parentElement ? [...n.parentElement.children].filter((c) => c.tagName === n.tagName) : []; if (sib.length > 1) s += `:nth-of-type(${sib.indexOf(n) + 1})`; path.unshift(s); n = n.parentElement; }
      candidates.push(path.join(" > "));
      out.push({
        tagName: el.tagName.toLowerCase(), role, ariaName: name, testId,
        visibleText: clip(el instanceof HTMLSelectElement ? el.selectedOptions[0]?.text : "value" in el && el.type !== "password" && el.value ? el.value : el.innerText, 120) || null,
        boundingBox: { x: r.x, y: r.y, width: r.width, height: r.height },
        preview: clip(el.outerHTML.slice(0, el.outerHTML.indexOf(">") + 1), 160),
        selector: { primary: candidates[0] ?? null, candidates },
      });
      if (out.length >= 6) break;
    }
    return out;
  }, [x, y, includeNonInteractable]);
  const top = await t.send("DOM.getNodeForLocation", { x: Math.round(x), y: Math.round(y), includeUserAgentShadowDOM: false }).catch(() => null);
  if (infos[0] && top) infos[0].nodeId = top.backendNodeId;
  return infos;
}

// ---------------- pageAssets ----------------
const inventories = new Map();
function pageAssets(t, pw) {
  return {
    async list() {
      const r = await t.evaluate(() => {
        const assets = new Map();
        const kindOf = (url, hint) => hint ?? (/\.(png|jpe?g|gif|webp|avif|svg|ico|bmp)(\?|$)/i.test(url) ? "image" : /\.(woff2?|ttf|otf|eot)(\?|$)/i.test(url) ? "font"
          : /\.css(\?|$)/i.test(url) ? "stylesheet" : /\.(mp4|webm|mov|m3u8)(\?|$)/i.test(url) ? "video" : /\.m?js(\?|$)/i.test(url) ? "script" : "other");
        const add = (url, kind, source) => {
          if (!url || url.startsWith("data:") || url.startsWith("blob:")) return;
          try { url = new URL(url, location.href).href; } catch { return; }
          const a = assets.get(url) ?? { url, kind: kindOf(url, kind), name: decodeURIComponent(new URL(url).pathname.split("/").pop() || "asset"), sources: [] };
          a.sources.push(source); assets.set(url, a);
        };
        document.querySelectorAll("img").forEach((i) => add(i.currentSrc || i.src, "image", { kind: "attribute", property: "src" }));
        document.querySelectorAll("video, video source, audio source").forEach((v) => add(v.currentSrc || v.src, "video", { kind: "attribute", property: "src" }));
        document.querySelectorAll("link[rel~=stylesheet]").forEach((l) => add(l.href, "stylesheet", { kind: "attribute", property: "href" }));
        document.querySelectorAll("link[rel~=icon]").forEach((l) => add(l.href, "image", { kind: "attribute", property: "href" }));
        document.querySelectorAll("script[src]").forEach((s) => add(s.src, "script", { kind: "attribute", property: "src" }));
        for (const el of document.querySelectorAll("*")) {
          const bg = getComputedStyle(el).backgroundImage;
          if (bg && bg !== "none") for (const m of bg.matchAll(/url\("?([^")]+)"?\)/g)) add(m[1], "image", { kind: "computedStyle", property: "background-image" });
        }
        for (const e of performance.getEntriesByType("resource")) add(e.name, e.initiatorType === "css" && /\.(woff2?|ttf|otf)/i.test(e.name) ? "font" : undefined, { kind: "resource" });
        const svgs = [...document.querySelectorAll("svg")].filter((s) => !s.closest("svg svg")).slice(0, 200).map((s, i) => ({ name: s.getAttribute("aria-label") ?? s.id ?? `svg-${i + 1}`, markup: s.outerHTML.slice(0, 20000) }));
        return { assets: [...assets.values()], svgs, pageUrl: location.href };
      });
      const id = createHash("sha1").update(r.pageUrl + Date.now()).digest("hex").slice(0, 12);
      const assets = r.assets.map((a) => ({ id: createHash("sha1").update(a.url).digest("hex").slice(0, 10), ...a }));
      const inlineSvgs = r.svgs.map((s, i) => ({ id: `svg${i + 1}`, ...s }));
      const byKind = {};
      for (const a of assets) byKind[a.kind] = (byKind[a.kind] ?? 0) + 1;
      inventories.set(id, assets);
      return { id, pageUrl: r.pageUrl, assets, inlineSvgs, summary: { byKind, inlineSvgCount: inlineSvgs.length, totalCount: assets.length } };
    },
    async bundle({ inventoryId, kinds, assetIds }) {
      const inv = inventories.get(inventoryId);
      if (!inv) throw new Error(`Unknown inventory ${inventoryId}. Call list() first.`);
      const pick = inv.filter((a) => (!assetIds || assetIds.includes(a.id)) && (!kinds || kinds.includes(a.kind)) && (assetIds || a.kind !== "script"));
      const dir = path.join(exportsDir(), `assets-${inventoryId}`);
      fs.mkdirSync(dir, { recursive: true });
      const req = (await pw.context()).request;
      const t0 = Date.now(), assets = [], failures = [];
      await Promise.all(pick.map(async (a) => {
        try {
          const res = await req.get(a.url, { timeout: 30000 });
          if (!res.ok()) throw new Error(`HTTP ${res.status()}`);
          const file = unique(path.join(dir, a.name.replace(/[^\w.-]+/g, "_") || a.id));
          fs.writeFileSync(file, await res.body());
          assets.push({ id: a.id, kind: a.kind, name: a.name, url: a.url, path: file, contentType: res.headers()["content-type"] ?? null });
        } catch (e) { failures.push({ id: a.id, name: a.name, url: a.url, reason: e.message, contentType: null }); }
      }));
      const manifestPath = path.join(dir, "manifest.json");
      fs.writeFileSync(manifestPath, JSON.stringify({ assets, failures }, null, 2));
      return { directoryPath: dir, manifestPath, assets, failures,
        summary: { requestedCount: pick.length, downloadedCount: assets.length, failedCount: failures.length, elapsedMs: Date.now() - t0 } };
    },
  };
}
