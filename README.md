<h1 align="center">cua</h1>

<p align="center">
  <b>Codex-style background browser and computer use for any agent harness.</b><br>
  Claude Code · Antigravity · Gemini CLI · Cursor · anything that speaks MCP
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple">
  <img alt="Node 22+" src="https://img.shields.io/badge/node-22%2B-339933?logo=node.js&logoColor=white">
  <img alt="MCP" src="https://img.shields.io/badge/MCP-stdio-6e56cf">
  <img alt="Zero dependencies" src="https://img.shields.io/badge/npm%20dependencies-0-blue">
</p>

<p align="center">
  <img src="docs/live-view.png" alt="The cua live view: a Codex-style browser with tabs, address bar and the agent's own cursor typing into Wikipedia's search box" width="900">
</p>

cua gives an agent its own browser and its own cursor. The agent works in a headless
browser and in native macOS apps **entirely in the background**. Your mouse and keyboard
stay yours, and your windows don't jump to the front. You watch it work in a live view
that fits in a sidebar or a floating HUD, and you can take over at any moment.

It is an independent reimplementation of the ideas that make Codex's computer use feel
good, built only on public APIs (Chrome DevTools Protocol, macOS Accessibility,
ScreenCaptureKit). It does not use or ship any part of the Codex runtime, and it needs no
npm packages.

## Contents

