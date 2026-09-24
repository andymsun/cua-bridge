# Accessibility (`tab.ax`)

The accessibility tree is the cheapest and most reliable way to read and drive a page.

```js
await tab.ax.write();                       // indexed state
await tab.ax.click(12);
await tab.ax.setValue(7, "hello@example.com");
await tab.ax.pressKey(null, "Return");
await tab.ax.write();                       // what changed since the last read
```

- Indices come from the latest read. After acting, read again and use the new indices.
- Reads after the first are diffs (`+` added, `-` removed). Pass
  `{ disableDiffing: true }` when you need the whole tree again, for example after you
  ignored earlier output.
- If a read says nothing changed, don't read again without acting in between. Use
  `write("screenshot")` or `write("both")` only when something visual is missing.
- `typeText`, `paste` and `pressKey` take an index to focus first, or `null` for the
  focused element.
- `scroll` takes an index or an `[x, y]` point over the area to scroll.
- `selectText(index, text, { prefix, suffix, selectionType })` selects text inside a field;
  `selectionType` `"cursor_before"` / `"cursor_after"` places the caret instead.
- `performSecondaryAction(index, name)`: Expand, Collapse, ShowMenu, Focus, ScrollIntoView,
  Increment, Decrement, Cancel.
- Prefer a relevant result that is already visible over opening a broader page.

Switch to Playwright locators for long, repetitive work where indices keep moving, or for
pages you are building and know the structure of.
