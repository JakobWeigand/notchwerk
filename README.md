<p align="center"><img src="docs/icon.png" width="128" alt="Claude Notch Icon"></p>

<h1 align="center">Claude Notch</h1>

<p align="center">Ein orangener Rand um den Notch deines MacBooks, der aufklappt sobald Claude dich braucht.</p>

Claude Notch ist eine kleine, kostenlose Mac App für die Menüleiste. Sie zeigt dir am Notch (oder oben rechts auf einem externen Bildschirm) was Claude Code gerade macht. Wenn Claude eine Freigabe braucht oder eine Frage hat, klappt der Notch mit einer Animation auf und du kannst direkt dort antworten. Das funktioniert auch über Vollbild-Apps und Filmen.

> Inoffizielles Hobbyprojekt. Nicht von Anthropic und nicht mit Anthropic verbunden.

## Was die App kann

| Zustand | Am Notch | Auf Bildschirmen ohne Notch |
|---|---|---|
| Ruhe | dünner orangener Rand um den Notch | Claude-Funke oben rechts, Klick öffnet die Liste |
| Claude arbeitet | Notch wird breiter, links dreht sich ein Funke, rechts läuft das Maskottchen. Überfahren zeigt die Sitzungen, die gerade arbeiten | Pille mit aktueller Aktion, Klick zeigt die Sitzungen |
| Claude braucht eine Freigabe | Notch klappt auf, pulsiert und zeigt Befehl mit **Erlauben / Immer erlauben / Ablehnen / Im Terminal** | gleiche Karte oben rechts |
| Claude hat eine Frage | Frage und Antwortmöglichkeiten | gleich |
| Claude ist fertig | kurze Einblendung „Fertig“ mit Ton, die Zeile verschwindet kurz danach | gleich |
| Claude App wird gestartet | kurze Begrüßung | gleich |

Weitere Punkte

* Bleibt immer im Vordergrund, auch in Vollbild-Spaces und über Videos.
* Erkennt automatisch ob ein Notch da ist. Bei zugeklapptem MacBook an Monitor, Maus und Tastatur erscheint die Anzeige oben rechts (oder oben mittig, umstellbar im Menü).
* Es wird nur gezeigt, was gerade passiert: Sitzungen, die arbeiten oder dich brauchen. Fertige Sitzungen verschwinden wieder. „Wartet“ steht nur da, wenn Claude wirklich eine Freigabe oder Antwort braucht.
* Jede Zeile zeigt, woher die Sitzung kommt: **Terminal**, **VS Code**, **Claude App** (dort mit dem Chat-Titel). Ein Klick auf die Zeile holt genau dieses Fenster nach vorn: den Tab im Terminal, das Projektfenster in VS Code oder den Chat in der Claude App.
* Die Liste erscheint beim Überfahren des Notch (oben rechts per Klick auf den Funken) und verschwindet, sobald die Maus wieder weg ist. Bis zu zwei Zeilen sind sofort zu sehen, bei mehr lässt sich scrollen. Wer die Zeilen dauerhaft unter dem Notch sehen will, schaltet im Menü **Arbeitende Sitzungen unter dem Notch zeigen** ein.
* Unten in der aufgeklappten Liste steht die Nutzung wie bei `/usage`: Ringe für das Sitzungslimit (5 Stunden) und das Wochenlimit, mit dem Anteil, der noch frei ist, und wann sich das Limit zurücksetzt.
* Der Abstand des orangenen Rands unter dem Notch ist einstellbar (Standard 1 mm), damit der echte Notch nicht hervorschaut.
* **Einstellungen** gibt es als eigenes Fenster: über das Zahnrad oben links in der aufgeklappten Liste oder über das ✦ Symbol in der Menüleiste. Dort lässt sich alles ein- und ausschalten, auch die ganze Anzeige auf einmal („Claude Notch eingeschaltet“). Pausiert fragt Claude Code wie gewohnt im Terminal.
* **Schwebender Reiter** statt Notch: In den Einstellungen unter „Anzeigeart“ wählbar. Der kleine Funke lässt sich mit der Maus an eine beliebige Stelle ziehen, bleibt im Vordergrund, wandert auf jeden Schreibtisch mit und öffnet die Liste beim Überfahren. Praktisch, wenn der Notch beim Surfen zu leicht ausgelöst wird.
* Abgebrochene Sitzungen (Esc, Stopp, Fenster zu) verschwinden von selbst: Die App merkt, wenn der Claude Code Prozess weg ist oder im Transkript „[Request interrupted by user]“ steht.
* Im ✦ Menü stehen die aktiven Sitzungen zum Anklicken, und **Demo abspielen** zeigt alle Animationen ohne Claude.
* Wenn die App nicht läuft, merkt Claude Code nichts davon und fragt ganz normal im Terminal.

