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

# Tiny pre-encoded clip the demo mode (-demoSwarm YES) falls back to on Macs with no video encoder.
[ -f "$ROOT/Tests/MarqueePlayerTests/Fixtures/test-clip.mp4" ] && cp "$ROOT/Tests/MarqueePlayerTests/Fixtures/test-clip.mp4" "$APP/Contents/Resources/demo-clip.mp4"

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
