#!/bin/bash
# Entfernt Notchwerk, die Hooks aus den settings.json aller Konten (~/.claude, ~/.claude-arbeit …)
# und ~/.claude-notch. Konten in Ordnern außerhalb des Home-Ordners bitte vorher in der App trennen.
set -euo pipefail
pkill -x Notchwerk >/dev/null 2>&1 || true
pkill -x ClaudeNotch >/dev/null 2>&1 || true

for SETTINGS in "$HOME"/.claude/settings.json "$HOME"/.claude[-_]*/settings.json; do
  [ -f "$SETTINGS" ] && grep -q ".claude-notch/hook.sh" "$SETTINGS" || continue
  cp "$SETTINGS" "$SETTINGS.claude-notch-backup"
  SETTINGS="$SETTINGS" /usr/bin/osascript -l JavaScript <<'JXA'
ObjC.import('Foundation');
ObjC.import('stdlib');
const path = $.getenv('SETTINGS');
const text = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null));
const root = JSON.parse(text);
const hooks = root.hooks || {};
for (const name of Object.keys(hooks)) {
  hooks[name] = hooks[name].filter(e => !(e.hooks || []).some(h => (h.command || '').includes('.claude-notch/hook.sh')));
  if (hooks[name].length === 0) delete hooks[name];
}
if (Object.keys(hooks).length === 0) delete root.hooks;
$(JSON.stringify(root, null, 2)).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
JXA
  echo "✓ Hooks entfernt aus $SETTINGS (Sicherung: $SETTINGS.claude-notch-backup)"
done

rm -rf "$HOME/.claude-notch"
rm -rf "/Applications/Notchwerk.app" "/Applications/Claude Notch.app"
defaults delete io.github.jakobweigand.claude-notch >/dev/null 2>&1 || true
echo "✓ Notchwerk entfernt"
