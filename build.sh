#!/bin/bash
# Compila build/Compa.app con todas las mascotas de pets/ dentro.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Compa.app"
ARCH="$(uname -m)"          # arm64 o x86_64: compila para esta Mac
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -sdk "$(xcrun --show-sdk-path)" \
  -target "$ARCH-apple-macos13.0" \
  -o "$APP/Contents/MacOS/Compa" \
  Sources/*.swift

cp -R pets "$APP/Contents/Resources/pets"
cp -R scenes "$APP/Contents/Resources/scenes"
[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Compa</string>
  <key>CFBundleDisplayName</key><string>Compa</string>
  <key>CFBundleIdentifier</key><string>com.juli.compa</string>
  <key>CFBundleExecutable</key><string>Compa</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || true

# El hook lo ejecuta Claude Code, no la app: vive fuera del bundle.
mkdir -p "$HOME/.compa/pets"
cp hooks/compa-hook.sh "$HOME/.compa/hook.sh"
chmod +x "$HOME/.compa/hook.sh"

echo "built $APP"
