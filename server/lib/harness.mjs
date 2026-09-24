// Which browser agents use: cua, or the harness's own built-in browser (e.g. the
// Claude app's browser pane tools). Switching edits only the entries cua manages:
//   - Claude Code: permission denies for the built-in browser tools vs. for mcp__cua,
//     and the cua skill (parked while the built-in browser is selected)
//   - JSON-configured harnesses (Antigravity, Gemini CLI, Cursor): the cua server entry
//     is parked and restored, so their own browser tools take over
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { paths } from "./config.mjs";

const home = os.homedir();
const cfgDir = path.dirname(paths.config);
const modeFile = path.join(cfgDir, "agent-browser");
const parkedServers = path.join(cfgDir, "parked-servers.json");
const skillDir = path.join(home, ".claude/skills/cua");
const parkedSkill = path.join(cfgDir, "parked-skill");
const claudeSettings = path.join(home, ".claude/settings.json");

export const MODES = { cua: "cua (background browser, live view, HUD)", builtin: "the harness's built-in browser" };

// The Claude app's browser tools that drive pages. preview_* stay allowed in both
// modes: cua's live view opens through them.
export const CLAUDE_BROWSER_TOOLS = [
  "navigate", "computer", "browser_batch", "find", "form_input", "get_page_text", "javascript_tool",
  "read_page", "read_console_messages", "read_network_requests", "resize_window",
  "tabs_close", "tabs_context", "tabs_create", "tabs_select",
].map((t) => `mcp__Claude_Browser__${t}`);
const CUA_RULE = "mcp__cua";

export const JSON_HARNESSES = [
  ["Antigravity", ".gemini/antigravity/mcp_config.json"],
  ["Antigravity IDE", ".gemini/antigravity-ide/mcp_config.json"],
  ["Gemini CLI", ".gemini/settings.json"],
  ["Cursor", ".cursor/mcp.json"],
].map(([name, rel]) => ({ name, file: path.join(home, rel) }));

const readJson = (f, fallback) => { try { return JSON.parse(fs.readFileSync(f, "utf8") || "null") ?? fallback; } catch { return fallback; } };
// write through symlinks (Antigravity's config is one) and never leave a half-written file
function writeJson(f, value) {
  const real = fs.existsSync(f) ? fs.realpathSync(f) : f;
  fs.mkdirSync(path.dirname(real), { recursive: true });
  const tmp = `${real}.cua-tmp`;
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2) + "\n");
  fs.renameSync(tmp, real);
}

export function currentMode() {
  try { const m = fs.readFileSync(modeFile, "utf8").trim(); if (m in MODES) return m; } catch {}
  return "cua";
}

/** Switch every harness to `mode` (default: re-apply the current one). Returns a report. */
export function applyMode(mode = currentMode()) {
  if (!(mode in MODES)) throw new Error(`unknown mode "${mode}" - use ${Object.keys(MODES).join(" or ")}`);
  const report = [];

  // Claude Code / Claude app
  const s = fs.existsSync(claudeSettings) ? readJson(claudeSettings, null) : fs.existsSync(path.dirname(claudeSettings)) ? {} : null;
  if (fs.existsSync(claudeSettings) && !s) report.push("Claude: settings.json unreadable, left alone");
  if (s) {
    const managed = new Set([...CLAUDE_BROWSER_TOOLS, CUA_RULE]);
    const deny = (s.permissions?.deny ?? []).filter((r) => !managed.has(r));
    deny.push(...(mode === "cua" ? CLAUDE_BROWSER_TOOLS : [CUA_RULE]));
    s.permissions = { ...(s.permissions ?? {}), deny };
    writeJson(claudeSettings, s);
    report.push(`Claude: ${mode === "cua" ? "built-in browser tools denied, cua allowed" : "cua denied, built-in browser allowed"}`);

    const parked = path.join(parkedSkill, "cua");
    if (mode === "builtin" && fs.existsSync(skillDir)) {
      fs.mkdirSync(parkedSkill, { recursive: true });
      fs.rmSync(parked, { recursive: true, force: true });
      fs.renameSync(skillDir, parked);
      report.push("Claude: cua skill parked");
    } else if (mode === "cua" && !fs.existsSync(skillDir) && fs.existsSync(parked)) {
      fs.renameSync(parked, skillDir);
      report.push("Claude: cua skill restored");
    }
  }

  // JSON-configured harnesses
  const stash = readJson(parkedServers, {});
  for (const { name, file } of JSON_HARNESSES) {
    if (!fs.existsSync(file)) continue;
    const cfg = readJson(file, null);
    if (!cfg) { report.push(`${name}: config unreadable, left alone`); continue; }
    const has = !!cfg.mcpServers?.cua;
    if (mode === "builtin" && has) {
      stash[file] = cfg.mcpServers.cua;
      delete cfg.mcpServers.cua;
      writeJson(file, cfg);
      report.push(`${name}: cua server parked`);
    } else if (mode === "cua" && !has && stash[file]) {
      cfg.mcpServers = { ...(cfg.mcpServers ?? {}), cua: stash[file] };
      writeJson(file, cfg);
      report.push(`${name}: cua server restored`);
    }
    if (mode === "cua") delete stash[file];
  }
  writeJson(parkedServers, stash);

  fs.mkdirSync(cfgDir, { recursive: true });
  fs.writeFileSync(modeFile, mode + "\n");
  return report;
}

/** For uninstall: drop every rule cua added, so the built-in browser works as before. */
export function release() {
  const s = fs.existsSync(claudeSettings) ? readJson(claudeSettings, null) : null;
  if (!s?.permissions?.deny) return;
  const managed = new Set([...CLAUDE_BROWSER_TOOLS, CUA_RULE]);
  s.permissions.deny = s.permissions.deny.filter((r) => !managed.has(r));
  writeJson(claudeSettings, s);
}
