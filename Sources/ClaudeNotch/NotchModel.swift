import AppKit
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

    var projectName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "Claude Code" : name
    }
}

/// Etwas, worauf Claude eine Antwort von dir braucht.
final class PendingRequest: Identifiable {
    enum Kind {
        case permission(tool: String, summary: String, canAlwaysAllow: Bool)
        case question(QuestionSet)
        case notice(title: String, message: String)
    }

    enum Answer {
        case allow
        case allowAlways
        case deny
        case terminal
        case answers([String: String])
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
    private let prefs = Preferences.shared

    var activeSessions: [SessionInfo] {
        sessions.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    var isWorking: Bool { sessions.values.contains { $0.state == .working } }
    var currentRequest: PendingRequest? { pending.first }

    // MARK: - Ereignisse von Claude Code

    func handle(event: [String: Any], reply: @escaping (Data?) -> Void, onClose: (@escaping () -> Void) -> Void) {
        let name = event["hook_event_name"] as? String ?? ""
        let sessionId = event["session_id"] as? String ?? "unbekannt"
        let cwd = event["cwd"] as? String ?? ""
        var session = sessions[sessionId] ?? SessionInfo(id: sessionId, cwd: cwd)
        if !cwd.isEmpty { session.cwd = cwd }
        session.updatedAt = Date()

        switch name {
        case "SessionStart":
            session.state = .idle
            session.detail = "Bereit"
            sessions[sessionId] = session
            reply(nil)

        case "UserPromptSubmit":
            session.state = .working
            session.detail = "Denkt nach …"
            sessions[sessionId] = session
            clearNotices(for: sessionId)
            reply(nil)

        case "PreToolUse":
            let tool = event["tool_name"] as? String ?? "Tool"
            let input = event["tool_input"] as? [String: Any] ?? [:]
            session.state = .working
            session.detail = ToolDescriber.short(tool: tool, input: input)
            sessions[sessionId] = session

            if tool == "AskUserQuestion", let questions = QuestionSet(toolInput: input) {
                if prefs.answerQuestionsInNotch {
                    session.state = .waiting
                    sessions[sessionId] = session
                    let request = PendingRequest(sessionId: sessionId, project: session.projectName,
                                                 kind: .question(questions)) { answer in
                        reply(HookResponses.questionAnswer(answer, toolInput: input))
                    }
                    enqueue(request, onClose: onClose)
                } else {
                    reply(nil)
                    let first = questions.questions[0]
                    enqueueNotice(sessionId: sessionId, project: session.projectName,
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

            guard prefs.answerInNotch else {
                reply(nil)
                enqueueNotice(sessionId: sessionId, project: session.projectName,
                              title: "Freigabe nötig: \(ToolDescriber.displayName(tool))",
                              message: ToolDescriber.long(tool: tool, input: input))
                return
            }
            let request = PendingRequest(
                sessionId: sessionId, project: session.projectName,
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
                enqueueNotice(sessionId: sessionId, project: session.projectName,
                              title: "Claude braucht dich", message: message)
            case "idle_prompt":
                session.state = .waiting
                session.detail = "Wartet auf deine Eingabe"
                sessions[sessionId] = session
                showBanner(Banner(style: .info, title: "Claude wartet auf dich", subtitle: session.projectName),
                           duration: 4)
            default:
                if !message.isEmpty {
                    showBanner(Banner(style: .info, title: message, subtitle: session.projectName), duration: 3.5)
                }
            }

        case "Stop":
            session.state = .done
            session.detail = "Fertig"
            sessions[sessionId] = session
            clearNotices(for: sessionId)
            reply(nil)
            showBanner(Banner(style: .done, title: "Fertig", subtitle: session.projectName), duration: 3)
            Sounds.play(.done)

        case "StopFailure":
            session.state = .done
            session.detail = "Abgebrochen"
            sessions[sessionId] = session
            reply(nil)
            showBanner(Banner(style: .info, title: "Abgebrochen", subtitle: session.projectName), duration: 3)

        case "SessionEnd":
            sessions[sessionId] = nil
            dropRequests(for: sessionId)
            reply(nil)

        default:
            if sessions[sessionId] != nil { sessions[sessionId] = session }
            reply(nil)
        }
        pruneStaleSessions()
    }

    // MARK: - Anfragen

    private func enqueue(_ request: PendingRequest, onClose: (@escaping () -> Void) -> Void) {
        pending.append(request)
        Sounds.play(.attention)
        let id = request.id
        onClose { [weak self] in
            // Hook wurde abgebrochen (z.B. im Terminal beantwortet oder Esc gedrückt).
            self?.remove(id)
        }
        let timeout = prefs.permissionTimeout
        timeouts[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.answer(id, with: .terminal)
        }
    }

    private func enqueueNotice(sessionId: String, project: String, title: String, message: String) {
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
            if case .notice = req.kind { remove(req.id) }
        }
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
    }

    // MARK: - Einblendungen

    func showBanner(_ banner: Banner, duration: Double) {
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

    /// Spielt alle Zustände einmal ab, ganz ohne Claude Code.
    func runDemo() {
        let demoId = "demo-session"
        let base: [String: Any] = ["session_id": demoId, "cwd": "/Users/du/Projekte/claude-notch"]
        func send(_ extra: [String: Any]) {
            handle(event: base.merging(extra) { $1 }, reply: { _ in }, onClose: { _ in })
        }
        Task { @MainActor in
            greet()
            try? await Task.sleep(nanoseconds: 3_600_000_000)
            send(["hook_event_name": "UserPromptSubmit", "prompt": "Baue mir eine Notch App"])
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            send(["hook_event_name": "PreToolUse", "tool_name": "Read",
                  "tool_input": ["file_path": "/Users/du/Projekte/claude-notch/Package.swift"]])
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            send(["hook_event_name": "PreToolUse", "tool_name": "Edit",
                  "tool_input": ["file_path": "/Users/du/Projekte/claude-notch/Sources/NotchView.swift"]])
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            send(["hook_event_name": "PermissionRequest", "tool_name": "Bash",
                  "tool_input": ["command": "swift build -c release", "description": "App bauen"],
                  "permission_suggestions": [["type": "addRules"]]])
            // Wartet bis die Demo-Freigabe beantwortet wurde (oder max. 20 s).
            for _ in 0..<80 where pending.contains(where: { $0.sessionId == demoId }) {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            for req in pending where req.sessionId == demoId { answer(req.id, with: .allow) }
            send(["hook_event_name": "PreToolUse", "tool_name": "Bash",
                  "tool_input": ["command": "swift build -c release"]])
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            send(["hook_event_name": "Stop"])
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            send(["hook_event_name": "SessionEnd"])
        }
    }
}
