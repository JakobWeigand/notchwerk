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

    /// Auswahl für den Abstand unter dem Notch. 1 mm sind auf einem MacBook-Display etwa 5 Punkte.
    static let extensionChoices: [(title: String, value: Double)] = [
        ("Keiner", 0),
        ("Klein (½ mm)", 3),
        ("Normal (1 mm)", 5),
        ("Groß (1½ mm)", 8),
        ("Sehr groß (2½ mm)", 12),
    ]

    private let defaults = UserDefaults.standard

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

    private init() {
        defaults.register(defaults: [
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
            "showUsage": true,
        ])
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
    }
}
