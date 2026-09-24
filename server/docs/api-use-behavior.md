# Using the API well

- Session state persists: define handles once with `const` and reuse them. Only fetch a new
  tab handle when the old one reports it is closed.
- Understand the screen before the next action. Choose the cheapest check: an AX read for
  structure, `dom_cua.get_visible_dom()` for locator ground truth, a screenshot when visual
  confirmation matters. Avoid taking both by default.
- When an action does nothing, look for the blocker (dialog, overlay, disabled button,
  validation message) before trying again or switching to coordinates.
- Judge "first", "top" or "next" by what is visible, not by DOM order.
- Don't reload a page with `goto` to the same URL; use `reload()` deliberately.
- For read-only lookups, one direct navigation to an obvious URL (or a search URL built from
  the user's filters) is fine. If that fails, use the site's own navigation instead of
  guessing more URLs. One focused search-engine query, then open the best result.
- When the page shows one authoritative signal (a selected option, a success message, an
  item in the basket, a URL parameter), accept it. Don't re-verify it elsewhere.
- Ask clarifying questions only when you can't make reasonable progress without them.
