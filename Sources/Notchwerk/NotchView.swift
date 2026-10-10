import NotchwerkShared
import SwiftUI

/// Zustand eines einzelnen Fensters (pro Bildschirm).
@MainActor
final class PanelState: ObservableObject {
    @Published var hovering = false
    /// Per Klick aufgeklappt. Schließt sich wieder, wenn die Maus eine Weile weg ist.
    @Published var pinned = false
    @Published var geometry: ScreenGeometry
    /// Ecke, an der die Kachel hängt, und Richtung, in die der Inhalt aufklappt (schwebender Reiter).
    @Published var anchor: Anchor = .topTrailing
    /// Der Reiter wird gezogen: der Controller verschiebt das Fenster unter der Maus mit.
    var onDragMoved: (() -> Void)?
    var onDragEnded: (() -> Void)?

    init(geometry: ScreenGeometry) {
        self.geometry = geometry
    }
}

struct NotchRootView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var prefs: Preferences
    @ObservedObject var panel: PanelState

    var body: some View {
        let g = panel.geometry
        let p = Layout.presentation(model: model, prefs: prefs, geometry: g,
                                    hovering: panel.hovering, pinned: panel.pinned)
        let size = Layout.size(for: p, model: model, prefs: prefs, geometry: g)

        let anchor: Anchor = g.style == .floating ? panel.anchor : .topTrailing
        let alignment: Alignment = g.isTile ? anchor.alignment : .top

        ZStack(alignment: alignment) {
            Color.clear
            NotchBody(model: model, prefs: prefs, presentation: p, geometry: g, pinned: panel.pinned, anchor: anchor,
                      onTap: { togglePinned(p) },
                      onDragMoved: { panel.onDragMoved?() },
                      onDragEnded: { panel.onDragEnded?() })
            .frame(width: size.width, height: size.height)
            .opacity(p == .hidden && g.isTile ? 0 : 1)
        }
        .frame(width: g.panelSize.width, height: g.panelSize.height, alignment: alignment)
        .animation(Theme.spring, value: p)
        .animation(Theme.spring, value: size)
    }

    /// Klick auf die Anzeige klappt die Sitzungsliste auf oder zu. Während einer Anfrage
    /// oder Einblendung passiert nichts, die haben ihre eigenen Knöpfe.
    private func togglePinned(_ p: Presentation) {
        switch p {
        case .request, .banner: return
        default: withAnimation(Theme.spring) { panel.pinned.toggle() }
        }
    }
}

