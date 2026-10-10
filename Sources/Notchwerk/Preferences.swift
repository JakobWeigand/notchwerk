import Foundation

/// Einstellungen, gespeichert in den UserDefaults.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    enum Placement: String, CaseIterable {
        case topCenter
        case topRight

        var title: String {
            switch self {
            case .topCenter: return "Oben mittig"
            case .topRight: return "Oben rechts"
            }
        }
    }

    enum DisplayMode: String, CaseIterable {
        case notch     // am Notch (oder oben rechts/mittig ohne Notch)
        case floating  // kleiner schwebender Reiter, frei verschiebbar

        var title: String {
            switch self {
            case .notch: return "Am Notch"
            case .floating: return "Schwebender Reiter (frei verschiebbar)"
            }
        }
    }

    /// Wie groß die aufgeklappte Liste ist: Breite und wie viele Sitzungen ohne Scrollen hineinpassen.
    enum ListSize: String, CaseIterable {
        case small, normal, large, extraLarge

        var title: String {
            switch self {
            case .small: return "Klein"
            case .normal: return "Normal"
            case .large: return "Groß"
            case .extraLarge: return "Sehr groß"
            }
        }

        var width: CGFloat {
            switch self {
            case .small: return 380
            case .normal: return 430
            case .large: return 520
            case .extraLarge: return 620
            }
        }

        var rows: Int {
            switch self {
            case .small: return 2
            case .normal: return 3
            case .large: return 5
            case .extraLarge: return 7
            }
        }
    }

    /// Auswahl für den Abstand unter dem Notch. 1 mm sind auf einem MacBook-Display etwa 5 Punkte.
    static let extensionChoices: [(title: String, value: Double)] = [
        ("Keiner", 0),
        ("Klein (½ mm)", 3),
        ("Normal (1 mm)", 5),
        ("Groß (1½ mm)", 8),
        ("Sehr groß (2½ mm)", 12),
    ]

    private let defaults = UserDefaults.standard

    /// Aus = Anzeige pausiert: nichts wird gezeigt, Freigaben und Fragen laufen wie gewohnt im Terminal.
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled") } }
    /// Am Notch oder als schwebender Reiter.
    @Published var displayMode: DisplayMode { didSet { defaults.set(displayMode.rawValue, forKey: "displayMode") } }
    /// Mitte des schwebenden Reiters in Bildschirmpunkten (-1 = noch nie verschoben).
    @Published var floatingX: Double { didSet { defaults.set(floatingX, forKey: "floatingX") } }
    @Published var floatingY: Double { didSet { defaults.set(floatingY, forKey: "floatingY") } }
    /// Orangener Rand um den Notch auch im Ruhezustand.
    @Published var alwaysShowRim: Bool { didSet { defaults.set(alwaysShowRim, forKey: "alwaysShowRim") } }
    /// Position auf Bildschirmen ohne Notch (z.B. externer Monitor bei zugeklapptem MacBook).
    @Published var placementWithoutNotch: Placement { didSet { defaults.set(placementWithoutNotch.rawValue, forKey: "placementWithoutNotch") } }
    /// Auf jedem angeschlossenen Bildschirm anzeigen statt nur auf dem Hauptbildschirm.
    @Published var showOnAllScreens: Bool { didSet { defaults.set(showOnAllScreens, forKey: "showOnAllScreens") } }
    /// Freigaben direkt im Notch beantworten (sonst nur Hinweis, Antwort im Terminal).
    @Published var answerInNotch: Bool { didSet { defaults.set(answerInNotch, forKey: "answerInNotch") } }
    /// Fragen von Claude (AskUserQuestion) direkt im Notch beantworten. Experimentell.
    @Published var answerQuestionsInNotch: Bool { didSet { defaults.set(answerQuestionsInNotch, forKey: "answerQuestionsInNotch") } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    /// Kurz aufklappen wenn die Claude App gestartet wird.
    @Published var greetOnClaudeLaunch: Bool { didSet { defaults.set(greetOnClaudeLaunch, forKey: "greetOnClaudeLaunch") } }
    /// Beim Überfahren mit der Maus die Sitzungsliste aufklappen (nur am Notch; oben rechts gilt Klick).
    @Published var expandOnHover: Bool { didSet { defaults.set(expandOnHover, forKey: "expandOnHover") } }
    /// Sekunden bis eine offene Freigabe an das Terminal zurückgegeben wird.
    @Published var permissionTimeout: Double { didSet { defaults.set(permissionTimeout, forKey: "permissionTimeout") } }
    /// Um so viele Punkte sitzt der orangene Rand tiefer als der Notch, damit nichts vom Notch hervorschaut.
    @Published var notchExtension: Double { didSet { defaults.set(notchExtension, forKey: "notchExtension") } }
    /// Laufende Sitzungen dauerhaft unter dem Notch zeigen, solange Claude arbeitet.
    /// Standard aus: die Liste erscheint beim Überfahren und verschwindet wieder.
    @Published var showSessionsInNotch: Bool { didSet { defaults.set(showSessionsInNotch, forKey: "showSessionsInNotch") } }
    /// Höchstens so viele Zeilen unter dem Notch. Mehr gibt es nach einem Klick zum Scrollen.
    @Published var compactRows: Int { didSet { defaults.set(compactRows, forKey: "compactRows") } }
    /// Nutzung (Sitzungs- und Wochenlimit) unten in der aufgeklappten Liste zeigen.
    @Published var showUsage: Bool { didSet { defaults.set(showUsage, forKey: "showUsage") } }
    /// Claude Code Konten (Konfigurationsordner). Das Standardkonto ~/.claude steht immer vorn.
    @Published var accounts: [ClaudeAccount] {
        didSet {
            let fixed = Self.withDefault(accounts)
            if fixed != accounts { accounts = fixed; return }
            if let data = try? JSONEncoder().encode(accounts) { defaults.set(data, forKey: "accounts") }
        }
    }
    /// Widgets auf dem Schreibtisch mit Nutzungsdaten versorgen. Dafür fragt die App auch im
    /// Hintergrund nach, alle `widgetRefreshMinutes` Minuten.
    @Published var widgetsEnabled: Bool { didSet { defaults.set(widgetsEnabled, forKey: "widgetsEnabled") } }
    @Published var widgetRefreshMinutes: Int { didSet { defaults.set(widgetRefreshMinutes, forKey: "widgetRefreshMinutes") } }
    /// Das Maskottchen in der Menüleiste läuft mit, solange Claude arbeitet, und winkt, wenn Claude dich braucht.
    @Published var animateMenuBarIcon: Bool { didSet { defaults.set(animateMenuBarIcon, forKey: "animateMenuBarIcon") } }
    /// Größe der aufgeklappten Liste.
    @Published var listSize: ListSize { didSet { defaults.set(listSize.rawValue, forKey: "listSize") } }
    /// Höhe des Maskottchens oben rechts und beim schwebenden Reiter, in Punkten.
    @Published var mascotSize: Double { didSet { defaults.set(mascotSize, forKey: "mascotSize") } }
    /// Projektordner (git-Checkout), aus dem die App gebaut wurde. Dann aktualisiert sie sich daraus
    /// (git pull und bauen), sonst über GitHub Releases. Trägt scripts/install.sh ein.
    @Published var sourceDir: String? { didSet { defaults.set(sourceDir, forKey: "sourceDir") } }
    /// Einmal am Tag nachsehen, ob es eine neue Version gibt.
    @Published var autoCheckUpdates: Bool { didSet { defaults.set(autoCheckUpdates, forKey: "autoCheckUpdates") } }

    static let mascotSizeRange: ClosedRange<Double> = 20...80
    /// Stufen fürs Menü. Klein ist die bisherige Größe.
    static let mascotSizeChoices: [(title: String, value: Double)] = [
        ("Klein", 24), ("Mittel", 36), ("Groß", 52), ("Sehr groß", 72),
    ]

    /// Abstände für das Aktualisieren im Hintergrund. Seltener als alle 10 Minuten, weil
    /// api.anthropic.com häufige Abfragen schnell mit einer Sperre beantwortet.
    static let widgetRefreshChoices = [10, 15, 30, 60]

    private init() {
        defaults.register(defaults: [
            "enabled": true,
            "displayMode": DisplayMode.notch.rawValue,
            "floatingX": -1.0,
            "floatingY": -1.0,
            "alwaysShowRim": true,
            "placementWithoutNotch": Placement.topRight.rawValue,
            "showOnAllScreens": false,
            "answerInNotch": true,
            "answerQuestionsInNotch": false,
            "playSounds": true,
            "greetOnClaudeLaunch": true,
            "expandOnHover": true,
            "permissionTimeout": 600.0,
            "notchExtension": 5.0,
            "showSessionsInNotch": false,
            "compactRows": 2,
            "showUsage": false,
            "widgetsEnabled": false,
            "widgetRefreshMinutes": 15,
            "animateMenuBarIcon": true,
            "mascotSize": 24.0,
            "listSize": ListSize.normal.rawValue,
            "autoCheckUpdates": false,
        ])
        enabled = defaults.bool(forKey: "enabled")
        displayMode = DisplayMode(rawValue: defaults.string(forKey: "displayMode") ?? "") ?? .notch
        floatingX = defaults.double(forKey: "floatingX")
        floatingY = defaults.double(forKey: "floatingY")
        alwaysShowRim = defaults.bool(forKey: "alwaysShowRim")
        placementWithoutNotch = Placement(rawValue: defaults.string(forKey: "placementWithoutNotch") ?? "") ?? .topRight
        showOnAllScreens = defaults.bool(forKey: "showOnAllScreens")
        answerInNotch = defaults.bool(forKey: "answerInNotch")
        answerQuestionsInNotch = defaults.bool(forKey: "answerQuestionsInNotch")
        playSounds = defaults.bool(forKey: "playSounds")
        greetOnClaudeLaunch = defaults.bool(forKey: "greetOnClaudeLaunch")
        expandOnHover = defaults.bool(forKey: "expandOnHover")
        permissionTimeout = defaults.double(forKey: "permissionTimeout")
        notchExtension = defaults.double(forKey: "notchExtension")
        showSessionsInNotch = defaults.bool(forKey: "showSessionsInNotch")
        compactRows = min(max(defaults.integer(forKey: "compactRows"), 1), 3)
        showUsage = defaults.bool(forKey: "showUsage")
        let saved = defaults.data(forKey: "accounts").flatMap { try? JSONDecoder().decode([ClaudeAccount].self, from: $0) }
        accounts = Self.withDefault(saved ?? [])
        widgetsEnabled = defaults.bool(forKey: "widgetsEnabled")
        let minutes = defaults.integer(forKey: "widgetRefreshMinutes")
        widgetRefreshMinutes = Self.widgetRefreshChoices.contains(minutes) ? minutes : 15
        animateMenuBarIcon = defaults.bool(forKey: "animateMenuBarIcon")
        mascotSize = min(max(defaults.double(forKey: "mascotSize"), Self.mascotSizeRange.lowerBound), Self.mascotSizeRange.upperBound)
        listSize = ListSize(rawValue: defaults.string(forKey: "listSize") ?? "") ?? .normal
        sourceDir = defaults.string(forKey: "sourceDir").flatMap { $0.isEmpty ? nil : $0 }
        autoCheckUpdates = defaults.bool(forKey: "autoCheckUpdates")
    }

    /// Standardkonto vorn, jeder Ordner nur einmal.
    private static func withDefault(_ list: [ClaudeAccount]) -> [ClaudeAccount] {
        var seen = Set<String>()
        var out: [ClaudeAccount] = []
        let def = list.first(where: \.isDefault) ?? .makeDefault()
        for account in [def] + list.filter({ !$0.isDefault }) where seen.insert(account.configDir).inserted {
            out.append(account)
        }
        return out
    }
}

extension Preferences {
    /// Konto, zu dem eine Sitzung gehört (über den Pfad des Transkripts). Längster passender Ordner gewinnt.
    func account(forTranscript path: String?) -> ClaudeAccount? {
        guard let path, !path.isEmpty else { return nil }
        return accounts.filter { $0.owns(transcriptPath: path) }.max { $0.configDir.count < $1.configDir.count }
    }

    func account(id: String) -> ClaudeAccount? {
        accounts.first { $0.id == id }
    }

    /// CLAUDE_CONFIG_DIR so merken, wie der Hook ihn gemeldet hat. Schreibt nur bei einer Änderung.
    func rememberEnvValue(_ value: String?, for id: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }), accounts[i].envValue != value else { return }
        accounts[i].envValue = value
    }
}

extension Preferences {
    /// Gespeicherte Position des schwebenden Reiters, falls er schon einmal verschoben wurde.
    var floatingPosition: CGPoint? {
        get { floatingX < 0 || floatingY < 0 ? nil : CGPoint(x: floatingX, y: floatingY) }
        set {
            floatingX = newValue.map { Double($0.x) } ?? -1
            floatingY = newValue.map { Double($0.y) } ?? -1
        }
    }
}
