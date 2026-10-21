<h1 align="center">cua</h1>

<p align="center">
  <b>Codex-style background browser and computer use for any agent harness.</b><br>
  Claude Code · Antigravity · Gemini CLI · Cursor · anything that speaks MCP
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple">
  <img alt="Node 22+" src="https://img.shields.io/badge/node-22%2B-339933?logo=node.js&logoColor=white">
  <img alt="MCP" src="https://img.shields.io/badge/MCP-stdio-6e56cf">
  <img alt="One dependency" src="https://img.shields.io/badge/npm%20dependencies-1%20(playwright--core)-blue">
</p>

<p align="center">
  <img src="docs/live-view.png" alt="The cua live view: a Codex-style browser with tabs, address bar and the agent's own cursor typing into Wikipedia's search box" width="900">
</p>

cua gives an agent its own browser and its own cursor. Browser actions stay in a
separate headless browser. Native actions address a selected process and window;
they never move your real pointer. Native apps can reject background input or change
keyboard focus, so read after each action. A live view shows the work in a sidebar
or floating HUD, and you can take over at any moment.

It speaks the same API as the ChatGPT app's in-app browser (`agent` / `browser` / `tab`
with `ax`, `playwright`, `dom_cua`, `cua` and capabilities) and its computer use (`sky`),
with explicit native window selection and fresh reads after each native action. It is
an independent implementation using CDP, Accessibility, ScreenCaptureKit and Playwright;
no Codex or ChatGPT code or assets are shipped. Native window IDs use the private
`_AXUIElementGetWindow` bridge. Mouse input uses optional private CoreGraphics calls
to keep its window-local point. These APIs can change with macOS. If the mouse
binding fails, CUA sends no mouse events; semantic Accessibility actions remain
available. See the [native API limits](server/docs/computer-use.md#native-mouse-input).

## Contents

- [Highlights](#highlights)
- [Screenshots](#screenshots)
- [Install](#install)
- [Using it](#using-it)
- [API at a glance](#api-at-a-glance)
- [In the Claude app](#in-the-claude-app)
- [Switching to the built-in browser](#switching-to-the-built-in-browser)
- [The HUD](#the-hud)
- [Configuration](#configuration)
- [CLI](#cli)
- [How it works](#how-it-works)
- [Security and privacy](#security-and-privacy)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Project layout](#project-layout)

## Andy Barista

Open `~/Applications/AndyBarista.app` or run `cua companion` for a café-themed desktop companion. Its compact native popup supports text, voice commands, and draft dictation. Each conversation has its own cursor, with area selection, circles, highlights, arrows, and freehand marks. Your real mouse stays yours.

Exact-label cursor requests use local Accessibility lookup without a model. Other requests use the installed Andy CLI with an explicit model and no fallback. Guide mode points while you act. Act mode asks for approval before each input.

The native notch hub shows companion sessions, installed providers, and connected MCP activity. It does not claim access to external conversations. The companion source and original artwork are MIT-licensed.

See [companion setup, privacy, controls, and checks](docs/companion.md).

## Highlights

- **The ChatGPT app's API, anywhere.** Accessibility-indexed actions, Playwright locators
  (frames, roles, actionability waits), a visible-DOM view with node ids, coordinate
  actions, dialogs, downloads, file choosers, the browser's own clipboard, page exports
  (Markdown, Google Docs/Sheets/Slides, YouTube transcripts), raw CDP with event paging, page
  asset bundling, WebMCP tools, and `sky` for native apps.
- **One tool, a real REPL.** The agent gets a single `js` tool backed by a persistent
  JavaScript session. `const tab = …` survives between calls, and loops, retries and
  conditionals run in one round trip instead of one tool call per click.
- **Compact reads that diff.** Pages and apps come back as an indexed accessibility tree.
  After the first read, the agent only gets what changed.
- **Never touches your cursor.** Browser input goes to the page through CDP. Native apps
  are driven through Accessibility actions, and key events go to one process only.
  Nothing moves the system pointer. Keyboard focus is checked before dispatch, but
  another app or person can change it concurrently; this is not an OS input sandbox.
- **Its own cursor.** A rounded, glowing arrowhead that moves on springs: long moves curve
  and turn along their heading, short ones scoot, and it settles with a small wiggle. Actions
  wait for it to arrive, so what you see is what the agent does. Same motion in the live
  view and the HUD.
- **Live view you can take over.** A Codex-style browser UI (tabs, address bar, back and
  forward) streams the tab the agent is driving at up to 60 fps. The page is rendered at
  the pane's exact size, so it fills the pane. Clicks, scrolling and typing in the view go
  straight to the page.
- **Native apps too.** Read, click, type, scroll and screenshot accessible Mac windows, including
  covered windows. Protected/custom controls and secure input can be unsupported.
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
  <br><i>Settings: the cua ↔ built-in browser switch, live status, and every option.</i>
</p>

## Install

```sh
git clone git@github.com:andymsun/cua-bridge.git ~/.local/share/cua-bridge
bash ~/.local/share/cua-bridge/scripts/setup-signing.sh  # explicit local Keychain setup
~/.local/share/cua-bridge/install.sh
```

**Requirements:** macOS 14+, Node 22+ (for the built-in WebSocket), Xcode command line
tools, Python 3, OpenSSL 3 for local certificate setup, and a Chromium-family browser (Chrome, Chromium, Helium, Brave or Edge).

The installer:

1. Builds three native apps into `~/Applications`:
   - **CuaAgent**, which holds the macOS permissions.
   - **CuaPreview**, the HUD and desktop cursors, which need no permissions.
   - **AndyBarista**, the interactive café companion with menu-bar controls.
2. Registers the `cua` MCP server with every harness it finds: Claude Code, Antigravity,
   Antigravity IDE, Gemini CLI and Cursor. Pass `--with-codex` to add Codex too.
3. Installs the Claude Code skill and the `cua` CLI (`~/.local/bin/cua`).

Native apps are compiled and signature-verified before replacement. Keep the same
code-signing identity on upgrades. Previous bundles are retained and must be inspected
before another replacement. For a helper-only repair, use
`python3 scripts/build-native.py` instead of rerunning all integration setup.
See [permission and signing details](docs/native-permissions.md).

For native apps, explicitly run `cua permissions accessibility` and
`cua permissions screen-recording`, then grant **CuaAgent** in System Settings.
Startup, capture and `cua doctor` do not prompt. Moving from an ad-hoc build may
require a new grant; stable signing is not a guarantee against every macOS prompt.
An example doctor result (actual grants are reported on your machine):

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

The agent calls one tool, `js`, with JavaScript. `agent`, `sky` and `nodeRepl` are ready in
every session, top-level `const` persists between calls, and the last expression is
returned:

```js
const browser = await agent.browsers.getDefault();
const tab = await browser.tabs.new();
await tab.goto("https://en.wikipedia.org/wiki/Special:Search");
await tab.ax.write();
```

```text
Tab 9C4CE163 · Search - Wikipedia · https://en.wikipedia.org/wiki/Special:Search
1 link "Jump to content"
…
7 searchbox "Search Wikipedia"
8 button "Search"
…
```

Act by index, or with Playwright locators for forms and repetitive work, then read again.
Later reads return only what changed:

```js
await tab.playwright.getByRole("searchbox", { name: "Search Wikipedia" }).fill("Engelbart");
await tab.ax.pressKey(null, "Return");
await tab.ax.write();      // (changes since last read: +38 −4, …)
```

Native apps work the same way:

```js
const s = await sky.get_app_state({ app: "Notes" });   // { app, text, screenshot: { url } }
await sky.click({ app: "Notes", element_index: 7 });
await sky.get_app_state({ app: "Notes" }); // read again before the next action
```

`cua.open(url)` and `cua.app(name)` remain as a shorter API over the same engine.

## API at a glance

The agent reads the full guide with `browser.documentation()`, and topics with
`agent.documentation.get(name)` (accessibility, file-uploads, computer-use, …). The sources
are in [`server/docs`](server/docs).

| Area | Calls |
| --- | --- |
| Browser | `agent.browsers.getDefault()`, `browser.tabs.new/get/list/selected`, `tabs.content({ urls })`, `nameSession(name)`, capabilities `visibility`, `viewport` |
| Tab | `goto`, `back`, `forward`, `reload`, `close`, `url`, `title`, `screenshot({ fullPage, clip })`, `getJsDialog()`, `markDeliverable()`, `markHandoff()` |
| `tab.ax` | `write/get("state" \| "screenshot" \| "both")`, `click`, `typeText`, `setValue`, `pressKey`, `paste`, `selectText`, `scroll`, `drag`, `performSecondaryAction` |
| `tab.playwright` | `getByRole/Text/Label/Placeholder/TestId`, `locator`, `frameLocator` → `click`, `fill`, `press`, `check`, `selectOption`, `setInputFiles`, reads; `evaluate`, `waitForURL`, `waitForLoadState`, `expectNavigation`, `waitForEvent("download" \| "filechooser")`, `domSnapshot`, `elementInfo`, `elementScreenshot` |
| `tab.dom_cua` | `get_visible_dom()` (all frames, node ids), `click`, `double_click`, `scroll`, `type`, `keypress`, `downloadMedia` |
| `tab.cua` | coordinate `click`, `double_click`, `move`, `drag`, `scroll`, `type`, `keypress`, `downloadMedia` |
| Tab extras | `clipboard` (the browser's own), `content.export()`, `exportGsuite(type)`, `exportYouTubeTranscript()`, `dev.logs()`, capabilities `cdp`, `pageAssets`, `webmcp` |
| `sky` | `list_apps`, `get_app_state`, `click`, `set_value`, `type_text`, `press_key`, `paste`, `scroll`, `select_text`, `perform_secondary_action`, `drag` |

Extension-only parts of the ChatGPT app's API (your own browser's open tabs and history)
report that they aren't available here.

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

## Switching to the built-in browser

You can flip every harness between cua and its own built-in browser (such as the
Claude app's browser pane tools) in one step:

```sh
cua toggle                 # flip
cua use builtin            # or pick one explicitly
cua use cua
cua use                    # show the current choice
```

The settings page has the same switch at the top. Switching changes only the entries cua
manages:

| Harness | cua selected | Built-in browser selected |
| --- | --- | --- |
| Claude Code / Claude app | Built-in page-driving browser tools are denied in `~/.claude/settings.json` (`preview_*` stays allowed so the live view can open) | `mcp__cua` is denied instead, and the cua skill is parked |
| Antigravity, Gemini CLI, Cursor | The `cua` server entry is present | The entry is parked in `~/.config/cua/parked-servers.json` and restored when you switch back |

The rest of each config is left alone. Unreadable configs are skipped rather than
overwritten, and symlinked configs are written through. Re-running the installer
re-applies your current choice. Uninstalling removes every rule cua added. The change
applies to new agent sessions, so restart any harness window that's already open.

## The HUD

`CuaPreview.app` is a small borderless card that streams what the agent is driving: the
active browser tab, or the native window when it's working in an app. It draws the agent's
cursor and click ripples on top.

- **Hover** to show the controls: close, take over, and quick settings. Take over opens the
  live view, or brings the native app forward. Quick settings switches position, corner,
  size, opacity and the agent cursor without opening the settings page.
- **Drag** it from anywhere on the card.
- **Modes:**
  - `auto` (the default) follows the app the agent was started from: VS Code or its
    terminal, Terminal, Ghostty, the Claude app, or any other app. Each call reports the
    harness's process ancestry, and the HUD pins itself to the nearest regular app with a
    window, follows that app's front window and hides when it isn't active. When the chain
    is broken (a tmux or herdr server), the bundle id macOS passed to the shell is used;
    with neither, the HUD is an ordinary window.
  - `attached` pins the HUD to one explicit host window (terminal, IDE or app), and
    hides it when that app isn't active.
  - `overlay` floats the HUD above everything.
  - `normal` makes it an ordinary draggable window without assuming a host.
- Size, corner, opacity, glyphs, tint, scrim and fade timings are all configurable.

Independent native previews do not replace each other:

```sh
cua windows "Code"
cua attach "Code" --window WINDOW_ID
# optionally add --host "Terminal" --host-window HOST_WINDOW_ID
cua views
cua detach VIEW_ID
```

Use IDs returned by `windows`. The captured target and positioning host are distinct.
Multiple windows are never selected by largest-window or frontmost fallback.
See the [native API guide](server/docs/computer-use.md) for per-session previews.

## On-screen pointer

Each agent session also gets its own cursor on your real screen, in its own colour, drawn
by a click-through overlay above everything (`CuaPreview --pointer`). Your cursor is never
moved and nothing is clicked by it; it is how an agent shows you things:

```js
const mail = await cua.app("Mail"); await mail.read();
await cua.point(mail, 14, "the archive button");   // glide there and say why
await cua.highlight(mail, 22, "this thread");      // ring a region
await cua.point({ x: 1200, y: 18 }, "menu bar clock");   // a screen point
cua.pointer.hide();
```

Element targets follow their window when it moves. With `pointer.followActions`, the cursor
also glides to each native click and keystroke target, so you can watch several agents work
at once. Labels and rings fade after `pointer.labelSeconds`; an idle cursor fades after
`pointer.idleSeconds`. The overlay quits after a quiet minute and returns on the next point.
Completed annotation ink also disappears after `pointer.labelSeconds` (six seconds by
default), after the current stroke ends. Waiting-guide ink and persistent selected areas
stay visible. Name or label changes do not extend completed ink lifetime.

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
| `pointer` | `enabled`, `followActions`, `labelSeconds`, `idleSeconds`, `scale`, `colors` |
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
| `cua doctor` | Read-only checks; does not start services or request permissions |
| `cua permissions accessibility\|screen-recording` | Explicitly request one macOS permission |
| `cua windows APP` / `apps` | List native targets |
| `cua attach APP --window ID` / `views` / `detach ID` | Independent native previews |
| `cua use [cua\|builtin]` / `cua toggle` | Choose which browser agents use |

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
- **Locators.** Playwright (`playwright-core`, no browser download) connects to the same
  Chrome as a second CDP client, so `tab.playwright` has Playwright's exact semantics while
  input still goes to the page, never the OS.
- **Cursor sync.** Every agent action announces a cursor move; the live view animates it and
  reports when it has arrived, and the action waits for that (up to about a second), so the
  cursor you see is where the agent acts.
- **Native agent.** A Swift app that owns the Accessibility and Screen Recording grants.
  - It builds per-client UUID snapshots bound to process launch identity and window ID.
  - It presses, sets values, scrolls and hit-tests through AX.
  - Keys are sent with `CGEvent.postToPid`, to that process only.
  - Windows are captured with ScreenCaptureKit, even when they're covered.
- **Live view.** A token-gated local page. One WebSocket carries frames down and input,
  navigation and viewport size up. Slow viewers drop old frames instead of queueing them.

## Security and privacy

- The web UI binds to `127.0.0.1` only and requires a random per-install token.
- CUA runs locally, but its text/screenshots are returned to your harness, which may
  send them to its model provider. Do not expose sensitive windows without authorization.
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
| Native apps say permission denied | Use the explicit `cua permissions` commands and grant access yourself; see [signing](docs/native-permissions.md). No TCC reset is needed as an automated step. |
| A site blocks the headless browser or keeps showing CAPTCHAs | Browsers started with a debugging port are detectable as automated, and cua doesn't hide that. Finish the check yourself in the live view, or set `browser.attach` to a browser you started with `--remote-debugging-port`. |
| Live view is blank | Run `cua status`. The browser starts on the first `cua.open()`, and `cua restart` resets everything. |
| The agent doesn't have the tool | Start a new conversation after installing, because harnesses load MCP servers at session start. |
| You want the harness's own browser for a while | `cua toggle`, then again to come back. |
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
    api.mjs              the session globals: cua, agent, sky, nodeRepl
    codex.mjs            the ChatGPT-compatible browser API (agent / browser / tab)
    sky.mjs              the ChatGPT-compatible computer-use API
    pw.mjs               Playwright on cua's browser, for locators
    visible-dom.mjs      in-page script behind dom_cua.get_visible_dom()
    docs.mjs             serves server/docs
    native.mjs           client for CuaAgent
    hud.mjs              HUD feed (frames, cursor, source)
    web.mjs              live view + settings server, WebSocket stream
    config.mjs           defaults, paths, overrides-only saving
    keys.mjs             "ctrl+shift+t" → CDP key events
  web/
    browser.html         live view
    cursor.js            the agent cursor (springs, curves, arrival events)
    settings.html        settings page
  docs/                  guides agents read on demand (browser, accessibility, computer-use, …)
agent/CuaAgent.swift     Accessibility + ScreenCaptureKit agent
hud/CuaPreview.swift     the HUD
skill/SKILL.md           Claude Code skill
docs/                    screenshots
install.sh · uninstall.sh · config.example.json
```
