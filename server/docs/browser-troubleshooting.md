# Troubleshooting

- **"Tab ... was closed"**: get a fresh tab with `browser.tabs.new()` or `.selected()`.
- **Locator timeouts**: the element isn't there or isn't actionable. Re-inspect with
  `tab.ax.write()` or `dom_cua.get_visible_dom()`; the page may have changed (e.g. a search
  box becoming a combobox once suggestions open).
- **Element index not in the last read**: read again; indices change after every read.
- **A dialog blocks the page**: `await tab.getJsDialog()` then `accept()` or `dismiss()`.
- **Sign-in required**: ask the user to sign in in the live view, then continue. Don't try
  other sites or sources to get around the sign-in.
- **CAPTCHA, "verify you are human", access denied by bot protection**: stop and ask the user
  to complete it in the live view, or leave that site to them. Don't try to get around it.
- **Nothing happens after a click**: check for overlays, cookie banners, or a disabled
  control; try the Playwright locator for the same element.
