import SwiftUI

/// Zustand eines einzelnen Fensters (pro Bildschirm).
@MainActor
final class PanelState: ObservableObject {
    @Published var hovering = false
    @Published var geometry: ScreenGeometry

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
        let p = Layout.presentation(model: model, prefs: prefs, hovering: panel.hovering)
        let size = Layout.size(for: p, model: model, geometry: g)

        ZStack(alignment: g.style == .corner ? .topTrailing : .top) {
            Color.clear
            NotchBody(model: model, prefs: prefs, presentation: p, geometry: g)
                .frame(width: size.width, height: size.height)
                .opacity(p == .hidden && g.style == .corner ? 0 : 1)
        }
        .frame(width: g.panelSize.width, height: g.panelSize.height,
               alignment: g.style == .corner ? .topTrailing : .top)
        .animation(Theme.spring, value: p)
        .animation(Theme.spring, value: size)
    }
}

/// Die schwarze Fläche mit orangem Rand und dem Inhalt.
private struct NotchBody: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var prefs: Preferences
    let presentation: Presentation
    let geometry: ScreenGeometry

    private var expanded: Bool { presentation.isExpanded }
    private var attention: Bool {
        if case .request = presentation { return true }
        return false
    }

    var body: some View {
        ZStack(alignment: .top) {
            background
            content
                .clipShape(clipShape)
        }
    }

    // MARK: Hintergrund und Rand

    @ViewBuilder
    private var background: some View {
        let rimVisible = presentation != .hidden
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !(attention || model.isWorking))) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let pulse = attention ? 0.5 + 0.5 * sin(t * 4.2) : (model.isWorking ? 0.5 + 0.5 * sin(t * 2.2) : 0.35)
            let glow = rimVisible ? (expanded ? 0.55 : 0.35) + 0.45 * pulse : 0
            ZStack {
                fillShape.fill(Color.black)
                strokeShape
                    .stroke(Theme.orange.opacity(rimVisible ? 0.95 : 0),
                            style: StrokeStyle(lineWidth: expanded ? 1.6 : 1.4, lineCap: .round, lineJoin: .round))
                    .shadow(color: Theme.orange.opacity(glow), radius: attention ? 9 : 5)
                    .shadow(color: Theme.orangeBright.opacity(glow * 0.5), radius: 2)
            }
        }
    }

    private var topRadius: CGFloat { expanded ? 14 : 7 }
    private var bottomRadius: CGFloat { expanded ? 24 : (presentation == .compact ? 12 : 10) }

    private var fillShape: AnyShape {
        geometry.style == .corner
            ? AnyShape(RoundedRectangle(cornerRadius: expanded ? 22 : 20, style: .continuous))
            : AnyShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
    }

    private var strokeShape: AnyShape {
        geometry.style == .corner
            ? AnyShape(RoundedRectangle(cornerRadius: expanded ? 22 : 20, style: .continuous))
            : AnyShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius, openTop: true))
    }

    private var clipShape: AnyShape { fillShape }

    // MARK: Inhalt

    @ViewBuilder
    private var content: some View {
        let topBar = geometry.style == .corner ? 0 : geometry.notchSize.height
        let side = geometry.style == .corner ? 16 : topRadius + 16

        VStack(spacing: 0) {
            if geometry.style == .corner {
                cornerHeader
            } else {
                wings
                    .frame(height: topBar)
            }
            if expanded {
                expandedContent
                    .padding(.horizontal, side)
                    .padding(.top, geometry.style == .corner ? 2 : 8)
                    .padding(.bottom, 14)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top)).animation(Theme.spring.delay(0.06)),
                        removal: .opacity.animation(.easeOut(duration: 0.12))))
            }
            Spacer(minLength: 0)
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
        .padding(.horizontal, expanded ? topRadius + 4 : topRadius - 3)
    }

    /// Kopfzeile für Bildschirme ohne Notch (oben rechts).
    @ViewBuilder
    private var cornerHeader: some View {
        HStack(spacing: 10) {
            Mascot(mood: mascotMood, size: 15)
                .frame(width: 26, height: 40)
            if presentation != .rim && presentation != .hidden {
                Text(headline)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.cream)
                    .lineLimit(1)
                    .transition(.opacity)
                Spacer(minLength: 0)
                SparkSpinner(active: model.isWorking || attention, size: 12)
            }
        }
        .padding(.horizontal, presentation == .rim || presentation == .hidden ? 7 : 12)
        .frame(height: 40)
    }

    private var headline: String {
        if model.currentRequest != nil { return "Claude braucht dich" }
        if let b = model.banner { return b.title }
        if let s = model.activeSessions.first { return s.detail.isEmpty ? s.projectName : s.detail }
        return "Claude"
    }

    private var mascotMood: Mascot.Mood {
        if attention { return .attention }
        if case .banner = presentation, model.banner?.style != .info { return .happy }
        if model.isWorking { return .working }
        return .idle
    }

    @ViewBuilder
    private var expandedContent: some View {
        switch presentation {
        case .request:
            if let req = model.currentRequest {
                RequestView(request: req, more: model.pending.count - 1) { answer in
                    model.answer(req.id, with: answer)
                }
                .id(req.id)
            }
        case .banner:
            if let banner = model.banner {
                BannerView(banner: banner)
                    .contentShape(Rectangle())
                    .onTapGesture { model.clearBanner() }
            }
        case .sessions:
            SessionListView(sessions: model.activeSessions, claudeRunning: model.claudeAppRunning)
        default:
            EmptyView()
        }
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

private struct SessionListView: View {
    let sessions: [SessionInfo]
    let claudeRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Claude")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.orange)
                Spacer()
                Text(sessions.isEmpty ? (claudeRunning ? "App geöffnet" : "Bereit") : "\(sessions.count) Sitzung\(sessions.count == 1 ? "" : "en")")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }
            if sessions.isEmpty {
                Text("Keine aktive Claude Code Sitzung. Sobald Claude arbeitet oder dich braucht, erscheint es hier.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.cream.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(sessions.prefix(4)) { s in
                HStack(spacing: 10) {
                    statusIcon(s.state)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.projectName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.cream)
                            .lineLimit(1)
                        Text(s.detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 32)
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ state: SessionInfo.State) -> some View {
        switch state {
        case .working: SparkSpinner(active: true, size: 12)
        case .waiting: Circle().fill(Theme.orangeBright).frame(width: 8, height: 8)
        case .done: Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.allow)
        case .idle: Circle().fill(Theme.muted.opacity(0.6)).frame(width: 7, height: 7)
        }
    }
}

private struct RequestView: View {
    let request: PendingRequest
    let more: Int
    let answer: (PendingRequest.Answer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch request.kind {
            case .permission(_, let summary, let canAlwaysAllow):
                codeBox(summary)
                HStack(spacing: 8) {
                    NotchButton("Ablehnen", role: .deny) { answer(.deny) }
                    NotchButton("Im Terminal", role: .ghost) { answer(.terminal) }
                    Spacer(minLength: 0)
                    if canAlwaysAllow {
                        NotchButton("Immer erlauben", role: .secondary) { answer(.allowAlways) }
                    }
                    NotchButton("Erlauben", role: .primary) { answer(.allow) }
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
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
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
        }
    }

    private func codeBox(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(Theme.cream.opacity(0.92))
            .lineLimit(3)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                .scaleEffect(hover ? 1.04 : 1)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
