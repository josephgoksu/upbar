#!/bin/sh
# Installs the latest Upbar into ~/Applications. No sudo, no admin password.
# curl -fsSL https://raw.githubusercontent.com/josephgoksu/upbar/main/install.sh | sh
set -eu
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL https://github.com/josephgoksu/upbar/releases/latest/download/Upbar.zip -o "$TMP/Upbar.zip"
pkill -x Upbar 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Upbar.app"
ditto -x -k "$TMP/Upbar.zip" "$HOME/Applications"
open "$HOME/Applications/Upbar.app"
echo "Upbar installed in ~/Applications. Look for the little bar chart in your menu bar."
