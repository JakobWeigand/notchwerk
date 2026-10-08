import Foundation

/// Ein Chat im Code-Tab der Claude Desktop App.
struct DesktopSession: Equatable {
    /// Kennung der App, z.B. "local_632fc49c-…".
    let id: String
    /// Titel des Chats, wie er in der Seitenleiste steht.
    let title: String

    /// Link, der genau diesen Chat in der Desktop App öffnet.
    var deepLink: URL? { URL(string: "claude://claude.ai/epitaxy/\(id)") }
}

/// Findet zu einer Claude Code Sitzung den passenden Chat der Desktop App.
/// Die App legt pro Chat eine JSON-Datei an, die unter `cliSessionId` die Kennung
/// der Claude Code Sitzung enthält (dieselbe `session_id`, die auch die Hooks melden).
enum DesktopSessions {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)

    /// Sucht im Hintergrund und meldet das Ergebnis auf dem Main-Thread.
    static func lookup(cliSessionId: String, completion: @escaping (DesktopSession?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = find(cliSessionId: cliSessionId)
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func find(cliSessionId: String) -> DesktopSession? {
        guard !cliSessionId.isEmpty else { return nil }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                             options: [.skipsHiddenFiles]) else { return nil }
        var candidates: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator
        where url.pathExtension == "json" && url.lastPathComponent.hasPrefix("local_") {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            candidates.append((url, date ?? .distantPast))
        }
        // Erst grob nach dem Text suchen, nur Treffer wirklich als JSON lesen.
        let needles = [
            Data("\"cliSessionId\":\"\(cliSessionId)\"".utf8),
            Data("\"cliSessionId\": \"\(cliSessionId)\"".utf8),
        ]
        for candidate in candidates.sorted(by: { $0.modified > $1.modified }) {
            guard let data = try? Data(contentsOf: candidate.url),
                  needles.contains(where: { data.range(of: $0) != nil }),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["cliSessionId"] as? String == cliSessionId else { continue }
            let id = obj["sessionId"] as? String ?? candidate.url.deletingPathExtension().lastPathComponent
            return DesktopSession(id: id, title: obj["title"] as? String ?? "")
        }
        return nil
    }
}
