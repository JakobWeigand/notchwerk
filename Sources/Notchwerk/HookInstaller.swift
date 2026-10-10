import Foundation

/// Richtet die Verbindung zwischen Claude Code und der App ein.
///
/// Alles bleibt lokal auf deinem Mac:
/// - ~/.claude-notch/hook.sh   kleines Skript, das Claude Code bei jedem Ereignis aufruft
/// - ~/.claude-notch/port      Port des lokalen Servers (nur 127.0.0.1)
/// - ~/.claude-notch/auth-header geheimer Token, bei jedem App-Start neu, nur für dich lesbar
enum HookInstaller {
    static let fm = FileManager.default
    static var home: URL { fm.homeDirectoryForCurrentUser }
    static var dir: URL { home.appendingPathComponent(".claude-notch", isDirectory: true) }
    static var scriptURL: URL { dir.appendingPathComponent("hook.sh") }
    static var portURL: URL { dir.appendingPathComponent("port") }
    static var headerURL: URL { dir.appendingPathComponent("auth-header") }

    /// Ereignis, Sekunden bis curl aufgibt, Timeout für Claude Code.
    static let events: [(name: String, maxTime: Int, timeout: Int)] = [
        ("SessionStart", 2, 5),
        ("UserPromptSubmit", 2, 5),
        ("PreToolUse", 2, 3600),       // lang nur für AskUserQuestion, siehe hook.sh
        ("PostToolUse", 2, 5),
        ("PermissionRequest", 3590, 3600),
        ("Notification", 2, 5),
        // Stop darf warten: auf eine Antwort im Notch (erweiterte Einstellung). Die App antwortet sofort,
        // wenn das aus ist; hook.sh hebt die Wartezeit nur für Stop an, siehe dort.
        ("Stop", 2, stopTimeout),
        ("StopFailure", 2, 5),
        ("SessionEnd", 1, 2),
    ]

    /// Sekunden, die hook.sh bei Stop höchstens auf die App wartet, und die Grenze für Claude Code.
    /// Muss über der längsten Wahl in `Preferences.replyWindowChoices` liegen.
    static let stopMaxTime = 320
    static let stopTimeout = 330

    static let script = """
    #!/bin/bash
    # Notchwerk Hook (Version 4): leitet Claude Code Ereignisse an die Notch App weiter.
    # Läuft die App nicht, passiert nichts und Claude Code arbeitet ganz normal weiter.
    DIR="$HOME/.claude-notch"
    MAX="${1:-2}"
    if [ ! -r "$DIR/port" ] || [ ! -r "$DIR/auth-header" ]; then cat >/dev/null; exit 0; fi
    PORT="$(cat "$DIR/port")"
    case "$PORT" in ''|*[!0-9]*) cat >/dev/null; exit 0 ;; esac
    INPUT="$(cat)"
    # Fragen von Claude (AskUserQuestion) dürfen auf eine Antwort im Notch warten.
    case "$INPUT" in *'"PreToolUse"'*) case "$INPUT" in *'"AskUserQuestion"'*) MAX=3590 ;; esac ;; esac
    # Am Ende darf die App auf eine Antwort im Notch warten (nur wenn das eingeschaltet ist).
    # Das Muster trifft auch "Stop" irgendwo im Text; dann darf curl nur länger warten, die App antwortet trotzdem sofort.
    case "$INPUT" in *'"Stop"'*) MAX=\(stopMaxTime) ;; esac
    # Herkunft: die Prozesskette nach oben. Daran erkennt die App, ob die Sitzung im Terminal,
    # in VS Code oder in der Claude App läuft, und kann beim Klick das richtige Fenster öffnen.
    ORIGIN=""; P=$PPID; set -f
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
      [ "$P" -gt 1 ] 2>/dev/null || break
      LINE="$(/bin/ps -o ppid=,tty=,comm= -p "$P" 2>/dev/null)" || break
      set -- $LINE; [ $# -ge 3 ] || break
      PP="$1"; TTY="$2"; shift 2
      ORIGIN="$ORIGIN$(printf '%s\\t%s\\t%s' "$P" "$TTY" "$*")"$'\\n'
      P="$PP"
    done
    ORIGIN_B64="$(printf '%s' "$ORIGIN" | /usr/bin/base64 | /usr/bin/tr -d '\\n')"
    # Konto: CLAUDE_CONFIG_DIR genau so, wie Claude Code es sieht ("1:<Pfad>" gesetzt, ":" nicht gesetzt).
    CONFIG_B64="$(printf '%s' "${CLAUDE_CONFIG_DIR+1}:${CLAUDE_CONFIG_DIR-}" | /usr/bin/base64 | /usr/bin/tr -d '\\n')"
    printf '%s' "$INPUT" | /usr/bin/curl -s --fail --connect-timeout 1 --max-time "$MAX" \\
      -H @"$DIR/auth-header" -H 'Content-Type: application/json' \\
      -H "X-Claude-Notch-Origin: $ORIGIN_B64" -H "X-Claude-Notch-Config: $CONFIG_B64" \\
      --data-binary @- "http://127.0.0.1:$PORT/event" 2>/dev/null
    exit 0

    """

    // MARK: - Laufzeitdateien

