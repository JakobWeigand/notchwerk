import AppKit
import NotchwerkShared
import SwiftUI

/// Farben im Stil von Claude (warmes Orange auf fast schwarzem Grund).
enum Theme {
    static let orange = Brand.orange
    static let orangeBright = Brand.orangeBright
    static let orangeDeep = Brand.orangeDeep
    static let ink = Brand.ink
    static let cream = Brand.cream
    static let muted = Brand.muted
    static let allow = Brand.allow
    static let deny = Brand.deny

    static let nsOrange = NSColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1)

    /// Bewegung nach Apples Vorbild (siehe Projekte/Design/apple-design): Federn statt fester Dauer,
    /// standardmäßig ohne Nachschwingen. Federn starten vom aktuellen Wert und lassen sich jederzeit
    /// umlenken. Ist in den Bedienungshilfen „Bewegung reduzieren“ an, wird nur kurz überblendet.
    static var spring: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 1)
    }
    static var softSpring: Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.5, dampingFraction: 1)
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// Reagiert schon beim Drücken, nicht erst beim Loslassen: kurz etwas kleiner, beim Loslassen
/// federt es zurück. Mit „Bewegung reduzieren“ wird nur abgedunkelt.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .scaleEffect(pressed && !Theme.reduceMotion ? scale : 1)
            .opacity(pressed && Theme.reduceMotion ? 0.75 : 1)
            .animation(pressed ? .easeOut(duration: 0.08) : Theme.spring, value: pressed)
    }
}
