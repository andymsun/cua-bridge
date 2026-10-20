# Andy Barista

Andy Barista is CUA's native desktop companion. Each conversation has its own cursor. These cursors point at controls and highlight areas without moving your mouse.

The companion source and original café artwork use the repository's MIT license. No Clicky code, assets, or private Andy Code source are included. The assistant provider has its own terms.

## Open the companion

After the normal install, open `~/Applications/AndyBarista.app`, or run:

```sh
cua companion
```

`cua companion --browser` opens the same interface in a browser. Desktop area selection, the menu-bar shortcut, and voice controls need the native app. Coordinate-based area selection also works in the browser interface.

The app starts the local daemon if necessary. It does not restart an existing daemon. If an old daemon lacks companion support, finish its active sessions before you stop it.

- **Control+Option+Space:** tap to open the popup or return focus to it. Tap again while it has focus to hide it. Hold for 250 ms to start voice input. A hold does not briefly hide an open popup.
- **Escape:** dismiss the popup and keep the draft. This does not stop an agent turn. During a gesture, Escape cancels the gesture first.
- **Control+Option+Escape:** stop companion turns and speech.
- The native popup measures 360 × 128 points when idle. It stays at its anchor while you type. Outside clicks transfer focus but do not hide it. Reply updates do not take focus back. History and settings are behind **···**.
- Enter sends. Shift-Enter inserts a line. During IME composition, Enter and Escape stay with the text editor. Each native conversation keeps its own draft across app restarts. Browser drafts stay in the current page.
- Quit stops companion turns and closes the app. It does not stop unrelated CUA sessions.
- Choose **New** in **···** for another conversation and cursor. Up to eight conversations can coexist.

## Native draft recovery

The native app restores drafts before it enables the editor. It keeps one draft per conversation in `companion-drafts.json` in the selected runtime directory. The file uses mode `0600`; it is not encrypted at rest. The cache holds at most sixteen records of 8,000 UTF-16 units each. It never silently evicts unsent text.

A background queue saves accepted edits with atomic file replacement. Quit waits for queued writes. A crash can recover the last completed write, not an edit still in transit. Recovery never sends a question automatically. If the server accepted a question just before a crash, its text can reappear as a draft. Check history before you send it again.

A late Send acknowledgment cannot erase newer text. Page reloads use a new restore epoch. A failed save stays visible even if another conversation saves successfully. Copy unsent text before you close the app after a save error. Unreadable or externally changed files stay untouched.

Confirmed **Remove** in the native popup deletes that conversation's cached draft. A draft can remain in the private file if its conversation disappears through another interface. The app does not delete recovered text solely because a session list omits it. Browser drafts remain page-local.

## Guide, point, and act

**Guide me** is the default. The assistant can read app accessibility, point at an element, show a ring or spotlight, and wait for expected text. It cannot send native input through its tools.

**Help me act** adds click, text, and key actions. Each action shows its app, element index, text, and reason. You must approve that exact action. Approval expires after two minutes. Read the prompt before you approve it.

**Stop** invalidates the turn's tool key, rejects pending approvals, stops its assistant process, and removes its cursor. It prevents future input. It cannot recall input already delivered to macOS.

The companion uses a restricted MCP adapter, not CUA's full JavaScript REPL. Built-in shell and file tools are disabled for companion turns. The normal CUA MCP API remains available to your existing harnesses under their own permission rules.

## Continue a guide

A manual step can take longer than the 30-second app check. The conversation then shows **Paused**, not Done. The compact native popup shows **Continue guide** instead of Clear marks. The browser shows Continue beside the pending step.

**Continue guide** keeps your draft. It starts a new Guide turn with the conversation's next-turn model. It resolves the app and window again before the model starts. If the window is missing or ambiguous, choose its current window and use Continue again. Old process IDs, window IDs, element references, and approvals never authorize a resumed step.

You can ask questions while a guide is paused. **Stop** cancels active work but keeps the saved step. **··· → End guide** clears the step and its marks without deleting messages or your draft. A submitted Act task also ends the manual guide. New conversations have separate guide state.

App restarts restore the saved step but do not read apps, start a model, or send input. Continue is always explicit. A provider error stays visible as an error, with the step available for a deliberate retry.

## Fast cursor requests

Exact-label requests use local Accessibility lookup instead of a model. For example:

- `Point to "Save changes"`
- `Circle the "Cancel" button`
- `Highlight "Open settings" in "Example App"`

