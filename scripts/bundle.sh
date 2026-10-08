#!/usr/bin/env bash
# Usage: scripts/bundle.sh <binary> <output.app> <version>
# Wraps a built executable into a macOS .app bundle.
set -euo pipefail
BIN="$1"; APP="$2"; VERSION="$3"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Marquee"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Marquee</string>
  <key>CFBundleDisplayName</key><string>Marquee</string>
  <key>CFBundleIdentifier</key><string>com.danskullz.marquee</string>
  <key>CFBundleExecutable</key><string>Marquee</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
</dict></plist>
PLIST
# Ad-hoc sign so the bundle is valid; CI replaces this with Developer ID when secrets exist.
codesign --force --sign - "$APP"
