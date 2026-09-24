#!/bin/bash
# Install cua: build the native apps, register the MCP server with every harness
# found, and install the Claude Code skill. Safe to re-run.
#
#   ./install.sh                 install / update
#   ./install.sh --rebuild-agent also rebuild CuaAgent (you will need to re-grant its permissions)
#   ./install.sh --with-codex    also register with Codex
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
APPS="$HOME/Applications"
REBUILD_AGENT=0; WITH_CODEX=0
for a in "$@"; do case "$a" in --rebuild-agent) REBUILD_AGENT=1;; --with-codex) WITH_CODEX=1;; esac; done
say() { printf '  %s\n' "$*"; }

[ "$(uname)" = "Darwin" ] || { echo "macOS only."; exit 1; }
NODE="$(command -v node || true)"
[ -n "$NODE" ] || { echo "Node.js 22+ is required (brew install node)."; exit 1; }
[ "$("$NODE" -p 'process.versions.node.split(".")[0]')" -ge 22 ] || { echo "Node.js 22+ is required (found $("$NODE" -v))."; exit 1; }
command -v swiftc >/dev/null || { echo "Xcode command line tools required: xcode-select --install"; exit 1; }

echo "==> native apps"
mkdir -p "$APPS" "$REPO/build"
mkapp() { # name source bundle-id
  local name="$1" src="$2" id="$3" app="$APPS/$1.app"
  local hash; hash="$(shasum -a 256 "$src" | cut -c1-16)"
  if [ "$name" = CuaAgent ] && [ "$REBUILD_AGENT" = 0 ] && [ -d "$app" ] \
     && [ "$(/usr/libexec/PlistBuddy -c 'Print :CuaSourceHash' "$app/Contents/Info.plist" 2>/dev/null)" = "$hash" ]; then
    say "$name.app unchanged - kept, so its permissions stay granted"; return
  fi
  swiftc -O -swift-version 5 -o "$REPO/build/$name" "$src" 2>&1 | grep -E "error" && exit 1 || true
  pkill -x "$name" 2>/dev/null || true
  rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
  cp "$REPO/build/$name" "$app/Contents/MacOS/$name"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CuaSourceHash</key><string>$hash</string>
</dict></plist>
PLIST
  codesign --force --deep -s - "$app" >/dev/null 2>&1 || true
  say "built $name.app"
}
mkapp CuaAgent "$REPO/agent/CuaAgent.swift" com.andymsun.cua.agent
mkapp CuaPreview "$REPO/hud/CuaPreview.swift" com.andymsun.cua.preview

echo "==> config"
"$NODE" --input-type=module -e "import { ensureDirs, paths } from '$REPO/server/lib/config.mjs'; ensureDirs(); console.log('  ' + paths.config);"

echo "==> cli"
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/cua" <<SH
#!/bin/sh
exec "$NODE" "$REPO/server/cli.mjs" "\$@"
SH
chmod +x "$HOME/.local/bin/cua"
say "~/.local/bin/cua  (status | start | stop | ui | settings | doctor)"

echo "==> harnesses"
SHIM="$REPO/server/shim.mjs"
register_json() { # label file
  local label="$1" file="$2"
  "$NODE" -e '
    const fs = require("fs"), [file, node, shim] = process.argv.slice(1);
    const real = fs.existsSync(file) ? fs.realpathSync(file) : file;
    let cfg = {}; try { cfg = JSON.parse(fs.readFileSync(real, "utf8") || "{}"); } catch {}
    cfg.mcpServers = { ...(cfg.mcpServers || {}), cua: { command: node, args: [shim] } };
    fs.mkdirSync(require("path").dirname(real), { recursive: true });
    fs.writeFileSync(real, JSON.stringify(cfg, null, 2) + "\n");
  ' "$file" "$NODE" "$SHIM"
  say "$label: $file"
}
if command -v claude >/dev/null; then
  claude mcp remove cua -s user >/dev/null 2>&1 || true
  claude mcp add cua --scope user -- "$NODE" "$SHIM" >/dev/null && say "Claude Code: registered (user scope)"
fi
[ -d "$HOME/.gemini/antigravity" ] && register_json "Antigravity" "$HOME/.gemini/antigravity/mcp_config.json"
[ -d "$HOME/.gemini/antigravity-ide" ] && register_json "Antigravity IDE" "$HOME/.gemini/antigravity-ide/mcp_config.json"
command -v gemini >/dev/null && register_json "Gemini CLI" "$HOME/.gemini/settings.json"
[ -d "$HOME/.cursor" ] && register_json "Cursor" "$HOME/.cursor/mcp.json"
if [ "$WITH_CODEX" = 1 ] && command -v codex >/dev/null; then
  codex mcp remove cua >/dev/null 2>&1 || true
  codex mcp add cua -- "$NODE" "$SHIM" >/dev/null && say "Codex: registered"
fi
say "anything else: an MCP stdio server with command \"$NODE\" and args [\"$SHIM\"]"

echo "==> Claude Code skill"
mkdir -p "$HOME/.claude/skills/cua"
cp "$REPO/skill/SKILL.md" "$HOME/.claude/skills/cua/SKILL.md"
say "~/.claude/skills/cua/SKILL.md"

echo "==> agent browser"
"$NODE" "$REPO/server/cli.mjs" use --apply

cat <<'NEXT'

==> done
  Browser control works now. Restart your harness so it loads the `cua` server.

  For native apps, grant CuaAgent.app (once per machine):
    System Settings > Privacy & Security > Accessibility     > enable CuaAgent
    System Settings > Privacy & Security > Screen Recording  > enable CuaAgent
  It asks for both the first time an app is driven. Check with: cua doctor

  Settings UI: cua settings      Live browser: cua ui
  Switch agents to the harness's built-in browser and back: cua toggle
NEXT
