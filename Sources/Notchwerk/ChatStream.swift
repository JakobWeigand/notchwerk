import Foundation

/// Was die claude-CLI mit `-p --output-format stream-json` Zeile für Zeile meldet, auf das reduziert,
/// was der Chat braucht. Alles andere (Hooks, Statusmeldungen, Werkzeugliste …) wird überlesen.
enum ChatStreamEvent: Equatable {
    /// Kennung der Sitzung, mit der sich der Chat bei diesem Konto fortsetzen lässt.
    case session(String)
    /// Ein neuer Textblock beginnt (nach einem Werkzeugaufruf zum Beispiel).
    case textBlockStart
    case textDelta(String)
    /// Claude liest gerade etwas, kurz und ohne Steuerzeichen („liest Skript.pdf“).
    case activity(String)
    case rateLimit(RateLimitInfo)
    /// Eine fertige Nachricht, die die CLI selbst erzeugt hat (Limit erreicht, nicht angemeldet …).
    case systemMessage(String)
    case result(ResultInfo)
}

struct RateLimitInfo: Equatable {
    enum Status: Equatable { case allowed, warning, rejected, other }

    let status: Status
    /// five_hour oder seven_day, falls genannt.
    let kind: String?
    let resetsAt: Date?
    /// Auslastung je Fenster als Bruchteil (1,02 = 102 %), wie in `unifiedWindows` gemeldet.
    let windows: [String: Double]
}

struct ResultInfo: Equatable {
    let isError: Bool
    let text: String
    let sessionID: String?
}

enum ChatStream {
    /// Eine Zeile der Ausgabe. Unlesbares oder Unbekanntes ergibt eine leere Liste.
    static func parse(line: Data) -> [ChatStreamEvent] {
        guard !line.isEmpty,
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = obj["type"] as? String else { return [] }

        switch type {
        case "system":
            if obj["subtype"] as? String == "init", let id = obj["session_id"] as? String, !id.isEmpty {
                return [.session(id)]
            }
            return []

        case "stream_event":
            // Nur der Hauptstrang, keine Unteragenten.
            guard obj["parent_tool_use_id"] is NSNull || obj["parent_tool_use_id"] == nil,
                  let event = obj["event"] as? [String: Any],
                  let eventType = event["type"] as? String else { return [] }
            if eventType == "content_block_start",
               (event["content_block"] as? [String: Any])?["type"] as? String == "text" {
                return [.textBlockStart]
            }
            if eventType == "content_block_delta",
               let delta = event["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String, !text.isEmpty {
                return [.textDelta(text)]
            }
            return []

        case "assistant":
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return [] }
            if message["model"] as? String == "<synthetic>" {
                let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n")
                return text.isEmpty ? [] : [.systemMessage(text)]
            }
            return content.compactMap { block in
                guard block["type"] as? String == "tool_use", let name = block["name"] as? String else { return nil }
                return .activity(describe(tool: name, input: block["input"] as? [String: Any] ?? [:]))
            }

        case "rate_limit_event":
            guard let info = obj["rate_limit_info"] as? [String: Any] else { return [] }
            return [.rateLimit(parseRateLimit(info))]

        case "result":
            return [.result(ResultInfo(isError: obj["is_error"] as? Bool ?? false,
                                       text: obj["result"] as? String ?? "",
                                       sessionID: obj["session_id"] as? String))]

        default:
            return []
        }
    }

    static func parseRateLimit(_ info: [String: Any]) -> RateLimitInfo {
        let status: RateLimitInfo.Status
        switch info["status"] as? String {
        case "allowed": status = .allowed
        case "allowed_warning": status = .warning
        case "rejected": status = .rejected
        default: status = .other
        }
        var windows: [String: Double] = [:]
        for (key, value) in info["unifiedWindows"] as? [String: Any] ?? [:] {
            if let w = value as? [String: Any], let u = number(w["utilization"]) { windows[key] = u }
        }
        return RateLimitInfo(status: status,
                             kind: info["rateLimitType"] as? String,
                             resetsAt: number(info["resetsAt"]).map { Date(timeIntervalSince1970: $0) },
                             windows: windows)
    }

    /// Kurzer, harmloser Text für „Claude liest gerade …“. Dateinamen stammen aus dem Ordner und
    /// können alles Mögliche enthalten: ohne Steuerzeichen, gekürzt.
    static func describe(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Read":
            if let path = input["file_path"] as? String, !path.isEmpty {
                return "liest \(clean((path as NSString).lastPathComponent))"
            }
            return "liest eine Datei"
        case "Glob": return "sucht Dateien"
        case "Grep": return "durchsucht die Unterlagen"
        default: return "arbeitet"
        }
    }

    private static func clean(_ text: String, limit: Int = 60) -> String {
        let scalars = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let result = String(String.UnicodeScalarView(scalars))
        return result.count > limit ? String(result.prefix(limit)) + "…" : result
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }
}
