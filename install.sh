#!/bin/sh
# Installs the latest Upbar into ~/Applications. No sudo. No administrator password.
# curl -fsSL https://raw.githubusercontent.com/josephgoksu/upbar/main/install.sh | sh
set -eu
URL=https://github.com/josephgoksu/upbar/releases/latest/download
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
curl -fsSL "$URL/Upbar.zip" -o Upbar.zip
curl -fsSL "$URL/Upbar.zip.sha256" -o Upbar.zip.sha256
shasum -a 256 -c Upbar.zip.sha256 >/dev/null || { echo "Checksum does not match. Upbar is not installed." >&2; exit 1; }
pkill -x Upbar 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Upbar.app"
ditto -x -k Upbar.zip "$HOME/Applications"
open "$HOME/Applications/Upbar.app"
echo "Upbar is installed in ~/Applications. Find the bar chart icon in the menu bar."
