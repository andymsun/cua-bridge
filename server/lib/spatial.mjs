// Bounded exact-label requests. This route never ranks substrings or guesses coordinates.
import { cleanOrigin, cleanTarget } from "./pointer.mjs";

const roles = Object.fromEntries("text textbox button checkbox radio popup menubutton combobox slider row cell image link window sheet dialog group scrollarea outline table list toolbar menuitem menu webarea heading disclosure stepper progress tabs column browser collection segmented colorwell datefield level splitgroup searchbox tab password".split(" ").map(role => [role, role]));
Object.assign(roles, { "text field": "textbox", "text box": "textbox", "search field": "searchbox", "search box": "searchbox", "menu item": "menuitem", "radio button": "radio", "check box": "checkbox", "pop-up button": "popup" });
const rolePattern = Object.keys(roles).sort((a, b) => b.length - a.length).join("|");
const quotes = { '"': '"', "'": "'", "“": "”", "‘": "’" };
const same = (a, b) => typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
const positiveInteger = (n, max) => Number.isInteger(n) && n > 0 && n <= max;
const appMatches = (app, query) => /^\d+$/.test(query)
  ? positiveInteger(Number(query), 2147483647) && Number(query) > 1 && app.pid === Number(query)
  : same(app.name, query) || same(app.bundleId, query);

// Keep offsets while hiding quoted text from the small grammar below.
function outsideQuotes(value) {
  let closing = null, out = "";
  for (let i = 0; i < value.length; i++) {
    const char = value[i];
    if (closing) { if (char === closing) closing = null; out += "x"; }
    else if (quotes[char] && !(char === "'" && /[\p{L}\p{N}]/u.test(value[i - 1] ?? ""))) { closing = quotes[char]; out += "x"; }
    else out += char;
  }
  return closing ? null : out;
}

function exactName(value, max) {
  value = value.trim();
  if (quotes[value[0]]) {
    if (value.at(-1) !== quotes[value[0]]) return null;
    value = value.slice(1, -1);
  } else if (/["“”‘’]|\b(?:and|or|then|near|next to|above|below|with)\b|[;!?]/i.test(value)
    || /^(?:it|this|that|these|those|first|second|third|last|any|all|each)\b/i.test(value)) return null;
  return value.trim() && value.length <= max ? value : null;
}

/** null means unsupported; a recognized but uncertain request stays local with a message. */
export function parseSpatial(goal) {
  if (typeof goal !== "string") return null;
  const input = goal.trim().replace(/^(?:(?:can|could|would) you\s+)?(?:please\s+)?/i, "");
  const prefix = /^(point(?:\s+(?:(?:me\s+)?(?:at|to)|out))?|highlight|circle|draw\s+(?:a\s+)?circle\s+around)(?:\s+|$)/i.exec(input);
  if (!prefix) return null;
  const kind = /^point/i.test(prefix[1]) ? "point" : /^highlight/i.test(prefix[1]) ? "highlight" : "circle";
  const unclear = { kind, message: 'Name one exact control, optionally its role and app, for example: circle the "Save" button in Notes.' };
  if (input.length > 1600 || /[\x00-\x1f\x7f]/.test(input)) return unclear;
  let body = input.slice(prefix[0].length).replace(/[.!?]$/, "").trim().replace(/^the\s+/i, "");
  let outside = outsideQuotes(body);
  if (!body || outside === null || /\b(?:and|or|then)\b|[;!?]/i.test(outside)) return unclear;
  let app, role;
  // "Sign in button" ends in a role, not an app called "button".
  if (!new RegExp(`(?:^|\\s)(?:${rolePattern})$`, "i").test(outside)) {
    const scopes = [...outside.matchAll(/\s+(?:in|within)\s+/gi)];
    if (scopes.length > 1) return unclear;
    if (scopes.length === 1) {
      const scope = scopes[0];
      app = exactName(body.slice(scope.index + scope[0].length), 200);
      if (!app) return unclear;
      body = body.slice(0, scope.index).trim(); outside = outsideQuotes(body);
    }
  }
  const leading = new RegExp(`^(${rolePattern})\\s+(?:(?:named|labelled|labeled)\\s+)?`, "i").exec(outside);
  const trailing = new RegExp(`\\s+(${rolePattern})$`, "i").exec(outside);
  if (leading) { role = roles[leading[1].toLowerCase()]; body = body.slice(leading[0].length); }
  else if (trailing) { role = roles[trailing[1].toLowerCase()]; body = body.slice(0, trailing.index); }
  const name = exactName(body, 512);
  if (!name || (!role && roles[body.toLowerCase()])) return unclear;
  return { kind, name, ...(role ? { role } : {}), ...(app ? { app } : {}) };
}

export function spatialContext(value = {}) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Choose a current running app and window.");
  const out = {};
  for (const key of ["app", "bundleId"]) {
    if (value[key] === undefined) continue;
    if (typeof value[key] !== "string" || value[key].length > 200) throw new Error(`Invalid ${key} context.`);
    if (value[key].trim()) out[key] = value[key].trim();
  }
  if (value.pid !== undefined) {
    if (!positiveInteger(value.pid, 2147483647) || value.pid === 1) throw new Error("Choose a valid running process pid.");
    out.pid = value.pid;
  }
  if (value.process !== undefined) {
    const identity = value.process;
    const launch = typeof identity === "string" && identity.startsWith(`${out.pid}:`) ? identity.slice(String(out.pid).length + 1) : "";
    if (typeof identity !== "string" || identity.length > 128 || !/^\d+(?:\.\d+)?(?:e[+-]?\d+)?$/i.test(launch) || !Number.isFinite(Number(launch)) || Number(launch) <= 0) throw new Error("Running process identity changed or is invalid. Select the app again.");
    out.process = identity;
  }
  if (value.windowId !== undefined) {
    if (!positiveInteger(value.windowId, 4294967295)) throw new Error("Choose a valid windowId.");
    out.windowId = value.windowId;
  }
  if (value.cursorOrigin !== undefined) out.cursorOrigin = cleanOrigin(value.cursorOrigin);
  return out;
}