/// Die schwarze Fläche mit orangem Rand und dem Inhalt.
private struct NotchBody: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var prefs: Preferences
    let presentation: Presentation
    let geometry: ScreenGeometry
    let pinned: Bool
    let anchor: Anchor
    let onTap: () -> Void
    let onDragMoved: () -> Void
    let onDragEnded: () -> Void

    private var corner: Bool { geometry.isTile }
    private var expanded: Bool { presentation.isExpanded }
    private var showsRows: Bool { Layout.showsRows(presentation, model: model, prefs: prefs) }
    private var open: Bool { expanded || showsRows }
    private var attention: Bool {
        guard case .request = presentation, let req = model.currentRequest else { return false }
        return req.needsYou
    }
    /// Zusätzlicher Abstand unter dem Notch, damit der Rand nicht am Notch klebt.
    private var ext: CGFloat { corner ? 0 : CGFloat(prefs.notchExtension) }
    /// Oben rechts oder als Reiter, solange nichts aufgeklappt ist: nur das Claude-Maskottchen,
    /// ohne Kasten und Rand. Arbeitet Claude, geht es gemächlich auf der Stelle.
    private var bareLogo: Bool {
        corner && (presentation == .rim || presentation == .hidden || (presentation == .compact && !showsRows))
    }
    /// Die Liste oben rechts und am Reiter kommt ohne Kopfzeile aus: „Claude“ steht in ihr selbst.
    private var headerless: Bool { corner && presentation == .sessions }

    var body: some View {
        ZStack(alignment: anchor.flipped ? .bottom : .top) {
            background
            // Immer dieselbe Ansicht, nur die Form wechselt. Mit if/else entstünde beim Aufklappen eine
            // neue Ansicht, die sofort in voller Größe erscheint, noch bevor der Kasten aufgegangen ist.
            content
                .clipShape(clipShape)
        }
        .contentShape(fillShape)
        .onTapGesture(perform: onTap)
    }

    /// Ziehen am Reiter verschiebt das Fenster. Ein Klick ohne Bewegung bleibt ein Klick.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { _ in onDragMoved() }
            .onEnded { _ in onDragEnded() }
    }

    // MARK: Hintergrund und Rand

    /// Mit „Bewegung reduzieren“ pulsiert der Rand nicht, er leuchtet gleichmäßig.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    private var background: some View {
        let rimVisible = presentation != .hidden && !bareLogo
        let pulsing = (attention || model.isWorking) && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !pulsing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let pulse = !pulsing ? (attention ? 1 : model.isWorking ? 0.6 : 0.35)
                : attention ? 0.5 + 0.5 * sin(t * 4.2) : 0.5 + 0.5 * sin(t * 2.2)
            let glow = rimVisible ? (open ? 0.55 : 0.35) + 0.45 * pulse : 0
            ZStack {
                fillShape.fill(Color.black)
                strokeShape
                    .stroke(Theme.orange.opacity(rimVisible ? 0.95 : 0),
                            style: StrokeStyle(lineWidth: open ? 1.6 : 1.4, lineCap: .round, lineJoin: .round))
                    .shadow(color: Theme.orange.opacity(glow), radius: attention ? 9 : 5)
                    .shadow(color: Theme.orangeBright.opacity(glow * 0.5), radius: 2)
            }
            .modifier(EarlyFade(progress: bareLogo ? 0 : 1))
        }
    }

    private var topRadius: CGFloat { open ? 14 : 7 }
    private var bottomRadius: CGFloat { open ? 24 : (presentation == .compact ? 12 : 10) }
    private var cornerRadius: CGFloat { open ? 22 : (presentation == .rim ? 15 : 20) }

    private var fillShape: AnyShape {
        corner
            ? AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            : AnyShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
    }

    private var strokeShape: AnyShape {
        corner
            ? AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            : AnyShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius, openTop: true))
    }

    /// Ohne Kasten großzügig, sonst stößt das Maskottchen beim Hüpfen oben an.
    private var clipShape: AnyShape {
        bareLogo ? AnyShape(Rectangle().inset(by: -40)) : fillShape
    }

    // MARK: Inhalt

    @ViewBuilder
    private var content: some View {
        let side: CGFloat = corner ? 14 : topRadius + 16

        VStack(spacing: 0) {
            if anchor.flipped {
                Spacer(minLength: 0)
            } else if !headerless {
                headerArea
            }
            if showsRows {
                CompactRowsView(model: model, rows: prefs.compactRows)
                    .padding(.horizontal, side - 6)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                    .transition(contentTransition)
            } else if expanded {
                expandedContent
                    .padding(.horizontal, side)
                    .padding(.top, headerless ? 10 : 6)
                    .padding(.bottom, 12)
                    .transition(contentTransition)
            }
            if anchor.flipped && !headerless {
                headerArea
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    /// Der Inhalt wächst aus der Stelle, an der die Anzeige hängt, und verschwindet auf demselben
    /// Weg wieder. Hinaus etwas schneller, damit er nicht unter dem schrumpfenden Rand zerquetscht wird.
    private var contentTransition: AnyTransition {
        let reveal = AnyTransition.modifier(active: LateFade(progress: 0), identity: LateFade(progress: 1))
        let path: AnyTransition = Theme.reduceMotion
            ? reveal
            : reveal.combined(with: .scale(scale: 0.94, anchor: growAnchor))
        return .asymmetric(insertion: path.animation(Theme.spring),
                           removal: path.animation(.easeOut(duration: 0.15)))
    }

    /// Ursprung der Bewegung: am Notch oben mittig, als Kachel die Ecke, an der sie hängt.
    private var growAnchor: UnitPoint {
        guard corner else { return .top }
        switch anchor {
        case .topTrailing: return .topTrailing
        case .topLeading: return .topLeading
        case .bottomTrailing: return .bottomTrailing
        case .bottomLeading: return .bottomLeading
        }
    }

    /// Kopfbereich: am Notch die Flügel neben der Kamera, sonst die Kachel mit dem Funken.
    @ViewBuilder
    private var headerArea: some View {
        if corner {
            let header = cornerHeader.frame(height: bareLogo ? Layout.idleTile(prefs).height : Layout.cornerHeader)
            if geometry.style == .floating {
                header.gesture(dragGesture)
            } else {
                header
            }
        } else {
            wings
                .frame(height: geometry.notchSize.height)
            if ext > 0 {
                Color.clear.frame(height: ext)
            }
        }
    }

    /// Links der Funke, rechts das Maskottchen. Dazwischen sitzt die Kamera.
    @ViewBuilder
    private var wings: some View {
        let showWings = presentation != .hidden && presentation != .rim
        HStack(spacing: 0) {
            if showWings {
                SparkSpinner(active: model.isWorking || attention, size: 14,
                             color: attention ? Theme.orangeBright : Theme.orange)
                    .frame(width: Layout.wing - 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.4)))
            }
            Spacer(minLength: geometry.notchSize.width)
            if showWings {
                Mascot(mood: mascotMood, size: 14)
                    .frame(width: Layout.wing - 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.4)))
            }
        }
        .padding(.horizontal, open ? topRadius + 4 : topRadius - 3)
    }

    /// Kopfzeile für Bildschirme ohne Notch (oben rechts). Im Ruhezustand nur das Claude-Maskottchen,
    /// frei auf dem Schreibtisch, ohne Kasten. Der leichte Schatten hält es auf hellen Hintergründen sichtbar.
    @ViewBuilder
    private var cornerHeader: some View {
        let idle = bareLogo
        HStack(spacing: 10) {
            if idle {
                Spacer(minLength: 0)
                // Unten ausgerichtet: Die Luft darüber ist zum Hüpfen da.
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Mascot(mood: mascotMood, size: CGFloat(prefs.mascotSize), cutOutEyes: true)
                        .shadow(color: .black.opacity(0.35), radius: 1.5 * CGFloat(prefs.mascotSize) / 24, y: 0.5)
                }
                .padding(.bottom, 7)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
                Spacer(minLength: 0)
            } else {
                // Ruhige Karten (fertig, Limit, Nachricht für später) haben Titel und Projekt selbst.
                // Oben steht dann nur das Maskottchen, damit nichts doppelt dasteht.
                if !calmCard {
                    SparkSpinner(active: model.isWorking || attention, size: 16,
                                 color: attention ? Theme.orangeBright : Theme.orange)
                        .frame(width: 22)
                    Text(headline)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.cream)
                        .lineLimit(1)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
                Mascot(mood: mascotMood, size: 14)
                    .frame(width: 24)
            }
        }
        .padding(.horizontal, idle ? 0 : 14)
    }

    /// Eine Karte, die nichts von dir braucht, ist gerade offen.
    private var calmCard: Bool {
        guard case .request = presentation, let req = model.currentRequest else { return false }
        return !req.needsYou
    }

    private var headline: String {
        if let req = model.currentRequest {
            if case .question = req.kind { return "Claude hat eine Frage" }
            return "Claude braucht dich"
        }
        if let b = model.banner { return b.title }
        if case .sessions = presentation { return "Claude" }
        let active = model.activeSessions
        if showsRows { return "\(active.count) aktive Sitzung\(active.count == 1 ? "" : "en")" }
        if let s = active.first { return s.detail.isEmpty ? s.displayName : "\(s.displayName) · \(s.detail)" }
        return "Claude"
    }

    private var mascotMood: Mascot.Mood {
        if attention || model.needsAttention { return .attention }
        if case .finished = model.currentRequest?.kind { return .happy }
        if case .banner = presentation, model.banner?.style != .info { return .happy }
        if model.isWorking { return .working }
        return .idle
    }

    @ViewBuilder
    private var expandedContent: some View {
        switch presentation {
        case .request:
            if let req = model.currentRequest {
                RequestView(request: req, more: model.pending.count - 1,
                            answer: { answer in model.answer(req.id, with: answer) },
                            replyDeadline: model.replying[req.id],
                            compose: { model.composeFollowUp(for: req.sessionId) },
                            startReply: { model.startReply(req.id) })
                .id(req.id)
            }
        case .banner:
            if let banner = model.banner {
                BannerView(banner: banner)
                    .contentShape(Rectangle())
                    .onTapGesture { model.clearBanner() }
            }
        case .sessions:
            // Ohne Kopfzeile zieht man den Reiter an der Zeile mit „Claude“.
            SessionListView(model: model, rows: prefs.listSize.rows, pinned: pinned,
                            showUsage: prefs.showUsage,
                            maxGauges: Layout.maxGauges(prefs: prefs, geometry: geometry),
                            showsMascot: headerless,
                            onDrag: headerless && geometry.style == .floating ? (onDragMoved, onDragEnded) : nil,
                            onClose: onTap)
        default:
            EmptyView()
        }
    }
}

