import AppKit
import CryptoKit
import Foundation

/// Ein Claude Code Konto. Claude Code trennt Konten über den Konfigurationsordner: Standard ist
/// ~/.claude, ein weiteres Konto läuft mit `CLAUDE_CONFIG_DIR="$HOME/.claude-arbeit" claude`.
/// Jeder Ordner hat seine eigene Anmeldung, eigene Einstellungen (also eigene Hooks) und eigene Limits.
struct ClaudeAccount: Codable, Identifiable, Hashable {
    static let defaultID = "default"

    let id: String
    var name: String
    /// Absoluter Pfad, ohne ~ und ohne Schrägstrich am Ende.
    let configDir: String
    /// In den Widgets zeigen.
    var showInWidgets = true
    /// CLAUDE_CONFIG_DIR genau so, wie der Hook ihn zuletzt gemeldet hat (nil: noch nie gesehen
    /// oder nicht gesetzt). Claude Code bildet den Namen im Schlüsselbund aus dieser Schreibweise.
    var envValue: String?

    var isDefault: Bool { id == Self.defaultID }

    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    static var defaultDir: String { home + "/.claude" }

    static func makeDefault() -> ClaudeAccount {
        ClaudeAccount(id: defaultID, name: "Standard", configDir: defaultDir)
    }

    /// Neues Konto für einen Ordner. Die ID ist der Pfad, damit dasselbe Konto nicht doppelt auftaucht.
    static func make(name: String, configDir: String) -> ClaudeAccount {
        let dir = normalize(configDir)
        return ClaudeAccount(id: dir == defaultDir ? defaultID : dir, name: name, configDir: dir)
    }

