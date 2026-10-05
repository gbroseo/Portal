#!/bin/bash
# Installs the freshly built app into /Applications, links the `portal` CLI, and relaunches.
set -euo pipefail
cd "$(dirname "$0")/.."
osascript -e 'quit app id "com.gbroseo.portal"' 2>/dev/null || true
pkill -x Portal 2>/dev/null || true
sleep 1
rm -rf "/Applications/传送门.app"
cp -R "build/传送门.app" /Applications/
mkdir -p "$HOME/.local/bin"
ln -sf "/Applications/传送门.app/Contents/MacOS/Portal" "$HOME/.local/bin/portal"
open "/Applications/传送门.app"
echo "installed; CLI: ~/.local/bin/portal"