// MARK: - Reihenfolge beim Auf- und Zuklappen

/// Der schwarze Kasten ist schon nach dem ersten Drittel der Bewegung voll da und verschwindet
/// beim Zuklappen erst im letzten Drittel. So steht nie Inhalt auf halb durchsichtigem Grund.
private struct EarlyFade: ViewModifier, Animatable {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.opacity(min(1, progress * 3))
    }
}

/// Gegenstück für den Inhalt: Er erscheint erst, wenn der Kasten schon steht, und ist beim
/// Zuklappen als Erstes weg.
private struct LateFade: ViewModifier, Animatable {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.opacity(max(0, (progress - 0.4) / 0.6))
    }
}

// MARK: - Teilansichten

private struct BannerView: View {
    let banner: Banner

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.orange.opacity(0.16))
                if banner.style == .done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.orange)
                } else {
                    SparkShape().fill(Theme.orange).frame(width: 18, height: 18)
                }
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.cream)
                    .lineLimit(1)
                Text(banner.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Die Zeilen direkt unter dem Notch, solange Claude arbeitet. Höchstens `rows` Stück.
private struct CompactRowsView: View {
    @ObservedObject var model: NotchModel
    let rows: Int

    var body: some View {
        let active = model.activeSessions
        VStack(spacing: 0) {
            ForEach(active.prefix(rows)) { s in
                SessionRow(session: s) { model.focus(s) }
            }
            if active.count > rows {
                Text("+\(active.count - rows) weitere · zum Öffnen klicken")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.muted)
                    .frame(height: 16)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 8)
            }
        }
    }
}

