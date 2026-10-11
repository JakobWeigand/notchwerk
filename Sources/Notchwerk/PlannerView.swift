import AppKit
import SwiftUI

/// „Später“ im Notch: einen Prompt planen, an Stelle der Sitzungsliste und ohne eigenes Fenster.
/// Erreichbar über „Später“ oben in der aufgeklappten Liste und über „Prompt planen …“ im Menü.
///
/// Der Notch liegt über allem (Ebene des Bildschirmschoners). Native Aufklappmenüs würden dahinter
/// aufgehen, deshalb wählt man hier alles über Chips, Segmente und Listen direkt im Notch.

// MARK: - Maße

/// Feste Höhen, damit der Kasten beim Umschalten nicht springt. `Layout.size` rechnet mit denselben Werten.
@MainActor
enum PlannerLayout {
    static let spacing: CGFloat = 8
    static let header: CGFloat = 22
    static let control: CGFloat = 26
    /// Drei Zeilen, dazu Innenabstand.
    static let targetBox: CGFloat = 3 * Layout.rowHeight + 8
    static let whenBlock: CGFloat = control + 6 + control
    static let editor: CGFloat = 64
    static let actions: CGFloat = 28
    static let maxPlannedRows = 3

    static func plannedCount(_ prefs: Preferences) -> Int {
        ScheduledPrompts.shared.jobs.count + (prefs.followUpsEnabled ? FollowUps.shared.planned.count : 0)
    }

    /// Trennlinie, Abstand und die sichtbaren Zeilen der geplanten Prompts.
    static func plannedBlock(_ count: Int) -> CGFloat {
        1 + 6 + CGFloat(min(count, maxPlannedRows)) * Layout.rowHeight
    }

    static func height(accounts: Int, planned: Int) -> CGFloat {
        var h = header + spacing + control + spacing + targetBox + spacing + whenBlock + spacing + editor + spacing + actions
        if accounts > 1 { h += control + spacing }
        if planned > 0 { h += spacing + plannedBlock(planned) }
        return h
    }
}

// MARK: - Entwurf

/// Was im Planer gerade eingestellt ist. Gehört zum Fenster des Notch, nicht zur Ansicht: So ist der
/// Entwurf noch da, wenn zwischendurch eine Freigabe kam oder du kurz zur Liste zurück bist.
@MainActor
final class PlannerDraft: ObservableObject {
    enum Destination: String, CaseIterable, Identifiable {
        case newChat, resume, running
        var id: String { rawValue }
        var title: String {
            switch self {
            case .newChat: return "Neuer Chat"
            case .resume: return "Alter Chat"
            case .running: return "Offenes Fenster"
            }
        }
    }

    struct Feedback: Equatable {
        let id = UUID()
        let text: String
        let ok: Bool
    }

    /// Heute plus höchstens so viele Tage.
    static let maxDays = 6

    @Published var accountID = ClaudeAccount.defaultID
    @Published var destination: Destination = .newChat
    @Published var trigger: ScheduledPrompts.Trigger = .limitReset
    @Published var dayOffset = 0
    /// Nur Stunde und Minute zählen, der Tag kommt aus `dayOffset`.
    @Published var clock = PlannerDraft.nextFullHour
    @Published var folder = ClaudeAccount.home
    @Published var chatID = ""
    @Published var sessionID = ""
    @Published var text = ""
    @Published var feedback: Feedback?
    @Published private(set) var chats: [ScheduledPrompts.RecentChat] = []
    @Published private(set) var loadingChats = false
    private var loadToken = UUID()

    init() {
        if !Calendar.current.isDateInToday(clock) { dayOffset = 1 }
    }

    private static var nextFullHour: Date {
        let next = Date().addingTimeInterval(3600)
        return Calendar.current.dateInterval(of: .hour, for: next)?.start ?? next
    }

