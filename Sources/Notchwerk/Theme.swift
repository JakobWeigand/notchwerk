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

    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.74)
    static let softSpring = Animation.spring(response: 0.55, dampingFraction: 0.86)
}
