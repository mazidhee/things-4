#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.1.0}"
APP_NAME="Things 4"
APP_BUNDLE="build/${APP_NAME}.app"
STAGE="build/dmg-stage"
DMG="build/Things4-${VERSION}.dmg"

./build.sh

echo "==> Verifying signature"
codesign --verify --deep --strict "$APP_BUNDLE"
lipo -archs "$APP_BUNDLE/Contents/MacOS/Things4"

echo "==> Staging DMG"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP_BUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me.txt" <<'TXT'
Things 4

Drag "Things 4" onto the Applications folder, then launch it from Applications.

First launch on another Mac:
macOS may block an app downloaded from the internet that is not notarized.
Right-click "Things 4" in Applications, choose Open, then confirm Open.
If macOS says the app is damaged, run this once in Terminal:

    xattr -dr com.apple.quarantine "/Applications/Things 4.app"

Add your own AI key in Settings (Command + comma). Keys are stored in your
macOS keychain. Nothing is sent until you press Send in the AI panel.
TXT

echo "==> Creating ${DMG}"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG" >/dev/null

shasum -a 256 "$DMG" | tee "${DMG}.sha256"

# Stable name for the "latest" download link.
cp "$DMG" "build/Things4.dmg"

echo
echo "DMG: $DMG"
echo "Latest alias: build/Things4.dmg"
du -h "$DMG"
