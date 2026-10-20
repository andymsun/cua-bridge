# Computer use (`sky`)

Native macOS apps are addressed by process identity and a selected window. There is
no fallback to the frontmost app or another window. Browser and native APIs are
independent of the harness: a terminal, IDE, desktop client or MCP client can use them.

```js
const windows = await sky.list_windows({ app: "Code" });
// Choose the intended windowId from this result, not an invented number.
const target = { app: "Code", window_id: windows[0].windowId };
let state = await sky.get_app_state(target);
// Inspect state.text before choosing an element index.
await sky.click({ ...target, element_index: 12 });
state = await sky.get_app_state(target); // mandatory after every action
```

- `list_apps()` lists installed/running apps. `list_windows({ app })` lists that
  process's windows with IDs, titles, frames, minimized state and process identity.
  Use an exact name, bundle ID or PID. Ambiguous process names are rejected.
- All native calls accept `window_id`. With one window it may be omitted; with
  multiple windows choose explicitly. Once read, the object stays bound to that
  window rather than following focus or a newly created window.
- `get_app_state({ app, window_id, disableDiff })` returns `app`, `windowId`,
  `process`, `text`, `screenshot` and `screenshotError`. A missing capture is reported,
  never hidden as success. The screenshot is a local `file://` JPEG.
- `click({ app, window_id, element_index | x, y, mouse_button, click_count })`:
  right button opens a context menu; two clicks open an item. Coordinates are
  points inside the selected window, matching the 1× screenshot.
- `set_value`, `type_text`, `press_key({ key: "cmd+s" })`,
  `paste({ text, format })`, `scroll({ element_index | x, y, direction, pages })`,
  `select_text({ element_index, text, prefix, suffix, selection_type })`,
  `perform_secondary_action({ element_index, action })`,
  `drag({ from_x, from_y, to_x, to_y })` accept the same target fields.
- Read after **each** action, including failed actions. Snapshot handles are consumed
  by the helper, expire after ten minutes, and do not collide between clients.
  Closed, moved, resized, minimized or relaunched targets require a fresh read or
  selection. A read is an observation, not a lock on another application's UI.
- Prefer element indices and `set_value`. Text input with newlines may submit a form.
  Keys are sent to one process only after checking its focused window. If the app
  cannot make the selected background window its keyboard target, CUA refuses and
  sends no keys. Concurrent human/app focus changes still require care; this is
  not OS-level input isolation. Never type passwords or solve human checks.
- Electron/Chromium accessibility is enabled on first read. Apps with inaccessible
  custom controls, protected content, secure input or platform restrictions may
  not support every action. CUA does not claim universal app compatibility.
- No startup/status/capture path requests macOS privacy permissions. Ask the user
  to run `cua permissions accessibility` or `cua permissions screen-recording` and
  approve access themselves. Never reset TCC as an automated repair.
- Same confirmation rules as the browser (see `confirmations`).

## Native mouse input

CUA prefers semantic Accessibility actions. Indexed middle clicks use mouse events,
not an ordinary press. A mouse fallback needs the exact process and selected window,
a visible positive target rectangle, full containment within applicable ancestor
clips, and a matching hit in that window. An uncertain target fails with
`click_target_unavailable`; CUA does not move the point onto another control.

Fallback also needs a definite unsupported Accessibility result. An uncertain
press, open, menu, or selection result returns `action_outcome_unknown`, with the
AX error code. CUA sends no later AX action or mouse event for that request.
Selection support must be readable before CUA tries that write. An unsupported
AXPress is not tried twice. This stops CUA's fallback, not effects inside an
Accessibility action. An AX error does not prove that the app did nothing.
Check the app before you repeat an uncertain action.

Mouse, drag, and coordinate-scroll events carry both the selected window ID and
its window-local point. The public `NSEvent` constructor supplies the window ID.
Optional private CoreGraphics calls restore the local point after the global point
is set. Their ABI appears in
[WebKit's CoreGraphicsTestSPI.h](https://github.com/WebKit/WebKit/blob/main/Tools/TestRunnerShared/spi/CoreGraphicsTestSPI.h).
CoreGraphics stays loaded through the app's framework links; the helper closes
only its extra symbol-lookup handle. A missing symbol or invalid mouse binding
returns `window_input_unavailable` without mouse output. Semantic actions do not
need this mouse path. Future macOS versions can need a compatibility update.

CUA constructs the complete click, drag, or scroll sequence before it posts any
part. It posts to the selected process, not the global event stream, and never
warps the real pointer. This is not universal background input support. AppKit
can use a first click to change the key window without sending it to the control.
Read the target after each action. Do not retry ambiguous input automatically.

Owned AppKit checks cover title-bar offsets, a negative-origin second display,
left/right/middle events, drag callbacks, and an actual scroll-view change. They
do not prove delivery to every app or unchanged keyboard focus in the background.

## Independent previews and host windows

The **target** is the window being captured/controlled. The optional **host** is
where its preview is positioned. They need not be the same application.

```js
const app = await cua.app("Code", { windowId: windows[0].windowId });
await app.read();
const view = await cua.hud.attach(app); // independent, draggable native preview
await cua.hud.views();
await cua.hud.detach(view.id);
```

For attachment to a particular IDE or terminal window, pass
`cua.hud.attach(app, { host: { pid, process, windowId } })` using an entry returned
by that host's `windows()`. No guessed frontmost/largest window. Up to eight views
are independent; closing a view detaches it. REPL-owned views detach on session end.
`cua attach` views persist until closed or detached, and do not require a browser.

CLI: `cua windows APP`, `cua attach APP --window ID`,
`cua attach APP --window ID --host HOST --host-window ID`, `cua views`,
`cua detach VIEW_ID`. Take over is an explicit human click and may activate the
selected native window. Helper restarts end existing native views.
