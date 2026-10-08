#!/bin/bash
# Baut "Notchwerk.app" in den Ordner dist/.
# Voraussetzung: Xcode oder die Command Line Tools (xcode-select --install). Beides ist kostenlos.
#
#   ./scripts/build-app.sh                       # für deinen Mac
#   ARCHS="arm64 x86_64" ./scripts/build-app.sh  # Universal (Apple Silicon + Intel), braucht Xcode
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.3.0}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
ARGS=(-c release)
for arch in ${ARCHS:-}; do ARGS+=(--arch "$arch"); done

echo "▸ Baue Notchwerk $VERSION …"
if ! swift build "${ARGS[@]}"; then
  # Nur Command Line Tools, kein Xcode: Das neueste SDK verlangt ein SwiftUI-Makro-Plugin,
  # das erst Xcode mitbringt. Mit dem vorherigen SDK klappt es.
  for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -r); do
    echo "▸ Erneut mit $(basename "$sdk") …"
    ARGS+=(--scratch-path ".build/$(basename "$sdk")")
    export SDKROOT="$sdk"
    swift build "${ARGS[@]}" && break
    unset SDKROOT
    unset 'ARGS[-1]'; unset 'ARGS[-1]'
  done
  [ -n "${SDKROOT:-}" ] || { echo "✗ Build fehlgeschlagen"; exit 1; }
fi
BIN="$(swift build "${ARGS[@]}" --show-bin-path)/Notchwerk"

APP="dist/Notchwerk.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Notchwerk"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"

if command -v iconutil >/dev/null 2>&1; then
  iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc Signatur: kostenlos, kein Apple Developer Account nötig.
codesign --force --deep --sign - "$APP"
echo "✓ Fertig: $APP"
