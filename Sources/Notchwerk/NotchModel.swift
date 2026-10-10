import AppKit
import Combine
import Foundation
import SwiftUI

/// Eine laufende Claude Code Sitzung.
struct SessionInfo: Identifiable, Equatable {
    enum State: Equatable { case idle, working, waiting, done }

    let id: String
    var cwd: String
    var state: State = .idle
    var detail: String = ""
    var updatedAt = Date()
    /// Terminal, VS Code, Claude App … (aus der Prozesskette des Hooks).
    var origin: SessionOrigin = .unknown
    /// Passender Chat in der Claude Desktop App, falls bekannt.
    var desktop: DesktopSession?
    /// Transkript der Sitzung. Darin steht, wenn du eine Antwort abgebrochen hast.
    var transcriptPath: String?
    var transcriptSize: UInt64 = 0
    /// Claude Code Konto, mit dem die Sitzung läuft (siehe ClaudeAccount).
    var accountID: String?
    /// Seit wann die Sitzung am Limit hängt. Claude Code macht nach dem Zurücksetzen von selbst weiter.
    var limitSince: Date?
    /// Titel des Chats aus dem Transkript (umbenannt oder von Claude Code vergeben), siehe SessionTitles.
    var chatTitle: String?

    /// Projektordner, lesbar: „wuerfelbecher-app“ → „Wuerfelbecher App“. Der echte Pfad steht im Tooltip.
    var projectName: String {
        if cwd == FileManager.default.homeDirectoryForCurrentUser.path { return "Home" }
        let name = Self.readable((cwd as NSString).lastPathComponent)
        return name.isEmpty ? "Claude Code" : name
    }

    /// Bindestriche und Unterstriche zu Leerzeichen, jedes Wort mit großem Anfangsbuchstaben.
    /// Der Rest bleibt, wie er ist (aus „myApp“ wird „MyApp“, nicht „Myapp“).
    static func readable(_ folder: String) -> String {
        folder.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Name in der Liste: der Chat-Titel aus der Desktop App, sonst der Projektordner.
    var displayName: String {
        if let title = desktop?.title, !title.isEmpty { return title }
        return projectName
    }

    /// Worum es im Chat geht: der Titel aus der Desktop App, sonst der aus dem Transkript.
    var title: String? {
        if let t = desktop?.title, !t.isEmpty { return t }
        return chatTitle
    }

    /// Arbeitet gerade, braucht dich oder ist gerade eben fertig geworden.
    var isActive: Bool { state == .working || state == .waiting || state == .done }
}

/// Etwas, worauf Claude eine Antwort von dir braucht.
final class PendingRequest: Identifiable {
    enum Kind {
        case permission(tool: String, summary: String, canAlwaysAllow: Bool)
        case question(QuestionSet)
        case notice(title: String, message: String)
        /// Limit erreicht. Claude Code macht nach dem Zurücksetzen von selbst weiter.
        case limit(message: String)
        /// Claude ist fertig und wartet bis `deadline` auf eine Antwort im Notch (erweitert).
        case reply(lastMessage: String, deadline: Date)
        /// Nachricht für später schreiben (erweitert). Kommt von dir, nicht von Claude Code.
        case compose
    }

    enum Answer {
        case allow
        case allowAlways
        case deny
        case terminal
        case answers([String: String])
        /// Text an Claude: Antwort im Notch oder geplante Nachricht.
        case message(String)
    }

    let id = UUID()
    let sessionId: String
    let project: String
    let kind: Kind
    let createdAt = Date()
    fileprivate let respond: (Answer) -> Void

    init(sessionId: String, project: String, kind: Kind, respond: @escaping (Answer) -> Void) {
        self.sessionId = sessionId
        self.project = project
        self.kind = kind
        self.respond = respond
    }
}

/// Fragen aus dem AskUserQuestion Tool.
struct QuestionSet {
    struct Question {
        let question: String
        let header: String
        let options: [String]
        let multiSelect: Bool
    }

    let questions: [Question]

