#!/bin/bash
# Install the CUA bridge: MCP shim, capture daemon, preview HUD, and skill.
#
#   ./install.sh                 install everything
#   CUA_BRIDGE_HOME=~/x ./install.sh
#
# Requires macOS with Xcode command line tools and the ChatGPT/Codex desktop app
# (it supplies the CUA runtime this bridge wraps).
set -euo pipefail

HOME_DIR="${CUA_BRIDGE_HOME:-$HOME/.claude/cua-bridge}"
CUA_NODE="${CUA_NODE_HOME:-/Applications/ChatGPT.app/Contents/Resources/cua_node}"
APPS="$HOME/Applications"
SRC="$(cd "$(dirname "$0")" && pwd)"

say() { printf '  %s\n' "$*"; }

[ "$(uname)" = "Darwin" ] || { echo "macOS only."; exit 1; }
command -v swiftc >/dev/null || { echo "swiftc not found. Install Xcode command line tools: xcode-select --install"; exit 1; }
[ -x "$CUA_NODE/bin/node_repl" ] || {
  echo "CUA runtime not found at $CUA_NODE"
  echo "Install the ChatGPT/Codex desktop app, or set CUA_NODE_HOME."
  exit 1
}

echo "==> paths"
say "bridge home : $HOME_DIR"
say "cua runtime : $CUA_NODE"

echo "==> files"
mkdir -p "$HOME_DIR" "$HOME_DIR/src" "$HOME_DIR/stream" "$APPS"
cp "$SRC"/js/*.mjs "$HOME_DIR/"
cp "$SRC"/bridge/cua-bridge.py "$HOME_DIR/"
cp "$SRC"/hud/src/*.swift "$HOME_DIR/src/"
chmod +x "$HOME_DIR/cua-bridge.py"
[ -f "$HOME_DIR/config.json" ] || cp "$SRC/config.example.json" "$HOME_DIR/config.json"
say "installed js modules, mcp shim, sources, config"

echo "==> skill"
mkdir -p "$HOME/.claude/skills/cua"
cp "$SRC/skill/SKILL.md" "$HOME/.claude/skills/cua/SKILL.md"
say "~/.claude/skills/cua/SKILL.md"

echo "==> build"
swiftc -O -o "$HOME_DIR/cua-capture-bin" "$SRC/hud/src/CuaCapture.swift"
swiftc -O -o "$HOME_DIR/cua-ui-bin"      "$SRC/hud/src/CuaPreviewUI.swift"
say "compiled capture daemon and preview HUD"

mkapp() { # name binary bundleid
  local app="$APPS/$1.app"
  rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
  cp "$2" "$app/Contents/MacOS/$1"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$1</string>
  <key>CFBundleIdentifier</key><string>$3</string>
  <key>CFBundleExecutable</key><string>$1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST
  codesign --force --deep -s - "$app" >/dev/null 2>&1 || true
}
mkapp CuaCapture "$HOME_DIR/cua-capture-bin" com.anthropic.claude.cuacapture
mkapp CuaPreview "$HOME_DIR/cua-ui-bin"      com.anthropic.claude.cuapreview
say "$APPS/CuaCapture.app  (holds Screen Recording)"
say "$APPS/CuaPreview.app  (UI only, no permissions)"

echo "==> mcp server"
if command -v claude >/dev/null; then
  claude mcp remove cua -s user >/dev/null 2>&1 || true
  claude mcp add cua --scope user -e CUA_BRIDGE_ELICIT=accept -- /usr/bin/python3 "$HOME_DIR/cua-bridge.py" >/dev/null
  say "registered as 'cua' (restart Claude Code to pick it up)"
else
  say "claude CLI not found - register manually:"
  say "claude mcp add cua --scope user -e CUA_BRIDGE_ELICIT=accept -- /usr/bin/python3 $HOME_DIR/cua-bridge.py"
fi

cat <<'NEXT'

==> one manual step
  Grant Screen Recording to CuaCapture.app:
    System Settings > Privacy & Security > Screen Recording > add ~/Applications/CuaCapture.app
  Then:
    open ~/Applications/CuaCapture.app && open ~/Applications/CuaPreview.app

  macOS ties that grant to the binary's cdhash. Re-running install.sh rebuilds
  CuaCapture and invalidates it; re-grant when you do.
NEXT
