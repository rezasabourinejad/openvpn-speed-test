#!/usr/bin/env bash
#
# Package the built app into a distributable .dmg with a drag-to-Applications layout.
#
# Usage:
#   scripts/make-dmg.sh [version]      # default version: dev
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="OpenVPN Speed Test"
APP="$ROOT/dist/$APP_NAME.app"
VERSION="${1:-dev}"
DMG="$ROOT/dist/OpenVPN-Speed-Test-${VERSION}-universal.dmg"

if [[ ! -d "$APP" ]]; then
    echo "App bundle not found — building it first."
    "$ROOT/scripts/build-app.sh"
fi

STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
echo "▶︎ Building DMG: $DMG"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG" >/dev/null

rm -rf "$STAGING"
echo "✓ Built: $DMG"
du -h "$DMG" | cut -f1 | xargs echo "  size:"