    init?(toolInput: [String: Any]) {
        guard let raw = toolInput["questions"] as? [[String: Any]], !raw.isEmpty else { return nil }
        questions = raw.compactMap { q in
            guard let text = q["question"] as? String else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
            return Question(question: text,
                            header: q["header"] as? String ?? "",
                            options: options,
                            multiSelect: q["multiSelect"] as? Bool ?? false)
        }
        if questions.isEmpty { return nil }
    }
}

/// Kurze Einblendung, die von selbst wieder verschwindet.
struct Banner: Equatable {
    enum Style { case greeting, done, info }
    let id = UUID()
    let style: Style
    let title: String
    let subtitle: String
}

@MainActor
final class NotchModel: ObservableObject {
    static let shared = NotchModel()

    @Published private(set) var sessions: [String: SessionInfo] = [:]
    @Published private(set) var pending: [PendingRequest] = []
    @Published private(set) var banner: Banner?
    @Published var claudeAppRunning = false

    private var bannerTask: Task<Void, Never>?
    private var timeouts: [UUID: Task<Void, Never>] = [:]
    private var settleTasks: [String: Task<Void, Never>] = [:]
    private var lookupsRunning: Set<String> = []
    private var lookupTimes: [String: Date] = [:]
    private var titleScans: [String: SessionTitles.State] = [:]
    private var titleRunning: Set<String> = []
    private var titleTimes: [String: Date] = [:]
    private var watchdog: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private let prefs = Preferences.shared

    private init() {
        startWatchdog()
        // Beim Pausieren offene Anfragen ans Terminal zurückgeben, sonst hängen sie unsichtbar.
        prefs.$enabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard !enabled, let self else { return }
                Task { @MainActor in self.releaseAllRequests() }
            }
            .store(in: &cancellables)
    }

    /// Sitzungen, die gerade arbeiten, dich brauchen oder eben fertig wurden. Die, die warten, zuerst.
    var activeSessions: [SessionInfo] {
        sessions.values.filter(\.isActive).sorted { a, b in
            if (a.state == .waiting) != (b.state == .waiting) { return a.state == .waiting }
            return a.updatedAt > b.updatedAt
        }
    }

    /// Bekannte Sitzungen, die gerade nichts tun (z.B. offene Chats in der Desktop App).
    var idleCount: Int { sessions.values.filter { !$0.isActive }.count }
    var isWorking: Bool { sessions.values.contains { $0.state == .working } }
    /// Eine Sitzung wartet auf das Zurücksetzen des Limits (höchstens `limitWaitMax` lang).
    var hasLimitWait: Bool {
        sessions.values.contains { s in s.limitSince.map { Date().timeIntervalSince($0) < Self.limitWaitMax } ?? false }
    }
    /// Länger als ein 5-Stunden-Fenster hält ein Limit den Mac nicht wach.
    static let limitWaitMax: TimeInterval = 5.5 * 3600
    var needsAttention: Bool { sessions.values.contains { $0.state == .waiting } }
    var currentRequest: PendingRequest? { pending.first }

    // MARK: - Konten

    /// Welches Konto eine Sitzung nutzt: zuerst CLAUDE_CONFIG_DIR, wie der Hook ihn meldet,
    /// sonst der Pfad des Transkripts. Meldet sich ein Ordner, den Notchwerk noch nicht kennt
    /// (z.B. weil du die settings.json samt Hook kopiert hast), kommt er als neues Konto dazu.
    private func account(for event: [String: Any], transcript: String?) -> ClaudeAccount? {
        guard let raw = event["_notch_config"] as? String, let colon = raw.firstIndex(of: ":") else {
            return prefs.account(forTranscript: transcript)
        }
        let isSet = raw[..<colon] == "1"
        let value = String(raw[raw.index(after: colon)...])
        guard isSet, !value.isEmpty else {
            prefs.rememberEnvValue(nil, for: ClaudeAccount.defaultID)
            return prefs.account(id: ClaudeAccount.defaultID)
        }
        let dir = ClaudeAccount.normalize(value)
        guard dir.hasPrefix("/") else { return prefs.account(forTranscript: transcript) }
        if let known = prefs.accounts.first(where: { $0.configDir == dir }) {
            prefs.rememberEnvValue(value, for: known.id)
            return prefs.account(id: known.id)
        }
        var added = ClaudeAccount.make(name: ClaudeAccount.suggestedName(forDir: dir), configDir: dir)
        added.envValue = value
        prefs.accounts.append(added)
        showBanner(Banner(style: .info, title: "Weiteres Konto erkannt",
                          subtitle: "„\(added.name)“ (\(added.displayPath)). Umbenennen in den Einstellungen."),
                   duration: 4)
        return added
    }

