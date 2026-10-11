import Foundation

/// Teilt den Limit-Stand der Konten mit dem Wrapper-Skript für die Editoren (siehe EditorWrapper):
/// `~/.claude-notch/limits.json`, nur für dich lesbar, mit nichts als Konto-Kennung und Zeitpunkt, bis zu dem das
/// Konto gesperrt ist. Das Skript wählt damit beim Start eines Editor-Chats das Konto, das nicht am Limit ist.
/// Die Datei entsteht nur, wenn das Skript angelegt wurde.
@MainActor
final class LimitFile {
    static let shared = LimitFile()

    nonisolated static var url: URL { HookInstaller.dir.appendingPathComponent("limits.json") }

    /// Limits, die ein Hook gemeldet hat, mit dem Zeitpunkt des Zurücksetzens, falls bekannt.
    private var hookBlocks: [String: Date] = [:]
    private var lastBlocks: [String: Int]?

    private init() {}

    /// Eine Sitzung hat ihr Limit gemeldet. Ist die Zeit des Zurücksetzens nicht bekannt, gilt das Konto nur kurz als
    /// gesperrt (10 Minuten), statt etwas zu raten. Danach probiert das Skript es wieder mit dem Konto.
    func noteHookLimit(accountID: String?, until: Date?) {
        guard let accountID else { return }
        hookBlocks[accountID] = until ?? Date().addingTimeInterval(600)
        publish()
    }

    /// Schreibt den aktuellen Stand, wenn er sich geändert hat.
    func publish() {
        guard EditorWrapper.isInstalled else {
            lastBlocks = nil
            return
        }
        let now = Date()
        var blocked: [String: Int] = [:]
        func merge(_ id: String, _ until: Date?) {
            guard let until, until > now else { return }
            blocked[id] = max(blocked[id] ?? 0, Int(until.timeIntervalSince1970))
        }
        for (id, until) in hookBlocks { merge(id, until) }
        for account in Preferences.shared.accounts { merge(account.id, ChatModel.shared.blockedUntil(account)) }
        guard blocked != lastBlocks else { return }

        let accounts = blocked.mapValues { ["blockedUntil": $0] }
        let object: [String: Any] = ["version": 1, "updatedAt": Int(now.timeIntervalSince1970), "accounts": accounts]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: HookInstaller.dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try data.write(to: Self.url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
            lastBlocks = blocked
        } catch {
            NSLog("Notchwerk: limits.json konnte nicht geschrieben werden")
        }
    }
}
