#!/bin/bash
# Remove everything install.sh created. Leaves ~/.claude/cua-bridge/config.json.
set -euo pipefail
HOME_DIR="${CUA_BRIDGE_HOME:-$HOME/.claude/cua-bridge}"
pkill -f CuaPreview 2>/dev/null || true
pkill -f CuaCapture 2>/dev/null || true
rm -rf "$HOME/Applications/CuaCapture.app" "$HOME/Applications/CuaPreview.app"
rm -rf "$HOME/.claude/skills/cua"
rm -f "$HOME_DIR"/*.mjs "$HOME_DIR"/cua-bridge.py "$HOME_DIR"/cua-*-bin
rm -rf "$HOME_DIR/src" "$HOME_DIR/stream"
command -v claude >/dev/null && claude mcp remove cua -s user >/dev/null 2>&1 || true
echo "removed. config kept at $HOME_DIR/config.json"
