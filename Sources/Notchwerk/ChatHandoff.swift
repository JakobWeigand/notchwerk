import Foundation

/// Was der Chat aus einer Claude Code Sitzung übernimmt, wenn deren Konto sein Limit erreicht hat:
/// die letzte Anfrage, die davor liegenden Nachrichten und der Projektordner (nur zum Lesen).
struct ChatHandoff {
    /// Woher es kommt, z.B. „Projekt › Titel (VS Code)“.
    let source: String
    /// Das Konto, das sein Limit erreicht hat.
    let blockedAccountID: String
    let blockedUntil: Date?
    let history: [ChatModel.Entry]
    let prompt: String
    /// Projektordner der Sitzung, falls er sich als Chat-Ordner eignet.
    let folder: String?
}

/// Liest aus dem Protokoll einer Claude Code Sitzung das, was für eine Übernahme nötig ist. Das Format ist
/// nicht dokumentiert: Fehlt etwas oder ändert es sich, kommt einfach weniger heraus und es wird nichts übernommen.
///
/// Gelesen wird nur das Ende der Datei. Übernommen werden Text von dir und von Claude, keine Werkzeugergebnisse
/// (die können Dateiinhalte enthalten), keine Denkblöcke, keine Hinweise der Editor-Erweiterung (geöffnete Datei,
/// Auswahl) und nichts aus Unteragenten.
enum TranscriptExcerpt {
    struct Result {
        var history: [ChatModel.Entry]
        /// Die letzte Anfrage von dir.
        var prompt: String?
    }

    private static let tailBytes: UInt64 = 2 * 1024 * 1024
    private static let maxLine = 512 * 1024
    private static let maxEntry = 4000
    private static let maxTotal = 12_000
    private static let maxEntries = 8

    nonisolated static func read(path: String) -> Result {
        let empty = Result(history: [], prompt: nil)
        guard let handle = FileHandle(forReadingAtPath: path) else { return empty }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return empty }
        let start = size > tailBytes ? size - tailBytes : 0
        try? handle.seek(toOffset: start)
        let data = handle.readDataToEndOfFile()

        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() } // die erste Zeile kann abgeschnitten sein

        var entries: [ChatModel.Entry] = []
        for line in lines where line.count < maxLine {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = object["type"] as? String, type == "user" || type == "assistant",
                  object["isSidechain"] as? Bool != true,
                  object["isMeta"] as? Bool != true,
                  object["isApiErrorMessage"] as? Bool != true,
                  let message = object["message"] as? [String: Any],
                  let text = plainText(message["content"]) else { continue }
            entries.append((type == "user" ? .user : .assistant, text))
        }

        guard let last = entries.lastIndex(where: { $0.role == .user }) else { return empty }
        var kept: [ChatModel.Entry] = []
        var budget = maxTotal
        for entry in entries[..<last].reversed() {
            guard kept.count < maxEntries, entry.text.count <= budget else { break }
            budget -= entry.text.count
            kept.append(entry)
        }
        return Result(history: kept.reversed(), prompt: entries[last].text)
    }

    /// Der Text einer Nachricht. Nachrichten, die nur aus Werkzeugergebnissen oder Hinweisen bestehen, ergeben nil.
    private static func plainText(_ content: Any?) -> String? {
        var parts: [String] = []
        if let text = content as? String {
            parts = [text]
        } else if let blocks = content as? [[String: Any]] {
            parts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        }
        let texts = parts.filter { !isWrapped($0) }
        let joined = clean(texts.joined(separator: "\n\n"))
        return joined.isEmpty ? nil : joined
    }

    /// Von Claude Code oder der Erweiterung eingefügte Hinweise stehen in eigenen Tags, z.B. `<ide_opened_file>…</ide_opened_file>`.
    private static let wrapper = try? NSRegularExpression(pattern: "^<([a-z][a-z0-9_-]*)[\\s>][\\s\\S]*</\\1>\\s*$")

    private static func isWrapped(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<") else { return false }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return wrapper?.firstMatch(in: trimmed, range: range) != nil
    }

    /// Ohne Steuerzeichen (außer Zeilenumbruch und Tab), ohne Leerraum am Rand, gekürzt.
    private static func clean(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "\n\t")
        let scalars = raw.unicodeScalars.filter { allowed.contains($0) || !CharacterSet.controlCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > maxEntry ? String(text.prefix(maxEntry)) + " …" : text
    }
}
