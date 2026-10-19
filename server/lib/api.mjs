// The `cua` object each REPL session sees. Reading calls (read, find, screenshot)
// emit into the tool result themselves; pass { emit: false } to keep a result in
// JS and write() only what matters.
import { config, saveConfig } from "./config.mjs";
import { makeCodexApi } from "./codex.mjs";
import { makeSky } from "./sky.mjs";

export function makeApiFactory({ engine, native, hud, urls, pw, pointers }) {
  return ({ write, image }) => {
    const emitting = (obj) => new Proxy(obj, {
      get(target, prop) {
        const v = Reflect.get(target, prop, target);
        if (typeof v !== "function") return v;
        if (prop === "read" || prop === "find") {
          return async (...args) => {
            const opts = (prop === "find" ? args[1] : args[0]) ?? {};
            const r = await v.call(target, ...args);
            if (opts.emit !== false) write(r);
            return r;
          };
        }
        if (prop === "screenshot") {
          return async (opts = {}) => {
            const buf = await v.call(target, opts);
            if (opts.emit !== false) image(buf, prop === "screenshot" && target.pid ? "image/jpeg" : "image/png");
            return buf;
          };
        }
        return v.bind(target);
      },
    });

    const opened = new Set();   // tabs this session created; closed at session end unless kept
    const attached = new Set(); // native previews are owned by this REPL session
    let hinted = false;         // live-view hint goes out once per session
    const hint = () => {
      if (hinted) return;
      hinted = true;
      write(`Live view for the user: ${urls().browser}\nIf your harness has a browser pane or sidebar (Claude app: mcp__Claude_Browser__preview_start with this url), open it there now so the user can watch and take over.`);
    };
    const wrapTab = (t) => {
      t.keep ??= function () { this.kept = true; return "tab will stay open after this session"; };
      return emitting(t);
    };

    const browser = {
      /** Open a URL in a new background tab and make it the driven tab. */
      async open(url = "about:blank") {
        const tab = await engine.newTab(url);
        opened.add(tab);
        write(`Opened tab ${tab.id.slice(0, 8)} · ${await tab.title()} · ${await tab.url()}  (call tab.read() for elements)`);
        hint();
        return wrapTab(tab);
      },
      /** The driven tab (or the tab with this id). */
      async tab(id) { return wrapTab(await engine.tab(id)); },
      async tabs() { await engine.ensure(); return engine.list(); },
      async restart() { await engine.shutdown(); await engine.ensure(); return "browser restarted"; },
      get running() { return engine.running; },
    };

    // This session's own cursor on the user's screen.
    const me = pointers.session();
    const follow = (a) => {
      a.onPointer = (target, kind) => { if (config().pointer.followActions) pointers.move(me, target, { kind: kind === "click" ? "click" : "move" }); };
      return a;
    };
    /** Point at element `at` (an index from the last read) or [x, y] in the window, saying why. */
    const pointAt = async (a, at, text, { highlight = false } = {}) => {
      const where = await a.locate(at);
      const target = where.rect && !highlight
        ? { windowId: where.windowId, x: where.rect.x + where.rect.w / 2, y: where.rect.y + where.rect.h / 2 }
        : where;
      if (!pointers.move(me, target, { text, kind: where.rect && highlight ? "rect" : "point" })) return "pointer is off in settings (pointer.enabled)";
      return `pointing at ${Array.isArray(at) ? `(${at[0]}, ${at[1]})` : `element ${at}`} in ${a.name}${text ? `: ${text}` : ""}`;
    };
    const point = async (target, at, text, opts) => {
      if (target && typeof target.locate === "function") return pointAt(target, at, text, opts);
      // a screen point in global points, top-left origin (what CGWindow bounds use)
      if (Number.isFinite(target?.x) && Number.isFinite(target?.y)) {
        if (!pointers.move(me, { screen: [target.x, target.y] }, { text: at })) return "pointer is off in settings (pointer.enabled)";
        return `pointing at screen (${target.x}, ${target.y})${at ? `: ${at}` : ""}`;
      }
      throw new Error("point(app, index | [x, y], label) or point({ x, y }, label)");
    };

    const apps = async () => native.apps();
    const app = async (query, options) => follow(emitting(await native.app(query, options)));

    const api = {
      browser,
      open: browser.open,
      tab: browser.tab,
      apps,
      app,
      hud: {
        status: (text) => hud.status(text),
        show: () => hud.launch(true),
        async attach(app, { host } = {}) {
          const view = await app.attach({ host: host?.target ?? host });
          try { await hud.showView(view.id); } catch (error) { await native.detach(view.id); throw error; }
          attached.add(view.id);
          return view;
        },
        views: () => native.views(),
        async detach(id) { const result = await native.detach(id); attached.delete(id); return result; },
      },
      point,
      highlight: (a, at, text) => pointAt(a, at, text, { highlight: true }),
      pointer: { hide: () => pointers.hide(me) },
      ui: () => { write(`Live browser: ${urls().browser}\nSettings: ${urls().settings}`); return urls(); },
      config: () => config(),
      setConfig: (patch) => saveConfig(deepMerge(config(), patch)),
      native: { status: () => native.status() },
    };
    Object.defineProperty(api, "__dispose", {
      enumerable: false,
      value: async () => {
        pointers.end(me);
        for (const id of attached) await native.detach(id).catch(() => {});
        attached.clear();
        if (!config().browser.closeTabsOnSessionEnd) return;
        for (const t of opened) if (!t.kept && engine.tabs.has(t.id)) await t.close().catch(() => {});
      },
    });
    const { agent } = makeCodexApi({ engine, pw, hud, urls, write, image, opened, hint });
    // the helpers Codex-style code expects, next to cua's own API
    const nodeRepl = {
      write: (v) => write(v),
      emitImage: ({ bytes, mimeType = "image/png" }) => image(bytes, mimeType),
    };
    return { cua: api, agent, sky: makeSky({ native, onApp: follow, pointAt }), nodeRepl, setupBrowserRuntime: async () => agent };
  };
}

function deepMerge(a, b) {
  const out = { ...a };
  for (const [k, v] of Object.entries(b ?? {})) {
    out[k] = v && typeof v === "object" && !Array.isArray(v) ? deepMerge(a?.[k] ?? {}, v) : v;
  }
  return out;
}
