# Computer use (`sky`)

`sky` drives native Mac apps through Accessibility. Input goes to that app only; the user's
cursor and keyboard are never used, and apps aren't brought to the front.

```js
let state = await sky.get_app_state({ app: "Notes" });   // name, bundle id or .app path
state.text;                                               // indexed accessibility tree
await sky.click({ app: "Notes", element_index: 12 });
await sky.type_text({ app: "Notes", text: "hello" });
state = await sky.get_app_state({ app: "Notes" });        // diff since the last read
```

- `get_app_state({ app, disableDiff })` → `{ app, text, screenshot: { url } }`. It launches the
  app in the background if needed. The screenshot is a `file://` JPEG; show it with
  `nodeRepl.emitImage({ bytes: fs.readFileSync(fileURLToPath(url)), mimeType: "image/jpeg" })`.
- `list_apps()` → installed and running apps. Try `get_app_state` by name first.
- `click({ app, element_index | x, y, mouse_button, click_count })` — right button shows the
  element's menu; two clicks open it. Coordinates are window points.
- `set_value`, `type_text`, `press_key({ key: "cmd+s" })`, `paste({ text, format })`
  (inserted as text; the clipboard isn't used), `scroll({ element_index | x, y, direction, pages })`,
  `select_text({ element_index, text, prefix, suffix, selection_type })`,
  `perform_secondary_action({ element_index, action })` with an action listed in the tree,
  `drag({ from_x, from_y, to_x, to_y })`.
- Prefer element indices over coordinates. Read again after acting; the runtime waits a
  moment first. If a name fails, retry with the bundle id from `list_apps()`.
- `type_text` with newlines may submit a form in some apps; prefer `set_value` for fields.
- Same confirmation rules as the browser (see "confirmations").
