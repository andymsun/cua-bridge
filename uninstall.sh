#!/bin/bash
# Remove cua. Keeps ~/.config/cua/config.json and browser profiles (logins)
# unless --purge is given.
set -uo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
PURGE=0; [ "${1:-}" = "--purge" ] && PURGE=1

"$HOME/.local/bin/cua" stop >/dev/null 2>&1
# give harnesses their built-in browser back
node --input-type=module -e "import { applyMode, release } from '$REPO/server/lib/harness.mjs'; applyMode('cua'); release();" 2>/dev/null
pkill -x CuaAgent 2>/dev/null; pkill -x CuaPreview 2>/dev/null
rm -rf "$HOME/Applications/CuaAgent.app" "$HOME/Applications/CuaPreview.app"
rm -f "$HOME/.local/bin/cua"
rm -rf "$HOME/.claude/skills/cua"
command -v claude >/dev/null && claude mcp remove cua -s user >/dev/null 2>&1
command -v codex >/dev/null && codex mcp remove cua >/dev/null 2>&1
for f in "$HOME/.gemini/antigravity/mcp_config.json" "$HOME/.gemini/antigravity-ide/mcp_config.json" "$HOME/.gemini/settings.json" "$HOME/.cursor/mcp.json"; do
  [ -f "$f" ] || continue
  node -e 'const fs=require("fs"),f=fs.realpathSync(process.argv[1]);let c={};try{c=JSON.parse(fs.readFileSync(f,"utf8")||"{}")}catch{};if(c.mcpServers&&c.mcpServers.cua){delete c.mcpServers.cua;fs.writeFileSync(f,JSON.stringify(c,null,2)+"\n")}' "$f"
done
if [ "$PURGE" = 1 ]; then
  rm -rf "$HOME/Library/Application Support/cua" "$HOME/.config/cua"
  echo "removed, including config and browser profiles"
else
  echo "removed. kept ~/.config/cua and browser profiles (./uninstall.sh --purge removes them)"
fi
