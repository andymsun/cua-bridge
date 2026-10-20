# Andy Barista Implementation Plan

> Historical implementation record. On 2026-10-20, the owner authorized tested commits and pushes for the follow-up work. Do not replace shared services or copy private code/assets. Current behavior and limits are in `docs/companion.md`.

**Goal:** A native café companion with independent desktop cursors, selected-area highlights, conversation, and an optional Andy Code backend.

**Architecture:** Extend the existing Node daemon and AppKit preview. A local authenticated page runs inside a native companion panel. A constrained MCP adapter gives the assistant app reads, visual pointers, and explicitly approved native actions; it does not expose the JavaScript REPL or shell. Existing harnesses keep their REPL and gain richer cursor controls.

**Tech Stack:** Node 22+, AppKit/WebKit on macOS 14+, existing Playwright dependency for checks. No new runtime dependencies.

**Spec:** The user requested original Andy/café visuals, an open companion, Andy Code integration, and extra desktop cursors that point and highlight areas. Build original behavior and artwork; incorporate no Clicky implementation or assets.

## Global Constraints

- Never move the real desktop pointer. Normal overlays remain click-through.
- Guide mode cannot send native input. Act mode needs approval for each action.
- Stop cancels the process, pending approval, and session cursors. Late events cannot revive a stopped turn.
- No automatic screenshots, microphone access, permission changes, or credentials in prompts.
- Native screen coordinates use global points with a top-left origin. Negative origins are valid.
- Respect Reduce Motion, keyboard access, readable contrast, and compact windows.
- Keep private Andy Code code out of this public repository. Use its CLI interface.

## Tasks

- [x] Extend `server/lib/pointer.mjs` and the REPL API with names, states, streamed labels, persistent areas, and spotlight highlights. Test input validation and session cleanup.
- [x] Add `server/lib/companion.mjs` and `server/companion-mcp.mjs`: conversations, restricted tools, streamed CLI output, approval, cancellation, and bounded local history. Test the process boundary and stale-turn rejection.
- [x] Add authenticated companion routes to `server/lib/web.mjs` and control routes to `server/daemon.mjs`. Add `cua companion` to `server/cli.mjs`.
- [x] Add `server/web/companion.html`: original café identity, multi-session controls, conversation, mode controls, selected-area context, error recovery, and approval UI.
- [x] Extend `hud/CuaPreview.swift`: native panel, region selection, menu-bar controls, wrapped edge-aware labels, cross-display cursor continuity, and reduced idle work.
- [x] Run existing tests, new companion tests, Swift compilation, browser interaction checks, and an isolated native visual check. Document actual results and remaining limits.

## Review Focus

- Cancellation during a pending native read or approval must not produce a later action.
- Untrusted labels and assistant text render as text, never executable HTML.
- Guide tools cannot escape into shell or arbitrary JavaScript.
- Labels and selected areas remain correct on negative-origin displays.
- Empty/disconnected/error states name the problem and a recovery action; never simulate an AI response.

## Implementation notes

- The standalone app bundles the public runtime, its existing dependency, and signed native helpers. Bundle-relative paths remove the dependency on a protected Desktop checkout. Isolated runtime state lives under Application Support.
- Companion tools use a separate native connection without HUD hooks, so app reads do not start automatic screenshots.
- New tests cover delayed connection cancellation, full-text approval, expired turn keys, process output, private history, safe HTML text, selected areas, and cursor/label collisions.
- Live checks completed: cold native startup, a real Andy backend turn through the restricted `say` tool, and two native overlays on two displays. The real pointer position stayed unchanged during the overlay sample.
- Accessibility and Screen Recording were not granted on this Mac. No privacy grants were changed. Live app reads/actions remain blocked until the owner enables CuaAgent access. Microphone capture, full-screen Spaces, and hot-plug display behavior were not exercised.
- Work is local and uncommitted. No changes to the private Andy Code repository or installed harness configuration.

