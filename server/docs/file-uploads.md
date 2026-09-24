# File uploads

Wait for the chooser and click the control that opens it in the same step:

```js
const [chooser] = await Promise.all([
  tab.playwright.waitForEvent("filechooser"),
  tab.playwright.getByRole("button", { name: "Upload" }).click(),
]);
await chooser.setFiles("/Users/me/report.pdf");    // or an array when chooser.isMultiple()
```

If the page has a plain `<input type="file">`, `locator.setInputFiles(path)` works directly.
Uploading sends the user's file to a third party: confirm unless the user already asked for
that file to go to that site. Paths are local to this machine; `~` is expanded.
