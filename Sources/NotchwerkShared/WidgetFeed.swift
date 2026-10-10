import Foundation

/// Was die App für die Widgets ablegt: nur Prozentwerte und Zeitpunkte je Konto, nie ein Token
/// und keine E-Mail-Adresse. Liegt in ~/.claude-notch/widget/usage.json. Die Widgets laufen in
/// einer Sandbox und dürfen genau diesen einen Ordner lesen, sonst nichts.
public struct WidgetFeed: Codable, Equatable {
    public static let currentVersion = 1

    public let version: Int
    public let updatedAt: Date
    /// So oft holt die App im Hintergrund neue Zahlen. Daran messen die Widgets, ab wann ein Stand alt ist.
    public let refreshMinutes: Int
    public let accounts: [Account]

    public init(updatedAt: Date, refreshMinutes: Int, accounts: [Account]) {
        self.version = Self.currentVersion
        self.updatedAt = updatedAt
        self.refreshMinutes = refreshMinutes
        self.accounts = accounts
    }

    /// Ab diesem Alter zeigen die Widgets an, von wann die Zahlen sind: zwei verpasste Abrufe, mindestens 30 Minuten.
    public var staleAfter: TimeInterval { max(30 * 60, Double(refreshMinutes * 2 * 60) + 5 * 60) }

    public struct Account: Codable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let status: Status
        /// Kurzer Hinweis, wenn etwas nicht stimmt (z.B. „Anmeldung abgelaufen“), sonst leer.
        public let message: String
        public let fetchedAt: Date?
        public let windows: [Window]

        public init(id: String, name: String, status: Status, message: String, fetchedAt: Date?, windows: [Window]) {
            self.id = id
            self.name = name
            self.status = status
            self.message = message
            self.fetchedAt = fetchedAt
            self.windows = windows
        }

        /// Das Fenster einer Art, falls die Antwort es enthält.
        public func window(_ kind: LimitKind) -> Window? {
            windows.first { LimitKind(key: $0.key) == kind }
        }
    }

    public enum Status: String, Codable {
        case ok, loading, noCredentials, expired, denied, failed
    }

    public struct Window: Codable, Equatable, Identifiable {
        /// Schlüssel aus der Antwort von api.anthropic.com, z.B. five_hour oder seven_day.
        public let key: String
        public let title: String
        /// Genutzt, 0 bis 100.
        public let percent: Double
        public let resetsAt: Date?

        public var id: String { key }
        public var remainingPercent: Int { max(0, 100 - Int(percent.rounded())) }

        public init(key: String, title: String, percent: Double, resetsAt: Date?) {
            self.key = key
            self.title = title
            self.percent = percent
            self.resetsAt = resetsAt
        }

        /// Stand zu einem späteren Zeitpunkt: Nach dem Zurücksetzen ist das Limit wieder frei,
        /// auch wenn die App noch keine neuen Zahlen geholt hat. `resetsAt` bleibt in der
        /// Vergangenheit stehen, daran erkennt die Anzeige „gerade zurückgesetzt“.
        public func projected(at date: Date) -> Window {
            guard let resetsAt, resetsAt <= date else { return self }
            return Window(key: key, title: title, percent: 0, resetsAt: resetsAt)
        }
    }
}

/// Die Arten von Limits, die die Widgets kennen.
public enum LimitKind: Equatable {
    case session      // five_hour
    case week         // seven_day, alle Modelle
    case fable        // Wochenlimit für Fable
    case other(String)

    public init(key: String) {
        switch key {
        case "five_hour": self = .session
        case "seven_day": self = .week
        default: self = key.lowercased().contains("fable") ? .fable : .other(key)
        }
    }
}

/// Lesen und Schreiben der Datei für die Widgets.
public enum WidgetFeedStore {
    /// Der echte Home-Ordner. In der Sandbox der Widgets zeigt NSHomeDirectory() in den Container,
    /// deshalb hier über die Benutzerdatenbank.
    public static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// Relativ zum Home-Ordner, so steht es auch in der Berechtigung der Widgets.
    public static let relativeDirectory = ".claude-notch/widget"
    public static var directory: URL { realHome.appendingPathComponent(relativeDirectory, isDirectory: true) }
    public static var fileURL: URL { directory.appendingPathComponent("usage.json") }

    public static func read() -> WidgetFeed? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let feed = try? decoder.decode(WidgetFeed.self, from: data),
              feed.version == WidgetFeed.currentVersion else { return nil }
        return feed
    }

    public static func write(_ feed: WidgetFeed) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(feed).write(to: fileURL, options: .atomic)
    }

    /// Beim Abschalten der Widgets: Datei entfernen, damit nichts Veraltetes stehen bleibt.
    public static func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
