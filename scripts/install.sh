#!/bin/bash
# Baut die App aus dem Quellcode und installiert sie nach /Applications.
# Weil du selbst baust, gibt es keine Gatekeeper-Warnung.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Bitte zuerst die kostenlosen Command Line Tools installieren:"
  echo "  xcode-select --install"
  exit 1
fi

./scripts/build-app.sh

TARGET="/Applications/Notchwerk.app"
osascript -e 'tell application "Notchwerk" to quit' >/dev/null 2>&1 || true
pkill -x Notchwerk >/dev/null 2>&1 || true
pkill -x ClaudeNotch >/dev/null 2>&1 || true
rm -rf "/Applications/Claude Notch.app"
sleep 0.5
rm -rf "$TARGET"
cp -R "dist/Notchwerk.app" "$TARGET"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
open "$TARGET"
echo "✓ Notchwerk läuft. Das ✦ Symbol findest du in der Menüleiste."