/// Die aufgeklappte Liste: alle aktiven Sitzungen, bei mehr als `rows` zum Scrollen.
private struct SessionListView: View {
    @ObservedObject var model: NotchModel
    let rows: Int
    let pinned: Bool
    let showUsage: Bool
    let maxGauges: Int
    /// Oben rechts und am Reiter: rechts das kleine Maskottchen, dort wo es vorher saß.
    var showsMascot = false
    /// Reiter an der Zeile mit „Claude“ verschieben.
    var onDrag: (moved: () -> Void, ended: () -> Void)?
    let onClose: () -> Void

    var body: some View {
        let active = model.activeSessions
        let visible = Layout.listRows(active: active.count, max: rows)
        VStack(alignment: .leading, spacing: 0) {
            // Links „Claude“, daneben die Einstellungen und der Stand.
            HStack(spacing: 8) {
                Text("Claude")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.orange)
                Button {
                    SettingsWindowController.shared.show()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(PressStyle(scale: 0.88))
                .help("Einstellungen")
                Text(active.isEmpty
                     ? (model.claudeAppRunning ? "App geöffnet" : "Bereit")
                     : "\(active.count) aktive Sitzung\(active.count == 1 ? "" : "en")")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                Spacer(minLength: 4)
                if showsMascot {
                    Mascot(mood: model.isWorking ? .working : .idle, size: 13)
                }
                if pinned {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.muted)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressStyle(scale: 0.88))
                }
            }
            .frame(height: Layout.listHeader)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { _ in onDrag?.moved() }
                .onEnded { _ in onDrag?.ended() },
                     including: onDrag == nil ? .subviews : .all)
            Spacer().frame(height: 4)
            if active.isEmpty {
                Text("Keine aktive Claude Code Sitzung. Sobald Claude arbeitet oder dich braucht, erscheint es hier.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.cream.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .topLeading)
            } else {
                ScrollView(.vertical, showsIndicators: active.count > rows) {
                    VStack(spacing: 0) {
                        ForEach(active) { s in
                            SessionRow(session: s) { model.focus(s) }
                        }
                    }
                }
                .frame(height: visible * Layout.rowHeight)
            }
            if model.idleCount > 0 {
                Text("\(model.idleCount) weitere Sitzung\(model.idleCount == 1 ? "" : "en") bereit")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.muted)
                    .frame(height: 16)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 8)
            }
            if showUsage {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
                    .padding(.top, 6)
                UsageView(maxGauges: maxGauges)
                    .frame(height: Layout.usageBlockHeight(Preferences.shared) - 7)
            }
        }
    }
}

