<p align="center"><img src="docs/icon.png" width="128" alt="Claude Notch Icon"></p>

<h1 align="center">Claude Notch</h1>

<p align="center">Ein orangener Rand um den Notch deines MacBooks, der aufklappt sobald Claude dich braucht.</p>

Claude Notch ist eine kleine, kostenlose Mac App für die Menüleiste. Sie zeigt dir am Notch (oder oben rechts auf einem externen Bildschirm) was Claude Code gerade macht. Wenn Claude eine Freigabe braucht oder eine Frage hat, klappt der Notch mit einer Animation auf und du kannst direkt dort antworten. Das funktioniert auch über Vollbild-Apps und Filmen.

> Inoffizielles Hobbyprojekt. Nicht von Anthropic und nicht mit Anthropic verbunden.

## Was die App kann

| Zustand | Am Notch | Auf Bildschirmen ohne Notch |
|---|---|---|
| Ruhe | dünner orangener Rand um den Notch | kleines Maskottchen oben rechts |
| Claude arbeitet | Notch wird breiter, links dreht sich ein Funke, rechts läuft das Maskottchen | Pille mit aktueller Aktion |
| Claude braucht eine Freigabe | Notch klappt auf, pulsiert und zeigt Befehl mit **Erlauben / Immer erlauben / Ablehnen / Im Terminal** | gleiche Karte oben rechts |
| Claude hat eine Frage | Frage und Antwortmöglichkeiten | gleich |
| Claude ist fertig | kurze Einblendung „Fertig“ mit Ton | gleich |
| Claude App wird gestartet | kurze Begrüßung | gleich |

Weitere Punkte

* Bleibt immer im Vordergrund, auch in Vollbild-Spaces und über Videos.
* Erkennt automatisch ob ein Notch da ist. Bei zugeklapptem MacBook an Monitor, Maus und Tastatur erscheint die Anzeige oben rechts (oder oben mittig, umstellbar im Menü).
* Mit der Maus über den Notch fahren zeigt alle laufenden Claude Code Sitzungen.
* Mehrere Sitzungen gleichzeitig, jeweils mit Projektname.
* Alles einstellbar über das ✦ Symbol in der Menüleiste. Dort gibt es auch **Demo abspielen**, um alle Animationen ohne Claude zu sehen.
* Wenn die App nicht läuft, merkt Claude Code nichts davon und fragt ganz normal im Terminal.

## Installation nur für dich (empfohlen)

Du baust die App selbst aus dem Quellcode. Das kostet nichts und macOS zeigt keine Warnung, weil die App auf deinem Mac entstanden ist.

```bash
# 1. Einmalig die kostenlosen Entwicklerwerkzeuge von Apple installieren
xcode-select --install

# 2. Projekt holen und installieren
git clone -b claude-notch https://github.com/JakobWeigand/Allgemein.git claude-notch
cd claude-notch
./scripts/install.sh
```

Beim ersten Start fragt die App, ob sie sich mit Claude Code verbinden soll. Mit **Verbinden** trägt sie einen Hook in `~/.claude/settings.json` ein (vorher wird `settings.json.claude-notch-backup` angelegt). Laufende Claude Code Sitzungen einmal neu starten, danach meldet sich Claude am Notch.

Damit die App nach jedem Neustart läuft, im Menü **Beim Anmelden starten** anhaken.

Aktualisieren geht mit `git pull && ./scripts/install.sh`. Entfernen mit `./scripts/uninstall.sh`.

## Öffentlich teilen

1. Auf GitHub ein neues öffentliches Repository anlegen, z.B. `claude-notch`.
2. Diesen Branch dorthin schieben
   ```bash
   git remote add public https://github.com/JakobWeigand/claude-notch.git
   git push public claude-notch:main
   ```
3. Für eine fertige Download-Version einen Tag setzen. GitHub Actions baut dann automatisch eine Universal-App (Apple Silicon und Intel) und hängt sie als Release an. Für öffentliche Repositories ist das kostenlos.
   ```bash
   git tag v0.1.0 && git push public v0.1.0
   ```

Andere laden dann `ClaudeNotch.zip` aus den Releases. Weil die App nicht von Apple notarisiert ist (das kostet 99 $ im Jahr), muss man sie beim ersten Mal per Rechtsklick → **Öffnen** starten oder einmal `xattr -dr com.apple.quarantine "/Applications/Claude Notch.app"` ausführen. Wer keine fremden Programme starten möchte, baut wie oben selbst aus dem Quellcode.

## Sicherheit

Die App braucht keinen Server, kein Konto und kein Internet. Alles bleibt auf deinem Mac.

* Claude Code ruft bei jedem Ereignis `~/.claude-notch/hook.sh` auf. Das Skript schickt die Daten an die App, die **nur auf 127.0.0.1** lauscht. Aus dem Netzwerk ist sie nicht erreichbar.
* Bei jedem App-Start entsteht ein neuer zufälliger Token (256 Bit) in `~/.claude-notch/auth-header` mit Rechten `600`. Nur dein Benutzer kann ihn lesen. Anfragen ohne passenden Token lehnt die App ab. So kann kein anderes Programm oder anderer Benutzer heimlich Freigaben erteilen.
* Der Token steht nie in der Befehlszeile und damit auch nicht in der Prozessliste.
* Läuft die App nicht oder antwortest du nicht innerhalb der Wartezeit (Standard 10 Minuten), gibt der Hook keine Entscheidung zurück. Claude Code fragt dann wie gewohnt im Terminal. Es wird also nie automatisch etwas erlaubt.
* Im öffentlichen Repository liegen keine Geheimnisse. Jeder Nutzer bekommt seinen eigenen Token.
* „Immer erlauben“ übernimmt genau die Regel, die Claude Code selbst vorschlägt.

## Wie es funktioniert

```
Claude Code ──Hook──▶ ~/.claude-notch/hook.sh ──HTTP 127.0.0.1 + Token──▶ Claude Notch.app
     ▲                                                                       │
     └──────────────── Antwort (Erlauben / Ablehnen / Antwort) ◀─────────────┘
```

Genutzte Hook-Ereignisse sind `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest`, `Notification`, `Stop`, `StopFailure` und `SessionEnd`. Die Hooks gelten für Claude Code im Terminal, in der IDE und im Code-Tab der Claude Desktop App.

## Grenzen

* Normale Chats in der Claude Desktop App bieten keine Schnittstelle. Hier erkennt die App nur, dass Claude geöffnet wurde (Begrüßung und Rand). Freigaben und Fragen kommen aus Claude Code.
* Fragen über `AskUserQuestion` im Notch zu beantworten ist experimentell und standardmäßig aus. Dann zeigt der Notch die Frage an und du antwortest im Terminal.
* Benötigt macOS 13 Ventura oder neuer.

## Selbst entwickeln

```bash
swift build            # schneller Test-Build
swift run              # direkt starten
./scripts/build-app.sh # fertige .app in dist/
```

Der Code liegt in `Sources/ClaudeNotch`

* `NotchView.swift` Aussehen und Animationen
* `NotchModel.swift` Zustände und Verarbeitung der Claude Code Ereignisse
* `NotchWindow.swift` Fenster über allem, Bildschirmerkennung, Maus
* `EventServer.swift` lokaler Server mit Token-Prüfung
* `HookInstaller.swift` Hook-Skript und Eintrag in `~/.claude/settings.json`
* `Mascot.swift` das kleine Pixel-Maskottchen
