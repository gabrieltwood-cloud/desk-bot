#!/bin/zsh
# Build Desk Bot from source and install it to ~/Applications, then launch it.
# Safe to re-run: it replaces the previous copy and keeps your settings.
set -euo pipefail
ROOT="${0:A:h:h}"
"$ROOT/build.sh"
mkdir -p "$HOME/Applications"
pkill -x "Desk Bot" 2>/dev/null || true
rm -rf "$HOME/Applications/Desk Bot.app"
cp -R "$ROOT/build/Desk Bot.app" "$HOME/Applications/"
open "$HOME/Applications/Desk Bot.app"
echo "Installed to ~/Applications/Desk Bot.app and launched."
