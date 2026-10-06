import AppKit
import SwiftUI

/// Farben im Stil von Claude (warmes Orange auf fast schwarzem Grund).
enum Theme {
    static let orange = Color(red: 0.851, green: 0.467, blue: 0.341)      // #D97757
    static let orangeBright = Color(red: 0.961, green: 0.588, blue: 0.431) // #F5966E
    static let orangeDeep = Color(red: 0.741, green: 0.365, blue: 0.239)   // #BD5D3D
    static let ink = Color(red: 0.055, green: 0.055, blue: 0.050)          // fast schwarz
    static let cream = Color(red: 0.941, green: 0.933, blue: 0.902)        // #F0EEE6
    static let muted = Color(red: 0.62, green: 0.60, blue: 0.56)
    static let allow = Color(red: 0.42, green: 0.74, blue: 0.47)
    static let deny = Color(red: 0.86, green: 0.36, blue: 0.33)

    static let nsOrange = NSColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1)

    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.74)
    static let softSpring = Animation.spring(response: 0.55, dampingFraction: 0.86)
}
