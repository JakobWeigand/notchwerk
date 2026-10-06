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
    /// Beim Überfahren mit der Maus die Sitzungsliste aufklappen.
    @Published var expandOnHover: Bool { didSet { defaults.set(expandOnHover, forKey: "expandOnHover") } }
    /// Sekunden bis eine offene Freigabe an das Terminal zurückgegeben wird.
    @Published var permissionTimeout: Double { didSet { defaults.set(permissionTimeout, forKey: "permissionTimeout") } }

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
    }
}