    // MARK: - Ereignisse von Claude Code

    func handle(event: [String: Any], reply: @escaping (Data?) -> Void, onClose: (@escaping () -> Void) -> Void) {
        let name = event["hook_event_name"] as? String ?? ""
        let sessionId = event["session_id"] as? String ?? "unbekannt"
        let cwd = event["cwd"] as? String ?? ""
        var session = sessions[sessionId] ?? SessionInfo(id: sessionId, cwd: cwd)
        if !cwd.isEmpty { session.cwd = cwd }
        if let transcript = event["transcript_path"] as? String, !transcript.isEmpty {
            session.transcriptPath = transcript
        }
        if let account = account(for: event, transcript: session.transcriptPath) {
            session.accountID = account.id
        }
        if let chain = event["_notch_origin"] as? String, !chain.isEmpty {
            let origin = SessionOrigin.parse(chain)
            if origin.host != .unknown || session.origin.host == .unknown { session.origin = origin }
        }
        session.updatedAt = Date()

        switch name {
        case "SessionStart":
            session.state = .idle
            session.detail = "Bereit"
            sessions[sessionId] = session
            reply(nil)

        case "UserPromptSubmit":
            session.limitSince = nil
            session.state = .working
            session.detail = "Denkt nach …"
            sessions[sessionId] = session
            settleTasks[sessionId]?.cancel()
            clearNotices(for: sessionId)
            reply(nil)

        case "PreToolUse":
            let tool = event["tool_name"] as? String ?? "Tool"
            let input = event["tool_input"] as? [String: Any] ?? [:]
            session.state = .working
            session.limitSince = nil
            session.detail = ToolDescriber.short(tool: tool, input: input)
            sessions[sessionId] = session

            if tool == "AskUserQuestion", let questions = QuestionSet(toolInput: input) {
                if prefs.answerQuestionsInNotch && prefs.enabled {
                    session.state = .waiting
                    sessions[sessionId] = session
                    let request = PendingRequest(sessionId: sessionId, project: session.displayName,
                                                 kind: .question(questions)) { answer in
                        reply(HookResponses.questionAnswer(answer, toolInput: input))
                    }
                    enqueue(request, onClose: onClose)
                } else {
                    reply(nil)
                    session.state = .waiting
                    session.detail = "Hat eine Frage"
                    sessions[sessionId] = session
                    let first = questions.questions[0]
                    enqueueNotice(sessionId: sessionId, project: session.displayName,
                                  title: "Claude hat eine Frage",
                                  message: first.question)
                }
            } else {
                reply(nil)
            }

        case "PostToolUse", "PostToolUseFailure", "PostToolBatch":
            session.state = .working
            sessions[sessionId] = session
            reply(nil)

        case "PermissionRequest":
            let tool = event["tool_name"] as? String ?? "Tool"
            let input = event["tool_input"] as? [String: Any] ?? [:]
            let suggestions = event["permission_suggestions"] as? [Any] ?? []
            session.state = .waiting
            session.detail = "Wartet auf Freigabe"
            sessions[sessionId] = session

            guard prefs.answerInNotch, prefs.enabled else {
                reply(nil)
                enqueueNotice(sessionId: sessionId, project: session.displayName,
                              title: "Freigabe nötig: \(ToolDescriber.displayName(tool))",
                              message: ToolDescriber.long(tool: tool, input: input))
                return
            }
            let request = PendingRequest(
                sessionId: sessionId, project: session.displayName,
                kind: .permission(tool: ToolDescriber.displayName(tool),
                                  summary: ToolDescriber.long(tool: tool, input: input),
                                  canAlwaysAllow: !suggestions.isEmpty)
            ) { answer in
                reply(HookResponses.permission(answer, suggestions: suggestions))
            }
            enqueue(request, onClose: onClose)

        case "Notification":
            reply(nil)
            let type = event["notification_type"] as? String ?? ""
            let message = event["message"] as? String ?? ""
            // Freigaben, die schon im Notch offen sind, nicht doppelt anzeigen.
            if type == "permission_prompt", pending.contains(where: { $0.sessionId == sessionId }) { return }
            switch type {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                session.state = .waiting
                session.detail = "Braucht dich"
                sessions[sessionId] = session
                enqueueNotice(sessionId: sessionId, project: session.displayName,
                              title: "Claude braucht dich", message: message)
            case "idle_prompt":
                // Claude ist fertig und wartet auf nichts Bestimmtes. Dafür gibt es keinen Hinweis,
                // sonst stünde dauernd „wartet auf dich“ da. Ein verpasstes Ende wird hier aufgeräumt.
                if session.state == .working || session.state == .done {
                    session.state = .idle
                    session.detail = "Bereit"
                }
                sessions[sessionId] = session
            case "quota_auto_resume_fired":
                // Limit zurückgesetzt, Claude Code macht von selbst weiter.
                session.limitSince = nil
                session.state = .working
                session.detail = "Limit zurückgesetzt, macht weiter"
                sessions[sessionId] = session
                clearNotices(for: sessionId)
                showBanner(Banner(style: .info, title: "Limit zurückgesetzt", subtitle: "\(session.displayName) macht weiter"),
                           duration: 4)
            case "quota_auto_resume_stale", "quota_auto_resume_disabled":
                session.limitSince = nil
                session.state = .waiting
                session.detail = "Braucht dich"
                sessions[sessionId] = session
                let stale = type == "quota_auto_resume_stale"
                enqueueNotice(sessionId: sessionId, project: session.displayName,
                              title: stale ? "Claude wartet auf Enter" : "Claude macht nicht von selbst weiter",
                              message: message.isEmpty
                                ? (stale ? "Das Limit ist zurückgesetzt, aber der Mac hat länger geschlafen. Im Terminal Enter drücken. „Mac wach halten“ in den Einstellungen verhindert das."
                                         : "Das Limit ist zurückgesetzt. Schau kurz bei Claude vorbei.")
                                : message)
            case "interrupted_prompt":
                session.state = .idle
                session.detail = "Abgebrochen"
                sessions[sessionId] = session
                clearNotices(for: sessionId)
            default:
                if !message.isEmpty {
                    showBanner(Banner(style: .info, title: message, subtitle: session.displayName), duration: 3.5)
                }
            }

        case "Stop":
            session.limitSince = nil
            clearNotices(for: sessionId)
            // Geplante Nachricht (erweitert): Claude macht gleich damit weiter.
            if let text = FollowUps.shared.take(for: sessionId) {
                session.state = .working
                session.detail = "Geplante Nachricht gesendet"
                sessions[sessionId] = session
                reply(HookResponses.continueWith(text))
                showBanner(Banner(style: .info, title: "Geplante Nachricht gesendet", subtitle: session.displayName),
                           duration: 3.5)
                break
            }
            session.state = .done
            session.detail = "Fertig"
            sessions[sessionId] = session
            Sounds.play(.done)
            // Im Notch antworten (erweitert): Claude Code wartet kurz auf deine Antwort.
            if prefs.replyInNotch && prefs.enabled {
                let last = Self.clip(event["last_assistant_message"] as? String ?? "", to: 600)
                let window = TimeInterval(prefs.replyWindow)
                let request = PendingRequest(sessionId: sessionId, project: session.displayName,
                                             kind: .reply(lastMessage: last, deadline: Date().addingTimeInterval(window))) { answer in
                    if case .message(let text) = answer {
                        reply(HookResponses.continueWith(text))
                    } else {
                        reply(nil)
                    }
                }
                enqueue(request, onClose: onClose, timeout: window, sound: false)
                break
            }
            reply(nil)
            showBanner(Banner(style: .done, title: "Fertig", subtitle: session.displayName), duration: 3)
            settleLater(sessionId)

        case "StopFailure":
            reply(nil)
            if event["error"] as? String == "rate_limit" {
                session.limitSince = Date()
                session.state = .idle
                session.detail = "Limit erreicht"
                sessions[sessionId] = session
                enqueueLimitNotice(session)
                break
            }
            session.state = .done
            session.detail = "Abgebrochen"
            sessions[sessionId] = session
            showBanner(Banner(style: .info, title: "Abgebrochen", subtitle: session.displayName), duration: 3)
            settleLater(sessionId)

        case "SessionEnd":
            sessions[sessionId] = nil
            settleTasks[sessionId]?.cancel()
            settleTasks[sessionId] = nil
            dropRequests(for: sessionId)
            reply(nil)

        default:
            if sessions[sessionId] != nil { sessions[sessionId] = session }
            reply(nil)
        }
        refreshDesktopInfo(for: sessionId)
        refreshTitle(for: sessionId)
        pruneStaleSessions()
    }

