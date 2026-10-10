import AppKit
import NotchwerkShared
import SwiftUI

/// An welcher Ecke des Fensters die Anzeige hängt und wohin sie aufklappt.
enum Anchor: Equatable {
    case topTrailing, topLeading, bottomTrailing, bottomLeading

    var alignment: Alignment {
        switch self {
        case .topTrailing: return .topTrailing
        case .topLeading: return .topLeading
        case .bottomTrailing: return .bottomTrailing
        case .bottomLeading: return .bottomLeading
        }
    }

    /// Inhalt klappt nach oben auf (Kopfzeile unten).
    var flipped: Bool { self == .bottomTrailing || self == .bottomLeading }
    var trailing: Bool { self == .topTrailing || self == .bottomTrailing }
}

/// Beschreibt, wo und wie die Anzeige auf einem Bildschirm sitzt.
struct ScreenGeometry: Equatable {
    enum Style: Equatable {
        case notch     // echter Notch (MacBook-Display)
        case pill      // kein Notch, oben mittig in der Menüleiste
        case corner    // kein Notch, oben rechts unter der Menüleiste
        case floating  // schwebender Reiter, frei verschiebbar
    }

    let style: Style
    /// Größe des (echten oder gedachten) Notch.
    let notchSize: CGSize
    let menuBarHeight: CGFloat

    /// Kachel-Darstellung (Funke in einer Ecke) statt Notch-Form.
    var isTile: Bool { style == .corner || style == .floating }

    /// Fenstergröße. Das Fenster ist durchsichtig und klickt durch, solange die Maus nicht auf der Anzeige ist.
    var panelSize: CGSize {
        switch style {
        // Großzügig, damit auch die größte Liste hineinpasst. Außerhalb der Anzeige klickt das Fenster durch.
        case .floating, .corner: return CGSize(width: 680, height: 600)
        default: return CGSize(width: 780, height: 600)
        }
    }