## Compact interaction revision

The owner rejected the large panel and asked for visible desktop gestures, a cursor-attached popup, Escape dismissal, and natural voice.

- Replaced the 430×740 panel with a cursor-anchored popup. The packaged idle window measured 360×132 points. History and settings are secondary controls.
- Added circle, highlight, arrow, and freehand paths. The independent cursor follows each stroke. A deterministic 7.6-second demo calls no model.
- Replaced fixed-duration dictation with native hold/release speech. Recognition stays on-device. Replies use sentence-sized system speech chunks. Escape and a cancelled pointer gesture discard capture.
- Fixed cancellation followed by an immediate new turn. An old native request cannot release the new turn's tool lock.
- Removed per-token desktop-label writes and hidden-history DOM updates. The popup streams the reply; desktop labels change at explicit guide steps.
- Final source checks passed: pointer/guide, host capture, nine native protocol cases, annotations, companion restrictions, real child-process lifecycle, browser voice callbacks, native popup, geometry, and idle voice selection.
- Native popup checks covered Escape with WebKit focus, draft retention, toggle, and gesture cancellation. Warm show-call samples were 0.85–6.64 ms. These are not end-to-end display measurements.
- Built certificate-signed apps at `build/light`. Reused the existing isolated runtime. Both saved conversations and both old runtime configs kept their exact file hashes.
- Ran the packaged native demo. All four marks appeared and the cursor disappeared at completion. The real pointer position matched before and after at `[1280,720]`. The local API acknowledged the demo in 16.92 ms; the cold overlay window appeared in 686.82 ms. A second run on the left display confirmed negative-origin placement, two overlay windows, and cleanup.
- Captured the native overlay alone as a nine-second video. Frame checks showed the circle, broad highlight, arrow, and freehand stroke. A cropped GIF shows the motion without unrelated desktop content.
- Microphone capture, enhanced voice quality, full-screen Spaces, and display hot-plug still need live checks. The synthesis preview selected Samantha. No OS privacy grants changed.

## Adaptive interaction follow-up

The owner reported a frozen cursor after arrival and unpredictable popup dismissal after an outside click.

- Reproduced focus-loss dismissal with a second native key window. `windowDidResignKey` hid the popup for every focus change. Removed that behavior. Outside clicks now transfer focus without hiding the popup or cancelling work.
- The native cursor could resume after settling; the missing behavior was a completed-state return. Added a 2.5-second display pause, then a return near the mouse. Active guide targets remain anchored. Existing marks do not follow the mouse.
- Ordinary CUA points and native action callbacks now enter the completed state. Guide points enter a persistent waiting state. Manual annotations release idle cursors without interrupting active turns.
- Idle companions react to a local mouse-position source at 30 Hz. They do not send samples to the backend. Pointer changes trigger native updates; no-change samples do not redraw. Active guide cursors yield space with a leader line when the human pointer overlaps them.
- Closed target windows do not hide completed companions. New targets interrupt idle behavior. Long strokes finish before return. Nonpersistent cursors still expire and stop their presence timer.
- Shortcut presses no longer hide an open popup before a voice hold. Short release dismisses a focused popup; the shortcut refocuses an unfocused popup. Content resize preserves AppKit's rounded horizontal position. Dismissal does not take focus from another app.
- Added failing-then-passing cases for outside focus, finished return, ordinary API state, closed targets, and the demo's idle phase. Native tests also covered fake mouse motion, annotation stability, collision leaders, negative-origin displays, long strokes, expiry, and cleanup.
- Carbon event tests used synthetic press/release/repeat events within the test app. They do not establish a physical OS shortcut or live microphone hold. No real pointer motion was injected.
- The packaged 13-second demo completed all four marks, return, and cleanup. A separate fixture process took keyboard focus while the packaged popup stayed visible at the same bounds. Window-only recordings show the packaged demo and a labelled input simulation.
- The first packaged capture exposed clipped native label text and a label over the real pointer. A failing native check measured 22 points of body height against 32 needed points. Switched to the native text cell measurement and added the mouse exclusion area to label placement. Both checks now pass.
- Deployed the certificate-signed `build/adaptive-v2/AndyBarista.app` to the existing isolated runtime. Checked native source hashes and bundled runtime files. Existing history and config hashes stayed unchanged. No active turn was stopped and the old popup had no draft.