/** Select only exact running metadata; never call the launch-capable resolve request. */
export function runningTarget(apps, context, requestedApp) {
  if (!Array.isArray(apps) || apps.length > 512) throw new Error("Running-app metadata is unavailable or incomplete.");
  const candidates = apps.filter(app => app && (requestedApp
    ? appMatches(app, requestedApp)
    : (context.pid === undefined || app.pid === context.pid)
      && (!context.app || appMatches(app, context.app))
      && (!context.bundleId || same(app.bundleId, context.bundleId))
      && (context.pid !== undefined || context.app || context.bundleId || app.active === true)));
  if (candidates.length !== 1) throw new Error(candidates.length ? "More than one running app matches. Choose an exact process and window." : "No exact running app matches. Select a running app and try again.");
  const app = candidates[0], target = spatialContext({ pid: app.pid, process: app.process });
  if (!target.pid || !target.process) throw new Error("Fresh running process identity is unavailable.");
  const sameApp = !requestedApp || app.pid === context.pid || same(requestedApp, context.app) || same(requestedApp, context.bundleId);
  if (sameApp) {
    if ((context.pid !== undefined && context.pid !== target.pid) || (context.process && context.process !== target.process)) throw new Error("Running process identity changed. Select the app again.");
    if (context.windowId !== undefined) target.windowId = context.windowId;
  }
  return target;
}

export function matchedTarget(result, query, identity) {
  const at = result?.target, rect = at?.rect;
  if (result?.status !== "matched" || result.name !== query.name || typeof result.role !== "string" || !result.role || result.role.length > 64
    || (query.role && result.role !== query.role) || !positiveInteger(result.windowId, 4294967295)
    || result.windowId !== at?.windowId || (identity.windowId !== undefined && identity.windowId !== result.windowId)
    || !rect || ![rect.x, rect.y, rect.w, rect.h].every(Number.isFinite) || rect.x < 0 || rect.y < 0 || rect.w <= 0 || rect.h <= 0
    || rect.x + rect.w > 1 + 1e-9 || rect.y + rect.h > 1 + 1e-9) throw new Error("The exact target could not be verified. Select the current app and try again.");
  return cleanTarget({ windowId: at.windowId, rect });
}