    @MainActor
    static func make(for screen: NSScreen, placement: Preferences.Placement, mode: Preferences.DisplayMode) -> ScreenGeometry {
        let menuBar = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        if mode == .floating {
            return ScreenGeometry(style: .floating, notchSize: CGSize(width: Layout.cornerHeader, height: Layout.cornerHeader),
                                  menuBarHeight: menuBar)
        }
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
        case .corner, .floating:
            return NSRect(x: screen.frame.maxX - size.width - 10,
                          y: screen.frame.maxY - menuBarHeight - 8 - size.height,
                          width: size.width, height: size.height)
        }
    }

    /// Fensterrahmen für den schwebenden Reiter: Die Kachel sitzt an `center`, der Inhalt klappt
    /// zur Bildschirmmitte hin auf. `center` wird so begrenzt, dass die Kachel sichtbar bleibt.
    /// Mit `rubberBand` stoppt sie am Rand nicht hart, sondern lässt sich mit wachsendem Widerstand
    /// ein Stück darüber hinaus ziehen. `center` im Ergebnis ist immer die begrenzte Stelle.
    @MainActor
    func floatingPlacement(center: CGPoint, tile: CGSize, on screen: NSScreen,
                           rubberBand: Bool = false) -> (frame: NSRect, anchor: Anchor, center: CGPoint) {
        let size = panelSize
        let area = screen.visibleFrame
        var c = center
        c.x = min(max(c.x, area.minX + tile.width / 2), area.maxX - tile.width / 2)
        c.y = min(max(c.y, area.minY + tile.height / 2), area.maxY - tile.height / 2)
        var shown = c
        if rubberBand {
            shown.x += Self.rubberBand(center.x - c.x, dimension: tile.width)
            shown.y += Self.rubberBand(center.y - c.y, dimension: tile.height)
        }
        let left = c.x > area.midX     // Inhalt nach links aufklappen
        let down = c.y > area.midY     // Inhalt nach unten aufklappen
        let x = left ? shown.x + tile.width / 2 - size.width : shown.x - tile.width / 2
        let y = down ? shown.y + tile.height / 2 - size.height : shown.y - tile.height / 2
        let anchor: Anchor = down ? (left ? .topTrailing : .topLeading) : (left ? .bottomTrailing : .bottomLeading)
        return (NSRect(x: x, y: y, width: size.width, height: size.height), anchor, c)
    }

    /// Je weiter über den Rand hinaus, desto weniger folgt die Kachel. Höchstens um `dimension`.
    static func rubberBand(_ overshoot: CGFloat, dimension: CGFloat, constant: CGFloat = 0.55) -> CGFloat {
        overshoot * dimension * constant / (dimension + constant * abs(overshoot))
    }

    @MainActor
    func defaultFloatingCenter(tile: CGSize, on screen: NSScreen) -> CGPoint {
        let area = screen.visibleFrame
        return CGPoint(x: area.maxX - 10 - tile.width / 2, y: area.maxY - 8 - tile.height / 2)
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
    /// Kopfzeile (und Ruhe-Kachel) auf Bildschirmen ohne Notch und beim schwebenden Reiter.
    static let cornerHeader: CGFloat = 46
    static let listHeader: CGFloat = 22
    /// Ruhe-Kachel oben rechts und beim schwebenden Reiter: so groß, dass das Maskottchen in der
    /// eingestellten Größe hineinpasst, mindestens so groß wie die Kopfzeile.
    /// Oben bleibt etwas Luft, damit das Maskottchen hüpfen kann.
    static func idleTile(_ prefs: Preferences) -> CGSize {
        let h = CGFloat(prefs.mascotSize)
        return CGSize(width: max(cornerHeader, (h * ClaudeLogo.aspect).rounded(.up) + 12),
                      height: max(cornerHeader, (h * 1.15).rounded(.up) + 14))
    }

    /// Breite der aufgeklappten Liste.
    static func expandedWidth(prefs: Preferences, geometry g: ScreenGeometry) -> CGFloat {
        g.isTile ? prefs.listSize.width : max(g.notchSize.width + 2 * wing, prefs.listSize.width + 50)
    }

    /// Wie viele Nutzungsringe nebeneinander passen.
    static func maxGauges(prefs: Preferences, geometry g: ScreenGeometry) -> Int {
        max(2, Int((expandedWidth(prefs: prefs, geometry: g) - 40) / 140))
    }

    /// Eine Zeile mit Nutzungsringen (je Konto eine).
    static let usageRowHeight: CGFloat = 43

    /// Konten, deren Nutzung unter der Liste steht. Höchstens drei, damit alles ins Fenster passt.
    static func usageAccounts(_ prefs: Preferences) -> [ClaudeAccount] {
        Array(prefs.accounts.prefix(3))
    }

    /// Höhe des Nutzungsbereichs unter der Liste, Trennlinie eingerechnet.
    static func usageBlockHeight(_ prefs: Preferences) -> CGFloat {
        7 + CGFloat(max(1, usageAccounts(prefs).count)) * usageRowHeight
    }

    static func presentation(model: NotchModel, prefs: Preferences, geometry g: ScreenGeometry,
                             hovering: Bool, pinned: Bool) -> Presentation {
        guard prefs.enabled else { return .hidden }
        if let req = model.currentRequest { return .request(req.id) }
        if let banner = model.banner { return .banner(banner.id) }
        if pinned { return .sessions }
        if hovering && prefs.expandOnHover { return .sessions }
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
        let tile = g.isTile
        let ext: CGFloat = tile ? 0 : CGFloat(prefs.notchExtension)
        let expandedWidth = Layout.expandedWidth(prefs: prefs, geometry: g)
        let top: CGFloat = tile ? cornerHeader : n.height + ext
        let rows = prefs.compactRows
        let active = model.activeSessions.count

        switch p {
        case .hidden:
            return tile ? .zero : n
        case .rim:
            return tile ? idleTile(prefs)
                        : CGSize(width: n.width + 8 + ext, height: n.height + 3 + ext)
        case .compact:
            if showsRows(p, model: model, prefs: prefs) {
                let shown = CGFloat(min(active, rows))
                let footer: CGFloat = active > rows ? 16 : 0
                return CGSize(width: expandedWidth, height: top + 4 + shown * rowHeight + footer + 10)
            }
            // Oben rechts und als Reiter: nur das Maskottchen, das in Ruhe weiterarbeitet.
            return tile ? idleTile(prefs)
                        : CGSize(width: n.width + 2 * wing, height: n.height + ext)
        case .banner:
            return CGSize(width: expandedWidth, height: top + 74)
        case .sessions:
            let body: CGFloat = active == 0 ? 40 : listRows(active: active, max: prefs.listSize.rows) * rowHeight
            let footer: CGFloat = model.idleCount > 0 ? 16 : 0
            let usage: CGFloat = prefs.showUsage ? usageBlockHeight(prefs) : 0
            // Oben rechts und als Reiter hat die Liste keine eigene Kopfzeile, sie beginnt gleich mit „Claude“.
            let head: CGFloat = tile ? 10 : top + 6
            return CGSize(width: expandedWidth, height: head + listHeader + 4 + body + footer + usage + 12)
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
