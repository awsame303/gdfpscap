#!/bin/bash
# Assemble FPS Uncap.app -- a double-clickable front end that carries the
# payload with it, so users never touch a terminal.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/build}"
APP="$OUT/FPS Uncap.app"

[ -f "$ROOT/build/fpsuncap.dylib" ] || { echo "run 'make' first"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>FPS Uncap</string>
    <key>CFBundleDisplayName</key>       <string>FPS Uncap</string>
    <key>CFBundleIdentifier</key>        <string>io.github.awsame303.fpsuncap</string>
    <key>CFBundleVersion</key>           <string>1.0.0</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleExecutable</key>        <string>FPS Uncap</string>
    <key>LSMinimumSystemVersion</key>    <string>11.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <!-- Without these, macOS denies access to a Geometry Dash living in a
         protected folder outright, instead of prompting the user to allow it.
         The install then fails with EPERM and there is nothing the user can
         click to fix it. -->
    <key>NSDocumentsFolderUsageDescription</key>
    <string>FPS Uncap needs access to modify Geometry Dash if it is installed in your Documents folder.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>FPS Uncap needs access to modify Geometry Dash if it is installed on your Desktop.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>FPS Uncap needs access to modify Geometry Dash if it is installed in your Downloads folder.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>FPS Uncap needs access to modify Geometry Dash if it is installed on an external drive.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>FPS Uncap uses system dialogs to ask you what to do.</string>
</dict>
</plist>
PLIST

cat > "$APP/Contents/MacOS/FPS Uncap" <<'LAUNCHER'
#!/bin/bash
exec "$(cd "$(dirname "$0")/../Resources" && pwd)/gui.sh"
LAUNCHER
chmod +x "$APP/Contents/MacOS/FPS Uncap"

cp "$ROOT/build/fpsuncap.dylib" "$ROOT/build/machsplice" \
   "$ROOT/tools/fpsuncap" "$ROOT/tools/gui.sh" "$ROOT/tools/find-gd.sh" \
   "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/fpsuncap" "$APP/Contents/Resources/gui.sh" \
         "$APP/Contents/Resources/machsplice"

codesign -f -s - --deep "$APP" 2>/dev/null || true
echo "built $APP"