- [Highlights](#highlights)
- [Screenshots](#screenshots)
- [Install](#install)
- [Using it](#using-it)
- [API at a glance](#api-at-a-glance)
- [In the Claude app](#in-the-claude-app)
- [The HUD](#the-hud)
- [Configuration](#configuration)
- [CLI](#cli)
- [How it works](#how-it-works)
- [Security and privacy](#security-and-privacy)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Project layout](#project-layout)

## Highlights

- **One tool, a real REPL.** The agent gets a single `js` tool backed by a persistent
  JavaScript session. `const tab = …` survives between calls, and loops, retries and
  conditionals run in one round trip instead of one tool call per click.
- **Compact reads that diff.** Pages and apps come back as an indexed accessibility tree.
  After the first read, the agent only gets what changed.
- **Never touches your cursor.** Browser input goes to the page through CDP. Native apps
  are driven through Accessibility actions, and key events go to one process only.
  Nothing moves the system pointer or types into whatever you're using.
- **Its own cursor.** An agent cursor with click ripples is drawn in the live view and the
  HUD, so you can see what it's pointing at.
- **Live view you can take over.** A Codex-style browser UI (tabs, address bar, back and
  forward) streams the tab the agent is driving at up to 60 fps. The page is rendered at
  the pane's exact size, so it fills the pane. Clicks, scrolling and typing in the view go
  straight to the page.
- **Native apps too.** Read, click, type, scroll and screenshot any Mac app through the
  same indexed model, including windows that are covered.
- **Works in every harness at once.** One daemon per user. Every harness shares the same
  browser, profile and logins, and each agent session gets its own REPL.
- **Configurable.** A settings page generated from the config schema, where changes apply
  live.

## Screenshots

<table>
  <tr>
    <td width="42%" valign="top">
      <img src="docs/live-view-sidebar.png" alt="Live view at sidebar width, with the agent cursor on a link">
    </td>
    <td valign="top">
      <b>Sidebar-sized live view.</b> The page is re-laid-out for whatever pane it's in,
      so it fills a narrow sidebar with no letterboxing. This is how it looks inside the
      Claude app's browser pane.<br><br>
      <img src="docs/hud.png" alt="The floating HUD: a borderless card streaming the agent's tab with its cursor">
      <br>
      <b>The HUD.</b> A borderless card that streams the agent's tab (or the native window
      it's driving). Controls appear on hover, and you can drag it anywhere. It can attach
      to your harness's window and hide when that app isn't active.
    </td>
  </tr>
</table>

<p align="center">
  <img src="docs/settings.png" alt="The settings page: live status and every option, grouped by section" width="760">
  <br><i>Settings: live status (browser, native agent, permissions, sessions) and every option.</i>
</p>

## Install

```sh
git clone git@github.com:andymsun/cua-bridge.git ~/.local/share/cua-bridge
~/.local/share/cua-bridge/install.sh
```

**Requirements:** macOS 14+, Node 22+ (for the built-in WebSocket), Xcode command line
tools, and a Chromium-family browser (Chrome, Chromium, Helium, Brave or Edge).

The installer:

1. Builds two small apps into `~/Applications`:
   - **CuaAgent**, which holds the macOS permissions.
   - **CuaPreview**, the HUD, which needs no permissions.
2. Registers the `cua` MCP server with every harness it finds: Claude Code, Antigravity,
   Antigravity IDE, Gemini CLI and Cursor. Pass `--with-codex` to add Codex too.
3. Installs the Claude Code skill and the `cua` CLI (`~/.local/bin/cua`).

Re-running it updates everything. CuaAgent is only rebuilt when its source changes
(`--rebuild-agent` forces it), because macOS ties permissions to the app's signature.

Browser control works right away. For native apps, grant **CuaAgent** once in System
Settings › Privacy & Security › **Accessibility** and **Screen Recording**, then check with
`cua doctor`:

```text
✓ node 25.2.1 (need 22+ for built-in WebSocket)
✓ browser: /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
✓ native agent: ~/Applications/CuaAgent.app
✓ HUD: ~/Applications/CuaPreview.app
✓ config: ~/.config/cua/config.json
✓ registered in: Claude Code, Antigravity, Antigravity IDE
✓ Accessibility granted to CuaAgent (native apps)
✓ Screen Recording granted to CuaAgent (native screenshots, HUD for apps)
```

### Other harnesses

cua is a plain MCP stdio server. Anything that can launch one can use it:

```json
{
  "mcpServers": {
    "cua": { "command": "node", "args": ["/Users/you/.local/share/cua-bridge/server/shim.mjs"] }
  }
}
```

## Using it

The agent calls one tool, `js`, with JavaScript. A typical call opens a page, acts and
checks the result in one go:

```js
const tab = await cua.open("https://en.wikipedia.org/wiki/Special:Search");
await tab.find("searchbox");          // matching lines with fresh indices
await tab.typeText(22, "Engelbart");
await tab.pressKey(null, "Return");
await tab.waitFor("Douglas Engelbart");
await tab.read();
```

What the agent sees back:

```text
Opened tab 4676D09C · Search - Wikipedia · https://en.wikipedia.org/wiki/Special:Search
Live view for the user: http://127.0.0.1:47821/?t=…
22 searchbox (focused)
23 button "Search"
Tab 4676D09C · Engelbart - Search results - Wikipedia · https://en.wikipedia.org/w/index.php?search=Engelbart…
26 link "Search"
27 searchbox "Search Wikipedia"
…
40 heading "Search results" h1
63 searchbox value="Engelbart"
64 button "Search"
…
```

Later `read()` calls return only the lines that changed. When most of the page changed,
they return the full tree instead.

Native apps use the same model:

```js
const notes = await cua.app("Notes");   // name or bundle id
await notes.read();
await notes.click(7);                   // Accessibility press, not a mouse click
await notes.typeText(4, "groceries");
```

## API at a glance

The full reference ships as the tool description
([`server/tool-description.md`](server/tool-description.md)), so every agent sees it.

| Area | Calls |
| --- | --- |
| Tabs | `cua.open(url)`, `cua.tab(id?)`, `cua.browser.tabs()`, `cua.browser.restart()`, `tab.keep()` |
| Navigation | `goto`, `back`, `forward`, `reload`, `close`, `url()`, `title()` |
| Reading | `read({ full })`, `find(query)`, `text()`, `screenshot({ fullPage })` |
| Acting | `click(target)`, `hover`, `typeText(target, text)`, `setValue`, `pressKey(target, "ctrl+a")`, `scroll(target, dir, pages)`, `drag(a, b)`, `upload(target, paths)` |
| Page scripting | `evaluate(fn, arg)` (live DOM), `waitFor(textOrSelector)`, `cdp(method, params)` |
| Debugging | `getLogs({ level })`, `getRequests({ filter })`, `dialog` + `handleDialog(accept, text)` |
| Native apps | `cua.apps()`, `cua.app(q)` → `read`, `find`, `click`, `setValue`, `typeText`, `pressKey`, `action`, `scroll`, `focus`, `screenshot` |
| UI & config | `cua.ui()`, `cua.hud.show()`, `cua.hud.status(text)`, `cua.config()`, `cua.setConfig(patch)` |

A target can be an index from the last read, a CSS selector, or `[x, y]`. `read`, `find`
and `screenshot` print their output into the tool result themselves; pass
`{ emit: false }` to keep a result in JS and `write()` only what matters.

## In the Claude app

cua's live view is a local web page, so any harness with a browser pane can show it. In the
Claude desktop app, the bundled skill tells Claude to open it in the browser sidebar as
soon as browser work starts. That gives you a Codex-style in-app browser while still using
Claude:

1. The first `cua.open()` of a session prints `Live view for the user: <url>`.
2. Claude opens that URL in its browser pane (`preview_start`).
3. The pane mirrors whichever tab cua is driving, sized to fill it. Click, scroll or type
   in it to hand the agent back a page, finish a login, or complete a CAPTCHA.

`cua ui` opens the same view in your default browser.

## The HUD

`CuaPreview.app` is a small borderless card that streams what the agent is driving: the
active browser tab, or the native window when it's working in an app. It draws the agent's
cursor and click ripples on top.

- **Hover** to show the controls: close, and take over. Take over opens the live view, or
  brings the native app forward.
- **Drag** it from anywhere on the card.
- **Modes:**
  - `attached` (the default) pins the HUD to a host app's window, such as Claude, and
    hides it when that app isn't active.
  - `overlay` floats the HUD above everything.
  - `normal` makes it an ordinary window.
- Size, corner, opacity, glyphs, tint, scrim and fade timings are all configurable.

## Configuration

`cua settings` opens the settings page, and changes apply live. The file lives at
`~/.config/cua/config.json` and stores only what you changed from the defaults.
[`config.example.json`](config.example.json) lists every key.

| Section | Key options |
| --- | --- |
| `browser` | `executable` (`auto` or a path), `headless`, `attach` (a CDP URL of a browser to drive instead), `profile`, `viewport`, `downloadsDir`, `dialogs` (`report`/`accept`/`dismiss`), `closeTabsOnSessionEnd` |
| `snapshot` | `diff`, `maxLines`, `maxTextLength` |
| `native` | `enabled`, `allowKeyEvents`, `maxDepth`, `maxLines` |
| `stream` | `fps` (default 30), `quality`, `maxWidth` |
| `hud` | `enabled`, `mode`, `attachTo`, `anchor`, `hideWhenHostInactive`, `width`, `opacity`, `cornerRadius`, `clickThrough`, `showAgentCursor`, `controlsCorner`, glyph and fade options |
| `web` | `port` (default 47821) |
| `repl` | `timeoutMs`, `maxOutputChars` |

Environment overrides: `CUA_CONFIG` (config file path) and `CUA_RUN_DIR` (sockets, token,
logs).

## CLI

| Command | What it does |
| --- | --- |
| `cua status` | Daemon, browser, and native agent state, plus the live view and settings URLs |
| `cua start` / `stop` / `restart` | Manage the daemon (it also starts on the first tool call) |
| `cua ui` | Open the live browser view |
| `cua settings` | Open the settings page |
| `cua doctor` | Check Node, browser, apps, harness registration and permissions |

## How it works

```mermaid
flowchart LR
  subgraph Harnesses
    A[Claude Code]:::h
    B[Antigravity]:::h
    C[Gemini CLI / Cursor / …]:::h
  end
  A & B & C -- MCP stdio --> S[shim.mjs<br/>one per session]
  S -- unix socket --> D[daemon.mjs<br/>one per user]
  D -- per-session vm REPL --> R[cua API]
  R -- CDP over WebSocket --> CH[Headless Chrome<br/>own profile]
  R -- JSON lines, unix socket --> AG[CuaAgent.app<br/>Accessibility + ScreenCaptureKit]
  D -- screencast frames --> W[Live view<br/>127.0.0.1:47821]
  D -- frames + cursor --> H[CuaPreview.app<br/>HUD]
  classDef h fill:#f4f4f5,stroke:#a1a1aa,color:#111
```

- **shim → daemon.** Each harness launches `shim.mjs`, a tiny MCP server that forwards
  calls to a single per-user daemon (and starts it if needed). The browser and its logins
  are shared, and each session gets its own REPL.
- **REPL.** Each session is a Node `vm` context. Top-level declarations are hoisted so they
  persist, a single trailing expression is returned automatically, and output is capped.
- **Browser engine.** A zero-dependency CDP client with flattened sessions.
  - Reads come from `Accessibility.getFullAXTree`, filtered to meaningful roles and
    indexed, with multiset diffs between reads.
  - Input goes through `Input.dispatch*`, so it's page-level and never touches the OS.
  - The live view uses `Page.startScreencast`, with the page's metrics matched to the
    viewer's size.
- **Native agent.** A Swift app that owns the Accessibility and Screen Recording grants.
  - It builds indexed AX snapshots per process.
  - It presses, sets values, scrolls and hit-tests through AX.
  - Keys are sent with `CGEvent.postToPid`, to that process only.
  - Windows are captured with ScreenCaptureKit, even when they're covered.
- **Live view.** A token-gated local page. One WebSocket carries frames down and input,
  navigation and viewport size up. Slow viewers drop old frames instead of queueing them.

## Security and privacy

- The web UI binds to `127.0.0.1` only and requires a random per-install token.
- Nothing leaves your machine except the pages the agent visits.
- The agent's browser uses its own profile under
  `~/Library/Application Support/cua/profiles`. It never sees your normal browser's
  cookies unless you point `browser.attach` at it.
- Page content is treated as untrusted. The skill and tool description tell agents to
  confirm before sending messages, submitting forms with side effects, buying things,
  deleting data or entering credentials.
- Agents are told never to solve CAPTCHAs. They hand them to you in the live view.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Native apps say permission denied | Grant CuaAgent **Accessibility** and **Screen Recording**, then run `cua doctor`. After `--rebuild-agent`, grant them again. |
| A site blocks the headless browser or keeps showing CAPTCHAs | Browsers started with a debugging port are detectable as automated, and cua doesn't hide that. Finish the check yourself in the live view, or set `browser.attach` to a browser you started with `--remote-debugging-port`. |
| Live view is blank | Run `cua status`. The browser starts on the first `cua.open()`, and `cua restart` resets everything. |
| The agent doesn't have the tool | Start a new conversation after installing, because harnesses load MCP servers at session start. |
| Anything else | The daemon log is at `~/Library/Application Support/cua/run/daemon.log`. |

Turning `browser.headless` off shows a real Chrome window, but Chrome takes focus when it
launches. That's why the default is headless.

## Uninstall

```sh
~/.local/share/cua-bridge/uninstall.sh          # keeps your config and browser profiles
~/.local/share/cua-bridge/uninstall.sh --purge  # removes those too
```

## Project layout

```text
server/
  shim.mjs               MCP stdio server each harness registers
  daemon.mjs             per-user daemon: browser, native agent, HUD feed, web UI, sessions
  cli.mjs                the `cua` command
  tool-description.md    API guide shown to agents
  lib/
    browser.mjs          CDP engine: tabs, snapshots, input, dialogs, logs, network, screencast
    cdp.mjs              minimal CDP client over Node's WebSocket
    snapshot.mjs         AX tree → indexed text, and diffs
    repl.mjs             persistent per-session vm REPL
    api.mjs              the `cua` object agents use
    native.mjs           client for CuaAgent
    hud.mjs              HUD feed (frames, cursor, source)
    web.mjs              live view + settings server, WebSocket stream
    config.mjs           defaults, paths, overrides-only saving
    keys.mjs             "ctrl+shift+t" → CDP key events
  web/
    browser.html         live view
    settings.html        settings page
agent/CuaAgent.swift     Accessibility + ScreenCaptureKit agent
hud/CuaPreview.swift     the HUD
skill/SKILL.md           Claude Code skill
docs/                    screenshots
install.sh · uninstall.sh · config.example.json
```
