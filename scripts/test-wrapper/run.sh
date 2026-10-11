#!/bin/bash
# Prüft das Start-Skript für Positron und VS Code (Sources/Notchwerk/EditorWrapperScript.swift) mit einer
# Attrappe von claude, ganz ohne deine Konten: Durchreichen, Wechsel bei einem Limit, gesperrtes
# Ausweichkonto, Start beim anderen Konto, SIGTERM. Jeder Fall läuft in einem eigenen HOME in einem
# temporären Ordner.
#
#   ./scripts/test-wrapper/run.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
TMP="$(mktemp -d -t notchwerk-wrapper-test)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Die Skripte aus dem Swift-Quelltext holen, genau so, wie die App sie schreibt.
cat > "$TMP/main.swift" <<'SWIFT'
import Foundation
let dir = CommandLine.arguments[1]
try! Data(EditorWrapperScript.shell.utf8).write(to: URL(fileURLWithPath: dir + "/claude-wrapper"))
try! Data(EditorWrapperScript.python.utf8).write(to: URL(fileURLWithPath: dir + "/claude-wrapper.py"))
SWIFT
DEV="$(xcode-select -p 2>/dev/null || true)"
SDK=""
if [ "$DEV" = "/Library/Developer/CommandLineTools" ]; then
  for sdk in $(ls -d "$DEV"/SDKs/MacOSX26*.sdk 2>/dev/null | sort -r); do SDK="$sdk"; break; done
fi
SDKROOT="${SDKROOT:-$SDK}" swiftc -o "$TMP/extract" "$TMP/main.swift" Sources/Notchwerk/EditorWrapperScript.swift
"$TMP/extract" "$TMP/bin"
chmod 700 "$TMP/bin/claude-wrapper" "$TMP/bin/claude-wrapper.py" scripts/test-wrapper/fake_claude.py

WRAP_BIN="$TMP/bin" WRAP_TMP="$TMP" python3 scripts/test-wrapper/drive.py
