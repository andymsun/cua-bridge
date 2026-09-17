---
name: cua
description: Drive browsers and native macOS apps through the Codex CUA Node REPL bridge (mcp__cua__js). Use for any browser automation, web testing, multi-step UI work, or native app control that the built-in Claude browser tools handle awkwardly - anything needing loops, conditionals, retries, or persistent handles across steps.
---

# CUA bridge

`mcp__cua__js` executes JavaScript in a **persistent** Node REPL with a pre-initialized
`cua` API covering browser tabs and native macOS apps behind one interface.

## Why prefer it

One `js` call can hold real control flow - loops, conditionals, retries, early exit -
so a whole interaction sequence that would be 8+ round trips with the discrete browser
tools becomes one call. Bindings persist between calls, so a `tab` handle stays live.

Prefer the built-in `mcp__Claude_Browser__*` tools only for the in-app preview pane
(`preview_start`, dev-server previews). Use this bridge for everything else.

## Protocol

**First call after startup or `js_reset` must be exactly one entry-point call** - no
extra statements, no snapshots. It returns the full API documentation plus initial UI state.

**Open on `about:blank`, not the target URL.** Entry points auto-emit the full AX tree,
and on a real page that can exceed the tool's output cap and spill to a file - defeating
the whole point of the sandbox. `goto()` does *not* auto-emit, so this keeps you in
control of what reaches context:

```javascript
let tab = await cua.createBrowserTab('chrome', 'about:blank', { sessionName: '🔎 Task' });
```

Then navigate and filter in the sandbox (see below). Pass the real URL directly only
when you know the page is small.

Other entry points:

```javascript
await cua.getState();                              // inventory: apps + browsers + tabs
let tab = await cua.getTab(id, { browser: 'chrome' });
let app = await cua.getApp('Notes');               // native macOS app
```

After that, batch freely.

## Core loop: accessibility first

`getAXState()` returns an indexed accessibility tree. Act on **element indices**, not
coordinates. Indices are re-derived from each fresh tree - never reuse stale ones.

**Emit little, compute a lot.** `{ emit: false }` returns the tree into a JS variable
without sending it to context. Filter there, emit only what matters:

```javascript
await tab.goto('https://news.ycombinator.com');
const st = await tab.getAXState({ emit: false, disableDiffing: true });
nodeRepl.write(st.split('\n').filter(l => /points/.test(l)).slice(0, 5).join('\n'));
```

```javascript
await tab.click(4);
await tab.setValue(12, 'search text');
await tab.pressKey('Return');
await tab.typeText('hello');
await tab.scroll(20, 'down', 1);
await tab.selectText(12, 'foo', { prefix: 'x' });
await tab.performSecondaryAction(7, 'Expand');   // only names the tree exposes
nodeRepl.write(await tab.getAXState());          // fresh tree, as a diff by default
```

Batch actions **and** the closing `getAXState()` into one call. The runtime auto-waits
after actions, so explicit sleeps are rarely needed.

AX state is returned as a **diff** against the previous tree. Pass
`{ disableDiffing: true }` for a full tree - do that after any screenshot-only
observation before trusting indices again.

Fall back to coordinates (`[x, y]`) or `getScreenshot()` only when AX is unavailable or
an action visibly fails. If something has no effect, inspect state for a blocker rather
than repeating the action or dropping straight to pixels.

## Tab extras

Beyond the shared `Target` interface, tabs add `goto`, `back`, `forward`, `reload`,
`close`, plus (via the docs returned on first call) Playwright locators, console logs,
and clipboard access. Don't call `goto` with the URL already loaded - use `reload()`.

## Output

- `nodeRepl.write(value)` - text into the tool result
- `await nodeRepl.emitImage(image)` - images
- Entry-point calls and `getAXState()` already emit; don't wrap them.

## Beyond browsers: the runtime itself

