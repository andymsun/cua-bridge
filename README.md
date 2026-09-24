# cua

Codex-style browser and computer use for any agent harness - Claude Code,
Antigravity, Gemini CLI, Cursor, or anything that speaks MCP. An independent
implementation on public APIs (Chrome DevTools Protocol, macOS Accessibility,
ScreenCaptureKit); it does not use or ship any part of the Codex runtime.

Everything runs **in the background**. The browser is headless with its own
profile, native apps are driven through Accessibility, and your real cursor and
keyboard are never touched. A HUD and a live browser view show you what the agent
is doing, with its own cursor, and let you take over.

## Why it feels like Codex

| | typical browser tools | cua |
| --- | --- | --- |
| Interface | many fixed tools, one round trip per click | one `js` tool into a persistent REPL: loops, retries, conditionals in one call |
| State | re-found every call | `const tab = ...` persists between calls |
| Reading | full page tree every time | indexed accessibility tree, then **diffs** |
| Input | moves your mouse or needs a window | page-level CDP events and Accessibility actions, fully background |
| Visibility | screenshots on request | live HUD + live browser view with the agent's cursor |
| Harnesses | one | any MCP client; all share one browser and its logins |

## Install

```sh
git clone git@github.com:andymsun/cua-bridge.git ~/.local/share/cua-bridge
~/.local/share/cua-bridge/install.sh
```

Requires macOS 14+, Node 22+, Xcode command line tools, and a Chromium-family
browser (Chrome, Chromium, Helium, Brave or Edge). The installer builds two small
apps, registers the MCP server with every harness it finds (Claude Code, Antigravity,
Antigravity IDE, Gemini CLI, Cursor; `--with-codex` for Codex), installs the
Claude Code skill and the `cua` CLI. Re-running it updates everything and keeps
CuaAgent as-is, so its permissions stay granted.

Browser control works immediately. For native apps, grant **CuaAgent** once:
System Settings > Privacy & Security > **Accessibility** and **Screen Recording**.

Any other harness: an MCP stdio server with command `node` and args
`["~/.local/share/cua-bridge/server/shim.mjs"]`.

## Using it

The agent gets one tool, `js`:

```js
const tab = await cua.open("https://example.com");  // background tab, becomes the driven tab
await tab.read();          // 12 link "More information…" ...
await tab.click(12);
await tab.read();          // (changes since last read: +14 −3, ...)

const notes = await cua.app("Notes");               // native apps, same model
await notes.read();
```

The full API is in the tool description (`server/tool-description.md`).

## The parts

| Piece | What it does |
| --- | --- |
| `server/shim.mjs` | The MCP server a harness registers. Starts the daemon if needed; gives each harness session its own REPL. |
| `server/daemon.mjs` | One per user. Owns the browser, native agent connection, HUD feed and web UI. |
| `server/lib/browser.mjs` | Zero-dependency CDP engine: tabs, accessibility snapshots, input, dialogs, console, network, uploads, screencast. |
| `agent/CuaAgent.swift` | Holds Accessibility + Screen Recording. Presses, sets values, scrolls and hit-tests through Accessibility; keys go only to the target process; captures windows even when covered. |
| `hud/CuaPreview.swift` | The HUD: chrome-less card, the agent's own cursor with click ripples, hover controls, attach-to-host behaviour. Needs no permissions. |
| `server/web/` | Live browser (Codex-style in-app browser, take-over-able) and the settings page. |
| `skill/SKILL.md` | Claude Code skill, including the hybrid flow below. |

## Hybrid with the Claude app

cua's live browser is a local web page: tab strip, address bar, the agent's cursor,
and full take-over (your clicks and typing go to the page, not your OS). The Claude
skill opens it in Claude's own browser pane, so Claude gets a Codex-style in-app
browser while still being Claude:

1. `cua.ui()` → `{ browser, settings }`
2. open the `browser` URL in the browser pane (`preview_start`)

## Settings

`cua settings` opens a settings page generated from the config schema; everything
applies live. The file is `~/.config/cua/config.json`.

| Section | Highlights |
| --- | --- |
| browser | executable, `headless`, `attach` (drive your own browser via its CDP URL), profile, viewport, downloads, dialog policy, closing agent tabs at session end |
| snapshot / native | diffing, line and text limits, tree depth, whether key events are allowed |
| stream | fps, JPEG quality, width |
| hud | on/off, attached / overlay / normal, host app, anchor, size, opacity, agent cursor, glyphs, controls corner, scrim, fades |
| web / repl | UI port, call timeout, output cap |

## CLI

`cua status` · `cua start|stop|restart` · `cua ui` · `cua settings` · `cua doctor`

## Notes

- Tabs an agent opens close when its session ends unless it calls `tab.keep()`.
- `tab.evaluate` reads the live DOM (including typed values).
- Headless Chrome can be blocked by some sites; switch `browser.headless` off or
  use `browser.attach`.
- macOS ties CuaAgent's permissions to its code signature. The installer only
  rebuilds it when its source changes (`--rebuild-agent` to force); re-grant after.
- The web UI binds to 127.0.0.1 and requires a per-install token.
- `./uninstall.sh` removes everything but your config and browser profiles
  (`--purge` removes those too).