/// Nutzung wie bei `/usage`: Ringe für Sitzungs- und Wochenlimit, dazu wie viel noch frei ist.
/// Bei mehreren Konten eine Zeile je Konto, vorn der Name.
private struct UsageView: View {
    let maxGauges: Int
    @ObservedObject private var monitor = UsageMonitor.shared
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        let accounts = Layout.usageAccounts(prefs)
        let several = accounts.count > 1
        VStack(spacing: 0) {
            ForEach(accounts) { account in
                UsageRow(account: account, state: monitor.state(for: account), showsName: several,
                         maxGauges: several ? min(maxGauges, 2) : maxGauges)
                    .frame(height: Layout.usageRowHeight)
            }
        }
        .padding(.horizontal, 6)
        .onAppear { monitor.refreshIfStale() }
    }
}

private struct UsageRow: View {
    let account: ClaudeAccount
    let state: UsageMonitor.AccountUsage
    let showsName: Bool
    let maxGauges: Int

    var body: some View {
        HStack(spacing: 10) {
            if showsName {
                Text(account.name)
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.orange)
                    .lineLimit(1)
                    .frame(width: 58, alignment: .leading)
                    .help(account.displayPath)
            }
            if let snap = state.snapshot {
                ForEach(snap.windows.prefix(maxGauges)) { window in
                    UsageGauge(window: window)
                }
                Spacer(minLength: 0)
                if state.status != .ok && state.status != .loading {
                    // Zahlen sind vom letzten Abruf, gerade klappt es nicht.
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .help("Stand \(snap.fetchedAt.formatted(date: .omitted, time: .shortened)): \(state.status.text)")
                }
            } else {
                Text(showsName ? state.status.text : "Nutzung: \(state.status.text)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        }
    }
}

private struct UsageGauge: View {
    let window: UsageWindow

    var body: some View {
        let used = Int(window.percent.rounded())
        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: CGFloat(min(window.percent, 100) / 100))
                    .stroke(tint, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(Theme.softSpring, value: window.percent)
                Text("\(used)")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.cream)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(window.title) · noch \(window.remainingPercent) %")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.cream)
                    .lineLimit(1)
                Text(window.resetText())
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
        }
        .help("\(window.title): \(used) % des Limits genutzt, \(window.remainingPercent) % frei")
    }

    private var tint: Color { Brand.usageTint(window.percent) }
}

/// Eine Sitzung: Zustand, Name, was gerade passiert, woher sie kommt. Klick holt das Fenster nach vorn.
private struct SessionRow: View {
    let session: SessionInfo
    let action: () -> Void
    @State private var hover = false
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var followUps = FollowUps.shared

    var body: some View {
        HStack(spacing: 2) {
            Button(action: action) { content }
                .buttonStyle(RowStyle(hover: hover))
                .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
                .help(tooltip)
            if prefs.followUpsEnabled {
                planButton
            }
        }
    }

