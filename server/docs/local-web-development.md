# Local web development

- Start the dev server yourself (in a terminal, in the background) and open
  `http://localhost:<port>`. Localhost pages don't need the live view to be shown.
- Test like a user: navigate, click, fill forms, then check the visible result.
- Use `tab.dev.logs({ levels: ["error", "warn"] })` for console errors and the `cdp`
  capability for network or performance detail.
- `browser.capabilities.get("viewport")` sets a specific size for responsive checks; reset
  it when done.
- Take screenshots at the key moments and include them in your final answer.
- After code changes, `tab.reload()`; hot reload may already have applied them.
