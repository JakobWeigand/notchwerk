import Foundation

/// Titel eines Chats, wie Claude Code ihn im Transkript ablegt: `custom-title` nach einem
/// Umbenennen (/rename), sonst `ai-title`, den Claude Code selbst vergibt. Das ist kein
/// dokumentiertes Format. Fehlt es oder ändert es sich, bleibt der Titel einfach leer.
///
/// Gelesen wird nur, was seit dem letzten Mal dazugekommen ist, und nur Zeilen dieser zwei Typen.
enum SessionTitles {
    struct State: Equatable {
        /// Bis hierhin ist die Datei gelesen (immer am Ende einer vollständigen Zeile).
        var offset: UInt64 = 0
        var aiTitle: String?
        var customTitle: String?

        /// Selbst vergebener Name vor dem automatischen.
        var title: String? { customTitle ?? aiTitle }
    }

    /// Beim ersten Lesen einer sehr großen Datei nur das Ende: Titel stehen nach jeder Runde neu drin.
    private static let firstReadLimit: UInt64 = 8 * 1024 * 1024
    private static let chunk = 1024 * 1024
    private static let maxTitleLength = 120

    /// Liest neue Zeilen ab `state.offset`. Läuft abseits des Main-Threads.
    static func scan(path: String, from state: State) -> State {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let handle = FileHandle(forReadingAtPath: path) else { return state }
        defer { try? handle.close() }

        var next = state
        // Datei kleiner geworden (neu angelegt): von vorn.
        if size < next.offset { next = State() }
        if next.offset == 0, size > firstReadLimit { next.offset = size - firstReadLimit }
        guard size > next.offset else { return next }

        var position = next.offset
        var carry = Data()
        try? handle.seek(toOffset: position)
        while position < size {
            let data = handle.readData(ofLength: chunk)
            if data.isEmpty { break }
            position += UInt64(data.count)
            carry.append(data)
            // Nur vollständige Zeilen auswerten, der Rest wartet auf den nächsten Durchgang.
            guard let lastNewline = carry.lastIndex(of: 0x0A) else { continue }
            let lines = carry[carry.startIndex...lastNewline]
            for line in lines.split(separator: 0x0A) { read(line, into: &next) }
            carry = Data(carry[carry.index(after: lastNewline)...])
        }
        next.offset = position - UInt64(carry.count)
        return next
    }

    private static func read(_ line: Data.SubSequence, into state: inout State) {
        // Schneller Vorfilter: die allermeisten Zeilen sind Nachrichten und werden nicht geparst.
        guard line.count < 4096,
              let text = String(data: Data(line), encoding: .utf8),
              text.contains("\"ai-title\"") || text.contains("\"custom-title\""),
              let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        switch obj["type"] as? String {
        case "ai-title":
            if let t = clean(obj["aiTitle"]) { state.aiTitle = t }
        case "custom-title":
            if let t = clean(obj["customTitle"]) { state.customTitle = t }
        default:
            break
        }
    }

    /// Eine Zeile, ohne Steuerzeichen, mit Höchstlänge.
    private static func clean(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let scalars = raw.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }
        let text = String(scalars).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return text.count > maxTitleLength ? String(text.prefix(maxTitleLength)) + "…" : text
    }
}
