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
