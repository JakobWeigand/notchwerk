import AppKit
import Foundation
import Security

/// Ein Nutzungsfenster, wie es auch `/usage` in Claude Code zeigt: wie viel vom Limit
/// verbraucht ist (0 bis 100 Prozent) und wann es sich zurücksetzt.
struct UsageWindow: Equatable, Identifiable {
    let id: String
    let title: String
    let percent: Double
    let resetsAt: Date?

    var remainingPercent: Int { max(0, 100 - Int(percent.rounded())) }

    func resetText(now: Date = Date()) -> String {
        guard let resetsAt else { return "" }
        let seconds = resetsAt.timeIntervalSince(now)
        if seconds <= 0 { return "setzt sich gerade zurück" }
        if seconds < 3600 { return "neu in \(max(1, Int(seconds / 60))) min" }
        if seconds < 24 * 3600 {
            let h = Int(seconds / 3600)
            let m = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
            return "neu in \(h) h \(m) min"
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEE HH:mm"
        return "neu \(f.string(from: resetsAt))"
    }
}

struct UsageSnapshot: Equatable {
    let windows: [UsageWindow]
    let fetchedAt: Date
}

/// Liest den Anmelde-Token von Claude Code. Der liegt im Schlüsselbund unter
/// „Claude Code-credentials“ (bei älteren Versionen in ~/.claude/.credentials.json).
/// Beim ersten Zugriff fragt macOS, ob Claude Notch den Eintrag lesen darf.
enum ClaudeCredentials {
    struct Token {
        let accessToken: String
        let expiresAt: Date?
    }

    enum Outcome {
        case found(Token)
        case missing
        case denied
        case failed(String)
    }

    static let service = "Claude Code-credentials"

    static func read() -> Outcome {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            if let data = item as? Data, let token = parse(data) { return .found(token) }
            return .failed("Eintrag im Schlüsselbund ist unlesbar")
        case errSecItemNotFound:
            if let data = fileData(), let token = parse(data) { return .found(token) }
            return .missing
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            return .denied
        default:
            return .failed("Schlüsselbund-Fehler \(status)")
        }
    }

    private static func fileData() -> Data? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        return try? Data(contentsOf: url)
    }

    private static func parse(_ data: Data) -> Token? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expires = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Token(accessToken: token, expiresAt: expires)
    }
}

/// Holt die Nutzung (Sitzungs- und Wochenlimit) von derselben Stelle wie `/usage` in Claude Code.
/// Der Token geht ausschließlich an api.anthropic.com. Es wird nichts verändert, nur gelesen.
@MainActor
final class UsageMonitor: ObservableObject {
    static let shared = UsageMonitor()

    enum Status: Equatable {
        case idle
        case loading
        case ok
        case noCredentials
        case expired
        case denied
        case failed(String)

        var text: String {
            switch self {
            case .idle, .loading: return "Nutzung wird geladen …"
            case .ok: return ""
            case .noCredentials: return "Nutzung: kein Claude Code Login gefunden (claude /login)"
            case .expired: return "Nutzung: Anmeldung abgelaufen, Claude Code einmal benutzen"
            case .denied: return "Nutzung: Zugriff auf den Schlüsselbund abgelehnt"
            case .failed(let why): return "Nutzung gerade nicht verfügbar (\(why))"
            }
        }
    }

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var status: Status = .idle

    private var running: Task<Void, Never>?
    /// Der Token bleibt nach dem ersten Lesen im Speicher. So fragt der Schlüsselbund höchstens
    /// einmal pro App-Start (oder gar nicht, wenn du „Immer erlauben“ gewählt hast).
    private var cachedToken: ClaudeCredentials.Token?
    private var deniedAt: Date?

    private enum FetchError: Error {
        case noCredentials, expired, denied, failed(String)
    }

    /// Neu laden, wenn die Daten älter als `maxAge` Sekunden sind. Wird nur beim Öffnen der Liste aufgerufen,
    /// im Hintergrund passiert nichts.
    func refreshIfStale(maxAge: TimeInterval = 60) {
        if let snapshot, Date().timeIntervalSince(snapshot.fetchedAt) < maxAge { return }
        // Nach „Nicht erlauben“ eine Weile nicht erneut fragen.
        if let deniedAt, Date().timeIntervalSince(deniedAt) < 15 * 60 { return }
        refresh()
    }

    func refresh() {
        guard running == nil else { return }
        if snapshot == nil { status = .loading }
        let cached = cachedToken
        running = Task { [weak self] in
            defer { self?.running = nil }
            do {
                let (token, snap) = try await Self.fetch(using: cached)
                self?.cachedToken = token
                self?.snapshot = snap
                self?.status = .ok
            } catch FetchError.noCredentials {
                self?.cachedToken = nil
                self?.status = .noCredentials
            } catch FetchError.expired {
                self?.cachedToken = nil
                self?.status = .expired
            } catch FetchError.denied {
                self?.cachedToken = nil
                self?.deniedAt = Date()
                self?.status = .denied
            } catch FetchError.failed(let why) {
                self?.status = .failed(why)
            } catch {
                self?.status = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        running?.cancel()
        running = nil
    }

    /// Läuft abseits des Main-Threads: Der Schlüsselbund-Dialog blockiert sonst die Animation.
    private nonisolated static func fetch(using cached: ClaudeCredentials.Token?) async throws
        -> (ClaudeCredentials.Token, UsageSnapshot) {
        var token = cached
        if let t = token, let expires = t.expiresAt, expires < Date() { token = nil }
        if token == nil {
            switch ClaudeCredentials.read() {
            case .found(let t): token = t
            case .missing: throw FetchError.noCredentials
            case .denied: throw FetchError.denied
            case .failed(let why): throw FetchError.failed(why)
            }
        }
        guard let token else { throw FetchError.noCredentials }
        if let expires = token.expiresAt, expires < Date() { throw FetchError.expired }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        request.setValue("claude-notch/\(version)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.failed("keine Antwort") }
        if http.statusCode == 401 || http.statusCode == 403 { throw FetchError.expired }
        guard (200..<300).contains(http.statusCode) else { throw FetchError.failed("HTTP \(http.statusCode)") }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.failed("unlesbare Antwort")
        }

        let known: [(key: String, title: String)] = [
            ("five_hour", "Sitzung"),
            ("seven_day", "Woche"),
            ("seven_day_opus", "Topmodell"),
            ("seven_day_sonnet", "Sonnet"),
        ]
        var windows: [UsageWindow] = []
        for entry in known {
            guard let w = obj[entry.key] as? [String: Any] else { continue }
            let raw = (w["utilization"] as? Double) ?? (w["utilization"] as? Int).map(Double.init)
            guard let raw else { continue }
            let resets = (w["resets_at"] as? String).flatMap(parseDate)
            windows.append(UsageWindow(id: entry.key, title: entry.title, percent: min(max(raw, 0), 100), resetsAt: resets))
        }
        guard !windows.isEmpty else { throw FetchError.failed("keine Limits in der Antwort") }
        return (token, UsageSnapshot(windows: windows, fetchedAt: Date()))
    }

    private nonisolated static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: text) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
