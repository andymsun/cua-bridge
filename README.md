# cua-bridge

Gives Claude Code the browser and computer-use runtime that ships inside the
ChatGPT/Codex desktop app, plus a live preview HUD modelled on Codex's own.

macOS only. Wraps a proprietary runtime that the desktop app supplies; nothing
here redistributes it.

## Why

It is not tool count. Claude Code already ships ~66 UI-automation tools; Codex
ships three. The difference is shape: Codex exposes one `js` tool into a
persistent Node REPL, so a sequence that costs 8+ round trips with discrete
tools becomes one call, with loops, conditionals and retries inside it.

| | Claude Code built-ins | this bridge |
| --- | --- | --- |
| Interface | N fixed-arity tools | one `js` tool into a persistent REPL |
| Composition | static batch, no data flow between steps | arbitrary JS control flow |
| State | stateless between calls | top-level bindings persist |
| Observation | full a11y tree each time | tree returned as a diff |
| Surfaces | 3 servers, 3 idioms | one interface for tabs *and* native apps |

## Install

```sh
git clone git@github.com:andymsun/cua-bridge.git
cd cua-bridge && ./install.sh
```

Then grant Screen Recording to `~/Applications/CuaCapture.app` and start both:

```sh
open ~/Applications/CuaCapture.app && open ~/Applications/CuaPreview.app
```

Restart Claude Code so it picks up the `cua` MCP server. `./uninstall.sh` reverses
everything and keeps your config.

## What it installs

| Path | Notes |
| --- | --- |
| `~/.claude/cua-bridge/cua-bridge.py` | stdio MCP shim. Adds Codex's turn metadata and answers elicitation. |
| `~/.claude/cua-bridge/*.mjs` | `preview` (capture + targeting), `iab` (built-in browser), `tabstream` (per-tab CDP screencast). |
| `~/Applications/CuaCapture.app` | Holds Screen Recording. Runs the `SCStream`, writes frames + host bounds. |
| `~/Applications/CuaPreview.app` | The HUD. No permissions. |
| `~/.claude/skills/cua/SKILL.md` | Usage protocol, loaded by Claude Code. |
| `~/.claude/cua-bridge/config.json` | Your settings. Not tracked; seeded from `config.example.json`. |

## Configuration

`config.json` is hot-reloaded - edit and it applies live, no restart.

| Key | Values |
| --- | --- |
| `mode` | `attached` (pins to host window, hides when it loses focus) · `overlay` (floats above all, all Spaces) · `normal` |
| `attachTo` `anchor` `margin` | host app · `top-left`/`top-right`/`bottom-left`/`bottom-right`/`center` · px |
| `hideWhenHostInactive` | in-app behaviour for attached mode |
| `width` `fps` `showCursor` | capture settings; changing these restreams |
| `opacity` `cornerRadius` `clickThrough` | card chrome |
| `controlsCorner` | which corner the hover glyphs sit in |
| `glyphClose` `glyphAction` | any SF Symbol name |
| `glyphSize` `glyphInset` `glyphGap` | glyph metrics |
| `glyphTint` | `auto` (adapts to page brightness) · `light` · `dark` |
| `scrimOpacity` `hoverFadeIn` `hoverFadeOut` | hover treatment |

Environment overrides: `CUA_BRIDGE_HOME`, `CUA_NODE_HOME`, `CUA_RUNTIME_DIR`,
`CUA_IAB_CHROME`, `CUA_IAB_PORT`, `CUA_BRIDGE_ELICIT`, `CUA_BRIDGE_TURN_MODE`.

## The HUD

Modelled on Codex's "Computer Use" window: a rounded card with the live frame and
no chrome at rest; on hover two bare glyphs fade in over a soft radial scrim - no
button backgrounds. Glyph colour adapts to page brightness. Drag from anywhere.

Dragging is explicit `mouseDown`/`mouseDragged`; a non-activating `NSPanel`
ignores `isMovableByWindowBackground`. A manual drag stops attached-mode
auto-anchoring until restart.

## Why two apps

macOS ties a Screen Recording grant to the binary's **cdhash**, so any rebuild
invalidates it. Capture and UI are separate processes: `CuaCapture` holds the
grant and stays frozen, `CuaPreview` renders frames from `/tmp/cua-preview/` and
needs no permissions, so the interface can be changed freely. The daemon also
publishes host-window bounds so the UI never needs the window list.

## Gotchas

| Symptom | Cause |
| --- | --- |
| `Sky Computer Use native pipe startup failed` | The ChatGPT app is running and owns the computer-use service. Quit it. |
| `Computer Use was not approved` | Client does not answer MCP elicitation. Install sets `CUA_BRIDGE_ELICIT=accept`. |
| HUD shows the wrong tab | Window capture follows the window, not the driven tab. Use `watchTab()`, not `watchApp()`. |
| HUD frozen on one frame | CDP only emits on visual change. An idle page produces no frames. |
| Screen Recording stops working | Something rebuilt `CuaCapture`. Re-grant. |
| `node_repl exec context not found` | A cua call ran outside a `js` tool call. Only `tabstream.mjs` streams between calls. |

Codex's in-app browser (`iab`) is not reachable: it is drawn by the desktop app
and only exposed when the runtime is hosted inside it. `iab.mjs` gives an
equivalent - a dedicated headless Chromium under full Playwright/CDP control.

## chezmoi

Not managed by chezmoi directly - it compiles binaries and holds a TCC grant. To
pull it on every machine, add to the dotfiles repo:

```
# run_onchange_after_20-cua-bridge.sh.tmpl
#!/bin/sh
set -eu
[ "$(uname)" = "Darwin" ] || exit 0
repo="$HOME/.local/share/cua-bridge"
[ -d "$repo" ] || git clone git@github.com:andymsun/cua-bridge.git "$repo"
git -C "$repo" pull --ff-only
"$repo/install.sh"
```

Screen Recording still needs granting once per machine.