The label must match exactly, including case. The app must already be open. Lookup checks the current process, window, control geometry, and visible target. It sends no input. A missing, ambiguous, covered, secure, or disabled target produces a short prompt instead of guessed coordinates. Other requests use the configured model.

When another window blocks lookup, the error names its app where available. Some system panels report full-screen bounds. CUA does not assume those windows are transparent. Dismiss the panel, or use **··· → Select** to mark an area yourself.

Opening the popup prepares the cursor overlay. The first submitted local request can start the selected CuaAgent helper. Passive status and provider discovery do not start it. CUA does not request app access automatically.

A three-goal check on this Mac published cursor data in 28.2, 43.1, and 54.3 ms with a warm helper. The first cold-helper request took 516.2 ms. The same goals through the earlier model route took 10,966.8 to 14,874.2 ms. These are local feed measurements, not visible cursor-arrival times or a general performance guarantee.

## Select an area

Choose **Select**, then drag across the desktop. Escape cancels. The selection overlay accepts input only during this operation. Normal agent overlays stay click-through.

Choose **Draw** for a circle, highlight, arrow, or freehand pen. Drag to define the mark. **Clear marks** removes this conversation's marks. Each cursor keeps at most twelve marks. Freehand strokes contain at most 512 points.

Rectangle highlights fill the selected bounds, including narrow vertical and square areas. The preview and final mark use the same stroke geometry and width. Cursor springs use elapsed frame time, including partial integration steps, rather than rounding each timer interval upward.

**Pointer demo** runs a 13-second local sequence: move, circle, highlight, arrow, freehand stroke, then a return near your mouse. Move your mouse during the final phase to see the cursor follow. It calls no model and sends no mouse input. The cursor follows the stroke as it appears. **Stop demo** removes the demo cursor without removing conversation marks. Escape also stops the local demo.

The selection becomes a persistent ring. Choose **Spotlight** to dim the surrounding area. A screen shows the most recently updated spotlight when conversations select competing regions. Other rings and cursors remain visible.

Selection records coordinates, not a screenshot. The assistant uses accessibility text to understand the app. It cannot infer image-only content from a selection. No screenshot is captured automatically.

Labels wrap, stay inside screen edges, and avoid existing labels when space permits. Cursor motion continues across displays. Reduce Motion disables flights. Display changes rebuild the overlays. Full-screen Spaces and display hot-plug behavior still need live coverage beyond the automated geometry checks.

## Adaptive cursor states

An active guide cursor stays at its target. It moves aside when your mouse reaches the same point and keeps a leader line to the target. Window-relative targets track the window; an accessibility control that moves inside the window still needs a new read and point.

After a turn, ordinary CUA point/action, or manual mark finishes, the cursor holds its position for 2.5 seconds. It waits for any stroke animation to finish. It then returns near your mouse and follows with a small offset. Existing annotations stay in their original positions. A new guide target stops this idle behavior immediately. A completed cursor can return even if its old target window closes.

Completed instructions disappear after the configured label lifetime. Their marks remain until you clear them. The compact popup shows **Done** and a **Clear marks** control for finished output. Clear marks keeps the conversation and draft. An active turn uses **Stop** instead.

The native overlay samples mouse position locally at 30 Hz only while an idle companion exists. It redraws for mouse changes; it does not write each sample to disk or send it to the model. The spring timer stops after the cursor settles. Reduce Motion removes flights. Clear marks or stop the conversation to remove its cursor.

## Permissions and privacy

Desktop cursors and area selection do not need Accessibility or Screen Recording permission. App reads and native actions need Accessibility for **CuaAgent**. Use **Settings → Enable app access** to request it explicitly, then approve CuaAgent in macOS System Settings. **Check app access** is passive.

Questions and the app text you request go to the configured assistant provider. CUA does not read app contents before you submit a task. Never include passwords or private keys in a prompt.

Conversation history stays in `companion-history.json` in the CUA run directory, with mode `0600`. It contains at most eight conversations and sixty messages per conversation. CUA restores conversations in Guide mode and does not resume old actions. Remove a conversation to delete its local history. History is not encrypted at rest. Backend processes use `--no-session-persistence`; provider retention is separate.

## Andy Code and other backends

The default backend is the installed `andy` CLI. Sign in to it before you submit your first task. No private Andy Code source is needed.

The adapter expects the Claude-compatible print/stream-json CLI protocol. Set these values in `~/.config/cua/config.json` to use a compatible executable:

```json
{
  "companion": {
    "command": "andy",
    "args": [],
    "model": "codex/gpt-6-astra"
  }
}
```