The REPL is a general Node sandbox with useful libraries already bundled. Bare
`await import()` fails on the CommonJS ones (`does not provide an export named
'default'`); use `createRequire` instead:

```javascript
const { createRequire } = await import('node:module');
const require = createRequire('/Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules/');
globalThis.req = require;   // persists for later calls

const sharp = req('sharp');          // image convert / resize / composite
const pw    = req('playwright');     // headless browser automation
const pm    = req('pixelmatch');     // pixel diffing
const { PNG } = req('pngjs');
```

Use `js_add_node_module_dir` to add another `node_modules` directory. Combined with
`tab.getScreenshot()`, sharp + pixelmatch make visual regression checks a single call.

## Live preview HUD

A carbon copy of Codex's "Computer Use" HUD, reverse-engineered from the real
thing (references in `~/.claude/cua-bridge/reference/`). Codex's is a
separate ~532x383 window owned by the ChatGPT process, shown only while it drives
an **external** browser tab - not the in-app side pane.

Resting: a rounded card with the live frame, no chrome at all.
Hover: two bare glyphs fade in **top-left** (close, hand-back-control) over a soft
radial scrim - no button backgrounds. Glyph colour adapts to page brightness.

Split into two apps so the UI can be rebuilt freely:

- `CuaCapture.app` - holds Screen Recording, runs the `SCStream`, writes frames +
  host bounds to `/tmp/cua-preview/`. **Never rebuild or re-sign it**: macOS ties
  the TCC grant to its cdhash.
- `CuaPreview.app` - UI only, no permissions.

```bash
open ~/Applications/CuaCapture.app && open ~/Applications/CuaPreview.app
```

Drag from anywhere on the card (explicit mouseDown/mouseDragged - a non-activating
NSPanel ignores `isMovableByWindowBackground`). A manual drag sets `userMoved` and
stops attached-mode auto-anchoring until restart.

Point it at what you drive:

```javascript
const P = await import(`file://${nodeRepl.homeDir}/.claude/cua-bridge/preview.mjs`);
P.watchApp('Helium');        // native app / whole window - live SCK stream
let view = P.watchTab(tab);  // browser TAB - per-tab frames (see below)
```

**Tabs must not use window capture** - it shows whichever tab the user is looking
at, not the one being driven. `watchTab()` clears the target so the daemon idles
and frames come from the tab itself. For the built-in browser, `tabstream.mjs`
gives continuous per-tab CDP `Page.startScreencast` (frames only on visual change).

### Toggles - `config.json`, hot-reloaded

`mode` (`attached` in-app / `overlay` / `normal`) · `attachTo` · `anchor` ·
`hideWhenHostInactive` · `margin` · `width` · `fps` · `showCursor` · `opacity` ·
`cornerRadius` · `clickThrough`

`/tmp/cua-preview/state.json` reports daemon status; read it to diagnose.

## Built-in browser

A dedicated headless Chromium under full Playwright + CDP control, with its own
profile, completely isolated from the user's tabs. Invisible except in the panel.

```javascript
const IAB = await import(`file://${nodeRepl.homeDir}/.claude/cua-bridge/iab.mjs`);
await IAB.openIAB('https://example.com');
await IAB.streamIAB(async (page, cdp) => {
  await page.locator('input[name=q]').fill('hello');
  await page.mouse.wheel(0, 700);
  await cdp.send('Network.enable');        // raw CDP available
  return await page.title();
}, { status: 'Claude — built-in browser' });
await IAB.closeIAB();
```

Use it for scraping, form flows, and anything you don't want touching the user's
live session. Use the normal `cua` browser when the work needs *their* logged-in
tabs. Close it when done.

## Cautions

- Close tabs you opened for a task.
- This drives the user's **real** browser and apps. Confirm before irreversible actions
  (sending, purchasing, deleting, submitting forms) per the standing safety rules.
- `js_reset` clears bindings but does not close tabs or apps.