    /// Gewählter Tag mit gewählter Uhrzeit.
    var due: Date {
        let cal = Calendar.current
        let hm = cal.dateComponents([.hour, .minute], from: clock)
        let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: Date())) ?? Date()
        return cal.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: day) ?? day
    }

    var dayTitle: String {
        switch dayOffset {
        case 0: return "Heute"
        case 1: return "Morgen"
        default:
            let day = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
            return day.formatted(.dateTime.weekday(.abbreviated).day().month(.twoDigits))
        }
    }

    /// Letzte Chats des Kontos neu einlesen. Eine ältere, langsamere Suche überschreibt nichts.
    func loadChats() {
        guard let account = Preferences.shared.account(id: accountID) else {
            chats = []
            return
        }
        let token = UUID()
        loadToken = token
        loadingChats = true
        Task.detached(priority: .userInitiated) {
            let found = ScheduledPrompts.recentChats(in: account)
            await MainActor.run { [weak self] in
                guard let self, self.loadToken == token else { return }
                self.chats = found
                self.loadingChats = false
                if !found.contains(where: { $0.id == self.chatID }) { self.chatID = "" }
            }
        }
    }

    func show(_ text: String, ok: Bool) {
        let fb = Feedback(text: text, ok: ok)
        feedback = fb
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.feedback == fb else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.feedback = nil }
        }
    }

    /// „heute 20:23“, „morgen 08:00“, sonst „Mo. 20:23“.
    static func short(_ date: Date) -> String {
        let cal = Calendar.current
        let clock = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "heute \(clock)" }
        if cal.isDateInTomorrow(date) { return "morgen \(clock)" }
        return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(clock)"
    }

    static func tilde(_ path: String) -> String {
        let home = ClaudeAccount.home
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - Ansicht

struct PlannerView: View {
    @ObservedObject var draft: PlannerDraft
    @ObservedObject var model: NotchModel
    /// Oben rechts und am Reiter: rechts das kleine Maskottchen, wie in der Liste.
    var showsMascot = false
    let onBack: () -> Void

    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var scheduler = ScheduledPrompts.shared
    @ObservedObject private var followUps = FollowUps.shared
    @ObservedObject private var usage = UsageMonitor.shared

    private var account: ClaudeAccount? { prefs.account(id: draft.accountID) }

    var body: some View {
        let planned = PlannerLayout.plannedCount(prefs)
        VStack(alignment: .leading, spacing: PlannerLayout.spacing) {
            header
                .frame(height: PlannerLayout.header)
            if prefs.accounts.count > 1 {
                accountRow
                    .frame(height: PlannerLayout.control)
            }
            NotchSegmented(options: PlannerDraft.Destination.allCases.map { .init(value: $0, title: $0.title) },
                           selection: $draft.destination)
                .frame(height: PlannerLayout.control)
            targetBox
                .frame(height: PlannerLayout.targetBox)
            whenBlock
                .frame(height: PlannerLayout.whenBlock)
            editor
                .frame(height: PlannerLayout.editor)
            actions
                .frame(height: PlannerLayout.actions)
            if planned > 0 {
                plannedBlock
                    .frame(height: PlannerLayout.plannedBlock(planned))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
        .onExitCommand(perform: onBack)
        .onAppear {
            if account == nil, let first = prefs.accounts.first { draft.accountID = first.id }
            usage.refreshIfStale()
            draft.loadChats()
        }
        .onChange(of: draft.accountID) { _ in
            draft.chatID = ""
            draft.sessionID = ""
            draft.loadChats()
        }
    }

    // MARK: Kopf

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .bold))
                    Text("Liste")
                        .font(.system(size: 11))
                }
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .contentShape(Capsule())
            }
            .buttonStyle(PressStyle(scale: 0.92))
            .help("Zurück zur Liste (Esc)")
            .accessibilityLabel("Zurück zur Liste")
            Text("Prompt für später")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.orange)
                .lineLimit(1)
            Spacer(minLength: 4)
            if showsMascot {
                Mascot(mood: model.isWorking ? .working : .idle, size: 13)
            }
        }
    }

    private var accountRow: some View {
        HStack(spacing: 8) {
            Text("Konto")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.muted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(prefs.accounts) { a in
                        Chip(title: a.name, selected: a.id == draft.accountID) {
                            withAnimation(Theme.spring) { draft.accountID = a.id }
                        }
                    }
                }
            }
        }
    }

    // MARK: Wohin

    private var targetBox: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
            Group {
                switch draft.destination {
                case .newChat: folderList
                case .resume: chatList
                case .running: sessionList
                }
            }
            .padding(4)
            .id(draft.destination)
            .transition(.opacity)
        }
    }

    /// Ordner aus offenen Sitzungen und letzten Chats, der gewählte immer dabei.
    private var folders: [String] {
        var seen = Set<String>()
        let recent = (runningSessions.map(\.cwd) + draft.chats.map(\.folder))
            .filter { ScheduledPrompts.isFolder($0) && seen.insert($0).inserted }
            .prefix(8)
        return seen.contains(draft.folder) ? Array(recent) : [draft.folder] + recent
    }

    private var folderList: some View {
        ScrollView(.vertical, showsIndicators: folders.count > 2) {
            VStack(spacing: 0) {
                ForEach(folders, id: \.self) { f in
                    PickRow(icon: "folder", title: SessionInfo.readable((f as NSString).lastPathComponent),
                            subtitle: PlannerDraft.tilde(f), selected: f == draft.folder) {
                        draft.folder = f
                    }
                }
                PickRow(icon: "folder.badge.plus", title: "Anderer Ordner …", selected: false, action: chooseFolder)
            }
        }
    }

    private var chatList: some View {
        Group {
            if draft.loadingChats && draft.chats.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if draft.chats.isEmpty {
                placeholder("Keine Chats für dieses Konto gefunden.")
            } else {
                ScrollView(.vertical, showsIndicators: draft.chats.count > 3) {
                    VStack(spacing: 0) {
                        ForEach(draft.chats) { chat in
                            PickRow(icon: "bubble.left",
                                    title: chat.title ?? "Chat ohne Titel",
                                    subtitle: "\(SessionInfo.readable((chat.folder as NSString).lastPathComponent)) · \(chat.modified.formatted(.relative(presentation: .named)))",
                                    selected: chat.id == draft.chatID) {
                                draft.chatID = chat.id
                            }
                        }
                    }
                }
            }
        }
    }

    /// Sitzungen dieses Kontos, die gerade offen sind. Nur dort kann der Stop-Hook etwas zustellen.
    private var runningSessions: [SessionInfo] {
        model.sessions.values
            .filter { ($0.accountID ?? ClaudeAccount.defaultID) == draft.accountID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var sessionList: some View {
        Group {
            let sessions = runningSessions
            if sessions.isEmpty {
                placeholder("Gerade ist keine Sitzung dieses Kontos offen. Für einen ruhenden Chat „Alter Chat“ wählen.")
            } else {
                ScrollView(.vertical, showsIndicators: sessions.count > 3) {
                    VStack(spacing: 0) {
                        ForEach(sessions) { s in
                            PickRow(icon: "terminal", title: s.title ?? s.projectName,
                                    subtitle: s.title == nil ? nil : s.projectName,
                                    selected: s.id == draft.sessionID) {
                                draft.sessionID = s.id
                            }
                        }
                    }
                }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Ordnerauswahl von macOS. Liegt über dem Notch, sonst verschwände sie dahinter.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: draft.folder)
        panel.prompt = "Wählen"
        panel.message = "Ordner für den neuen Chat"
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        NSApp.activate(ignoringOtherApps: true)
        let draft = self.draft
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in draft.folder = url.path }
        }
    }

    // MARK: Wann

    private var whenBlock: some View {
        ZStack(alignment: .topLeading) {
            if draft.destination == .running {
                Text("Claude bekommt den Prompt in diesem Fenster, sobald es dort das nächste Mal fertig ist, zum Beispiel wenn es nach dem Limit von selbst weitergemacht hat. In ein Fenster, das gerade nichts tut, tippt Notchwerk nicht.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    NotchSegmented(options: [.init(value: ScheduledPrompts.Trigger.limitReset, title: "Nach dem Limit-Reset"),
                                             .init(value: .time, title: "Zu einer Uhrzeit")],
                                   selection: $draft.trigger)
                        .frame(height: PlannerLayout.control)
                    ZStack(alignment: .leading) {
                        if draft.trigger == .time {
                            timeRow.transition(.opacity)
                        } else {
                            resetRow.transition(.opacity)
                        }
                    }
                    .frame(height: PlannerLayout.control)
                }
                .transition(.opacity)
            }
        }
    }

    private var resetRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.orange)
            Text(resetText)
                .font(.system(size: 11))
                .foregroundStyle(Theme.cream.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private var resetText: String {
        if let account, let reset = scheduler.nextReset(for: account) {
            let start = reset.addingTimeInterval(ScheduledPrompts.resetDelay)
            return "Limit neu \(PlannerDraft.short(reset)), Start \(PlannerDraft.short(start))"
        }
        return prefs.showUsage ? "Zeitpunkt noch unbekannt, Nutzung wird geladen …"
                               : "Braucht die Nutzungsanzeige (Einstellungen › Nutzung)"
    }

    private var timeRow: some View {
        HStack(spacing: 6) {
            StepButton(systemImage: "chevron.left", label: "Früherer Tag", enabled: draft.dayOffset > 0) {
                draft.dayOffset -= 1
            }
            Text(draft.dayTitle)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.cream)
                .lineLimit(1)
                .frame(width: 84)
                .accessibilityLabel("Tag: \(draft.dayTitle)")
            StepButton(systemImage: "chevron.right", label: "Späterer Tag", enabled: draft.dayOffset < PlannerDraft.maxDays) {
                draft.dayOffset += 1
            }
            DatePicker("Uhrzeit", selection: $draft.clock, displayedComponents: .hourAndMinute)
                .datePickerStyle(.field)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Uhrzeit")
            Text("Uhr")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
            Spacer(minLength: 4)
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                let left = draft.due.timeIntervalSince(ctx.date)
                Text(left <= 0 ? "schon vorbei" : "in \(Self.duration(left))")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(left <= 0 ? Theme.deny : Theme.muted)
                    .lineLimit(1)
            }
        }
    }

    /// „2 Std. 5 Min.“, „45 Min.“
    private static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) Min." }
        return m == 0 ? "\(h) Std." : "\(h) Std. \(m) Min."
    }

    // MARK: Prompt

    private var editor: some View {
        TextField("", text: $draft.text,
                  prompt: Text("Was soll Claude tun? Zum Beispiel: Teste alles und fasse die Fehler zusammen").foregroundColor(Theme.muted),
                  axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Theme.cream)
            .tint(Theme.orange)
            .lineLimit(3, reservesSpace: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.orange.opacity(0.3), lineWidth: 1))
            .onSubmit(plan)
            .onChange(of: draft.text) { value in
                if value.count > FollowUps.maxLength { draft.text = String(value.prefix(FollowUps.maxLength)) }
            }
            .accessibilityLabel("Prompt für Claude")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if !prefs.followUpsEnabled {
                Text("Planen ist aus. Einschalten unter Einstellungen › Erweitert.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                NotchButton("Einstellungen", role: .secondary) { SettingsWindowController.shared.show() }
            } else {
                Group {
                    if let fb = draft.feedback {
                        Label(fb.text, systemImage: fb.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(fb.ok ? Theme.allow : Theme.deny)
                    } else {
                        Text(summary)
                            .foregroundStyle(Theme.muted)
                    }
                }
                .font(.system(size: 11))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
                Spacer(minLength: 4)
                NotchButton("Planen", role: .primary, action: plan)
                    .disabled(!canPlan)
                    .opacity(canPlan ? 1 : 0.5)
                    .help("Planen (Return)")
            }
        }
    }

    /// Was genau passiert, in einer Zeile. Was du bestätigst, siehst du vollständig.
    private var summary: String {
        let what: String
        switch draft.destination {
        case .newChat:
            what = "Neuer Chat in \(PlannerDraft.tilde(draft.folder))"
        case .resume:
            guard let chat = draft.chats.first(where: { $0.id == draft.chatID }) else { return "Chat oben wählen" }
            what = "„\(chat.title ?? "Chat ohne Titel")“ fortsetzen"
        case .running:
            guard let s = model.sessions[draft.sessionID] else { return "Sitzung oben wählen" }
            return "\(s.title ?? s.projectName), wenn Claude dort fertig ist"
        }
        switch draft.trigger {
        case .time:
            return "\(what), \(PlannerDraft.short(draft.due))"
        case .limitReset:
            guard let account, let reset = scheduler.nextReset(for: account) else { return what }
            return "\(what), \(PlannerDraft.short(reset.addingTimeInterval(ScheduledPrompts.resetDelay)))"
        }
    }

    private var canPlan: Bool {
        guard prefs.followUpsEnabled, !FollowUps.sanitize(draft.text).isEmpty, let account else { return false }
        switch draft.destination {
        case .running:
            return model.sessions[draft.sessionID] != nil
        case .newChat:
            guard ScheduledPrompts.isFolder(draft.folder) else { return false }
        case .resume:
            guard draft.chats.contains(where: { $0.id == draft.chatID }) else { return false }
        }
        switch draft.trigger {
        case .time: return draft.due > Date()
        case .limitReset: return scheduler.nextReset(for: account) != nil
        }
    }

    private func plan() {
        guard canPlan else { return }
        do {
            switch draft.destination {
            case .running:
                guard let s = model.sessions[draft.sessionID] else { throw ScheduledPrompts.PlanError.badSession }
                followUps.plan(draft.text, for: s.id, project: s.displayName)
                draft.show("Geplant für „\(s.displayName)“", ok: true)
            case .newChat, .resume:
                let target: ScheduledPrompts.Target
                if draft.destination == .newChat {
                    target = .newChat(folder: draft.folder)
                } else {
                    guard let chat = draft.chats.first(where: { $0.id == draft.chatID }) else {
                        throw ScheduledPrompts.PlanError.badSession
                    }
                    target = .resume(sessionId: chat.id, folder: chat.folder,
                                     title: chat.title ?? SessionInfo.readable((chat.folder as NSString).lastPathComponent))
                }
                let job = try scheduler.plan(text: draft.text, accountID: draft.accountID, target: target,
                                             trigger: draft.trigger, at: draft.due)
                draft.show("Geplant für \(PlannerDraft.short(job.due))", ok: true)
            }
            withAnimation(Theme.spring) { draft.text = "" }
        } catch {
            draft.show(error.localizedDescription, ok: false)
        }
    }

    // MARK: Geplant

    private var plannedBlock: some View {
        let count = PlannerLayout.plannedCount(prefs)
        return VStack(spacing: 6) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
            ScrollView(.vertical, showsIndicators: count > PlannerLayout.maxPlannedRows) {
                VStack(spacing: 0) {
                    ForEach(scheduler.jobs) { job in
                        PlannedLine(when: PlannerDraft.short(job.due),
                                    what: ScheduledPrompts.summary(of: job) + accountSuffix(job.accountID),
                                    text: job.text) {
                            withAnimation(Theme.spring) { scheduler.cancel(job.id) }
                        }
                    }
                    if prefs.followUpsEnabled {
                        ForEach(followUps.planned.values.sorted { $0.createdAt < $1.createdAt }, id: \.sessionId) { f in
                            PlannedLine(when: "wenn fertig", what: f.project, text: f.text) {
                                withAnimation(Theme.spring) { followUps.cancel(f.sessionId) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func accountSuffix(_ id: String) -> String {
        guard prefs.accounts.count > 1, let a = prefs.account(id: id) else { return "" }
        return " · \(a.name)"
    }
}

// MARK: - Bausteine

/// Segmente im Stil des Notch. Die Markierung gleitet zum gewählten Segment, mit „Bewegung
/// reduzieren“ blendet sie nur über.
struct NotchSegmented<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
    }

    let options: [Option]
    @Binding var selection: Value
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let on = option.value == selection
                Button {
                    withAnimation(Theme.spring) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.system(size: 11.5, weight: on ? .semibold : .medium, design: .rounded))
                        .foregroundStyle(on ? Theme.ink : Theme.cream.opacity(0.8))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            if on {
                                if Theme.reduceMotion {
                                    Capsule(style: .continuous).fill(Theme.orange)
                                } else {
                                    Capsule(style: .continuous).fill(Theme.orange)
                                        .matchedGeometryEffect(id: "selection", in: ns)
                                }
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(PressStyle(scale: 0.97))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.07)))
    }
}

private struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular, design: .rounded))
                .lineLimit(1)
                .foregroundStyle(selected ? Theme.ink : Theme.cream.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule(style: .continuous).fill(selected ? Theme.orange : Color.white.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle(scale: 0.94))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Eine wählbare Zeile in der Liste unter „Wohin“.
private struct PickRow: View {
    let icon: String
    let title: String
    var subtitle: String?
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: selected ? "checkmark.circle.fill" : icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(selected ? Theme.orange : Theme.muted)
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(Theme.cream)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: Layout.rowHeight)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.1 : hover ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.985))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Kleiner Pfeil zum Weiterschalten des Tages.
private struct StepButton: View {
    let systemImage: String
    let label: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(enabled ? Theme.cream : Theme.muted.opacity(0.4))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(enabled ? 0.08 : 0.03)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle(scale: 0.88))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// Ein geplanter Prompt: wann, wohin und Löschen. Der ganze Text steht im Tooltip und für VoiceOver.
private struct PlannedLine: View {
    let when: String
    let what: String
    let text: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "clock.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.orange)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(when)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.cream)
                .lineLimit(1)
                .fixedSize()
            Text(what)
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel("\(what): \(text)")
            Spacer(minLength: 4)
            Button(action: onCancel) {
                Image(systemName: "trash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.deny.opacity(0.85))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(scale: 0.88))
            .help("Löschen")
            .accessibilityLabel("Geplanten Prompt löschen")
        }
        .padding(.horizontal, 8)
        .frame(height: Layout.rowHeight)
        .help(text)
    }
}