    /// Nachricht für das nächste Ende dieser Sitzung planen (erweiterte Einstellung).
    private var planButton: some View {
        let planned = followUps.followUp(for: session.id)
        return Button {
            NotchModel.shared.composeFollowUp(for: session.id)
        } label: {
            Image(systemName: planned == nil ? "text.bubble" : "text.bubble.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(planned == nil ? Theme.muted : Theme.orange)
                .frame(width: 22, height: Layout.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.88))
        .help(planned.map { "Geplant: \($0.text)" } ?? "Nachricht planen, die Claude beim nächsten Ende bekommt")
        .accessibilityLabel(planned == nil ? "Nachricht planen" : "Geplante Nachricht ändern")
    }

    /// Links das Konto (bei mehreren), dann das Projekt, dann worum es im Chat geht.
    /// Ohne bekannten Titel steht dort, was Claude gerade tut.
    private var content: some View {
        HStack(spacing: 8) {
            statusIcon
                .frame(width: 14)
            if let account = accountName {
                Text(account)
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.orange)
                    .lineLimit(1)
                    .frame(width: 52, alignment: .leading)
            }
            Text(session.projectName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.cream)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 170, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
            if let title = session.title {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.muted.opacity(0.7))
                Text(title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.cream.opacity(0.78))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            } else if !session.detail.isEmpty {
                Text(session.detail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let icon = originIcon {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .help(session.origin.label)
                    .accessibilityLabel(session.origin.label)
            }
            Image(systemName: "arrow.up.forward")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.orange.opacity(hover ? 1 : 0.35))
        }
        .padding(.horizontal, 8)
        .frame(height: Layout.rowHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// Woher die Sitzung kommt, als kleines Symbol statt Text. Der Name steht im Tooltip.
    private var originIcon: String? {
        switch session.origin.host {
        case .claudeApp: return "macwindow"
        case .vscode, .cursor: return "chevron.left.forwardslash.chevron.right"
        case .terminal: return "terminal"
        case .other: return "app"
        case .unknown: return session.origin.tty == nil ? nil : "terminal"
        }
    }

    /// Tooltip: was Claude gerade tut und wo.
    private var tooltip: String {
        [session.detail, session.title.map { _ in session.projectName }, session.cwd]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Hervorhebung beim Überfahren, kräftiger und minimal kleiner schon beim Drücken.
    private struct RowStyle: ButtonStyle {
        let hover: Bool

        func makeBody(configuration: Configuration) -> some View {
            let pressed = configuration.isPressed
            configuration.label
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(pressed ? 0.15 : hover ? 0.09 : 0)))
                .scaleEffect(pressed && !Theme.reduceMotion ? 0.985 : 1)
                .animation(pressed ? .easeOut(duration: 0.08) : Theme.spring, value: pressed)
        }
    }

    /// Kontoname, aber nur wenn es mehr als ein Konto gibt.
    private var accountName: String? {
        let prefs = Preferences.shared
        guard prefs.accounts.count > 1, let id = session.accountID else { return nil }
        return prefs.account(id: id)?.name
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch session.state {
        case .working: SparkSpinner(active: true, size: 12)
        case .waiting: Circle().fill(Theme.orangeBright).frame(width: 8, height: 8)
        case .done: Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.allow)
        case .idle: Circle().fill(Theme.muted.opacity(0.6)).frame(width: 7, height: 7)
        }
    }
}

/// Meldet, ob ein Text im Kasten abgeschnitten wird.
private struct TruncationKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct RequestView: View {
    let request: PendingRequest
    let more: Int
    let answer: (PendingRequest.Answer) -> Void
    /// Nach „Antworten …“ auf der Fertig-Meldung: bis wann Claude Code wartet.
    let replyDeadline: Date?
    /// Nachricht für später schreiben (aus dem Limit-Hinweis).
    let compose: () -> Void
    /// „Antworten …“ auf der Fertig-Meldung.
    let startReply: () -> Void
    /// Erlauben erst kurz nach dem Erscheinen, damit ein Klick, der eigentlich woanders hin
    /// sollte, nichts freigibt. Die Ansicht entsteht pro Anfrage neu (.id), also auch pro Anfrage.
    @State private var armed = false
    /// Passt der Befehl nicht ganz in den Kasten, wird im Notch nichts erlaubt: Erlauben gälte
    /// sonst auch für den Teil, den man hier nicht sieht.
    @State private var truncated = false

    var body: some View {
        if case .finished = request.kind, replyDeadline == nil {
            finishedCompact
        } else {
            card
        }
    }

