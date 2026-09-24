# Screenshots

- `const png = await tab.screenshot()` returns bytes; `{ fullPage: true }` captures the whole
  page and `{ clip: { x, y, width, height } }` a region.
- Show one to yourself with `nodeRepl.emitImage({ bytes: png, mimeType: "image/png" })`, or
  use `await tab.ax.write("screenshot")`.
- To give the user a screenshot, save it (`fs.writeFileSync(path, png)` after
  `const fs = await import("node:fs")`) and include it in your reply as a Markdown image.
- When testing a site you are building, capture the key moments and include them in the
  final answer. If the user asked for screenshots, always include them.
