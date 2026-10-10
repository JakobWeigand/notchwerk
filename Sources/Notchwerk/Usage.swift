import AppKit
import Combine
import Foundation
import NotchwerkShared
import Security
import WidgetKit

/// Ein Nutzungsfenster, wie es auch `/usage` in Claude Code zeigt: wie viel vom Limit
/// verbraucht ist und wann es sich zurücksetzt.
struct UsageWindow: Equatable, Identifiable {
    /// five_hour, seven_day oder seven_day_<modell>, z.B. seven_day_fable.
    let id: String
    let title: String
    /// Genutzt in Prozent. Kann über 100 liegen, Claude Code zeigt dann z.B. „101 % used“.
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

/// Liest den Anmelde-Token von Claude Code für ein Konto. Er liegt im Schlüsselbund unter
/// „Claude Code-credentials“ (weitere Konten mit Anhang, siehe ClaudeAccount), ersatzweise in
/// <Ordner>/.credentials.json. Der Token bleibt im Arbeitsspeicher und geht nur an api.anthropic.com.
enum ClaudeCredentials {
    struct Token: Equatable {
        let accessToken: String
        let expiresAt: Date?
    }

    enum Outcome {
        case found(Token)
        case missing
        case denied
        case failed(String)
    }

    /// Zuerst über /usr/bin/security: Claude Code legt seinen Eintrag mit genau diesem Werkzeug an,
    /// und der Eintrag erlaubt ihm deshalb das Lesen. So fragt macOS nicht nach, auch nicht nach einem
    /// Update von Notchwerk oder wenn Claude Code den Token erneuert (beides macht ein „Immer erlauben“
    /// wieder zunichte). Klappt das nicht und hast du die Liste selbst geöffnet (`interactive`), liest
    /// die App den Eintrag direkt. Dann fragt macOS wie gewohnt, ob Notchwerk ihn verwenden darf.
    static func read(for account: ClaudeAccount, interactive: Bool) async -> Outcome {
        var problem: Outcome?
        for service in account.keychainServiceCandidates {
            switch await SecurityTool.readPassword(service: service) {
            case .found(let data):
                if let token = parse(data) { return .found(token) }
                // Eintrag ohne Claude-Anmeldung (manche enthalten nur MCP-Daten): weitersuchen.
            case .notFound:
                continue
            case .failed(let why):
                guard interactive else { problem = .failed(why); continue }
                switch readInProcess(service: service) {
                case .found(let token): return .found(token)
                case .missing: continue
                case let other: problem = other
                }
            }
        }
        if let data = try? Data(contentsOf: account.credentialsFileURL), let token = parse(data) {
            return .found(token)
        }
        return problem ?? .missing
    }

    /// Direkt über die Schlüsselbund-Schnittstelle. macOS fragt dabei, ob Notchwerk den Eintrag lesen darf.
    private static func readInProcess(service: String) -> Outcome {
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
            return .missing
        case errSecItemNotFound:
            return .missing
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            return .denied
        default:
            return .failed("Schlüsselbund-Fehler \(status)")
        }
    }

    /// JSON mit „claudeAiOauth“. `security -w` gibt manche Einträge als Hex aus, auch das wird erkannt.
    static func parse(_ raw: Data) -> Token? {
        var data = raw
        while let last = data.last, last == 0x0A || last == 0x0D || last == 0x20 { data.removeLast() }
        if let token = parseJSON(data) { return token }
        if let text = String(data: data, encoding: .utf8), let bytes = Data(hex: text) { return parseJSON(bytes) }
        return nil
    }

    private static func parseJSON(_ data: Data) -> Token? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expires = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Token(accessToken: token, expiresAt: expires)
    }
}

/// Ruft /usr/bin/security mit einer festen Zeitgrenze auf. Das Passwort kommt über eine Pipe
/// zurück, nie über Argumente, und taucht deshalb in keiner Prozessliste auf.
enum SecurityTool {
    enum Result {
        case found(Data)
        case notFound
        case failed(String)
    }

    static func readPassword(service: String) async -> Result {
        // Claude Code legt den Eintrag unter deinem Benutzernamen an. Ohne -a könnte ein Eintrag
        // eines anderen Benutzers (z.B. root nach `sudo claude`) gefunden werden.
        let env = ProcessInfo.processInfo.environment["USER"] ?? ""
        let user = env.isEmpty ? NSUserName() : env
        let first = await run(["find-generic-password", "-a", user, "-s", service, "-w"])
        if case .notFound = first {
            return await run(["find-generic-password", "-s", service, "-w"])
        }
        return first
    }

