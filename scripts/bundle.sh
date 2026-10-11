#!/usr/bin/env bash
# Usage: scripts/bundle.sh <binary> <output.app> <version>
# Wraps a built executable into a macOS .app bundle, including the LGPL libmpv/FFmpeg dylibs.
#
# Environment:
#   MPV_VENDOR_DIR     directory produced by scripts/build-mpv.sh (default <repo>/Vendor/mpv)
#   BUNDLE_ARCH        arm64 | x86_64 to thin the (universal) dylibs for a per-arch bundle; unset keeps universal
#   REQUIRE_FRAMEWORKS 1 = fail if the dylibs are missing (CI); otherwise bundle without a player and warn
set -euo pipefail
BIN="$1"; APP="$2"; VERSION="$3"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="${MPV_VENDOR_DIR:-$ROOT/Vendor/mpv}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Marquee"
# SwiftPM's executable resources are kept in a sibling bundle; ship it with the app.
RESOURCE_BUNDLE="$(dirname "$BIN")/Marquee_Marquee.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"; fi
# Drop local symbols (~half the executable; §5.6 size budget). Crash symbolication will use dSYMs later.
strip -x "$APP/Contents/MacOS/Marquee"

# --- Frameworks: LGPL dylibs stay separate files so users can replace them (LGPL relinking). ---
if ls "$VENDOR"/lib/*.dylib >/dev/null 2>&1; then
  for f in "$VENDOR"/lib/*.dylib; do
    [ -L "$f" ] && continue   # skip dev-only symlinks (libmpv.dylib -> libmpv.2.dylib)
    dest="$APP/Contents/Frameworks/$(basename "$f")"
    if [ -n "${BUNDLE_ARCH:-}" ]; then lipo "$f" -thin "$BUNDLE_ARCH" -output "$dest"; else cp "$f" "$dest"; fi
  done
  # Licence texts + relinking notice travel with the binaries.
  mkdir -p "$APP/Contents/Resources/Licenses"
  cp -R "$VENDOR/licenses/." "$APP/Contents/Resources/Licenses/" 2>/dev/null || true
  [ -f "$ROOT/docs/licenses.md" ] && cp "$ROOT/docs/licenses.md" "$APP/Contents/Resources/Licenses/THIRD-PARTY.md"
  # The app dlopens libmpv from Contents/Frameworks; the rpath also lets any future direct link resolve.
  if ! otool -l "$APP/Contents/MacOS/Marquee" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Marquee"
  fi
  # Sign inside-out (dylibs first, then the app). Ad-hoc here; CI swaps in Developer ID when available.
  for f in "$APP"/Contents/Frameworks/*.dylib; do codesign --force --sign - "$f"; done
elif [ "${REQUIRE_FRAMEWORKS:-0}" = 1 ]; then
  echo "error: no dylibs in $VENDOR/lib; run scripts/build-mpv.sh" >&2; exit 1
else
  echo "warning: no dylibs in $VENDOR/lib; bundling without libmpv (run scripts/build-mpv.sh)" >&2
  rmdir "$APP/Contents/Frameworks"
fi

# Compile the brand asset catalog into the bundle. actool emits the Assets.car the Dock, Finder and
# the About panel read, an AppIcon.icns, and a partial Info.plist carrying CFBundleIconName.
CATALOG="$ROOT/brand/Assets.xcassets"
ACTUAL="$(xcode-select -p 2>/dev/null || true)"
if [ ! -x "${DEVELOPER_DIR:-$ACTUAL}/usr/bin/actool" ] && [ -x /Applications/Xcode.app/Contents/Developer/usr/bin/actool ]; then
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if [ -d "$CATALOG" ]; then
  if [ -x "${DEVELOPER_DIR:-/nonexistent}/usr/bin/actool" ]; then
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/out"
    DEVELOPER_DIR="$DEVELOPER_DIR" actool \
      --compile "$TMP/out" --output-format human-readable-text \
      --app-icon AppIcon --output-partial-info-plist "$TMP/partial.plist" \
      --minimum-deployment-target 15.0 --target-device mac --platform macosx "$CATALOG"
    # Xcode's layout: a compiled Assets.car file and a sibling .icns, both flat in Resources.
    mv "$TMP/out/Assets.car" "$APP/Contents/Resources/Assets.car"
    mv "$TMP/out/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    ICON_PLIST="$(cat "$TMP/partial.plist")"
    rm -rf "$TMP"
  else
    echo "warning: actool not found; bundling without a compiled asset catalog (icon will be the generic one)" >&2
    ICON_PLIST=""
  fi
else
  echo "error: $CATALOG is missing; run scripts/make-icons.sh" >&2; exit 1
fi

# Tiny pre-encoded clip the demo mode (-demoSwarm YES) falls back to on Macs with no video encoder.
[ -f "$ROOT/Tests/MarqueePlayerTests/Fixtures/test-clip.mp4" ] && cp "$ROOT/Tests/MarqueePlayerTests/Fixtures/test-clip.mp4" "$APP/Contents/Resources/demo-clip.mp4"

# actool hands back the icon keys; splice them in so a hand-written Info.plist can't drift from
# what the catalog actually produced.
PLIST_BODY="${ICON_PLIST:-<dict/>}"
PLIST_BODY="${PLIST_BODY#*<dict>}"
PLIST_BODY="${PLIST_BODY%%</dict>*}"
PLIST_BODY="$(printf '%s' "$PLIST_BODY" | sed '/^[[:space:]]*$/d')"
if [ -n "$PLIST_BODY" ]; then PLIST_BODY="$PLIST_BODY
"; fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
$PLIST_BODY  <key>CFBundleName</key><string>Marquee</string>
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