    /// Fertig, mit „Antworten …“. Sieht aus wie die normale Fertig-Meldung und fragt nichts.
    private var finishedCompact: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Theme.orange.opacity(0.16))
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.orange)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fertig")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.cream)
                    Text(request.project)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { answer(.terminal) }
            .accessibilityElement(children: .combine)
            NotchButton("Antworten …", role: .secondary, action: startReply)
                .help("Claude eine weitere Anweisung geben. Claude Code wartet dann bis zur eingestellten Zeit.")
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch request.kind {
            case .permission(_, let summary, let canAlwaysAllow):
                codeBox(summary)
                    .onPreferenceChange(TruncationKey.self) { truncated = $0 }
                HStack(spacing: 8) {
                    NotchButton("Ablehnen", role: .deny) { answer(.deny) }
                    NotchButton("Im Terminal", role: .ghost) { answer(.terminal) }
                    Spacer(minLength: 0)
                    if truncated {
                        Text("Zu lang zum Prüfen, bitte im Terminal")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    } else {
                        if canAlwaysAllow {
                            NotchButton("Immer erlauben", role: .secondary) { answer(.allowAlways) }
                                .disabled(!armed).opacity(armed ? 1 : 0.5)
                        }
                        NotchButton("Erlauben", role: .primary) { answer(.allow) }
                            .disabled(!armed).opacity(armed ? 1 : 0.5)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: armed)
                .task {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    armed = true
                }
            case .notice(_, let message):
                Text(message.isEmpty ? "Schau kurz bei Claude vorbei." : message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.cream.opacity(0.9))
                    .lineLimit(3)
                HStack {
                    Spacer()
                    NotchButton("Verstanden", role: .primary) { answer(.terminal) }
                }
            case .question(let set):
                questionBody(set)
            case .limit(let message):
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.cream.opacity(0.9))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer()
                    if Preferences.shared.followUpsEnabled {
                        NotchButton("Nachricht für danach …", role: .secondary) { compose() }
                    }
                    NotchButton("Verstanden", role: .primary) { answer(.terminal) }
                }
            case .finished:
                MessageComposer(prompt: "Weitere Anweisung an Claude …", sendTitle: "Senden", cancelTitle: "Schließen",
                                deadline: replyDeadline,
                                send: { answer(.message($0)) },
                                cancel: { answer(.terminal) })
            case .compose:
                Text("Claude bekommt die Nachricht, sobald die Sitzung das nächste Mal fertig ist, auch nach einem Limit. Sie geht nur an Claude, nie an ein Terminal.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                MessageComposer(prompt: "Zum Beispiel: Mach weiter und teste danach alles",
                                initial: FollowUps.shared.followUp(for: request.sessionId)?.text ?? "",
                                sendTitle: "Planen", cancelTitle: "Abbrechen",
                                extra: FollowUps.shared.followUp(for: request.sessionId) == nil ? nil : (
                                    "Löschen", { FollowUps.shared.cancel(request.sessionId); answer(.terminal) }),
                                send: { answer(.message($0)) },
                                cancel: { answer(.terminal) })
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if case .finished = request.kind {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.allow)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.cream)
                .lineLimit(1)
            Spacer(minLength: 4)
            if more > 0 {
                Text("+\(more)")
                    .font(.system(size: 10.5, weight: .bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.orange.opacity(0.25)))
                    .foregroundStyle(Theme.orangeBright)
            }
            Text(request.project)
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
    }

    private var title: String {
        switch request.kind {
        case .permission(let tool, _, _): return "Claude möchte \(tool) nutzen"
        case .notice(let title, _): return title
        case .question: return "Claude hat eine Frage"
        case .limit: return "Limit erreicht"
        case .finished: return "Fertig"
        case .compose: return "Nachricht für später"
        }
    }

    private func codeBox(_ text: String) -> some View {
        let font = Font.system(size: 11.5, design: .monospaced)
        return Text(text)
            .font(font)
            .foregroundStyle(Theme.cream.opacity(0.92))
            .lineLimit(3)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Abgeschnitten? Die sichtbare Höhe mit der Höhe des ganzen Textes vergleichen.
            .background(GeometryReader { shown in
                Text(text)
                    .font(font)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: shown.size.width, alignment: .leading)
                    .hidden()
                    .background(GeometryReader { full in
                        Color.clear.preference(key: TruncationKey.self,
                                               value: full.size.height > shown.size.height + 1)
                    })
            })
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.orange.opacity(0.25), lineWidth: 1))
    }

    @ViewBuilder
    private func questionBody(_ set: QuestionSet) -> some View {
        let q = set.questions[0]
        Text(q.question)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.cream.opacity(0.92))
            .lineLimit(2)
        if set.questions.count == 1, !q.multiSelect, !q.options.isEmpty {
            VStack(spacing: 6) {
                ForEach(Array(q.options.prefix(4).enumerated()), id: \.offset) { _, option in
                    NotchButton(option, role: .option) { answer(.answers([q.question: option])) }
                }
            }
            HStack {
                Spacer()
                NotchButton("Im Terminal antworten", role: .ghost) { answer(.terminal) }
            }
        } else {
            HStack {
                Spacer()
                NotchButton("Im Terminal antworten", role: .primary) { answer(.terminal) }
            }
        }
    }
}

