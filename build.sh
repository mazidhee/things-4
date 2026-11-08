#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Things 4"
BIN_NAME="Things4"
APP_BUNDLE="build/${APP_NAME}.app"

echo "==> Building (universal: arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "==> Icon"
# A custom icon dropped at assets/AppIcon.icns wins over the generated one.
if [ -f assets/AppIcon.icns ]; then
  mkdir -p build
  cp assets/AppIcon.icns build/AppIcon.icns
elif [ ! -f build/AppIcon.icns ]; then
  mkdir -p build
  swift tools/makeicon.swift build/icon-1024.png >/dev/null
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  sips -z 16 16     build/icon-1024.png --out "$ICONSET/icon_16x16.png" >/dev/null
  sips -z 32 32     build/icon-1024.png --out "$ICONSET/icon_16x16@2x.png" >/dev/null
  sips -z 32 32     build/icon-1024.png --out "$ICONSET/icon_32x32.png" >/dev/null
  sips -z 64 64     build/icon-1024.png --out "$ICONSET/icon_32x32@2x.png" >/dev/null
  sips -z 128 128   build/icon-1024.png --out "$ICONSET/icon_128x128.png" >/dev/null
  sips -z 256 256   build/icon-1024.png --out "$ICONSET/icon_128x128@2x.png" >/dev/null
  sips -z 256 256   build/icon-1024.png --out "$ICONSET/icon_256x256.png" >/dev/null
  sips -z 512 512   build/icon-1024.png --out "$ICONSET/icon_256x256@2x.png" >/dev/null
  sips -z 512 512   build/icon-1024.png --out "$ICONSET/icon_512x512.png" >/dev/null
  cp build/icon-1024.png "$ICONSET/icon_512x512@2x.png"
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi

echo "==> Assembling ${APP_BUNDLE}"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "${BIN_DIR}/${BIN_NAME}" "$APP_BUNDLE/Contents/MacOS/${BIN_NAME}"
cp build/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
# Things 3 list icons, if extracted locally into assets/ThingsIcons (see .gitignore).
if [ -d assets/ThingsIcons ]; then
  mkdir -p "$APP_BUNDLE/Contents/Resources/ThingsIcons"
  cp assets/ThingsIcons/*.png "$APP_BUNDLE/Contents/Resources/ThingsIcons/"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Things 4</string>
    <key>CFBundleDisplayName</key><string>Things 4</string>
    <key>CFBundleIdentifier</key><string>com.tanay.things4</string>
    <key>CFBundleExecutable</key><string>Things4</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.1.0</string>
    <key>CFBundleVersion</key><string>4</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSCalendarsFullAccessUsageDescription</key><string>Things 4 shows your calendar events next to your to-dos in Today and Upcoming. Events are only read, never changed.</string>
    <key>NSAppleEventsUsageDescription</key><string>Quick Entry with Autofill (⌃⌥Space) links the web page, Mail message or file you are looking at.</string>
    <key>NSRemindersFullAccessUsageDescription</key><string>Things 4 copies your to-do reminders to a “Things 4” list so your iPhone and Apple Watch remind you too.</string>
    <key>NSRemindersUsageDescription</key><string>Things 4 copies your to-do reminders to a “Things 4” list so your iPhone and Apple Watch remind you too.</string>
    <key>NSCalendarsUsageDescription</key><string>Things 4 shows your calendar events next to your to-dos in Today and Upcoming.</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>com.tanay.things4</string>
            <key>CFBundleURLSchemes</key><array><string>things4</string></array>
        </dict>
    </array>
    <key>NSHumanReadableCopyright</key><string>Things 4 — free and open-source software.</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad hoc)"
# Pin the designated requirement to the bundle ID: the default ad-hoc requirement is the
# build's cdhash, so macOS forgot the Calendar permission after every rebuild.
codesign --force --deep --sign - -r='designated => identifier "com.tanay.things4"' "$APP_BUNDLE"

echo
echo "Built: $APP_BUNDLE"
echo "Install: cp -R \"$APP_BUNDLE\" /Applications/"
