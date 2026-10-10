import Foundation

/// Geplante Nachrichten an Claude (erweiterte Einstellung): Du schreibst sie vorab, zum Beispiel
/// wenn das Limit erreicht ist, und die App gibt sie Claude, sobald die Sitzung das nächste Mal
/// fertig ist. Claude Code macht nach dem Zurücksetzen des Limits von selbst weiter; am Ende dieses
/// Durchgangs antwortet der Stop-Hook mit „weitermachen“ und deinem Text als nächster Anweisung.
///
/// Der Text geht nur als JSON an Claude Code, nie an eine Shell oder ein Terminal. Er liegt nur im
/// Arbeitsspeicher und ist nach einem Neustart der App oder nach `maxAge` weg.
@MainActor
final class FollowUps: ObservableObject {
    static let shared = FollowUps()

    struct FollowUp: Equatable {
        let sessionId: String
        let project: String
        let text: String
        let createdAt: Date
    }

    /// Höchstens so viele Zeichen. Länger braucht man im Notch nicht, und es hält die Antwort klein.
    nonisolated static let maxLength = 4000
    /// Danach verfällt eine Nachricht, die nie zugestellt wurde (z.B. weil die Sitzung nicht weitermachte).
    static let maxAge: TimeInterval = 24 * 3600

    /// Je Sitzung höchstens eine geplante Nachricht.
    @Published private(set) var planned: [String: FollowUp] = [:]

    private let prefs = Preferences.shared

    private init() {}

    /// Wartet gerade etwas auf Zustellung? Hält den Mac wach und verschiebt automatische Updates.
    var hasScheduled: Bool {
        prefs.followUpsEnabled && planned.values.contains { !isExpired($0) }
    }

    func followUp(for sessionId: String) -> FollowUp? {
        guard prefs.followUpsEnabled, let f = planned[sessionId], !isExpired(f) else { return nil }
        return f
    }

    /// Plant `text` für die Sitzung. Leerer Text löscht die Planung.
    func plan(_ text: String, for sessionId: String, project: String) {
        guard prefs.followUpsEnabled else { return }
        let clean = Self.sanitize(text)
        guard !clean.isEmpty else {
            planned[sessionId] = nil
            return
        }
        planned[sessionId] = FollowUp(sessionId: sessionId, project: project, text: clean, createdAt: Date())
    }

    func cancel(_ sessionId: String) {
        planned[sessionId] = nil
    }

    func cancelAll() {
        planned.removeAll()
    }

    /// Beim Stop-Hook: die geplante Nachricht herausgeben und vergessen.
    func take(for sessionId: String) -> String? {
        guard let f = followUp(for: sessionId) else {
            planned[sessionId] = nil
            return nil
        }
        planned[sessionId] = nil
        return f.text
    }

    private func isExpired(_ f: FollowUp) -> Bool {
        Date().timeIntervalSince(f.createdAt) > Self.maxAge
    }

    /// Ohne Steuerzeichen (außer Zeilenumbruch und Tab), ohne Leerraum am Rand, mit fester Höchstlänge.
    nonisolated static func sanitize(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "\n\t")
        let scalars = text.unicodeScalars.filter {
            allowed.contains($0) || !CharacterSet.controlCharacters.contains($0)
        }
        let clean = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(clean.prefix(maxLength))
    }
}
