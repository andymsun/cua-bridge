// Computer use for native Mac apps, with the same `sky` API the ChatGPT app gives
// its models, built on CuaAgent (Accessibility and process-targeted input only -
// the user's cursor and keyboard are never used).
import { execFile } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import { pathToFileURL } from "node:url";
import { paths } from "./config.mjs";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const run = (cmd, args) => new Promise((res) => execFile(cmd, args, { maxBuffer: 16 << 20 }, (e, out) => res(e ? "" : out)));
const shotsDir = () => { const d = path.join(path.dirname(paths.run), "screenshots"); fs.mkdirSync(d, { recursive: true, mode: 0o700 }); return d; };
const MOUSE = { l: "left", left: "left", r: "right", right: "right", m: "middle", middle: "middle" };
const htmlToText = (h) => String(h).replace(/<br\s*\/?>/gi, "\n").replace(/<\/(p|div|li|h\d)>/gi, "\n").replace(/<[^>]+>/g, "")
  .replace(/&nbsp;/g, " ").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&").trim();
const mdToText = (m) => String(m).replace(/\*\*(.+?)\*\*/g, "$1").replace(/\*(.+?)\*/g, "$1").replace(/`(.+?)`/g, "$1")
  .replace(/\[(.+?)\]\((.+?)\)/g, "$1 ($2)").replace(/^#{1,6}\s+/gm, "");

let installed = null, installedAt = 0;
async function installedApps() {
  if (installed && Date.now() - installedAt < 10 * 60_000) return installed;
  const roots = ["/Applications", "/System/Applications", path.join(process.env.HOME, "Applications")];
  const list = (await run("mdfind", ["kMDItemContentType == 'com.apple.application-bundle'", ...roots.flatMap((r) => ["-onlyin", r])])).split("\n").filter(Boolean);
  const meta = list.length ? await run("mdls", ["-name", "kMDItemCFBundleIdentifier", "-name", "kMDItemDisplayName", "-name", "kMDItemLastUsedDate", "-name", "kMDItemUseCount", ...list]) : "";
  const apps = [];
  let cur = {};
  for (const line of meta.split("\n")) {
    const m = line.match(/^(kMDItem\w+)\s+=\s+(.*)$/);
    if (!m) continue;
    const v = m[2] === "(null)" ? undefined : m[2].replace(/^"|"$/g, "");
    if (m[1] === "kMDItemCFBundleIdentifier") { if (cur.id) apps.push(cur); cur = { id: v }; }
    else if (m[1] === "kMDItemDisplayName") cur.displayName = v?.replace(/\.app$/, "");
    else if (m[1] === "kMDItemLastUsedDate") cur.lastUsedDate = v ? new Date(v.replace(" +0000", "Z").replace(" ", "T")).toISOString() : undefined;
    else if (m[1] === "kMDItemUseCount") cur.useCount = v ? Number(v) : undefined;
  }
  if (cur.id) apps.push(cur);
  installed = apps.filter((a) => a.id); installedAt = Date.now();
  return installed;
}

export function makeSky({ native }) {
  const byPid = new Map();         // keep one App per process so reads diff against the last one
  const app = async (query, windowId) => {
    if (!query) throw new Error("Pass the app: a display name, bundle id or app path");
    const a = await native.app(String(query).replace(/^.*\/([^/]+)\.app\/?$/, "$1"), { windowId });
    const key = `${a.info.process}:${windowId ?? "single"}`;
    const known = byPid.get(key);
    if (known) return known;
    byPid.set(key, a);
    return a;
  };
  // after an action, give the app a moment before its state is read (Codex waits about a second)
  const settle = async (a) => { const since = Date.now() - (a.lastActionAt ?? 0); if (since < 800) await sleep(800 - since); };

  return {
    target: "mac",
    async list_apps() {
      const running = await native.apps();
      const all = await installedApps().catch(() => []);
      const out = new Map(all.map((a) => [a.id, { ...a, isRunning: false }]));
      for (const r of running) out.set(r.bundleId || r.name, { ...(out.get(r.bundleId) ?? {}), id: r.bundleId || r.name, displayName: r.name, isRunning: true });
      return [...out.values()].sort((a, b) => (b.isRunning - a.isRunning) || String(b.lastUsedDate ?? "").localeCompare(String(a.lastUsedDate ?? "")));
    },
    async list_windows({ app: q }) { return (await app(q)).windows(); },
    async get_app_state({ app: q, window_id, disableDiff = false }) {
      const a = await app(q, window_id);
      await settle(a);
      const text = await a.read({ full: !!disableDiff });
      let screenshot = null, screenshotError = null;
      try {
        const file = path.join(shotsDir(), `${a.pid}-${Date.now()}.jpg`);
        fs.writeFileSync(file, await a.screenshot(), { mode: 0o600 });
        screenshot = { url: pathToFileURL(file).href };
        const old = fs.readdirSync(shotsDir()).filter((f) => /^\d+-\d+\.jpg$/.test(f)).sort().slice(0, -40);   // keep the latest 40
        for (const f of old) fs.rmSync(path.join(shotsDir(), f), { force: true });
      } catch (error) { screenshotError = { code: error.code ?? "capture_failed", message: error.message }; }
      return { app: a.name, windowId: a.info.windowId, process: a.info.process, screenshot, screenshotError, text };
    },
    async click({ app: q, window_id, element_index, x, y, mouse_button = "left", click_count = 1 }) {
      const a = await app(q, window_id);
      const target = element_index ?? (x != null && y != null ? [x, y] : null);
      if (target == null) throw new Error("click needs element_index or x and y");
      await a.click(target, { button: MOUSE[mouse_button] ?? "left", count: click_count });
    },
    async drag({ app: q, window_id, from_x, from_y, to_x, to_y }) { await (await app(q, window_id)).drag([from_x, from_y], [to_x, to_y]); },
    async paste({ app: q, window_id, text, format = "text" }) {
      // inserted as text through Accessibility: the user's clipboard is never touched
      const plain = format === "html" ? htmlToText(text) : format === "md" ? mdToText(text) : String(text);
      await (await app(q, window_id)).typeText(null, plain);
    },
    async perform_secondary_action({ app: q, window_id, element_index, action }) { await (await app(q, window_id)).action(element_index, action); },
    async press_key({ app: q, window_id, key }) { await (await app(q, window_id)).pressKey(null, key); },
    async scroll({ app: q, window_id, element_index, x, y, direction = "down", pages = 1 }) {
      const a = await app(q, window_id);
      if (element_index != null) return void await a.scroll(element_index, direction, pages);
      if (x == null || y == null) throw new Error("scroll needs element_index or x and y");
      await a.scrollAt(x, y, direction, pages);
    },
    async select_text({ app: q, window_id, element_index, text, prefix, suffix, selection_type }) {
      await (await app(q, window_id)).selectText(element_index, text, { prefix, suffix, selectionType: selection_type });
    },
    async set_value({ app: q, window_id, element_index, value }) { await (await app(q, window_id)).setValue(element_index, value); },
    async type_text({ app: q, window_id, text }) { await (await app(q, window_id)).typeText(null, text); },
  };
}
