#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="SerialScreen"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
ICON_SOURCE="$ROOT_DIR/Assets/icon.icns"

swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$ROOT_DIR/.build/release/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

if [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$APP_DIR/Contents/Resources/icon.icns"
  ICON_TAG='<key>CFBundleIconFile</key><string>icon.icns</string>'
else
  ICON_TAG=''
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>com.elvin.serialscreen</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  $ICON_TAG
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

cp -R "$APP_DIR" /Applications/

echo "Built: $APP_DIR"
echo "Installed: /Applications/$APP_NAME.app"
