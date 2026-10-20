import assert from "node:assert/strict";
import { test } from "node:test";
import fs from "node:fs";

const url = new URL("../server/lib/spatial.mjs", import.meta.url);
const spatial = fs.existsSync(url) ? await import(url) : {};

test("bounded spatial grammar preserves exact labels and native roles", () => {
  assert.equal(typeof spatial.parseSpatial, "function", "a local grammar must exist before model routing");
  const cases = [
    ['point at the Save button', { kind: "point", name: "Save", role: "button" }],
    ['Please point me to “Save changes” in Notes.', { kind: "point", name: "Save changes", app: "Notes" }],
    ['Could you highlight the search field named "Find in page"?', { kind: "highlight", name: "Find in page", role: "searchbox" }],
    ['circle the "Save" button in Text Editor', { kind: "circle", name: "Save", role: "button", app: "Text Editor" }],
    ['draw a circle around the menu item "Export…"', { kind: "circle", name: "Export…", role: "menuitem" }],
    ['point to the Sign in button', { kind: "point", name: "Sign in", role: "button" }],
    ['Highlight "Research and development"', { kind: "highlight", name: "Research and development" }],
    ['Circle "  Café  "', { kind: "circle", name: "  Café  " }],
    ['point at "button"', { kind: "point", name: "button" }],
    ["point at the Owner's notes tab", { kind: "point", name: "Owner's notes", role: "tab" }],
  ];
  for (const [goal, expected] of cases) assert.deepEqual(spatial.parseSpatial(goal), expected, goal);
});

test("recognized ambiguous or unbounded queries never become model goals or guessed labels", () => {
  assert.equal(typeof spatial.parseSpatial, "function");
  for (const goal of ['point at', 'highlight Save and Cancel', 'circle it', 'point to Save or Done',
    'circle "Save" then click it', 'point at the first button', 'highlight "Save',
    'point at Save in Notes in Safari', `circle "${"x".repeat(513)}"`, 'circle Save\nthen type yes']) {
    const result = spatial.parseSpatial(goal);
    assert.ok(result?.message, `clarify locally: ${goal.slice(0, 100)}`);
    assert.equal(result.name, undefined, "ambiguous input cannot become an exact lookup");
  }
  for (const goal of ['explain this screen', 'click the Save button', 'write a summary', 'how do I circle a word?']) {
    assert.equal(spatial.parseSpatial(goal), null, goal);
  }
});