Further REA work refreshed dispatch metadata and traced selected native handlers with LLVM disassembly. `DetachedCursorClickCatcherView.mouseEntered:` at `0x101a650ac` calls `0x101a64fec`; that body passes true to an optional callback. The exit body at `0x101a65120` passes false to the same callback slot. Mouse-down has a separate callback. Metadata also records detached cursor hover, reattach tasks, pulse timers, and dock/undock flight targets. These support distinct interaction states, not a claim that every idle cursor continuously follows the mouse.

`HomeSpaceWindowManager.windowDidResignKey:` at `0x100aa6664` dispatches through `0x100aa6470` and `0x100aa64a4` into a closure. The trace does not prove an unconditional hide policy. The local fix follows the owner's requested stable popup behavior; it is not a copied Clicky implementation. Swift metadata coverage remains partial.

## Clicky evidence and capability gaps

Analysis used the installed Clicky 1.0.53 build 64 and REA 6.7.0. No account data, credentials, private history, source code, or third-party artwork was copied.

- REA artifact evidence: `ev_58c0f529af60c553dfcd4aacae9f34ecf06d3b1d7f2c5d4c2a6d4451d8b5d64c`.
- REA ARM64 dispatch evidence: `ev_3ff772510a7719f6621c1b0cb8d83df3ffd2d4a0a51eae32bbc8732443c24746`.
- Metadata coverage: 471 Objective-C classes, 2,206 ivars, and 576 dispatch implementations. Swift declarations and dispatch slots were not decoded. This is partial evidence, not a complete decompilation.
- `OverlayWindow` and `DetachedCursorClickPanel` separate passive cursor visuals from interactive surfaces. Focused disassembly traced their selected `canBecomeKeyWindow` handlers at `0x101a03a94` and `0x101a65a08` through `0x10010c8bc`, which returns zero.
- Voice metadata names separate hold shortcuts, Apple speech, realtime microphone/playback, duplex audio, voice activity detection, and interruption tasks. Embedded copy says: “Hold the keyboard shortcut to answer. Release to send.” These names do not prove the active provider or current runtime behavior.
- The bundled `cua-driver 0.28.2` help describes session-owned overlays, reduced motion, themes, and separate cursor-motion controls. Its static tool list includes exact-window state checks, browser interaction, menus, and explicit capture. These are driver capabilities, not proof that Clicky's UI exposes every tool.
- The driver emitted a default product-telemetry notice during the static tool-list command. No telemetry setting was changed. No account stores or live session/history commands were used.

| Capability | Current CUA state | Limit |
| --- | --- | --- |
| Independent animated cursors and desktop marks | Implemented; packaged demo captured | Full-screen Spaces and hot-plug need live checks |
| Small popup, shortcut, Escape | Implemented; native checks passed | Popup anchors on invocation; it does not chase the mouse |
| Area selection and manual pen | Implemented; geometry and cancellation checks passed | Human drag input was not automated on the real desktop |
| Hold/release speech and spoken replies | Implemented; synthesis and frontend callback checks passed | Live recognition needs OS approval |
| Hands-free/full-duplex voice, automatic speech interruption | Not implemented | Hold-to-talk is not full-duplex parity |
| Exact-app reads and approved input | Implemented; protocol checks passed | This Mac has not granted Accessibility |
| Image-only screen understanding in the companion | Not implemented | Selection supplies coordinates, not an image |
| Private Clicky connectors or hosted services | Not reproduced | No private protocol or account access was used |
