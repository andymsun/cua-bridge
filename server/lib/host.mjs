// Which app a harness runs in: VS Code, its terminal, Terminal, Ghostty, the Claude app...
// The shim records its process ancestry, nearest first, plus the bundle id macOS passes
// down to processes an app starts (the fallback when a multiplexer server breaks the chain).
// The HUD picks the nearest regular app with a window; only it can ask AppKit.
import { execFileSync } from "node:child_process";

export function ancestry(parents, start, limit = 32) {
  const out = [];
  for (let p = start; p > 1 && out.length < limit && !out.includes(p); p = parents.get(p) ?? 0) out.push(p);
  return out;
}

export function hostInfo(start = process.ppid, env = process.env) {
  const parents = new Map();
  try {
    for (const line of execFileSync("ps", ["-A", "-o", "pid=,ppid="], { encoding: "utf8" }).split("\n")) {
      const [pid, ppid] = line.trim().split(/\s+/).map(Number);
      if (pid) parents.set(pid, ppid);
    }
  } catch {}
  return { ancestors: ancestry(parents, start), bundleId: env.__CFBundleIdentifier || null };
}

/** The shape the HUD reads, from whatever a shim sent; null when there is nothing usable. */
export function cleanHost(host) {
  const ancestors = (Array.isArray(host?.ancestors) ? host.ancestors : [])
    .filter((p) => Number.isInteger(p) && p > 1).slice(0, 32);
  const bundleId = typeof host?.bundleId === "string" && /^[\w.-]{1,255}$/.test(host.bundleId) ? host.bundleId : null;
  return ancestors.length || bundleId ? { ancestors, bundleId } : null;
}
