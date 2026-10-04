#!/bin/sh
# ./build.sh          -> dist/Upbar.app + dist/Upbar.zip (universal, ad-hoc signed)
# ./build.sh install  -> also installs to ~/Applications and relaunches
# Optional env: SIGN_IDENTITY (Developer ID), NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER (App Store Connect API key)
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
if [ -n "${SIGN_IDENTITY:-}" ]; then
  # Developer ID + hardened runtime: required for notarization.
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
zip_app() {
  rm -f dist/Upbar.zip* && ditto -c -k --keepParent "$APP" dist/Upbar.zip
  (cd dist && shasum -a 256 Upbar.zip > Upbar.zip.sha256)
}
zip_app
if [ -n "${NOTARY_KEY:-}" ]; then
  xcrun notarytool submit dist/Upbar.zip --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  xcrun stapler staple "$APP"
  zip_app  # zip again so the download carries the stapled ticket
fi
if [ "${1:-}" = install ]; then
  pkill -x Upbar || true
  mkdir -p ~/Applications && rm -rf ~/Applications/Upbar.app && cp -R "$APP" ~/Applications/
  open ~/Applications/Upbar.app
fi