    private static func run(_ arguments: [String], timeout: TimeInterval = 5) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                process.arguments = arguments
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failed("security ließ sich nicht starten"))
                    return
                }
                // Sollte doch eine Rückfrage erscheinen, nicht ewig warten.
                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                switch (process.terminationReason, process.terminationStatus) {
                case (.exit, 0): continuation.resume(returning: .found(data))
                case (.exit, 44): continuation.resume(returning: .notFound)  // errSecItemNotFound
                case (.uncaughtSignal, _): continuation.resume(returning: .failed("Schlüsselbund antwortet nicht"))
                case (_, let code): continuation.resume(returning: .failed("Schlüsselbund-Fehler \(code)"))
                }
            }
        }
    }
}

private extension Data {
    /// Hex-Text (z.B. "7b22…") in Bytes.
    init?(hex: String) {
        let chars = Array(hex.utf8)
        guard !chars.isEmpty, chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = Self.nibble(chars[i]), let lo = Self.nibble(chars[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
            i += 2
        }
        self.init(bytes)
    }

    static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }
}

/// Holt die Nutzung je Konto von derselben Stelle wie `/usage` in Claude Code. Es wird nichts
/// verändert, nur gelesen. Abgefragt wird beim Öffnen der Liste und, wenn die Widgets eingeschaltet
/// sind, im Hintergrund in einem festen Abstand. api.anthropic.com sperrt bei zu vielen Abfragen
/// schnell für eine Weile; dann wartet die App von selbst länger (5 Minuten bis 1 Stunde).
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
        case rateLimited(until: Date)
        case unavailable(String)
        case failed(String)

        /// Kurz, für Notch, Menü und Einstellungen.
        var text: String {
            switch self {
            case .idle, .loading: return "wird geladen …"
            case .ok: return ""
            case .noCredentials: return "nicht angemeldet (claude, dann /login)"
            case .expired: return "Anmeldung abgelaufen, Konto einmal in Claude Code benutzen"
            case .denied: return "Zugriff auf den Schlüsselbund abgelehnt"
            case .rateLimited(let until): return "zu viele Abfragen, wieder ab \(Self.clock(until))"
            case .unavailable(let why): return why
            case .failed(let why): return "gerade nicht verfügbar (\(why))"
            }
        }

        var feedStatus: WidgetFeed.Status {
            switch self {
            case .ok, .rateLimited: return .ok
            case .idle, .loading: return .loading
            case .noCredentials: return .noCredentials
            case .expired: return .expired
            case .denied: return .denied
            case .unavailable, .failed: return .failed
            }
        }

        /// Kurzer Hinweis für die Widgets.
        var widgetText: String {
            switch self {
            case .ok, .idle, .loading, .rateLimited: return ""
            case .noCredentials: return "Nicht angemeldet"
            case .expired: return "Anmeldung abgelaufen"
            case .denied: return "Kein Zugriff auf den Schlüsselbund"
            case .unavailable: return "Nicht verfügbar"
            case .failed: return "Gerade nicht verfügbar"
            }
        }

        private static func clock(_ date: Date) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "de_DE")
            f.dateFormat = "HH:mm"
            return f.string(from: date)
        }
    }

    struct AccountUsage: Equatable {
        var snapshot: UsageSnapshot?
        var status: Status = .idle
    }

    /// Stand je Konto (Schlüssel: ClaudeAccount.id).
    @Published private(set) var usage: [String: AccountUsage] = [:]

    private let prefs = Preferences.shared
    private var batch: Task<Void, Never>?
    /// Der Token bleibt nach dem ersten Lesen im Speicher und wird erst neu gelesen, wenn er abläuft.
    private var tokens: [String: ClaudeCredentials.Token] = [:]
    private var lastAttempt: [String: Date] = [:]
    private var deniedAt: [String: Date] = [:]
    /// Nach einer Sperre (HTTP 429) bis dahin nicht fragen.
    private var blockedUntil: [String: Date] = [:]
    private var penalty: [String: TimeInterval] = [:]
    private var timer: Timer?
    private var timerMinutes = 0
    private var started = false
    private var widgetsWereEnabled = false
    private var lastWidgetSignature: String?
    private var lastWidgetReload: Date?
    private var cancellables: Set<AnyCancellable> = []
    private var wakeObserver: NSObjectProtocol?

    private enum FetchError: Error {
        case noCredentials, expired, denied
        case rateLimited(retryAfter: TimeInterval?)
        case unavailable(String)
        case failed(String)
    }

    private init() {}

    /// Beim App-Start: Zeitplan für die Widgets einrichten und Einstellungen beobachten.
    func start() {
        guard !started else { return }
        started = true
        widgetsWereEnabled = prefs.widgetsEnabled
        prefs.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // objectWillChange kommt vor der Änderung, also erst danach auswerten.
                DispatchQueue.main.async { self?.preferencesChanged() }
            }
            .store(in: &cancellables)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                guard let self, self.prefs.widgetsEnabled else { return }
                self.refreshAll(interactive: false, maxAge: Double(self.prefs.widgetRefreshMinutes) * 30)
            }
        }
        configureTimer()
        if prefs.widgetsEnabled {
            refreshAll(interactive: false, maxAge: 0)
        } else {
            WidgetFeedStore.remove()
        }
    }

    func state(for account: ClaudeAccount) -> AccountUsage {
        usage[account.id] ?? AccountUsage()
    }

    /// Beim Öffnen der Liste: Konten neu laden, deren Stand älter als `maxAge` Sekunden ist.
    /// Darf notfalls nach dem Schlüsselbund fragen, du hast ja gerade selbst nachgesehen.
    func refreshIfStale(maxAge: TimeInterval = 180) {
        guard prefs.showUsage else { return }
        refreshAll(interactive: true, maxAge: maxAge)
    }

    /// „Jetzt aktualisieren“ in den Einstellungen. Eine laufende Sperre gilt trotzdem.
    func refreshNow() {
        refreshAll(interactive: true, maxAge: 0)
    }

    /// Laufende Abfrage abbrechen (z.B. beim Ausschalten der Anzeige).
    func stop() {
        guard !prefs.widgetsEnabled else { return }
        batch?.cancel()
        batch = nil
    }

    private func refreshAll(interactive: Bool, maxAge: TimeInterval) {
        guard prefs.showUsage || prefs.widgetsEnabled, batch == nil else { return }
        let now = Date()
        let due = prefs.accounts.filter { isDue($0, now: now, maxAge: maxAge) }
        guard !due.isEmpty else { return }
        for account in due where usage[account.id]?.snapshot == nil {
            usage[account.id, default: AccountUsage()].status = .loading
        }
        // Nacheinander, damit höchstens eine Rückfrage des Schlüsselbunds auf einmal erscheint.
        batch = Task { [weak self] in
            for account in due {
                guard let self, !Task.isCancelled else { break }
                await self.load(account, interactive: interactive)
            }
            self?.batch = nil
            self?.publishWidgets()
        }
    }

    private func isDue(_ account: ClaudeAccount, now: Date, maxAge: TimeInterval) -> Bool {
        if let until = blockedUntil[account.id], until > now { return false }
        // Nach „Nicht erlauben“ eine Weile nicht erneut fragen.
        if let denied = deniedAt[account.id], now.timeIntervalSince(denied) < 15 * 60 { return false }
        if let last = lastAttempt[account.id], now.timeIntervalSince(last) < maxAge { return false }
        return true
    }

    private func load(_ account: ClaudeAccount, interactive: Bool) async {
        let id = account.id
        lastAttempt[id] = Date()
        do {
            let (token, snapshot) = try await Self.fetch(account, cached: tokens[id], interactive: interactive)
            // Das Konto wurde inzwischen entfernt: nichts mehr ablegen.
            guard prefs.account(id: id) != nil else { return }
            tokens[id] = token
            penalty[id] = nil
            blockedUntil[id] = nil
            usage[id] = AccountUsage(snapshot: snapshot, status: .ok)
        } catch let error as FetchError {
            guard prefs.account(id: id) != nil else { return }
            var state = usage[id] ?? AccountUsage()
            switch error {
            case .noCredentials:
                tokens[id] = nil
                state.snapshot = nil
                state.status = .noCredentials
            case .expired:
                tokens[id] = nil
                state.status = .expired
            case .denied:
                tokens[id] = nil
                deniedAt[id] = Date()
                state.status = .denied
            case .rateLimited(let retryAfter):
                // 5, 10, 20, 40, 60 Minuten. Ein Retry-After vom Server gilt, wenn er länger ist.
                let next = min(max((penalty[id] ?? 150) * 2, 300), 3600)
                penalty[id] = next
                let until = Date().addingTimeInterval(max(retryAfter ?? 0, next))
                blockedUntil[id] = until
                state.status = .rateLimited(until: until)
            case .unavailable(let why):
                blockedUntil[id] = Date().addingTimeInterval(3600)
                state.status = .unavailable(why)
            case .failed(let why):
                state.status = .failed(why)
            }
            usage[id] = state
        } catch {
            usage[id, default: AccountUsage()].status = .failed(error.localizedDescription)
        }
    }

    // MARK: - Abfrage

    private enum Response {
        case ok([String: Any])
        case unauthorized
    }

    /// Läuft abseits des Main-Threads, damit eine Rückfrage des Schlüsselbunds nichts blockiert.
    private nonisolated static func fetch(_ account: ClaudeAccount, cached: ClaudeCredentials.Token?,
                                          interactive: Bool) async throws -> (ClaudeCredentials.Token, UsageSnapshot) {
        var token = cached
        if let t = token, let expires = t.expiresAt, expires < Date() { token = nil }
        let fromCache = token != nil
        if token == nil { token = try await readToken(account, interactive: interactive) }
        guard var current = token else { throw FetchError.noCredentials }
        if let expires = current.expiresAt, expires < Date() { throw FetchError.expired }

        var response = try await request(current)
        if case .unauthorized = response, fromCache {
            // Claude Code hat den Token inzwischen vielleicht erneuert: einmal frisch lesen.
            let fresh = try await readToken(account, interactive: interactive)
            if fresh.accessToken != current.accessToken {
                current = fresh
                response = try await request(current)
            }
        }
        guard case .ok(let obj) = response else { throw FetchError.expired }
        let windows = parseWindows(obj)
        guard !windows.isEmpty else { throw FetchError.failed("keine Limits in der Antwort") }
        return (current, UsageSnapshot(windows: windows, fetchedAt: Date()))
    }

    private nonisolated static func readToken(_ account: ClaudeAccount, interactive: Bool) async throws -> ClaudeCredentials.Token {
        switch await ClaudeCredentials.read(for: account, interactive: interactive) {
        case .found(let token): return token
        case .missing: throw FetchError.noCredentials
        case .denied: throw FetchError.denied
        case .failed(let why): throw FetchError.failed(why)
        }
    }

    private nonisolated static func request(_ token: ClaudeCredentials.Token) async throws -> Response {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        request.setValue("notchwerk/\(version)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.failed("keine Antwort") }
        switch http.statusCode {
        case 200..<300:
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw FetchError.failed("unlesbare Antwort")
            }
            return .ok(obj)
        case 401:
            return .unauthorized
        case 403:
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("user:profile") {
                throw FetchError.unavailable("Login ohne Zugriff auf die Nutzung, einmal neu anmelden (/login)")
            }
            if body.contains("oauth_not_allowed_for_organization") {
                throw FetchError.unavailable("von deiner Organisation nicht freigegeben")
            }
            return .unauthorized
        case 429:
            throw FetchError.rateLimited(retryAfter: retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
        default:
            throw FetchError.failed("HTTP \(http.statusCode)")
        }
    }

    /// Retry-After als Sekunden oder als HTTP-Datum. 0 oder Vergangenheit zählen nicht.
    private nonisolated static func retryAfter(_ value: String?) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return seconds > 0 ? seconds : nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = f.date(from: value) else { return nil }
        let seconds = date.timeIntervalSinceNow
        return seconds > 0 ? seconds : nil
    }

    /// Seit Mitte 2026 stehen die Limits in einer Liste „limits“: session, weekly_all und je Modell
    /// weekly_scoped (z.B. Fable). Die älteren Felder five_hour, seven_day, seven_day_opus und
    /// seven_day_sonnet dienen als Ersatz, wenn die Liste fehlt. Unbekanntes wird übersprungen.
    nonisolated static func parseWindows(_ obj: [String: Any]) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        func add(_ id: String, _ title: String, _ percent: Double, _ resets: Date?) {
            guard !windows.contains(where: { $0.id == id }) else { return }
            windows.append(UsageWindow(id: id, title: title, percent: max(percent, 0), resetsAt: resets))
        }

        for limit in obj["limits"] as? [[String: Any]] ?? [] {
            guard let kind = limit["kind"] as? String, let percent = number(limit["percent"]) else { continue }
            let resets = (limit["resets_at"] as? String).flatMap(parseDate)
            switch kind {
            case "session":
                add("five_hour", "Sitzung", percent, resets)
            case "weekly_all":
                add("seven_day", "Woche", percent, resets)
            case "weekly_scoped":
                let model = (limit["scope"] as? [String: Any])?["model"] as? [String: Any]
                guard let name = (model?["display_name"] as? String) ?? (model?["id"] as? String),
                      !name.isEmpty else { continue }
                add("seven_day_" + slug(name), name, percent, resets)
            default:
                continue
            }
        }

        let flat: [(key: String, title: String)] = [
            ("five_hour", "Sitzung"),
            ("seven_day", "Woche"),
            ("seven_day_opus", "Opus"),
            ("seven_day_sonnet", "Sonnet"),
        ]
        for entry in flat {
            guard let w = obj[entry.key] as? [String: Any], let percent = number(w["utilization"]) else { continue }
            add(entry.key, entry.title, percent, (w["resets_at"] as? String).flatMap(parseDate))
        }

        // Sitzung, dann Woche, dann die Modelle in der Reihenfolge der Antwort.
        func rank(_ w: UsageWindow) -> Int { w.id == "five_hour" ? 0 : (w.id == "seven_day" ? 1 : 2) }
        return windows.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    private nonisolated static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    private nonisolated static func slug(_ text: String) -> String {
        String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    private nonisolated static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: text) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    // MARK: - Einstellungen und Zeitplan

    private func preferencesChanged() {
        // Entfernte Konten vergessen.
        let ids = Set(prefs.accounts.map(\.id))
        for id in Array(usage.keys) where !ids.contains(id) { usage[id] = nil }
        for id in Array(tokens.keys) where !ids.contains(id) { tokens[id] = nil }

        configureTimer()
        if prefs.widgetsEnabled != widgetsWereEnabled {
            widgetsWereEnabled = prefs.widgetsEnabled
            if prefs.widgetsEnabled {
                refreshAll(interactive: false, maxAge: 60)
            } else {
                // Widgets zeigen dann wieder den Hinweis zum Einschalten statt alter Zahlen.
                WidgetFeedStore.remove()
                lastWidgetSignature = nil
                WidgetCenter.shared.reloadAllTimelines()
                return
            }
        }
        // Neues Konto: gleich laden. Namen oder Auswahl geändert: Widgets neu beschreiben.
        if prefs.showUsage || prefs.widgetsEnabled,
           prefs.accounts.contains(where: { usage[$0.id] == nil }) {
            refreshAll(interactive: prefs.showUsage, maxAge: 60)
        }
        publishWidgets()
    }

    private func configureTimer() {
        let minutes = prefs.widgetsEnabled ? prefs.widgetRefreshMinutes : 0
        guard minutes != timerMinutes else { return }
        timer?.invalidate()
        timer = nil
        timerMinutes = minutes
        guard minutes > 0 else { return }
        let interval = TimeInterval(minutes * 60)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll(interactive: false, maxAge: interval - 60) }
        }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Widgets

    /// Schreibt die Datei für die Widgets und lädt sie neu, wenn sich etwas Sichtbares geändert hat
    /// (oder spätestens nach 25 Minuten, damit „Stand“ stimmt). macOS rationiert das Neuladen.
    private func publishWidgets() {
        guard prefs.widgetsEnabled else { return }
        let accounts = prefs.accounts.filter(\.showInWidgets).map { account -> WidgetFeed.Account in
            let state = usage[account.id] ?? AccountUsage()
            return WidgetFeed.Account(
                id: account.id,
                name: account.name,
                status: state.status.feedStatus,
                message: state.status.widgetText,
                fetchedAt: state.snapshot?.fetchedAt,
                windows: (state.snapshot?.windows ?? []).map {
                    WidgetFeed.Window(key: $0.id, title: $0.title, percent: $0.percent, resetsAt: $0.resetsAt)
                })
        }
        let feed = WidgetFeed(updatedAt: Date(), refreshMinutes: prefs.widgetRefreshMinutes, accounts: accounts)
        do {
            try WidgetFeedStore.write(feed)
        } catch {
            NSLog("Notchwerk: Widget-Datei konnte nicht geschrieben werden: \(error)")
            return
        }
        let signature = accounts.map { a in
            "\(a.id)|\(a.name)|\(a.status.rawValue)|\(a.message)|" + a.windows.map {
                "\($0.key)=\(Int($0.percent.rounded()))@\(Int(($0.resetsAt?.timeIntervalSince1970 ?? 0) / 60))"
            }.joined(separator: ",")
        }.joined(separator: ";")
        let overdue = lastWidgetReload.map { Date().timeIntervalSince($0) > 25 * 60 } ?? true
        if signature != lastWidgetSignature || overdue {
            lastWidgetSignature = signature
            lastWidgetReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
