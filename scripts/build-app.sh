#!/bin/bash
# Baut "Claude Notch.app" in den Ordner dist/.
# Voraussetzung: Xcode oder die Command Line Tools (xcode-select --install). Beides ist kostenlos.
#
#   ./scripts/build-app.sh                       # für deinen Mac
#   ARCHS="arm64 x86_64" ./scripts/build-app.sh  # Universal (Apple Silicon + Intel), braucht Xcode
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
ARGS=(-c release)
for arch in ${ARCHS:-}; do ARGS+=(--arch "$arch"); done

echo "▸ Baue Claude Notch $VERSION …"
swift build "${ARGS[@]}"
BIN="$(swift build "${ARGS[@]}" --show-bin-path)/ClaudeNotch"

APP="dist/Claude Notch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeNotch"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"

if command -v iconutil >/dev/null 2>&1; then
  iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc Signatur: kostenlos, kein Apple Developer Account nötig.
codesign --force --deep --sign - "$APP"
echo "✓ Fertig: $APP"
