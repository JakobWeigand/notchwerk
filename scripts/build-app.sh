#!/bin/bash
# Baut "Notchwerk.app" in den Ordner dist/.
# Voraussetzung: Xcode oder die Command Line Tools (xcode-select --install). Beides ist kostenlos.
#
#   ./scripts/build-app.sh                       # für deinen Mac
#   ARCHS="arm64 x86_64" ./scripts/build-app.sh  # Universal (Apple Silicon + Intel), braucht Xcode
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.7.2}"
# Fortlaufend, bei jedem Build größer: Minuten seit 1.1.2026. macOS merkt sich die Widgets je
# Build-Nummer und übernimmt neue Widgets erst mit einer höheren. Kurz, weil zu lange Nummern stören.
BUILD="${BUILD:-$(( ($(date +%s) - 1767225600) / 60 ))}"
# Commit für „Nach Updates suchen“ in der App, mit -dirty bei ungesicherten Änderungen.
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || true)"
if [ -n "$COMMIT" ] && [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then COMMIT="$COMMIT-dirty"; fi
ARGS=(-c release)
for arch in ${ARCHS:-}; do ARGS+=(--arch "$arch"); done

# Nur Command Line Tools, kein Xcode? Deren neuestes SDK verlangt ein SwiftUI-Makro-Plugin,
# das erst Xcode mitbringt. Dann gleich das vorherige SDK nehmen, statt erst in den Fehler zu laufen.
DEV="$(xcode-select -p 2>/dev/null || true)"
if [ -z "${SDKROOT:-}" ] && [ "$DEV" = "/Library/Developer/CommandLineTools" ] \
   && [ ! -f "$DEV/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]; then
  for sdk in $(ls -d "$DEV"/SDKs/MacOSX26*.sdk 2>/dev/null | sort -r); do
    export SDKROOT="$sdk"
    ARGS+=(--scratch-path ".build/$(basename "$sdk")")
    echo "▸ Command Line Tools ohne Xcode erkannt, nutze $(basename "$sdk")"
    break
  done
fi

echo "▸ Baue Notchwerk $VERSION …"
LOG="$(mktemp -t notchwerk-build)"
if ! swift build "${ARGS[@]}" >"$LOG" 2>&1; then
  # Letzter Versuch mit den anderen verfügbaren SDKs.
  OK=""
  for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -r); do
    [ "${SDKROOT:-}" = "$sdk" ] && continue
    echo "▸ Erneut mit $(basename "$sdk") …"
    export SDKROOT="$sdk"
    ARGS+=(--scratch-path ".build/$(basename "$sdk")")
    if swift build "${ARGS[@]}" >"$LOG" 2>&1; then OK=1; break; fi
    # Die beiden zuletzt angehängten Argumente wieder weg. Ohne negative Indizes, die kennt
    # die Bash 3.2 von macOS nicht.
    ARGS=("${ARGS[@]:0:${#ARGS[@]}-2}")
  done
  if [ -z "$OK" ]; then
    cat "$LOG"
    echo "✗ Build fehlgeschlagen. Mit Xcode (kostenlos im App Store) klappt es in jedem Fall."
    exit 1
  fi
fi
grep -E "Compiling|Build complete" "$LOG" | tail -1
rm -f "$LOG"
BIN_DIR="$(swift build "${ARGS[@]}" --show-bin-path)"

# Die Widgets starten nur über den Einstieg für Erweiterungen (siehe Package.swift).
# Ohne -q: grep würde sonst früh abbrechen, nm bekäme SIGPIPE und pipefail meldete einen Fehler.
if ! nm -m "$BIN_DIR/NotchwerkWidgets" | grep "_NSExtensionMain (from Foundation)" >/dev/null; then
  echo "✗ Den Widgets fehlt der Einstieg _NSExtensionMain, macOS würde sie nicht anbieten."
  exit 1
fi

APP="dist/Notchwerk.app"
APPEX="$APP/Contents/PlugIns/NotchwerkWidgets.appex"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS"
cp "$BIN_DIR/Notchwerk" "$APP/Contents/MacOS/Notchwerk"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" -e "s/__COMMIT__/$COMMIT/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp "$BIN_DIR/NotchwerkWidgets" "$APPEX/Contents/MacOS/NotchwerkWidgets"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Widgets-Info.plist > "$APPEX/Contents/Info.plist"

if command -v iconutil >/dev/null 2>&1; then
  iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc Signatur: kostenlos, kein Apple Developer Account nötig. Von innen nach außen und
# ohne --deep: --deep würde den Widgets ihre Sandbox-Berechtigung nehmen, dann ignoriert macOS sie.
codesign --force --sign - --timestamp=none --entitlements Resources/Widgets.entitlements "$APPEX"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
echo "✓ Fertig: $APP"