## Schnellstart ohne Kompilieren

1. Unter [Releases](https://github.com/JakobWeigand/claude-notch/releases/latest) die neueste `ClaudeNotch.zip` herunterladen.
2. Terminal öffnen und diese eine Zeile einfügen
   ```bash
   cd ~/Downloads && { [ -d "Claude Notch.app" ] || ditto -x -k ClaudeNotch.zip .; } && rm -rf "/Applications/Claude Notch.app" && mv "Claude Notch.app" /Applications/ && xattr -dr com.apple.quarantine "/Applications/Claude Notch.app" && open "/Applications/Claude Notch.app"
   ```
3. Im Fenster „Mit Claude Code verbinden?“ auf **Verbinden** klicken.

Die App startet ab jetzt automatisch beim Anmelden.

## Installation aus dem Quellcode

Du baust die App selbst aus dem Quellcode. Das kostet nichts und macOS zeigt keine Warnung, weil die App auf deinem Mac entstanden ist.

```bash
# 1. Einmalig die kostenlosen Entwicklerwerkzeuge von Apple installieren
xcode-select --install

# 2. Projekt holen und installieren
git clone https://github.com/JakobWeigand/claude-notch.git
cd claude-notch
./scripts/install.sh
```

Beim ersten Start fragt die App, ob sie sich mit Claude Code verbinden soll. Mit **Verbinden** trägt sie einen Hook in `~/.claude/settings.json` ein (vorher wird `settings.json.claude-notch-backup` angelegt). Laufende Claude Code Sitzungen einmal neu starten, danach meldet sich Claude am Notch.

Damit die App nach jedem Neustart läuft, im Menü **Beim Anmelden starten** anhaken.

Aktualisieren geht mit `git pull && ./scripts/install.sh`. Entfernen mit `./scripts/uninstall.sh`.

## Neue Download-Version

Ein Tag genügt. GitHub Actions baut daraus automatisch eine Universal-App (Apple Silicon und Intel) und hängt sie unter **Releases** an.

```bash
git tag v0.2.1 && git push origin v0.2.1
```

Weil die App nicht von Apple notarisiert ist (das kostet 99 $ im Jahr), muss man sie beim ersten Mal per Rechtsklick → **Öffnen** starten oder einmal `xattr -dr com.apple.quarantine "/Applications/Claude Notch.app"` ausführen. Die Zeile im Schnellstart erledigt das schon. Wer keine fremden Programme starten möchte, baut wie oben selbst aus dem Quellcode.

## Sicherheit

Die App braucht keinen Server, kein Konto und kein Internet. Alles bleibt auf deinem Mac.

* Claude Code ruft bei jedem Ereignis `~/.claude-notch/hook.sh` auf. Das Skript schickt die Daten an die App, die **nur auf 127.0.0.1** lauscht. Aus dem Netzwerk ist sie nicht erreichbar.
* Bei jedem App-Start entsteht ein neuer zufälliger Token (256 Bit) in `~/.claude-notch/auth-header` mit Rechten `600`. Nur dein Benutzer kann ihn lesen. Anfragen ohne passenden Token lehnt die App ab. So kann kein anderes Programm oder anderer Benutzer heimlich Freigaben erteilen.
* Der Token steht nie in der Befehlszeile und damit auch nicht in der Prozessliste.
* Läuft die App nicht oder antwortest du nicht innerhalb der Wartezeit (Standard 10 Minuten), gibt der Hook keine Entscheidung zurück. Claude Code fragt dann wie gewohnt im Terminal. Es wird also nie automatisch etwas erlaubt.
* Im öffentlichen Repository liegen keine Geheimnisse. Jeder Nutzer bekommt seinen eigenen Token.
* „Immer erlauben“ übernimmt genau die Regel, die Claude Code selbst vorschlägt.
* Für die Nutzungsanzeige liest die App den Anmelde-Token von Claude Code aus dem Schlüsselbund („Claude Code-credentials“). macOS fragt dabei nach; mit **Immer erlauben** nie wieder, mit **Erlauben** höchstens einmal pro App-Start, weil der Token danach im Speicher bleibt. Abgefragt wird nur beim Öffnen der Liste, nie im Hintergrund. Der Token geht nur an `api.anthropic.com`, an dieselbe Stelle, die auch `/usage` in Claude Code abfragt, und wird nirgends gespeichert. Wer das nicht möchte, schaltet **Nutzung zeigen** im Menü aus oder klickt bei der Nachfrage auf „Nicht erlauben“.

## Wie es funktioniert

```
Claude Code ──Hook──▶ ~/.claude-notch/hook.sh ──HTTP 127.0.0.1 + Token──▶ Claude Notch.app
     ▲                                                                       │
     └──────────────── Antwort (Erlauben / Ablehnen / Antwort) ◀─────────────┘
```

Genutzte Hook-Ereignisse sind `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest`, `Notification`, `Stop`, `StopFailure` und `SessionEnd`. Die Hooks gelten für Claude Code im Terminal, in der IDE und im Code-Tab der Claude Desktop App.

Woher eine Sitzung kommt, liest `hook.sh` aus der Prozesskette (welche App hat Claude Code gestartet) und schickt sie als Kopfzeile mit. Für Chats im Code-Tab der Desktop App findet die App über `~/Library/Application Support/Claude/claude-code-sessions/` den Chat-Titel und den Link, der genau diesen Chat öffnet. Beim ersten Klick auf eine Terminal-Sitzung fragt macOS einmal, ob Claude Notch das Terminal steuern darf (nur dafür, den richtigen Tab auszuwählen).

## Grenzen

* Normale Chats in der Claude Desktop App und auf claude.ai im Browser bieten keine Schnittstelle. Hier erkennt die App nur, dass Claude geöffnet wurde (Begrüßung und Rand). Ob dort gerade eine Antwort entsteht, lässt sich von außen nicht zuverlässig erkennen. Angezeigt wird alles aus Claude Code: Terminal, VS Code und der Code-Tab der Desktop App.
* In VS Code holt der Klick das Fenster nach vorn, in dem der Projektordner offen ist. Läuft Claude Code dort in einem Unterordner, öffnet VS Code diesen Ordner in einem neuen Fenster.
* Fragen über `AskUserQuestion` im Notch zu beantworten ist experimentell und standardmäßig aus. Dann zeigt der Notch die Frage an und du antwortest im Terminal.
* Benötigt macOS 13 Ventura oder neuer.

## Selbst entwickeln

```bash
swift build            # schneller Test-Build
swift run              # direkt starten
./scripts/build-app.sh # fertige .app in dist/
```

Nur Command Line Tools ohne Xcode? Dann kann `swift build` mit dem neuesten SDK an `@State` scheitern (dem SDK fehlt das SwiftUI-Makro-Plugin, das erst Xcode mitbringt). `build-app.sh` weicht dann automatisch auf das vorherige SDK aus. Von Hand geht das so:

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk swift build
```

Der Code liegt in `Sources/ClaudeNotch`

* `NotchView.swift` Aussehen und Animationen
* `SettingsWindow.swift` das Einstellungsfenster
* `NotchModel.swift` Zustände und Verarbeitung der Claude Code Ereignisse
* `NotchWindow.swift` Fenster über allem, Bildschirmerkennung, Maus
* `Geometry.swift` Größen und welcher Zustand gerade gezeigt wird
* `SessionOrigin.swift` Terminal, VS Code oder Claude App? (aus der Prozesskette)
* `DesktopSessions.swift` Chat-Titel und Link für Sitzungen aus der Claude Desktop App
* `SessionFocus.swift` holt beim Klick das richtige Fenster nach vorn
* `Usage.swift` Nutzung (Sitzungs- und Wochenlimit) wie bei `/usage`
* `EventServer.swift` lokaler Server mit Token-Prüfung
* `HookInstaller.swift` Hook-Skript und Eintrag in `~/.claude/settings.json`
* `Mascot.swift` das kleine Pixel-Maskottchen