    /// ~ auflösen, Schrägstrich am Ende weg, symbolische Verweise nicht anfassen.
    static func normalize(_ path: String) -> String {
        var p = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    var configURL: URL { URL(fileURLWithPath: configDir, isDirectory: true) }
    var settingsURL: URL { configURL.appendingPathComponent("settings.json") }
    var credentialsFileURL: URL { configURL.appendingPathComponent(".credentials.json") }

    /// Pfad wie im Terminal, mit ~ statt dem Home-Ordner.
    var displayPath: String {
        configDir.hasPrefix(Self.home + "/") ? "~" + configDir.dropFirst(Self.home.count) : configDir
    }

    /// Mögliche Namen des Schlüsselbund-Eintrags, in dem Claude Code die Anmeldung ablegt.
    /// Ohne CLAUDE_CONFIG_DIR heißt er „Claude Code-credentials“. Ist die Variable gesetzt, hängt
    /// Claude Code die ersten 8 Hex-Zeichen des SHA-256 über ihren Wert an, genau so geschrieben,
    /// wie er gesetzt ist (Unicode-normalisiert, sonst unverändert: ein Schrägstrich am Ende ergibt
    /// einen anderen Namen). Zuerst kommt die Schreibweise, die der Hook gemeldet hat, dann die
    /// üblichen. Probiert wird der Reihe nach, bis ein Eintrag passt.
    var keychainServiceCandidates: [String] {
        let base = "Claude Code-credentials"
        var raws: [String] = []
        if let envValue, !envValue.isEmpty { raws.append(envValue) }
        if !isDefault { raws += [configDir, configDir + "/"] }
        var names = raws.map { "\(base)-\(Self.shortHash($0))" }
        if isDefault { names.append(base) }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    static func shortHash(_ text: String) -> String {
        let normalized = text.precomposedStringWithCanonicalMapping
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).lowercased()
    }

    /// Globale Konfiguration von Claude Code. Darin steht unter „oauthAccount“, wer angemeldet ist.
    /// Ohne CLAUDE_CONFIG_DIR ist das ~/.claude.json, sonst <Ordner>/.claude.json. Eine alte
    /// <Ordner>/.config.json hat Vorrang, wenn es sie gibt.
    var globalConfigURLs: [URL] {
        let legacy = configURL.appendingPathComponent(".config.json")
        if isDefault && (envValue ?? "").isEmpty {
            return [legacy, URL(fileURLWithPath: Self.home).appendingPathComponent(".claude.json")]
        }
        return [legacy, configURL.appendingPathComponent(".claude.json")]
    }

    /// Wer laut Claude Code angemeldet ist: E-Mail und Organisation. Liest nur diese Felder,
    /// Tokens stehen in dieser Datei nicht.
    struct SignedIn: Equatable {
        let email: String
        let organization: String?
    }

    func signedIn() -> SignedIn? {
        for url in globalConfigURLs where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            // Die erste vorhandene Datei gilt, auch wenn darin (noch) niemand angemeldet ist.
            guard let oauth = obj["oauthAccount"] as? [String: Any],
                  let email = oauth["emailAddress"] as? String, !email.isEmpty else { return nil }
            let org = (oauth["organizationName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return SignedIn(email: email, organization: org)
        }
        return nil
    }

    /// Gehört eine Sitzung zu diesem Konto? Claude Code legt Transkripte unter <Ordner>/projects/ ab.
    func owns(transcriptPath: String) -> Bool {
        transcriptPath.hasPrefix(configDir + "/")
    }

    // MARK: - Im Terminal benutzen

    /// Befehl, mit dem Claude Code dieses Konto benutzt.
    var shellCommand: String {
        isDefault ? "claude" : "CLAUDE_CONFIG_DIR=\(shellPath) claude"
    }

    /// Kurzbefehl für ~/.zshrc, z.B. `alias claude-arbeit='CLAUDE_CONFIG_DIR="$HOME/.claude-arbeit" claude'`.
    var aliasLine: String {
        let slug = Self.slug(name).isEmpty ? "konto" : Self.slug(name)
        return "alias claude-\(slug)='\(shellCommand.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Pfad für die Shell: im Home-Ordner als "$HOME/…", sonst in einfachen Anführungszeichen.
    private var shellPath: String {
        let rest = configDir.dropFirst(Self.home.count)
        if configDir.hasPrefix(Self.home + "/"), rest.allSatisfy({ $0.isLetter || $0.isNumber || "/._-".contains($0) }) {
            return "\"$HOME\(rest)\""
        }
        return "'" + configDir.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Öffnet ein Terminal-Fenster, in dem Claude Code mit diesem Konto startet. Bei einem
    /// neuen Ordner führt Claude Code dort durch die Anmeldung.
    func openInTerminal() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: HookInstaller.dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let file = HookInstaller.dir.appendingPathComponent("anmelden-\(Self.slug(name).isEmpty ? "konto" : Self.slug(name)).command")
        let label = name.replacingOccurrences(of: "\"", with: "")
        let script = """
        #!/bin/zsh
        # Von Notchwerk angelegt: startet Claude Code mit dem Konto „\(label)“.
        export CLAUDE_CONFIG_DIR=\(shellPath)
        cd "$HOME"
        if ! command -v claude >/dev/null 2>&1; then
          echo "Claude Code (claude) wurde nicht gefunden. Bitte zuerst installieren."
          read -k 1 "?Taste drücken zum Schließen …"
          exit 1
        fi
        echo "Claude Code mit dem Konto „\(label)“ ($CLAUDE_CONFIG_DIR)."
        echo "Falls Claude Code nicht von selbst nach der Anmeldung fragt: /login eingeben."
        echo
        exec claude

        """
        try Data(script.utf8).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        NSWorkspace.shared.open(file)
    }

    /// Name aus dem Ordner: ~/.claude-arbeit → „Arbeit“, ~/.claude_work → „Work“.
    static func suggestedName(forDir dir: String) -> String {
        var name = (dir as NSString).lastPathComponent
        if name.hasPrefix(".claude") { name.removeFirst(".claude".count) }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-_. "))
            .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        guard let first = name.first else { return "Weiteres Konto" }
        return first.uppercased() + name.dropFirst()
    }

    /// Kleinbuchstaben, Ziffern und Bindestriche, z.B. „Arbeit (Firma)“ → „arbeit-firma“.
    static func slug(_ text: String) -> String {
        let map: [Character: String] = ["ä": "ae", "ö": "oe", "ü": "ue", "ß": "ss"]
        var out = ""
        for ch in text.lowercased() {
            if let r = map[ch] { out += r } else if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch) } else if !out.hasSuffix("-") { out += "-" }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

/// Sucht im Home-Ordner nach weiteren Konfigurationsordnern von Claude Code (~/.claude-arbeit,
/// ~/.claude-work …), damit du ein schon eingerichtetes zweites Konto nur noch übernehmen musst.
enum AccountDiscovery {
    static func candidates(excluding known: [ClaudeAccount]) -> [String] {
        let fm = FileManager.default
        let home = ClaudeAccount.home
        let knownDirs = Set(known.map(\.configDir))
        guard let names = try? fm.contentsOfDirectory(atPath: home) else { return [] }
        return names
            .filter { $0.hasPrefix(".claude") && $0 != ".claude" && $0 != ".claude-notch" && $0 != ".claude.json" }
            .map { home + "/" + $0 }
            .filter { dir in
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue, !knownDirs.contains(dir) else { return false }
                return [".claude.json", "settings.json", "projects", ".credentials.json"]
                    .contains { fm.fileExists(atPath: dir + "/" + $0) }
            }
            .sorted()
    }

    /// Vorschlag für einen neuen Ordner, der noch nicht existiert: ~/.claude-arbeit, ~/.claude-arbeit-2 …
    static func suggestedDir(for name: String) -> String {
        let slug = ClaudeAccount.slug(name).isEmpty ? "konto" : ClaudeAccount.slug(name)
        let base = ClaudeAccount.home + "/.claude-" + slug
        var dir = base
        var n = 2
        while FileManager.default.fileExists(atPath: dir) {
            dir = "\(base)-\(n)"
            n += 1
        }
        return dir
    }
}
