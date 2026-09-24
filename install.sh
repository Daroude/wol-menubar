#!/bin/bash
# Installs wol-menubar as a SwiftBar plugin.
# The plugin is symlinked, so `git pull` in this folder is all an update needs.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="wol-menubar.30s.sh"

# 1. SwiftBar
if [ ! -d /Applications/SwiftBar.app ] && [ ! -d "$HOME/Applications/SwiftBar.app" ]; then
  if command -v brew >/dev/null; then
    echo "→ Installing SwiftBar via Homebrew …"
    brew install --cask swiftbar
  else
    echo "✗ SwiftBar is not installed and Homebrew is not available."
    echo "  Get it from https://github.com/swiftbar/SwiftBar/releases, then run install.sh again."
    exit 1
  fi
fi

# 2. Plugin folder: reuse SwiftBar's, otherwise create ~/SwiftBarPlugins
DIR="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
if [ -z "$DIR" ]; then
  DIR="$HOME/SwiftBarPlugins"
  defaults write com.ameba.SwiftBar PluginDirectory -string "$DIR"
fi
mkdir -p "$DIR"

# 3. Link the plugin
chmod +x "$REPO/$PLUGIN"
ln -sf "$REPO/$PLUGIN" "$DIR/$PLUGIN"
echo "✓ Linked $DIR/$PLUGIN → $REPO/$PLUGIN"

# 4. Start or refresh SwiftBar
if pgrep -x SwiftBar >/dev/null; then
  open -g "swiftbar://refreshallplugins"
else
  open -a SwiftBar
fi
echo "✓ Done – look for the computer icon in your menu bar and choose “Add computer from network…”."