Use an absolute executable path if a GUI launch cannot find it. Arguments go directly to the executable, without shell expansion. This is a replaceable CLI adapter, not a built-in local model server.

Open **··· → Model for next turn** to choose `codex/gpt-6-astra`, `codex/gpt-5.6-sol`, or the configured default. The choice belongs to that conversation and survives app restarts. It does not change an active turn, another conversation, or your backend settings. Conversation names, such as Barista or Espresso, do not select a model.

Astra is the default here. OpenAI describes Astra as its highest-capability model for demanding work and Sol as a model for complex professional work. Both publish a 1,050,000-token context limit. Barista still sends its bounded history, not a whole desktop or an unlimited conversation.

As checked on 20 October 2026, their published Standard API rates per million tokens are:

| Model | Input | Output |
| --- | ---: | ---: |
| GPT-6 Astra | $10 | $50 |
| GPT-5.6 Sol | $4 | $20 |

These are API rates, not Codex subscription charges. Cache, long-context, and service-tier rates differ. Your signed-in backend controls access, usage, and charges. The selector does not enable Fast mode or change reasoning effort. A lower published price does not prove lower latency: Astra was faster in this Mac's three-goal check, but that is not a general speed or quality ranking.

Sources: [Astra specifications](https://developers.openai.com/api/docs/models/gpt-6-astra), [Sol specifications](https://developers.openai.com/api/docs/models/gpt-5.6-sol). The drawer links open in your browser, outside the authenticated companion page.

The selected CLI must support the chosen model and the print/stream-json protocol. Fallback is disabled. The drawer separates the next-turn choice from the last turn's requested and reported model. An unexpected reported model stops the turn. An unsupported saved choice stays visible until you choose a supported model. A local cursor request reports **Local · no model used**.

## Notch hub and connected agents

The native hub uses the main display by default. It sits below the menu area on an external monitor and below the camera area on a notched display. Open the hub's **Hub display** picker to pin it to a monitor or the MacBook. The menu-bar **Andy Hub → Display** menu provides the same choice.

The choice survives app restarts. If that display disconnects, the hub uses the main display without erasing the saved choice. It returns when the selected display reconnects. Display choices do not take keyboard focus.

Open the hub to choose a conversation, stop its turn, or open an eligible client host. The menu bar provides the same controls. Passive updates do not take focus.

`cua mcp-config` prints the MCP definition for the selected CUA runtime. It starts no service and changes no client settings. Use the definition in a client's per-session configuration.

An isolated app and its MCP client must use the same `CUA_RUN_DIR` and `CUA_CONFIG`. The definition also includes the selected helper paths. Do not point a client at another runtime and expect it to appear in this app's hub.

The hub shows MCP client identity and CUA tool activity. It does not read private conversation histories. A registered client can be idle, busy, in error, or stale. These states do not describe all work in the external conversation. The host action checks the live application against the registered process ancestry and bundle ID.

The installed-provider list is an inventory, not a connection. Andy Code, Claude Code, Codex, Antigravity, OpenCode, Cursor Agent, Cursor IDE, HeyClicky, and CUA have separate records. An installed executable does not prove that a conversation can receive a prompt or stop command.

True external conversation attachment needs a selected endpoint and session. Codex app-server, OpenCode's server, and Cursor ACP have different protocols. The app does not guess endpoints, read credential stores, or change global client hooks.

## Voice

Hold **Talk** in the controls drawer or **Control+Option+Space** to speak a command. Release to send one phrase. This route does not replace your typed draft. Use the microphone button to dictate into the draft without sending it. Push it again to finish dictation.

Each capture belongs to the conversation and draft that started it. A conversation change cancels capture. A late result cannot replace a newer draft or enter another conversation. Escape cancels the phrase and keeps the draft. A cancelled pointer gesture does not send speech. The native controller limits a held capture to 45 seconds.

Voice uses Apple's Speech framework with on-device recognition and AVAudioEngine. It does not call `andy voice` or send raw audio to a cloud transcriber. The submitted text goes to the configured assistant provider. An unavailable on-device language produces an error instead of a cloud fallback.

Speech Recognition and Microphone access need explicit macOS approval. Normal popup use never opens the microphone. If you release the key before approval, setup can finish, but capture does not start. Hold the shortcut again after approval.

Voice requests get spoken replies in sentence-sized chunks. A new voice request stops playback and an active agent turn. Escape stops playback without stopping an agent turn. **Read reply aloud** also works for typed requests.

Output uses the highest-quality matching system voice available to the app, excluding personal voices. The **···** drawer shows the selected voice. Install an enhanced macOS voice for better output. The current local preview selected Samantha; this does not establish Clicky-quality voice or full-duplex conversation. Live microphone recognition still needs a check after OS approval.

## Rich cursors from any harness

```js
cua.pointer.name("Andy · Reviewer");
await cua.point(app, index, "Start here");
cua.pointer.say("Choose this tab, then wait for the next page", "waiting");
cua.pointer.area({ x: -1200, y: 100, w: 320, h: 180 }, "This is the selected area", {
  spotlight: true,
  persistent: true
});
cua.pointer.annotate({ kind: "circle", rect: { x: 100, y: 100, w: 160, h: 80 }, label: "Look here" });
cua.pointer.annotate({ kind: "arrow", points: [[100, 220], [280, 260]], durationMs: 650 });
cua.pointer.hide();
```

Screen coordinates are points with a top-left origin. Negative origins are valid for displays to the left or above the primary display. Window targets use normalized coordinates and track the selected window.

## Isolated development app

Build signed apps without changing installed helpers or harness settings:

```sh
python3 scripts/build-native.py --build-only build/barista --isolated --identity "YOUR EXISTING SIGNING IDENTITY"
open build/barista/AndyBarista.app
```

The destination must not contain older app bundles. The app bundles its server, web assets, dependency, and signed helpers. It does not need access to the source checkout at runtime. Node 22+ and an assistant backend must remain installed.

An isolated build stores its config, sockets, and history in its own directory under `~/Library/Application Support/cua/isolated`. Its plist records the exact path. It does not use the Desktop for runtime data or need broad Desktop access. The build does not create or change a code-signing identity.

To keep an existing isolated history, pass `--runtime-dir "/absolute/path/to/existing/runtime"` with `--isolated`. The build keeps an existing config and history. It does not replace a live daemon. Close the old app and stop that isolated daemon after all its sessions finish, then open the new build. Keep one shortcut owner.

## Checks

```sh
node scripts/test-companion.mjs
node scripts/test-companion-process.mjs
node scripts/test-companion-ui.mjs build --native
node scripts/test-annotations.mjs
swiftc -swift-version 5 hud/CompanionVoice.swift scripts/test-voice.swift -o build/voice-check
build/voice-check
node scripts/test-pointer.mjs
node scripts/test-host.mjs
node scripts/test-native.mjs
swiftc -parse-as-library hud/PointerGeometry.swift scripts/test-pointer-geometry.swift -o build/geometry-check
build/geometry-check
node scripts/test-spatial.mjs
node scripts/test-companion-local.mjs
node scripts/test-companion-model.mjs
node scripts/test-companion-guide.mjs
node scripts/test-companion-draft-ui.mjs
swiftc -parse-as-library -swift-version 5 hud/CompanionDrafts.swift scripts/test-companion-drafts.swift -o build/drafts-check
build/drafts-check build
node scripts/test-native-lookup.mjs
node scripts/test-agent-hub.mjs
node scripts/test-hub-protocol.mjs
node scripts/test-hub-shim.mjs
node scripts/test-hub-web.mjs
swiftc -swift-version 5 hud/CompanionComposer.swift scripts/test-composer.swift -o build/composer-check
build/composer-check
swiftc -swift-version 5 hud/CompanionHub.swift scripts/test-companion-hub.swift -o build/hub-check
build/hub-check
swiftc -D COMPANION_TEST -swift-version 5 hud/CuaPreview.swift hud/PointerGeometry.swift hud/Companion.swift hud/CompanionComposer.swift hud/CompanionDrafts.swift hud/CompanionHub.swift hud/CompanionVoice.swift scripts/test-pointer-motion.swift -o build/motion-check
# Use an unused private CUA_RUN_DIR and CUA_CONFIG for this visible overlay check.
CUA_RUN_DIR="/absolute/path/to/private/check-runtime" CUA_CONFIG="/absolute/path/to/private/check-runtime/config.json" build/motion-check
```

The UI check uses an isolated browser and a named fixture backend. The process check covers actual child processes, not a live provider. Separate live checks on this Mac covered the packaged Astra model route and an Andy Code MCP connection. The local cursor, native input, hub, Stop, and demo checks also ran.

Full Clicky parity is not established. Live microphone recognition, full-duplex voice, and arbitrary external conversation attachment are not covered. The app does not type dictation into other apps or interpret image-only controls automatically. Physical shortcut use, VoiceOver, full-screen Spaces, Stage Manager, and physical display hot-plug still need live checks. No privacy permission was changed automatically.
