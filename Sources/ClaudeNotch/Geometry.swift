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
        style == .corner ? CGSize(width: 460, height: 380) : CGSize(width: 680, height: 380)
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
    /// Höhe einer Sitzungszeile.
    static let rowHeight: CGFloat = 26
    /// Kopfzeile (und Ruhe-Kachel) auf Bildschirmen ohne Notch.
    static let cornerHeader: CGFloat = 46
    static let listHeader: CGFloat = 22
    /// Zeile mit den Nutzungsringen unter der Liste (Trennlinie eingerechnet).
    static let usageHeight: CGFloat = 50

    static func presentation(model: NotchModel, prefs: Preferences, geometry g: ScreenGeometry,
                             hovering: Bool, pinned: Bool) -> Presentation {
        if let req = model.currentRequest { return .request(req.id) }
        if let banner = model.banner { return .banner(banner.id) }
        if pinned { return .sessions }
        // Oben rechts (ohne Notch) öffnet nur ein Klick die Liste, nicht das Überfahren.
        if hovering && prefs.expandOnHover && g.style != .corner { return .sessions }
        if !model.activeSessions.isEmpty { return .compact }
        if prefs.alwaysShowRim || model.claudeAppRunning || !model.sessions.isEmpty { return .rim }
        return .hidden
    }

    /// Zeigt der Zustand Sitzungszeilen direkt unter dem Notch?
    static func showsRows(_ p: Presentation, model: NotchModel, prefs: Preferences) -> Bool {
        p == .compact && prefs.showSessionsInNotch && !model.activeSessions.isEmpty
    }

    static func size(for p: Presentation, model: NotchModel, prefs: Preferences, geometry g: ScreenGeometry) -> CGSize {
        let n = g.notchSize
        let corner = g.style == .corner
        let ext: CGFloat = corner ? 0 : CGFloat(prefs.notchExtension)
        let expandedWidth: CGFloat = corner ? 430 : max(n.width + 2 * wing, 480)
        let top: CGFloat = corner ? cornerHeader : n.height + ext
        let rows = prefs.compactRows
        let active = model.activeSessions.count

        switch p {
        case .hidden:
            return corner ? .zero : n
        case .rim:
            return corner ? CGSize(width: cornerHeader, height: cornerHeader)
                          : CGSize(width: n.width + 8 + ext, height: n.height + 3 + ext)
        case .compact:
            if showsRows(p, model: model, prefs: prefs) {
                let shown = CGFloat(min(active, rows))
                let footer: CGFloat = active > rows ? 16 : 0
                return CGSize(width: expandedWidth, height: top + 4 + shown * rowHeight + footer + 10)
            }
            return corner ? CGSize(width: 250, height: cornerHeader)
                          : CGSize(width: n.width + 2 * wing, height: n.height + ext)
        case .banner:
            return CGSize(width: expandedWidth, height: top + 74)
        case .sessions:
            let body: CGFloat = active == 0 ? 40 : listRows(active: active, max: rows) * rowHeight
            let footer: CGFloat = model.idleCount > 0 ? 16 : 0
            let usage: CGFloat = prefs.showUsage ? usageHeight : 0
            return CGSize(width: expandedWidth, height: top + 6 + listHeader + 4 + body + footer + usage + 12)
        case .request:
            return CGSize(width: expandedWidth, height: top + requestHeight(model.currentRequest))
        }
    }

    /// Sichtbare Zeilen in der Liste: höchstens `max`, bei mehr eine halbe Zeile als Hinweis zum Scrollen.
    static func listRows(active: Int, max rows: Int) -> CGFloat {
        active <= rows ? CGFloat(active) : CGFloat(rows) + 0.5
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
