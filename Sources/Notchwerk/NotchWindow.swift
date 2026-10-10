import AppKit
import Combine
import SwiftUI

/// Rahmenloses, durchsichtiges Fenster über allem, auch über Vollbild-Apps und Videos.
final class NotchPanel: NSPanel {
    convenience init(frame: NSRect) {
        self.init(contentRect: frame,
                  styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered,
                  defer: false)
        isFloatingPanel = true
        level = .screenSaver
        // canJoinAllSpaces: wandert mit auf jeden Schreibtisch (Space) und über Vollbild-Apps.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Damit Buttons schon beim ersten Klick reagieren, ohne dass die App aktiviert werden muss.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Erstellt pro Bildschirm ein Fenster und kümmert sich um Maus, Bildschirmwechsel und Verschieben.
@MainActor
final class NotchController {
    private struct Entry {
        let panel: NotchPanel
        let state: PanelState
        let screen: NSScreen
        var insideSince: Date?
        var outsideSince: Date?
        /// Beim Ziehen des Reiters: Abstand zwischen Mauszeiger und Kachelmitte.
        var grabOffset: CGPoint?
        var floatingCenter: CGPoint
        /// Von außen aufgeklappt (Klick auf ein Widget): bis dahin offen lassen, auch ohne Maus.
        var holdOpenUntil: Date?
    }

    private let model: NotchModel
    private let prefs: Preferences
    private var entries: [Entry] = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var lastLayoutKey = ""

    init(model: NotchModel, prefs: Preferences) {
        self.model = model
        self.prefs = prefs
    }

    func start() {
        rebuild()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildSoon() }
        })
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.bringToFront() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildSoon() }
        })

        prefs.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.rebuildIfLayoutChanged() }
            }
            .store(in: &cancellables)

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.trackMouse() }
        }
    }

    private func layoutKey() -> String {
        "\(prefs.showOnAllScreens)-\(prefs.placementWithoutNotch.rawValue)-\(prefs.displayMode.rawValue)-\(prefs.mascotSize)"
    }

    private func rebuildIfLayoutChanged() {
        if layoutKey() != lastLayoutKey { rebuild() }
    }

    private func rebuildSoon() {
        // Nach dem Auf- oder Zuklappen braucht macOS einen Moment, bis die Bildschirme stimmen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            Task { @MainActor in self?.rebuild() }
        }
    }

    func rebuild() {
        lastLayoutKey = layoutKey()
        for e in entries { e.panel.orderOut(nil) }
        entries.removeAll()

        for screen in targetScreens() {
            let geometry = ScreenGeometry.make(for: screen, placement: prefs.placementWithoutNotch, mode: prefs.displayMode)
            let state = PanelState(geometry: geometry)
            var frame = geometry.panelFrame(on: screen)
            var center = CGPoint.zero
            if geometry.style == .floating {
                let tile = Layout.idleTile(prefs)
                let placed = geometry.floatingPlacement(
                    center: prefs.floatingPosition ?? geometry.defaultFloatingCenter(tile: tile, on: screen),
                    tile: tile, on: screen)
                frame = placed.frame
                state.anchor = placed.anchor
                center = placed.center
            }
            let panel = NotchPanel(frame: frame)
            let root = NotchRootView(model: model, prefs: prefs, panel: state)
            let host = FirstMouseHostingView(rootView: root)
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: geometry.panelSize)
            panel.contentView = host
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            let index = entries.count
            state.onDragMoved = { [weak self] in self?.dragMoved(index) }
            state.onDragEnded = { [weak self] in self?.dragEnded(index) }
            entries.append(Entry(panel: panel, state: state, screen: screen, floatingCenter: center))
        }
    }

    private func targetScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        if prefs.showOnAllScreens { return screens }
        if prefs.displayMode == .floating {
            return NSScreen.main.map { [$0] } ?? screens.first.map { [$0] } ?? []
        }
        // MacBook offen: Bildschirm mit Notch. Zugeklappt: Hauptbildschirm (der mit der Menüleiste).
        if let notched = screens.first(where: { screen in
            if #available(macOS 12.0, *) { return screen.safeAreaInsets.top > 0 }
            return false
        }) {
            return [notched]
        }
        return screens.first.map { [$0] } ?? []
    }

    private func bringToFront() {
        for e in entries { e.panel.orderFrontRegardless() }
    }

    /// Liste mit Sitzungen und Nutzung aufklappen, z.B. nach einem Klick auf ein Widget.
    /// Sie bleibt ein paar Sekunden offen, auch wenn die Maus gerade woanders ist.
    func showList() {
        guard !entries.isEmpty else { return }
        entries[0].holdOpenUntil = Date().addingTimeInterval(8)
        withAnimation(Theme.spring) { entries[0].state.pinned = true }
    }

    // MARK: - Reiter verschieben

    private func dragMoved(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        let mouse = NSEvent.mouseLocation
        if entries[index].grabOffset == nil {
            let c = entries[index].floatingCenter
            entries[index].grabOffset = CGPoint(x: c.x - mouse.x, y: c.y - mouse.y)
        }
        let offset = entries[index].grabOffset ?? .zero
        let target = CGPoint(x: mouse.x + offset.x, y: mouse.y + offset.y)
        let e = entries[index]
        let placed = e.state.geometry.floatingPlacement(center: target, tile: Layout.idleTile(prefs), on: e.screen)
        entries[index].floatingCenter = placed.center
        if e.state.anchor != placed.anchor { e.state.anchor = placed.anchor }
        e.panel.setFrame(placed.frame, display: true)
    }

    private func dragEnded(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        entries[index].grabOffset = nil
        prefs.floatingPosition = entries[index].floatingCenter
    }

    // MARK: - Maus

    /// Das Fenster nimmt nur Klicks an, wenn die Maus wirklich auf der Anzeige ist.
    private func trackMouse() {
        let mouse = NSEvent.mouseLocation
        let now = Date()
        for i in entries.indices {
            let e = entries[i]
            let rect = interactiveRect(for: e)
            let inside = (!rect.isEmpty && rect.insetBy(dx: -4, dy: -4).contains(mouse)) || e.grabOffset != nil
            if e.panel.ignoresMouseEvents == inside {
                e.panel.ignoresMouseEvents = !inside
            }
            if inside {
                entries[i].outsideSince = nil
                entries[i].holdOpenUntil = nil
                if entries[i].insideSince == nil { entries[i].insideSince = now }
                if !e.state.hovering, let since = entries[i].insideSince, now.timeIntervalSince(since) > 0.18 {
                    e.state.hovering = true
                }
            } else {
                entries[i].insideSince = nil
                if entries[i].outsideSince == nil { entries[i].outsideSince = now }
                if e.state.hovering, let since = entries[i].outsideSince, now.timeIntervalSince(since) > 0.45 {
                    e.state.hovering = false
                }
                // Per Klick geöffnete Liste schließt sich, wenn die Maus eine Weile weg ist.
                if e.state.pinned, let since = entries[i].outsideSince, now.timeIntervalSince(since) > 1.5,
                   (e.holdOpenUntil ?? .distantPast) < now {
                    withAnimation(Theme.spring) { e.state.pinned = false }
                }
            }
        }
    }

    private func interactiveRect(for e: Entry) -> NSRect {
        let g = e.state.geometry
        let p = Layout.presentation(model: model, prefs: prefs, geometry: g,
                                    hovering: e.state.hovering, pinned: e.state.pinned)
        var size = Layout.size(for: p, model: model, prefs: prefs, geometry: g)
        // Im Ruhezustand reicht der Notch selbst als Fläche zum Überfahren.
        if size == .zero, !g.isTile { size = g.notchSize }
        let frame = e.panel.frame
        switch g.style {
        case .notch, .pill:
            return NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
                          width: size.width, height: size.height)
        case .corner:
            return NSRect(x: frame.maxX - size.width, y: frame.maxY - size.height,
                          width: size.width, height: size.height)
        case .floating:
            let a = e.state.anchor
            return NSRect(x: a.trailing ? frame.maxX - size.width : frame.minX,
                          y: a.flipped ? frame.minY : frame.maxY - size.height,
                          width: size.width, height: size.height)
        }
    }
}
