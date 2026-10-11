import Foundation

/// Der Wrapper für die Claude Code Erweiterung in VS Code und Positron (Einstellung `claudeCode.claudeProcessWrapper`).
///
/// Die Erweiterung startet `claude` fest mit einem Konto (`CLAUDE_CONFIG_DIR`), und Claude Code kann das Konto
/// nicht mitten in einer Sitzung wechseln. Das Skript steht deshalb zwischen Editor und `claude`: Es wählt beim
/// Start das Konto, das nicht am Limit ist, und kann bei einem Limit `claude` mit dem anderen Konto neu starten
/// (siehe EditorWrapperScript). Notchwerk legt die Skripte nur auf Klick in den Einstellungen an und ändert die
/// Einstellungen der Editoren nie selbst.
enum EditorWrapper {
    static let version = 1

    static var shellURL: URL { HookInstaller.dir.appendingPathComponent("claude-wrapper") }
    static var pythonURL: URL { HookInstaller.dir.appendingPathComponent("claude-wrapper.py") }

    enum Status: Equatable {
        case missing
        case current
        case outdated
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: shellURL.path)
    }

    static func status() -> Status {
        let fm = FileManager.default
        guard fm.fileExists(atPath: shellURL.path), fm.fileExists(atPath: pythonURL.path) else { return .missing }
        let python = (try? String(contentsOf: pythonURL, encoding: .utf8)) ?? ""
        return python.contains("NOTCHWERK_WRAPPER_VERSION = \(version)") ? .current : .outdated
    }

    /// Schreibt beide Skripte nach ~/.claude-notch/ (nur für dich les- und ausführbar).
    static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: HookInstaller.dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        for (url, text) in [(pythonURL, EditorWrapperScript.python), (shellURL, EditorWrapperScript.shell)] {
            try Data(text.utf8).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }

    /// Löscht die Skripte und den Limit-Stand. Die Zeilen in den Einstellungen der Editoren bleiben, bis du sie entfernst.
    static func remove() {
        let fm = FileManager.default
        for url in [shellURL, pythonURL, LimitFile.url] { try? fm.removeItem(at: url) }
    }

    // MARK: - Einstellungen für den Editor

    /// Der Wert für CLAUDE_CONFIG_DIR bei einem Konto, wie ihn auch der Chat zuerst probiert (nil: Variable weglassen).
    static func configValue(for account: ClaudeAccount) -> String? {
        ClaudeCLI.configChoices(for: account).first ?? nil
    }

    /// Die Zeilen für die settings.json von VS Code oder Positron. `primary` ist das Konto, mit dem der Editor
    /// läuft, `fallback` das, auf das er bei einem Limit ausweichen darf.
    static func snippet(primary: ClaudeAccount, fallback: ClaudeAccount, seamless: Bool) -> String {
        var variables: [String] = []
        if let value = configValue(for: primary) {
            variables.append(#"{ "name": "CLAUDE_CONFIG_DIR", "value": \#(jsonString(value)) }"#)
        }
        variables.append(#"{ "name": "NOTCHWERK_FALLBACK_CONFIG_DIR", "value": \#(jsonString(configValue(for: fallback) ?? "default")) }"#)
        if seamless {
            variables.append(#"{ "name": "NOTCHWERK_SEAMLESS", "value": "1" }"#)
        }
        let list = variables.map { "    " + $0 }.joined(separator: ",\n")
        return """
        "claudeCode.claudeProcessWrapper": \(jsonString(shellURL.path)),
        "claudeCode.environmentVariables": [
        \(list)
        ]
        """
    }

    /// Ein JSON-Text in Anführungszeichen, Sonderzeichen maskiert.
    static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}