    static func prepareRuntime(port: UInt16, token: String) {
        do {
            try ensureDir()
            try writePrivate("X-Claude-Notch-Token: \(token)\n", to: headerURL)
            try writePrivate("\(port)\n", to: portURL)
            // Skript aktuell halten, falls die App aktualisiert wurde.
            if fm.fileExists(atPath: scriptURL.path) { try writeScript() }
        } catch {
            NSLog("Notchwerk: Konnte Laufzeitdateien nicht schreiben: \(error)")
        }
    }

    static func cleanupRuntime() {
        try? fm.removeItem(at: portURL)
        try? fm.removeItem(at: headerURL)
    }

    // MARK: - Installation in <Konfigurationsordner>/settings.json

    /// Jedes Konto (jeder Konfigurationsordner) hat seine eigene settings.json. Damit Sitzungen
    /// aller Konten hier erscheinen, kommt der Hook in jede davon.
    @MainActor static var accounts: [ClaudeAccount] { Preferences.shared.accounts }

    /// Mit dem Standardkonto (~/.claude) verbunden. Danach richtet sich die Frage beim ersten Start.
    @MainActor static var isInstalled: Bool { isInstalled(in: .makeDefault()) }

    /// Mit allen eingetragenen Konten verbunden.
    @MainActor static var isInstalledEverywhere: Bool { accounts.allSatisfy(isInstalled(in:)) }

    static func isInstalled(in account: ClaudeAccount) -> Bool {
        guard let data = try? Data(contentsOf: account.settingsURL),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(scriptURL.path)
    }

    enum InstallError: LocalizedError {
        case invalidSettings(String)

        var errorDescription: String? {
            switch self {
            case .invalidSettings(let path):
                return "\(path) ist kein gültiges JSON. Bitte zuerst reparieren, ich ändere sonst nichts."
            }
        }
    }

    /// Mit allen eingetragenen Konten verbinden.
    @MainActor static func install() throws {
        for account in accounts { try install(into: account) }
    }

    /// Bei allen eingetragenen Konten wieder entfernen.
    @MainActor static func uninstall() throws {
        for account in accounts where isInstalled(in: account) { try uninstall(from: account) }
    }

    static func install(into account: ClaudeAccount) throws {
        try ensureDir()
        try writeScript()
        try updateSettings(at: account.settingsURL, display: account.displayPath + "/settings.json") { hooks in
            for e in events {
                var list = hooks[e.name] as? [[String: Any]] ?? []
                list.removeAll(where: isOurs)
                list.append([
                    "hooks": [[
                        "type": "command",
                        "command": command(maxTime: e.maxTime),
                        "timeout": e.timeout,
                    ]],
                ])
                hooks[e.name] = list
            }
        }
    }

    static func uninstall(from account: ClaudeAccount) throws {
        guard fm.fileExists(atPath: account.settingsURL.path) else { return }
        try updateSettings(at: account.settingsURL, display: account.displayPath + "/settings.json") { hooks in
            for (name, value) in hooks {
                guard var list = value as? [[String: Any]] else { continue }
                list.removeAll(where: isOurs)
                hooks[name] = list.isEmpty ? nil : list
            }
        }
    }

    /// Steht in der settings.json noch ein älterer Eintrag von uns (andere Wartezeiten)?
    static func isOutdated(in account: ClaudeAccount) -> Bool {
        guard let data = try? Data(contentsOf: account.settingsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        for e in events {
            let ours = (hooks[e.name] as? [[String: Any]] ?? []).filter(isOurs)
            guard let inner = (ours.first?["hooks"] as? [[String: Any]])?.first else { return true }
            if inner["command"] as? String != command(maxTime: e.maxTime) { return true }
            if (inner["timeout"] as? NSNumber)?.intValue != e.timeout { return true }
        }
        return false
    }

    /// Nach einem Update der App: unsere Einträge bei den schon verbundenen Konten auf den neuen
    /// Stand bringen. Fremde Einträge bleiben unberührt, vorher wird wie immer gesichert.
    @MainActor static func refreshOutdated() {
        for account in accounts where isInstalled(in: account) && isOutdated(in: account) {
            do {
                try install(into: account)
            } catch {
                NSLog("Notchwerk: Hook bei \(account.displayPath) nicht aktualisiert: \(error.localizedDescription)")
            }
        }
    }

    private static func command(maxTime: Int) -> String {
        "\"\(scriptURL.path)\" \(maxTime)"
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        let inner = entry["hooks"] as? [[String: Any]] ?? []
        return inner.contains { ($0["command"] as? String)?.contains(".claude-notch/hook.sh") == true }
    }

    private static func updateSettings(at settingsURL: URL, display: String,
                                       _ change: (inout [String: Any]) -> Void) throws {
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var root: [String: Any] = [:]
        if fm.fileExists(atPath: settingsURL.path) {
            let data = try Data(contentsOf: settingsURL)
            if !data.isEmpty {
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw InstallError.invalidSettings(display)
                }
                root = obj
            }
            // Sicherheitskopie vor jeder Änderung.
            let backup = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.claude-notch-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL, to: backup)
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        change(&hooks)
        root["hooks"] = hooks.isEmpty ? nil : hooks
        let out = try JSONSerialization.data(withJSONObject: root,
                                             options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: settingsURL, options: .atomic)
    }

    // MARK: - Hilfsfunktionen

    private static func ensureDir() throws {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    private static func writeScript() throws {
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
    }

    private static func writePrivate(_ text: String, to url: URL) throws {
        // Erst mit 0600 anlegen, dann füllen, damit der Token nie lesbar für andere ist.
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(text.utf8))
    }
}
