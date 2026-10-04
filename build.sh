#!/bin/sh
# ./build.sh          -> dist/Upbar.app + dist/Upbar.zip (universal, ad-hoc signed)
# ./build.sh install  -> also installs to ~/Applications and relaunches
set -eu
cd "$(dirname "$0")"
ARGS="-c release --arch arm64 --arch x86_64"
swift build $ARGS
APP=dist/Upbar.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS"
cp "$(swift build $ARGS --show-bin-path)/Upbar" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
mkdir -p "$APP/Contents/Resources" && cp Resources/Upbar.icns "$APP/Contents/Resources/"
[ -n "${VERSION:-}" ] && plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" dist/Upbar.zip
(cd dist && shasum -a 256 Upbar.zip > Upbar.zip.sha256)
if [ "${1:-}" = install ]; then
  pkill -x Upbar || true
  mkdir -p ~/Applications && rm -rf ~/Applications/Upbar.app && cp -R "$APP" ~/Applications/
  open ~/Applications/Upbar.app
fi