struct NotchButton: View {
    enum Role { case primary, secondary, deny, ghost, option }

    let title: String
    let role: Role
    let action: () -> Void
    @State private var hover = false

    init(_ title: String, role: Role, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: role == .primary ? .semibold : .medium, design: .rounded))
                .lineLimit(1)
                .frame(maxWidth: role == .option ? .infinity : nil, alignment: role == .option ? .leading : .center)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(foreground)
                .background(Capsule(style: .continuous).fill(background))
                .overlay(Capsule(style: .continuous).stroke(border, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }

    private var foreground: Color {
        switch role {
        case .primary: return Theme.ink
        case .deny: return Theme.deny
        case .ghost: return Theme.muted
        default: return Theme.cream
        }
    }

    private var background: Color {
        switch role {
        case .primary: return hover ? Theme.orangeBright : Theme.orange
        case .secondary, .option: return Color.white.opacity(hover ? 0.16 : 0.09)
        case .deny: return Theme.deny.opacity(hover ? 0.22 : 0.12)
        case .ghost: return Color.white.opacity(hover ? 0.08 : 0)
        }
    }

    private var border: Color {
        switch role {
        case .option: return Theme.orange.opacity(hover ? 0.6 : 0.25)
        case .secondary: return Theme.orange.opacity(0.35)
        default: return .clear
        }
    }
}

/// Eingabefeld für eine Nachricht an Claude. Bekommt nie von selbst den Fokus: Erst ein Klick ins
/// Feld nimmt Tastatureingaben an, damit Tippen in einer anderen App nicht versehentlich hier landet.
private struct MessageComposer: View {
    let prompt: String
    var initial = ""
    let sendTitle: String
    let cancelTitle: String
    /// Claude Code wartet nur bis dahin, die Zeit läuft sichtbar mit.
    var deadline: Date?
    /// Weiterer Knopf links, z.B. „Löschen“.
    var extra: (title: String, action: () -> Void)?
    let send: (String) -> Void
    let cancel: () -> Void

    @State private var text = ""
    @State private var loaded = false

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("", text: $text, prompt: Text(prompt).foregroundColor(Theme.muted), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.cream)
                .tint(Theme.orange)
                .lineLimit(2...3)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.orange.opacity(0.3), lineWidth: 1))
                .onSubmit(submit)
                .onChange(of: text) { value in
                    if value.count > FollowUps.maxLength { text = String(value.prefix(FollowUps.maxLength)) }
                }
                .accessibilityLabel(prompt)
            HStack(spacing: 8) {
                NotchButton(cancelTitle, role: .ghost, action: cancel)
                if let extra {
                    NotchButton(extra.title, role: .deny, action: extra.action)
                }
                Spacer(minLength: 0)
                if let deadline {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text("Claude wartet noch \(max(0, Int(deadline.timeIntervalSince(ctx.date).rounded()))) s")
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(Theme.muted)
                    }
                }
                NotchButton(sendTitle, role: .primary, action: submit)
                    .disabled(trimmed.isEmpty)
                    .opacity(trimmed.isEmpty ? 0.5 : 1)
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            text = initial
        }
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        send(trimmed)
    }
}
