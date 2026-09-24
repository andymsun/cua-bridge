// Indexed accessibility snapshots + diffing, shared by the browser and native
// backends. A snapshot is a list of { indent, text, ref } entries; `ref` is the
// backend handle an action resolves (a DOM backendNodeId or a native AX index).

const INTERACTIVE = new Set([
  "button", "link", "textbox", "searchbox", "combobox", "checkbox", "radio", "switch",
  "slider", "spinbutton", "menuitem", "menuitemcheckbox", "menuitemradio", "tab",
  "option", "listbox", "treeitem", "menubutton", "PopUpButton", "textarea",
]);
const NAMED_STRUCTURE = new Set([
  "heading", "img", "image", "dialog", "alertdialog", "alert", "navigation", "main",
  "banner", "contentinfo", "form", "search", "region", "table", "row", "cell",
  "columnheader", "rowheader", "listitem", "figure", "tabpanel", "status", "log", "Iframe",
]);
const STATE_PROPS = ["focused", "checked", "pressed", "selected", "expanded", "disabled", "required", "readonly", "invalid"];

const clip = (s, n) => {
  s = String(s ?? "").replace(/\s+/g, " ").trim();
  return s.length > n ? s.slice(0, n - 1) + "…" : s;
};

/** CDP Accessibility.getFullAXTree nodes -> snapshot entries. */
export function fromCdpAx(nodes, { maxTextLength = 120 } = {}) {
  const byId = new Map(nodes.map((n) => [n.nodeId, n]));
  const root = nodes.find((n) => !n.parentId) ?? nodes[0];
  const out = [];
  let focused = null;

  const walk = (node, depth, parentName) => {
    if (!node) return;
    const kids = () => (node.childIds ?? []).map((id) => byId.get(id));
    if (node.ignored) { for (const k of kids()) walk(k, depth, parentName); return; }
    const role = node.role?.value ?? "";
    const name = clip(node.name?.value, maxTextLength);
    const value = node.value?.value;
    const props = Object.fromEntries((node.properties ?? []).map((p) => [p.name, p.value?.value]));

    let emit = false, text = "";
    if (role === "StaticText" || role === "InlineTextBox") {
      if (role === "StaticText" && name && name !== parentName) { emit = true; text = `text "${name}"`; }
    } else if (role === "Iframe") {
      // the frame's own tree is spliced in after this entry (see Tab.#snapshot)
      out.push({ indent: depth, text: `iframe${name ? ` "${name}"` : ""}`, ref: node.backendDOMNodeId, frameOwner: node.backendDOMNodeId });
      return;
    } else if (INTERACTIVE.has(role) || (NAMED_STRUCTURE.has(role) && name) || role === "RootWebArea") {
      emit = role !== "RootWebArea";
      const states = STATE_PROPS
        .filter((k) => props[k] !== undefined && props[k] !== false && props[k] !== "false")
        .map((k) => (props[k] === true || props[k] === "true" ? k : `${k}=${props[k]}`));
      text = [
        role,
        name && `"${name}"`,
        value !== undefined && value !== "" && `value="${clip(value, maxTextLength)}"`,
        role === "heading" && props.level && `h${props.level}`,
        states.length && `(${states.join(", ")})`,
      ].filter(Boolean).join(" ");
    }
    if (emit) {
      out.push({ indent: depth, text, ref: node.backendDOMNodeId });
      if (props.focused) focused = out.length - 1;
    }
    const editable = ["textbox", "searchbox", "combobox", "textarea", "spinbutton"].includes(role);
    if (editable) return;              // its text children just repeat value="..."
    const childParentName = emit ? name : parentName;
    for (const k of kids()) walk(k, emit ? depth + 1 : depth, childParentName);
  };
  walk(root, 0, "");
  return { entries: out, focused };
}

/** Render entries with 1-based indices. Returns text + index->ref map. */
export function render(entries, { maxLines = 500, header = "", focused = null } = {}) {
  const refs = new Map();
  const lines = [];
  entries.slice(0, maxLines).forEach((e, i) => {
    refs.set(i + 1, e.ref);
    lines.push(`${"  ".repeat(Math.min(e.indent, 12))}${i + 1} ${e.text}`);
  });
  if (entries.length > maxLines) {
    lines.push(`… ${entries.length - maxLines} more elements not shown (use find(), or scroll and re-read)`);
  }
  const foot = focused !== null && focused < maxLines ? `\nFocused: ${focused + 1} ${entries[focused].text}` : "";
  return { text: (header ? header + "\n" : "") + lines.join("\n") + foot, refs };
}

/** Multiset diff of entry texts. Returns null when a full tree is more useful. */
export function diff(prevTexts, entries, { maxLines = 500 } = {}) {
  if (!prevTexts) return null;
  const count = (arr) => arr.reduce((m, t) => m.set(t, (m.get(t) ?? 0) + 1), new Map());
  const prev = count(prevTexts);
  const seen = new Map();
  const added = [];
  entries.slice(0, maxLines).forEach((e, i) => {
    const n = (seen.get(e.text) ?? 0) + 1;
    seen.set(e.text, n);
    if (n > (prev.get(e.text) ?? 0)) added.push(`+ ${i + 1} ${e.text}`);
  });
  const removed = [];
  for (const [t, n] of prev) {
    const now = seen.get(t) ?? 0;
    for (let k = now; k < n; k++) removed.push(`- ${t}`);
  }
  const total = Math.max(prevTexts.length, entries.length, 1);
  if ((added.length + removed.length) / total > 0.5) return null;
  const unchanged = Math.min(entries.length, maxLines) - added.length;
  if (!added.length && !removed.length) return `(no change since last read — ${unchanged} elements)`;
  return [`(changes since last read: +${added.length} −${removed.length}, ${unchanged} unchanged)`,
    ...removed.slice(0, 80), ...added.slice(0, 200)].join("\n");
}
