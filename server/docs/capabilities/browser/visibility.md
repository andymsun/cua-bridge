# Capability: visibility

`get()` → whether a live view is open. `set(true)` shows the browser to the user: it opens
the HUD and gives you the live-view URL to open in your harness's browser pane.

Keep work in the background unless the user wants to watch or wants the page in front of
them. Navigating to answer a question doesn't need visibility.
