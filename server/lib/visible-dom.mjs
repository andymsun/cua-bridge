// In-page script for dom_cua.get_visible_dom(): what is actually on screen in one
// frame, as compact lines. Interactable elements get ids that dom_cua actions use;
// the elements are kept on window.__cuaNodes until the next snapshot.
export const VISIBLE_DOM_JS = String(function visibleDom(opts) {
  const maxText = opts?.maxText ?? 100;
  const INTERACTIVE_TAGS = new Set(["A", "BUTTON", "INPUT", "SELECT", "TEXTAREA", "SUMMARY", "OPTION", "VIDEO", "AUDIO"]);
  const INTERACTIVE_ROLES = new Set(["button", "link", "checkbox", "radio", "switch", "tab", "menuitem", "menuitemcheckbox",
    "menuitemradio", "option", "combobox", "textbox", "searchbox", "slider", "spinbutton", "treeitem", "gridcell"]);
  const TEXT_TAGS = new Set(["H1", "H2", "H3", "H4", "H5", "H6", "P", "LI", "TD", "TH", "LABEL", "LEGEND", "CAPTION", "DT", "DD", "FIGCAPTION", "BLOCKQUOTE", "PRE", "SPAN", "DIV", "STRONG", "EM", "B", "SMALL"]);
  const vw = innerWidth, vh = innerHeight;
  const nodes = (window.__cuaNodes = []);
  const frames = (window.__cuaFrames = []);
  const lines = [];
  let below = 0;
  const clip = (s) => { s = String(s ?? "").replace(/\s+/g, " ").trim(); return s.length > maxText ? s.slice(0, maxText - 1) + "…" : s; };
  const visible = (el) => {
    const r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) return null;
    const cs = getComputedStyle(el);
    if (cs.visibility === "hidden" || cs.display === "none" || Number(cs.opacity) === 0) return null;
    if (r.bottom <= 0 || r.right <= 0 || r.left >= vw) return null;
    if (r.top >= vh) { below++; return null; }
    return r;
  };
  const interactive = (el) => INTERACTIVE_TAGS.has(el.tagName) && !(el.tagName === "A" && !el.hasAttribute("href"))
    || INTERACTIVE_ROLES.has(el.getAttribute("role")) || el.isContentEditable && el.parentElement?.isContentEditable !== true
    || el.hasAttribute("onclick") || (el.tabIndex >= 0 && el.hasAttribute("tabindex"));
  const ownText = (el) => [...el.childNodes].filter((n) => n.nodeType === 3).map((n) => n.data).join(" ");
  const describe = (el, id) => {
    const tag = el.tagName.toLowerCase();
    const bits = [];
    const role = el.getAttribute("role");
    if (role) bits.push(`role=${role}`);
    for (const a of ["id", "type", "name", "aria-label", "placeholder", "title", "alt", "href", "aria-expanded", "aria-checked", "aria-selected"]) {
      const v = el.getAttribute(a);
      if (v != null && v !== "") bits.push(`${a}=${JSON.stringify(clip(a === "href" ? v.slice(0, 80) : v))}`);
    }
    if (el instanceof HTMLInputElement && (el.type === "checkbox" || el.type === "radio")) bits.push(el.checked ? "checked" : "unchecked");
    else if ("value" in el && el.value && !(el instanceof HTMLButtonElement) && el.type !== "password") bits.push(`value=${JSON.stringify(clip(el.value))}`);
    if (el.disabled) bits.push("disabled");
    if (document.activeElement === el) bits.push("focused");
    const text = clip(el instanceof HTMLSelectElement ? el.selectedOptions[0]?.text : el.innerText ?? el.textContent);
    return `${id == null ? "" : `[${id}] `}<${tag}${bits.length ? " " + bits.join(" ") : ""}>${text ? " " + JSON.stringify(text) : ""}`;
  };
  const walk = (el, depth) => {
    for (const child of el.children) {
      if (["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "HEAD", "META", "LINK"].includes(child.tagName)) continue;
      const r = visible(child);
      if (!r && child.tagName !== "SLOT" && !child.shadowRoot) {
        // hidden or offscreen containers can still hold fixed/visible descendants
        if (getComputedStyle(child).display !== "none") walk(child, depth);
        continue;
      }
      if (child.tagName === "IFRAME" || child.tagName === "FRAME") {
        lines.push(`${"  ".repeat(depth)}<iframe src=${JSON.stringify(clip(child.src))}> (frame content follows)`);
        lines.push({ frameIndex: frames.push(child) - 1, depth: depth + 1 });
        continue;
      }
      if (interactive(child)) {
        nodes.push(child);
        lines.push("  ".repeat(depth) + describe(child, nodes.length - 1));
        if (child.tagName === "SELECT" || child.tagName === "BUTTON" || child.tagName === "A") continue;
        walk(child.shadowRoot ?? child, depth + 1);
        continue;
      }
      const own = clip(ownText(child));
      if (own && TEXT_TAGS.has(child.tagName)) lines.push(`${"  ".repeat(depth)}<${child.tagName.toLowerCase()}> ${JSON.stringify(own)}`);
      walk(child.shadowRoot ?? child, depth + (own ? 1 : 0));
    }
  };
  walk(document.body ?? document.documentElement, 0);
  return { lines, count: nodes.length, below, scrollY: Math.round(scrollY), height: document.documentElement.scrollHeight, vh };
});