    /// Liest den Chat-Titel nach, höchstens alle paar Sekunden je Sitzung und nur neue Zeilen.
    /// Nur Transkripte in den Ordnern bekannter Konten: Der Pfad kommt aus dem Hook.
    private func refreshTitle(for id: String, force: Bool = false) {
        guard let s = sessions[id], let raw = s.transcriptPath, !titleRunning.contains(id) else { return }
        if !force, let last = titleTimes[id], Date().timeIntervalSince(last) < 4 { return }
        let path = (raw as NSString).standardizingPath
        guard path.hasPrefix("/"), path.hasSuffix(".jsonl"),
              prefs.accounts.contains(where: { path.hasPrefix($0.configDir + "/projects/") }) else { return }
        titleRunning.insert(id)
        titleTimes[id] = Date()
        let state = titleScans[id] ?? SessionTitles.State()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let next = SessionTitles.scan(path: path, from: state)
            DispatchQueue.main.async {
                guard let self else { return }
                self.titleRunning.remove(id)
                guard self.sessions[id] != nil else {
                    self.titleScans[id] = nil
                    return
                }
                self.titleScans[id] = next
                if let title = next.title, self.sessions[id]?.chatTitle != title {
                    self.sessions[id]?.chatTitle = title
                }
            }
        }
    }

    /// Nach „Fertig“ verschwindet die Sitzung kurz darauf aus der Anzeige.
    private func settleLater(_ sessionId: String) {
        settleTasks[sessionId]?.cancel()
        settleTasks[sessionId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_500_000_000)
            guard !Task.isCancelled, let self, var s = self.sessions[sessionId], s.state == .done else { return }
            s.state = .idle
            s.detail = "Bereit"
            withAnimation(Theme.spring) { self.sessions[sessionId] = s }
        }
    }

    /// Sucht für Sitzungen aus der Desktop App den Chat-Titel und den Link zum Chat.
    private func refreshDesktopInfo(for id: String) {
        guard let s = sessions[id], s.origin.host == .claudeApp, !lookupsRunning.contains(id) else { return }
        if let d = s.desktop, !d.title.isEmpty { return }
        // Der Titel entsteht erst nach der ersten Antwort. Nicht bei jedem Ereignis neu suchen.
        if let last = lookupTimes[id], Date().timeIntervalSince(last) < 20 { return }
        lookupsRunning.insert(id)
        lookupTimes[id] = Date()
        DesktopSessions.lookup(cliSessionId: id) { [weak self] found in
            guard let self else { return }
            self.lookupsRunning.remove(id)
            guard let found, var s = self.sessions[id] else { return }
            s.desktop = found
            self.sessions[id] = s
        }
    }

    /// Holt das Fenster nach vorn, in dem die Sitzung läuft.
    func focus(_ session: SessionInfo) {
        SessionFocus.open(session)
    }

    // MARK: - Abbrüche erkennen

    /// Manches meldet kein Hook: ein beendeter Prozess, ein Abbruch mit Esc oder Stopp, eine Sitzung,
    /// die einfach nichts mehr sagt. Das prüft der Wächter alle drei Sekunden.
    private func startWatchdog() {
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.checkSessions()
            }
        }
    }

    private func checkSessions() {
        let now = Date()
        for (id, var session) in sessions {
            if let pid = session.origin.cliPID, !Self.isAlive(pid) {
                sessions[id] = nil
                settleTasks[id]?.cancel()
                settleTasks[id] = nil
                dropRequests(for: id)
                continue
            }
            guard session.state == .working || session.state == .waiting else { continue }
            refreshTitle(for: id)
            if let path = session.transcriptPath,
               let result = Self.transcriptStatus(path, lastSize: session.transcriptSize) {
                session.transcriptSize = result.size
                if result.interrupted {
                    session.state = .idle
                    session.detail = "Abgebrochen"
                    session.updatedAt = now
                    sessions[id] = session
                    clearNotices(for: id)
                    dropRequests(for: id)
                    continue
                }
                sessions[id] = session
            }
            if session.state == .working, now.timeIntervalSince(session.updatedAt) > 15 * 60 {
                session.state = .idle
                session.detail = "Keine Rückmeldung"
                sessions[id] = session
            }
        }
    }

    private nonisolated static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Liest nur, wenn sich die Datei verändert hat, und nur das Ende. Der Abbruch steht als
    /// Eintrag „[Request interrupted by user]“ ganz hinten im Transkript.
    private nonisolated static func transcriptStatus(_ path: String, lastSize: UInt64) -> (size: UInt64, interrupted: Bool)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value, size != lastSize else { return nil }
        guard let handle = FileHandle(forReadingAtPath: path) else { return (size, false) }
        defer { try? handle.close() }
        let tail: UInt64 = 16_384
        try? handle.seek(toOffset: size > tail ? size - tail : 0)
        let data = handle.readData(ofLength: Int(tail))
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return (size, false)
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.suffix(4).reversed() {
            if line.contains("[Request interrupted by user") { return (size, true) }
            if line.contains("\"type\":\"assistant\"") { return (size, false) }
            if line.contains("\"type\":\"user\""), !line.contains("tool_result") { return (size, false) }
        }
        return (size, false)
    }

    /// Alle offenen Anfragen ans Terminal zurückgeben (beim Pausieren).
    func releaseAllRequests() {
        for req in pending {
            req.respond(.terminal)
            remove(req.id)
        }
    }

    // MARK: - Anfragen

    private func enqueue(_ request: PendingRequest, onClose: (@escaping () -> Void) -> Void,
                         timeout: TimeInterval? = nil, sound: Bool = true) {
        pending.append(request)
        if sound { Sounds.play(.attention) }
        let id = request.id
        onClose { [weak self] in
            // Hook wurde abgebrochen (z.B. im Terminal beantwortet oder Esc gedrückt).
            self?.remove(id)
        }
        let timeout = timeout ?? prefs.permissionTimeout
        timeouts[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.answer(id, with: .terminal)
        }
    }

    private func enqueueNotice(sessionId: String, project: String, title: String, message: String) {
        guard prefs.enabled else { return }
        pending.removeAll { req in
            if case .notice = req.kind, req.sessionId == sessionId { return true }
            return false
        }
        let request = PendingRequest(sessionId: sessionId, project: project,
                                     kind: .notice(title: title, message: message)) { _ in }
        pending.append(request)
        Sounds.play(.attention)
    }

    func answer(_ id: UUID, with answer: PendingRequest.Answer) {
        guard let request = pending.first(where: { $0.id == id }) else { return }
        request.respond(answer)
        remove(id)
        switch request.kind {
        case .compose, .limit:
            return // nur bei uns, Claude Code wartet nicht darauf
        case .reply:
            guard var session = sessions[request.sessionId] else { return }
            if case .message = answer {
                session.state = .working
                session.detail = "Antwort gesendet"
            } else {
                settleLater(request.sessionId)
            }
            sessions[request.sessionId] = session
            return
        default:
            break
        }
        if var session = sessions[request.sessionId] {
            switch answer {
            case .deny:
                session.detail = "Abgelehnt"
            case .terminal:
                session.detail = "Antwort im Terminal"
            default:
                session.state = .working
                session.detail = "Weiter geht's …"
            }
            sessions[request.sessionId] = session
        }
    }

    func dismiss(_ id: UUID) {
        answer(id, with: .terminal)
    }

    private func remove(_ id: UUID) {
        timeouts[id]?.cancel()
        timeouts[id] = nil
        withAnimation(Theme.spring) {
            pending.removeAll { $0.id == id }
        }
    }

    private func clearNotices(for sessionId: String) {
        for req in pending where req.sessionId == sessionId {
            switch req.kind {
            case .notice, .limit: remove(req.id)
            default: break
            }
        }
    }

    // MARK: - Limit und geplante Nachrichten

    /// Hinweis im Notch: Limit erreicht, und wann es sich zurücksetzt, falls die Nutzung bekannt ist.
    private func enqueueLimitNotice(_ session: SessionInfo) {
        guard prefs.enabled else { return }
        var message = "Claude Code macht nach dem Zurücksetzen von selbst weiter"
        if let reset = limitReset(for: session) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "de_DE")
            f.dateFormat = Calendar.current.isDateInToday(reset) ? "HH:mm" : "EEE HH:mm"
            message += " (neu um \(f.string(from: reset)))"
        }
        message += "."
        if prefs.keepAwake == .off { message += " Damit das klappt, darf der Mac nicht schlafen." }
        pending.removeAll { req in
            if case .limit = req.kind { return req.sessionId == session.id }
            return false
        }
        let request = PendingRequest(sessionId: session.id, project: session.displayName,
                                     kind: .limit(message: message)) { _ in }
        pending.append(request)
        Sounds.play(.attention)
    }

    /// Zeitpunkt, zu dem sich ein ausgeschöpftes Limit des Kontos zurücksetzt (nur mit Nutzungsanzeige bekannt).
    private func limitReset(for session: SessionInfo) -> Date? {
        guard let id = session.accountID, let account = prefs.account(id: id),
              let snap = UsageMonitor.shared.state(for: account).snapshot else { return nil }
        return snap.windows.filter { $0.percent >= 99.5 }.compactMap(\.resetsAt).filter { $0 > Date() }.max()
    }

    /// Feld zum Schreiben einer Nachricht öffnen, die Claude beim nächsten Ende der Sitzung bekommt.
    func composeFollowUp(for sessionId: String) {
        guard prefs.followUpsEnabled, prefs.enabled, let session = sessions[sessionId] else { return }
        pending.removeAll { req in
            guard req.sessionId == sessionId else { return false }
            switch req.kind {
            case .compose, .limit: return true
            default: return false
            }
        }
        let request = PendingRequest(sessionId: sessionId, project: session.displayName, kind: .compose) { answer in
            guard case .message(let text) = answer else { return }
            Task { @MainActor in FollowUps.shared.plan(text, for: sessionId, project: session.displayName) }
        }
        withAnimation(Theme.spring) { pending.append(request) }
    }

    /// Ganz kurz, mit sichtbarem „…“, falls gekürzt.
    private static func clip(_ text: String, to limit: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > limit ? String(t.prefix(limit)) + " …" : t
    }

    private func dropRequests(for sessionId: String) {
        for req in pending where req.sessionId == sessionId {
            req.respond(.terminal)
            remove(req.id)
        }
    }

    private func pruneStaleSessions() {
        let limit = Date().addingTimeInterval(-60 * 60)
        for (id, s) in sessions where s.updatedAt < limit && !pending.contains(where: { $0.sessionId == id }) {
            sessions[id] = nil
        }
        for id in Array(titleScans.keys) where sessions[id] == nil {
            titleScans[id] = nil
            titleTimes[id] = nil
        }
    }

    // MARK: - Einblendungen

    func showBanner(_ banner: Banner, duration: Double) {
        guard prefs.enabled else { return }
        bannerTask?.cancel()
        withAnimation(Theme.spring) { self.banner = banner }
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(Theme.softSpring) { self?.banner = nil }
        }
    }

    func clearBanner() {
        bannerTask?.cancel()
        withAnimation(Theme.softSpring) { banner = nil }
    }

    func greet() {
        showBanner(Banner(style: .greeting, title: "Hallo! Claude ist bereit", subtitle: "Ich melde mich hier, wenn Claude dich braucht."),
                   duration: 3.2)
        Sounds.play(.greeting)
    }

    // MARK: - Demo

    /// Spielt alle Zustände einmal ab, ganz ohne Claude Code: zwei Sitzungen, eine aus VS Code
    /// und eine aus dem Terminal, mit Freigabe und Abschluss.
    func runDemo() {
        let vscode = (id: "demo-vscode", cwd: "/Users/du/Projekte/claude-notch",
                      origin: "1\t??\t/Applications/Visual Studio Code.app/Contents/MacOS/Electron\n")
        let terminal = (id: "demo-terminal", cwd: "/Users/du/Projekte/spiele",
                        origin: "1\tttys999\t/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal\n")
        func send(_ s: (id: String, cwd: String, origin: String), _ extra: [String: Any]) {
            var event: [String: Any] = ["session_id": s.id, "cwd": s.cwd, "_notch_origin": s.origin]
            for (key, value) in extra { event[key] = value }
            handle(event: event, reply: { _ in }, onClose: { _ in })
        }
        func pause(_ seconds: Double) async {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        Task { @MainActor in
            greet()
            await pause(3.6)
            send(vscode, ["hook_event_name": "UserPromptSubmit", "prompt": "Baue mir eine Notch App"])
            await pause(1.4)
            send(terminal, ["hook_event_name": "UserPromptSubmit", "prompt": "Teste das Würfelspiel"])
            await pause(1.6)
            send(vscode, ["hook_event_name": "PreToolUse", "tool_name": "Read",
                          "tool_input": ["file_path": "/Users/du/Projekte/claude-notch/Package.swift"]])
            await pause(1.6)
            send(terminal, ["hook_event_name": "PreToolUse", "tool_name": "Bash",
                            "tool_input": ["command": "npm test"]])
            await pause(1.8)
            send(vscode, ["hook_event_name": "PreToolUse", "tool_name": "Edit",
                          "tool_input": ["file_path": "/Users/du/Projekte/claude-notch/Sources/NotchView.swift"]])
            await pause(1.8)
            send(vscode, ["hook_event_name": "PermissionRequest", "tool_name": "Bash",
                          "tool_input": ["command": "swift build -c release", "description": "App bauen"],
                          "permission_suggestions": [["type": "addRules"]]])
            // Wartet bis die Demo-Freigabe beantwortet wurde (oder max. 20 s).
            for _ in 0..<80 where pending.contains(where: { $0.sessionId == vscode.id }) {
                await pause(0.25)
            }
            for req in pending where req.sessionId == vscode.id { answer(req.id, with: .allow) }
            send(vscode, ["hook_event_name": "PreToolUse", "tool_name": "Bash",
                          "tool_input": ["command": "swift build -c release"]])
            await pause(2.2)
            send(terminal, ["hook_event_name": "Stop"])
            await pause(3.0)
            send(vscode, ["hook_event_name": "Stop"])
            await pause(4.0)
            send(vscode, ["hook_event_name": "SessionEnd"])
            send(terminal, ["hook_event_name": "SessionEnd"])
        }
    }
}
