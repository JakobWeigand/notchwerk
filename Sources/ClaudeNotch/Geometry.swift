import AppKit
import SwiftUI

/// Beschreibt, wo und wie die Anzeige auf einem Bildschirm sitzt.
struct ScreenGeometry: Equatable {
    enum Style: Equatable {
        case notch   // echter Notch (MacBook-Display)
        case pill    // kein Notch, oben mittig in der Menüleiste
        case corner  // kein Notch, oben rechts unter der Menüleiste
    }

    let style: Style
    /// Größe des (echten oder gedachten) Notch.
    let notchSize: CGSize
    let menuBarHeight: CGFloat

    /// Fenstergröße. Das Fenster ist durchsichtig und klickt durch, solange die Maus nicht auf der Anzeige ist.
    var panelSize: CGSize {
        style == .corner ? CGSize(width: 440, height: 380) : CGSize(width: 680, height: 380)
    }

    @MainActor
    static func make(for screen: NSScreen, placement: Preferences.Placement) -> ScreenGeometry {
        let menuBar = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        if #available(macOS 12.0, *), screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return ScreenGeometry(style: .notch,
                                  notchSize: CGSize(width: width, height: screen.safeAreaInsets.top),
                                  menuBarHeight: menuBar)
        }
        switch placement {
        case .topCenter:
            return ScreenGeometry(style: .pill, notchSize: CGSize(width: 150, height: min(menuBar, 32)),
                                  menuBarHeight: menuBar)
        case .topRight:
            return ScreenGeometry(style: .corner, notchSize: CGSize(width: 40, height: 40), menuBarHeight: menuBar)
        }
    }

    @MainActor
    func panelFrame(on screen: NSScreen) -> NSRect {
        let size = panelSize
        switch style {
        case .notch, .pill:
            return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                          width: size.width, height: size.height)
        case .corner:
            return NSRect(x: screen.frame.maxX - size.width - 10,
                          y: screen.frame.maxY - menuBarHeight - 8 - size.height,
                          width: size.width, height: size.height)
        }
    }
}

/// Was gerade angezeigt wird.
enum Presentation: Equatable {
    case hidden
    case rim
    case compact
    case request(UUID)
    case banner(UUID)
    case sessions

    var isExpanded: Bool {
        switch self {
        case .request, .banner, .sessions: return true
        default: return false
        }
    }
}

@MainActor
enum Layout {
    static let wing: CGFloat = 54

    static func presentation(model: NotchModel, prefs: Preferences, hovering: Bool) -> Presentation {
        if let req = model.currentRequest { return .request(req.id) }
        if let banner = model.banner { return .banner(banner.id) }
        if hovering && prefs.expandOnHover { return .sessions }
        if model.isWorking || model.sessions.values.contains(where: { $0.state == .waiting }) { return .compact }
        if prefs.alwaysShowRim || model.claudeAppRunning || !model.sessions.isEmpty { return .rim }
        return .hidden
    }

    static func size(for p: Presentation, model: NotchModel, geometry g: ScreenGeometry) -> CGSize {
        let n = g.notchSize
        let expandedWidth: CGFloat = g.style == .corner ? 380 : max(n.width + 2 * wing, 440)
        let top: CGFloat = g.style == .corner ? 0 : n.height

        switch p {
        case .hidden:
            return g.style == .corner ? .zero : n
        case .rim:
            return g.style == .corner ? CGSize(width: 40, height: 40) : CGSize(width: n.width + 8, height: n.height + 3)
        case .compact:
            return g.style == .corner ? CGSize(width: 250, height: 40) : CGSize(width: n.width + 2 * wing, height: n.height)
        case .banner:
            return CGSize(width: expandedWidth, height: top + 74)
        case .sessions:
            let rows = max(1, min(model.sessions.count, 4))
            return CGSize(width: expandedWidth, height: top + 50 + CGFloat(rows) * 40)
        case .request:
            return CGSize(width: expandedWidth, height: top + requestHeight(model.currentRequest))
        }
    }

    static func requestHeight(_ req: PendingRequest?) -> CGFloat {
        guard let req else { return 120 }
        switch req.kind {
        case .permission: return 176
        case .notice: return 132
        case .question(let set):
            if set.questions.count == 1, !set.questions[0].multiSelect {
                return 112 + CGFloat(min(set.questions[0].options.count, 4)) * 36
            }
            return 150
        }
    }
}
