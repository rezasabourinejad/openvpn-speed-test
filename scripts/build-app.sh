#!/usr/bin/env bash
#
# Build a universal (Apple Silicon + Intel) "OpenVPN Speed Test.app" bundle.
#
# Usage:
#   scripts/build-app.sh            # universal release build → dist/OpenVPN Speed Test.app
#   ARCHS="arm64" scripts/build-app.sh   # single-arch (faster, for local dev)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="OpenVPN Speed Test"
PRODUCT="OVPNSpeedTestApp"
BUNDLE_ID="com.ovpnspeedtest.app"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

# Default to a universal binary; override with ARCHS="arm64" for a quick local build.
ARCHS="${ARCHS:-arm64 x86_64}"
ARCH_FLAGS=()
for a in $ARCHS; do ARCH_FLAGS+=("--arch" "$a"); done

echo "▶︎ Building $PRODUCT (release) for: $ARCHS"
swift build -c release "${ARCH_FLAGS[@]}" --product "$PRODUCT"

# Locate the produced binary (universal builds land under .build/apple/...).
BIN=""
for candidate in \
    ".build/apple/Products/Release/$PRODUCT" \
    ".build/release/$PRODUCT"; do
    if [[ -f "$candidate" ]]; then BIN="$candidate"; break; fi
done
if [[ -z "$BIN" ]]; then
    BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --product "$PRODUCT" --show-bin-path)/$PRODUCT"
fi
echo "▶︎ Binary: $BIN"
file "$BIN" || true

echo "▶︎ Assembling bundle: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$PRODUCT"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns" && \
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true

# Ad-hoc codesign so Gatekeeper lets it run locally.
echo "▶︎ Ad-hoc signing"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (codesign skipped)"

echo "✓ Built: $APP"
echo "  Open with:  open \"$APP\""
