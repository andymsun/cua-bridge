# Tab cleanup

- Tabs you open are temporary: they close when your session ends.
- Tabs that were already open (opened by the user or another session) stay open unless you
  close them explicitly.
- `await tab.markDeliverable()` keeps a tab the user should see as a result (a filled form
  left for review, a finished document, a checkout page).
- `await tab.markHandoff()` keeps a tab so work can continue later.
