#!/bin/bash
# Build MacDuo.app
set -euo pipefail
cd "$(dirname "$0")"

APP="build/MacDuo.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
  -framework Cocoa -framework IOKit -framework QuartzCore -framework ServiceManagement \
  -framework ScreenCaptureKit -framework CoreMedia \
  MacDuo.swift -o "$APP/Contents/MacOS/MacDuo"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>MacDuo</string>
  <key>CFBundleDisplayName</key>       <string>MacDuo</string>
  <key>CFBundleExecutable</key>        <string>MacDuo</string>
  <key>CFBundleIdentifier</key>        <string>com.by.macduo</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key>           <string>1</string>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <key>LSUIElement</key>               <true/>
  <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

# Signing. A Developer ID is strongly preferred: a TCC grant against an ad-hoc signature is
# bound to the cdhash and dies on every rebuild, so the screen-recording prompt comes back
# every single time. A Developer ID is bound to the Team ID and the grant survives rebuilds.
# Local signing only — not notarized, not for distribution.
# Set MACDUO_IDENTITY to pick a specific identity; otherwise the first Developer ID
# Application identity in your keychain is used.
IDENTITY="${MACDUO_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
fi

if [ -n "$IDENTITY" ] && codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null; then
  echo "Signed with $IDENTITY — the screen recording grant survives rebuilds"
else
  echo "No Developer ID found, falling back to ad-hoc — screen recording has to be re-granted after every rebuild"
  codesign --force --sign - "$APP" 2>/dev/null || echo "warning: codesign failed"
fi

echo "✅ Built: $APP"
