// xdotool-style key combos ("ctrl+a", "Return", "super+shift+t") -> CDP key events.

const MOD = { alt: 1, option: 1, ctrl: 2, control: 2, meta: 4, super: 4, cmd: 4, command: 4, shift: 8 };

const NAMED = {
  return: ["Enter", "Enter", 13, "\r"], enter: ["Enter", "Enter", 13, "\r"],
  tab: ["Tab", "Tab", 9, "\t"], escape: ["Escape", "Escape", 27], esc: ["Escape", "Escape", 27],
  backspace: ["Backspace", "Backspace", 8], delete: ["Delete", "Delete", 46],
  space: [" ", "Space", 32, " "],
  up: ["ArrowUp", "ArrowUp", 38], down: ["ArrowDown", "ArrowDown", 40],
  left: ["ArrowLeft", "ArrowLeft", 37], right: ["ArrowRight", "ArrowRight", 39],
  home: ["Home", "Home", 36], end: ["End", "End", 35],
  pageup: ["PageUp", "PageUp", 33], page_up: ["PageUp", "PageUp", 33], prior: ["PageUp", "PageUp", 33],
  pagedown: ["PageDown", "PageDown", 34], page_down: ["PageDown", "PageDown", 34], next: ["PageDown", "PageDown", 34],
};
for (let i = 1; i <= 12; i++) NAMED[`f${i}`] = [`F${i}`, `F${i}`, 111 + i];

export function parseCombo(combo) {
  const parts = String(combo).split("+").map((s) => s.trim()).filter(Boolean);
  let modifiers = 0;
  let keyPart = parts[parts.length - 1] ?? "";
  for (const p of parts.slice(0, -1)) {
    const m = MOD[p.toLowerCase().replace(/_[lr]$/, "")];
    if (m === undefined) throw new Error(`Unknown modifier "${p}" in "${combo}"`);
    modifiers |= m;
  }
  const named = NAMED[keyPart.toLowerCase().replace(/^kp_/, "")];
  if (named) {
    const [key, code, vk, text] = named;
    return { key, code, windowsVirtualKeyCode: vk, text: modifiers & ~8 ? undefined : text, modifiers };
  }
  if ([...keyPart].length !== 1) throw new Error(`Unknown key "${keyPart}" in "${combo}"`);
  const ch = keyPart;
  const upper = ch.toUpperCase();
  const isLetter = /[a-z]/i.test(ch);
  const isDigit = /[0-9]/.test(ch);
  const key = modifiers & 8 && isLetter ? upper : ch;
  return {
    key,
    code: isLetter ? `Key${upper}` : isDigit ? `Digit${ch}` : undefined,
    windowsVirtualKeyCode: isLetter || isDigit ? upper.charCodeAt(0) : ch.charCodeAt(0),
    text: modifiers & ~8 ? undefined : key,
    modifiers,
  };
}
