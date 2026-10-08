import AppKit
import Foundation

/// Baut die JSON-Antworten, die Claude Code von einem Hook erwartet.
enum HookResponses {
    static func permission(_ answer: PendingRequest.Answer, suggestions: [Any]) -> Data? {
        var decision: [String: Any]
        switch answer {
        case .allow:
            decision = ["behavior": "allow"]
        case .allowAlways:
            decision = ["behavior": "allow"]
            if !suggestions.isEmpty { decision["updatedPermissions"] = suggestions }
        case .deny:
            decision = ["behavior": "deny", "message": "Im Notch abgelehnt."]
        case .terminal, .answers:
            return nil // keine Entscheidung: Claude Code fragt wie gewohnt im Terminal
        }
        return encode([
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision,
            ],
        ])
    }

    static func questionAnswer(_ answer: PendingRequest.Answer, toolInput: [String: Any]) -> Data? {
        guard case .answers(let answers) = answer else { return nil }
        var updated = toolInput
        updated["answers"] = answers
        return encode([
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "updatedInput": updated,
            ],
        ])
    }

    private static func encode(_ obj: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: obj)
    }
}

/// Lesbare Kurzbeschreibungen für Tool-Aufrufe.
enum ToolDescriber {
    static func displayName(_ tool: String) -> String {
        if tool.hasPrefix("mcp__") {
            let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
            return parts.dropFirst().joined(separator: " · ")
        }
        return tool
    }

    static func short(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Bash":
            return "$ " + oneLine(input["command"] as? String ?? "")
        case "Read":
            return "Liest " + file(input["file_path"])
        case "Edit", "MultiEdit":
            return "Bearbeitet " + file(input["file_path"])
        case "Write":
            return "Schreibt " + file(input["file_path"])
        case "Grep", "Glob":
            return "Sucht " + oneLine(input["pattern"] as? String ?? "")
        case "WebFetch":
            return "Öffnet " + host(input["url"] as? String)
        case "WebSearch":
            return "Sucht im Web"
        case "Task", "Agent":
            return "Startet Helfer"
        case "TodoWrite", "TaskCreate", "TaskUpdate":
            return "Plant nächste Schritte"
        case "AskUserQuestion":
            return "Hat eine Frage"
        default:
            return displayName(tool)
        }
    }

    static func long(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Bash":
            let cmd = input["command"] as? String ?? ""
            if let desc = input["description"] as? String, !desc.isEmpty {
                return "\(desc)\n$ \(cmd)"
            }
            return "$ \(cmd)"
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
            return (input["file_path"] as? String ?? input["notebook_path"] as? String) ?? short(tool: tool, input: input)
        case "WebFetch":
            return input["url"] as? String ?? ""
        default:
            if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]),
               let text = String(data: data, encoding: .utf8) {
                return String(text.prefix(400))
            }
            return short(tool: tool, input: input)
        }
    }

    private static func file(_ value: Any?) -> String {
        guard let path = value as? String else { return "Datei" }
        return (path as NSString).lastPathComponent
    }

    private static func host(_ url: String?) -> String {
        guard let url, let host = URL(string: url)?.host else { return "Webseite" }
        return host
    }

    private static func oneLine(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return line.count > 60 ? String(line.prefix(57)) + "…" : line
    }
}

enum Sounds {
    enum Kind { case attention, done, greeting }

    @MainActor
    static func play(_ kind: Kind) {
        guard Preferences.shared.playSounds, Preferences.shared.enabled else { return }
        let name: String
        switch kind {
        case .attention: name = "Pop"
        case .done: name = "Glass"
        case .greeting: name = "Tink"
        }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
