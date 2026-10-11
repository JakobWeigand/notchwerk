import AppKit
import Foundation

/// Eine Zeile im Chat: deine Nachricht, Claudes Antwort oder ein Hinweis der App (z.B. Kontowechsel).
struct ChatMessage: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant, notice }
    enum Tone: Equatable { case info, switched, warning, error }
    /// Knöpfe unter einem Hinweis.
    enum Action: Equatable {
        case useHere(accountID: String)
        case useAlways(accountID: String)
        case retry
        case cancelTurn
    }

    let id = UUID()
    var role: Role
    var text: String
    /// Welches Konto geantwortet hat (nur bei Antworten). Wer antwortet, soll man immer sehen.
    var accountID: String?
    var isStreaming = false
    /// „liest Skript.pdf“, solange Claude in den Unterlagen nachsieht.
    var activity: String?
    var tone: Tone = .info
    var actions: [Action] = []
}

/// Der Chat im eigenen Fenster. Jede Antwort kommt von `claude -p` mit dem Konto, das gerade dran ist
/// (siehe ClaudeCLI). Erreicht dieses Konto sein Limit, springt, wenn erlaubt, ein anderes Konto ein
/// und bekommt den bisherigen Verlauf mit. Notchwerk hält den Chat nur im Arbeitsspeicher; Claude Code
/// legt wie im Terminal ein Protokoll im Ordner des antwortenden Kontos an.
@MainActor
final class ChatModel: ObservableObject {
    static let shared = ChatModel()

    /// Ein erreichtes Limit eines Kontos.
    struct Block: Equatable {
        let until: Date
        /// Ob die CLI die Zeit des Zurücksetzens genannt hat. Sonst wird nur kurz gewartet und neu versucht.
        let resetKnown: Bool
        let kind: String?

        var label: String {
            let name: String
            switch kind {
            case "five_hour": name = "Sitzungslimit"
            case "seven_day": name = "Wochenlimit"
            default: name = "Limit"
            }
            return resetKnown ? "\(name) erreicht (neu \(ChatModel.resetClock(until)))" : "\(name) erreicht"
        }
    }

    enum AccountState: Equatable {
        case ready(sessionPercent: Int?, weekPercent: Int?)
        case limited(Block)
        case notSignedIn
    }

    @Published private(set) var messages: [ChatMessage] = []
    /// Ein Durchgang läuft (der Prozess arbeitet).
    @Published private(set) var isRunning = false
    /// Ein Durchgang läuft oder wartet auf deine Entscheidung (Kontowechsel). Dann ist das Eingabefeld gesperrt.
    @Published private(set) var isBusy = false
    @Published var draft = ""
    /// Das Konto, das zuerst antworten soll.
    @Published var preferredAccountID: String
    /// Das Konto, das zuletzt geantwortet hat.
    @Published private(set) var answeringID: String?
    @Published private(set) var blocks: [String: Block] = [:]
    /// Zuletzt gemeldete Auslastung je Konto und Fenster (1,0 = 100 %), aus den Meldungen der CLI.
    @Published private(set) var seen: [String: [String: Double]] = [:]
    /// Zählt jede Änderung, damit die Ansicht bei Bedarf nach unten scrollen kann.
    @Published private(set) var revision = 0
    /// Steigt, wenn das Eingabefeld den Fokus bekommen soll (beim Öffnen des Fensters).
    @Published private(set) var focusRequest = 0
    /// Projektordner einer übernommenen Sitzung. Gilt für diesen Chat statt des gespeicherten Ordners.
    @Published private(set) var folderOverride: String?

    private let prefs = Preferences.shared

    private struct CLISession {
        let id: String
        /// So viele Nachrichten des Verlaufs kennt die Sitzung dieses Kontos schon.
        var covered: Int
        let folder: String
    }

    private struct Turn {
        let userID: UUID
        let text: String
    }

    private final class RunContext {
        let token = UUID()
        let account: ClaudeAccount
        let run: ClaudeRun
        let assistantID: UUID
        let resumed: Bool
        let folder: String
        let configIndex: Int
        let configCount: Int
        var sawText = false
        var sessionID: String?
        var limit: RateLimitInfo?
        var systemText: String?
        var result: ResultInfo?

        init(account: ClaudeAccount, run: ClaudeRun, assistantID: UUID, resumed: Bool, folder: String,
             configIndex: Int, configCount: Int) {
            self.configIndex = configIndex
            self.configCount = configCount
            self.account = account
            self.run = run
            self.assistantID = assistantID
            self.resumed = resumed
            self.folder = folder
        }
    }

    private var cliSessions: [String: CLISession] = [:]
    /// Welche Schreibweise von CLAUDE_CONFIG_DIR bei einem Konto funktioniert hat (siehe ClaudeCLI.configChoices).
    private var configIndex: [String: Int] = [:]
    /// Aus einer Sitzung übernommener Verlauf. Er geht an Claude mit, steht aber nicht als Nachricht im Chat.
    private var seeded: [Entry] = []
    /// Nachrichten davor gehören zu einem früheren Thema und gehen nicht mehr an Claude.
    private var contextStart = 0
    private var turn: Turn?
    private var current: RunContext?
    /// Konten, die du für diesen Chat als Reserve zugelassen hast (ohne es dauerhaft einzustellen).
    private var reserveForThisChat: Set<String> = []

    private init() {
        let stored = Preferences.shared.chatAccountID
        let accounts = Preferences.shared.accounts
        preferredAccountID = accounts.contains { $0.id == stored } ? (stored ?? ClaudeAccount.defaultID) : ClaudeAccount.defaultID
    }

    // MARK: - Konten

    var accounts: [ClaudeAccount] { prefs.accounts }

    func account(_ id: String?) -> ClaudeAccount? {
        guard let id else { return nil }
        return prefs.account(id: id)
    }

    func name(of id: String?) -> String {
        account(id)?.name ?? "Konto"
    }

    /// Das Konto, das gerade antwortet oder als Nächstes antworten würde.
    var shownAccount: ClaudeAccount? {
        if let id = current?.account.id ?? answeringID, let a = account(id) { return a }
        return account(preferredAccountID) ?? accounts.first
    }

    func state(of account: ClaudeAccount) -> AccountState {
        if let block = blockInfo(for: account) { return .limited(block) }
        if account.signedIn() == nil { return .notSignedIn }
        func percent(_ key: String) -> Int? { seen[account.id]?[key].map { Int(($0 * 100).rounded()) } }
        return .ready(sessionPercent: percent("five_hour"), weekPercent: percent("seven_day"))
    }

    /// Wann ist das Konto wieder dran? Aus dem, was die CLI zuletzt gemeldet hat, und, falls die Nutzungsanzeige
    /// an ist, aus deren Stand. Beides gilt nur bis zum Zeitpunkt des Zurücksetzens.
    private func blockInfo(for account: ClaudeAccount) -> Block? {
        let now = Date()
        var found: Block?
        if let block = blocks[account.id], block.until > now { found = block }
        if prefs.showUsage || prefs.widgetsEnabled,
           let snapshot = UsageMonitor.shared.state(for: account).snapshot {
            let full = snapshot.windows.filter {
                ($0.id == "five_hour" || $0.id == "seven_day") && $0.percent >= 99.5 && ($0.resetsAt ?? .distantPast) > now
            }
            if let latest = full.max(by: { ($0.resetsAt ?? .distantPast) < ($1.resetsAt ?? .distantPast) }),
               let reset = latest.resetsAt, found.map({ reset > $0.until }) ?? true {
                found = Block(until: reset, resetKnown: true, kind: latest.id)
            }
        }
        return found
    }

    func setPreferred(_ id: String, remember: Bool) {
        guard account(id) != nil else { return }
        preferredAccountID = id
        if remember { prefs.chatAccountID = id }
    }

    // MARK: - Ordner

    /// Warum ein Ordner nicht als Chat-Ordner taugt, oder nil. Claude darf darin alles lesen, also
    /// nicht den Home-Ordner, nicht ~/Library und nicht versteckte Ordner wie ~/.ssh oder die Konten.
    nonisolated static func folderProblem(_ path: String) -> String? {
        guard ScheduledPrompts.isFolder(path) else { return "Der Ordner existiert nicht." }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let home = URL(fileURLWithPath: ClaudeAccount.home).resolvingSymlinksInPath().path
        if resolved == home { return "Bitte einen Unterordner wählen, nicht den ganzen Home-Ordner." }
        guard resolved.hasPrefix(home + "/") else { return "Der Ordner muss in deinem Home-Ordner liegen." }
        let first = resolved.dropFirst(home.count + 1).split(separator: "/").first.map(String.init) ?? ""
        if first.hasPrefix(".") || first == "Library" {
            return "Versteckte Ordner und ~/Library sind für den Chat gesperrt, dort liegen Schlüssel und Anmeldungen."
        }
        return nil
    }

    /// Der Ordner, den Claude gerade lesen darf: der der übernommenen Sitzung, sonst der gewählte.
    var effectiveFolder: String? { folderOverride ?? prefs.chatFolder }

    var folderIsUsable: Bool {
        guard let folder = effectiveFolder else { return false }
        return Self.folderProblem(folder) == nil
    }

    func setFolder(_ path: String?) {
        if path == nil, folderOverride != nil {
            folderOverride = nil
            return
        }
        if let path, Self.folderProblem(path) != nil { return }
        folderOverride = nil
        let resolved = path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        guard resolved != prefs.chatFolder else { return }
        prefs.chatFolder = resolved
        // Eine fortgesetzte Sitzung kennt nur den alten Ordner.
        cliSessions.removeAll()
        if !messages.isEmpty {
            let text = resolved.map { "Ordner gewechselt. Claude liest jetzt in „\(Self.folderTitle($0))“." } ?? "Ordner entfernt. Claude hat keinen Zugriff auf Dateien mehr."
            append(ChatMessage(role: .notice, text: text))
        }
    }

    nonisolated static func folderTitle(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Leerer Ordner für den reinen Chat ohne Unterlagen: nur der Arbeitsordner von Claude Code, nichts darin.
    private static func scratchFolder() -> String {
        let url = HookInstaller.dir.appendingPathComponent("chat", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return url.path
    }

    // MARK: - Senden

    nonisolated static let maxMessageLength = 20_000

    /// Ohne Steuerzeichen (außer Zeilenumbruch und Tab), ohne Leerraum am Rand, mit fester Höchstlänge.
    nonisolated static func sanitize(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "\n\t")
        let scalars = text.unicodeScalars.filter { allowed.contains($0) || !CharacterSet.controlCharacters.contains($0) }
        let clean = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(clean.prefix(maxMessageLength))
    }

    var canSend: Bool { !isBusy && !Self.sanitize(draft).isEmpty }

    func send() {
        guard !isBusy else { return }
        let text = Self.sanitize(draft)
        guard !text.isEmpty else { return }
        draft = ""
        let user = ChatMessage(role: .user, text: text)
        append(user)
        turn = Turn(userID: user.id, text: text)
        isBusy = true
        next()
    }

    /// Wer antwortet auf die aktuelle Nachricht? Das gewählte Konto, solange es kann.
    private enum Choice {
        case use(ClaudeAccount, replacing: (account: ClaudeAccount, block: Block)?)
        case consent(from: ClaudeAccount, block: Block, candidate: ClaudeAccount)
        case allBlocked(until: Date?, accountCount: Int)
    }

    private func choice() -> Choice {
        let all = accounts
        guard let preferred = account(preferredAccountID) ?? all.first else { return .allBlocked(until: nil, accountCount: 0) }
        guard let block = blockInfo(for: preferred) else { return .use(preferred, replacing: nil) }

        let others = all.filter { $0.id != preferred.id && $0.signedIn() != nil && blockInfo(for: $0) == nil }
        if let reserve = others.first(where: { prefs.chatReserveIDs.contains($0.id) || reserveForThisChat.contains($0.id) }) {
            return .use(reserve, replacing: (preferred, block))
        }
        if let candidate = others.first {
            return .consent(from: preferred, block: block, candidate: candidate)
        }
        let soonest = all.compactMap { blockInfo(for: $0)?.until }.min()
        return .allBlocked(until: soonest, accountCount: all.count)
    }

    private func next() {
        guard turn != nil else { return }
        removeActionNotices()
        switch choice() {
        case .use(let account, let replacing):
            announce(using: account, replacing: replacing)
            start(account, resume: true)

        case .consent(let from, let block, let candidate):
            // Gehört das Konto zu einer Organisation, sagen wir das dazu: Dort können eigene Regeln gelten.
            let organization = candidate.signedIn()?.sharedOrganization
            var text = "\(from.name): \(block.label). Mit \(candidate.name)\(organization.map { " (Organisation „\($0)“)" } ?? "") weiterschreiben? "
            text += "Deine Nachrichten gehen dann an dieses Konto und zählen dort aufs Limit."
            if organization != nil { text += " Bei Konten einer Organisation können deren Regeln gelten." }
            append(ChatMessage(
                role: .notice, text: text, tone: .warning,
                actions: [.useHere(accountID: candidate.id), .useAlways(accountID: candidate.id), .cancelTurn]))

        case .allBlocked(let until, let count):
            var text = count > 1 ? "Alle Konten sind am Limit." : "Das Konto ist am Limit."
            if let until { text += " Das erste ist ab \(Self.resetClock(until)) wieder frei." }
            append(ChatMessage(role: .notice, text: text, tone: .warning, actions: [.retry, .cancelTurn]))
        }
    }

    /// Sagt im Chat, warum ein anderes Konto antwortet, und wann das gewählte wieder dran ist.
    private func announce(using account: ClaudeAccount, replacing: (account: ClaudeAccount, block: Block)?) {
        // Bei der ersten Nachricht gibt es noch keinen Verlauf, den man mitgeben könnte.
        let handover = transcript(before: turn?.userID).isEmpty ? "" : ", der Verlauf wird mitgegeben"
        if let replacing {
            if answeringID != account.id {
                append(ChatMessage(role: .notice,
                                   text: "\(replacing.account.name): \(replacing.block.label). Weiter mit \(account.name)\(handover).",
                                   tone: .switched))
            }
        } else if let last = answeringID, last != account.id {
            append(ChatMessage(role: .notice,
                               text: "\(account.name) ist wieder frei. Weiter mit \(account.name)\(handover).",
                               tone: .switched))
        }
    }

    func perform(_ action: ChatMessage.Action) {
        switch action {
        case .useHere(let id):
            reserveForThisChat.insert(id)
            next()
        case .useAlways(let id):
            if !prefs.chatReserveIDs.contains(id) { prefs.chatReserveIDs.append(id) }
            next()
        case .retry:
            next()
        case .cancelTurn:
            guard let turn else { return }
            removeActionNotices()
            messages.removeAll { $0.id == turn.userID }
            if Self.sanitize(draft).isEmpty { draft = turn.text }
            self.turn = nil
            isBusy = false
            bump()
        }
    }

    // MARK: - Durchgang

    private func start(_ account: ClaudeAccount, resume: Bool) {
        guard let turn else { return }
        let useFolder = folderIsUsable
        let folder = useFolder ? (effectiveFolder ?? Self.scratchFolder()) : Self.scratchFolder()
        let choices = ClaudeCLI.configChoices(for: account)
        let index = min(configIndex[account.id] ?? 0, max(choices.count - 1, 0))

        let history = transcript(before: turn.userID)
        var sessionID: String?
        let prompt: String
        if resume, let known = cliSessions[account.id], known.folder == folder {
            sessionID = known.id
            let missed = Array(history.dropFirst(min(known.covered, history.count)))
            prompt = Self.compose(history: missed, kind: .missed, text: turn.text)
        } else {
            prompt = Self.compose(history: history, kind: .full, text: turn.text)
        }

        var assistant = ChatMessage(role: .assistant, text: "", accountID: account.id)
        assistant.isStreaming = true
        append(assistant)

        let run = ClaudeRun(config: choices.isEmpty ? nil : choices[index], folder: folder, useFolder: useFolder,
                            sessionID: sessionID, prompt: prompt, systemPrompt: Self.systemPrompt(useFolder: useFolder))
        let context = RunContext(account: account, run: run, assistantID: assistant.id,
                                 resumed: sessionID != nil, folder: folder,
                                 configIndex: index, configCount: choices.count)
        current = context
        isRunning = true
        run.start()
        Task { [weak self] in
            for await output in run.outputs {
                guard let self, self.current?.token == context.token else { return }
                self.handle(output, context)
            }
        }
    }

    private func handle(_ output: ClaudeRun.Output, _ context: RunContext) {
        switch output {
        case .event(let event):
            switch event {
            case .session(let id):
                context.sessionID = id
            case .textBlockStart:
                update(context.assistantID) { if !$0.text.isEmpty { $0.text += "\n\n" } }
            case .textDelta(let text):
                context.sawText = true
                update(context.assistantID) { $0.text += text; $0.activity = nil }
            case .activity(let text):
                update(context.assistantID) { $0.activity = text }
            case .rateLimit(let info):
                record(info, for: context.account)
                if info.status == .rejected, context.limit == nil {
                    context.limit = info
                    context.run.cancel()
                }
            case .systemMessage(let text):
                context.systemText = text
            case .result(let info):
                context.result = info
            }
        case .failedToStart(let why):
            end(context, error: why)
        case .exited(let status, let stderr, let timedOut):
            finish(context, status: status, stderr: stderr, timedOut: timedOut)
        }
    }

    private func record(_ info: RateLimitInfo, for account: ClaudeAccount) {
        if !info.windows.isEmpty { seen[account.id, default: [:]].merge(info.windows) { _, new in new } }
        guard info.status == .rejected else { return }
        blocks[account.id] = limitBlock(info.resetsAt, kind: info.kind)
        LimitFile.shared.publish()
    }

    /// Ohne bekannte Zeit des Zurücksetzens nur kurz warten und dann neu versuchen, statt etwas zu raten.
    private func limitBlock(_ reset: Date?, kind: String?) -> Block {
        if let reset, reset > Date() { return Block(until: reset, resetKnown: true, kind: kind) }
        return Block(until: Date().addingTimeInterval(300), resetKnown: false, kind: kind)
    }

    private func finish(_ context: RunContext, status: Int32, stderr: String, timedOut: Bool) {
        let account = context.account

        // Limit erreicht: Antwort verwerfen und das nächste passende Konto nehmen.
        var limited = context.limit != nil
        if !limited, context.result?.isError == true || status != 0,
           Self.looksLikeLimit(context.systemText ?? context.result?.text ?? "") {
            blocks[account.id] = limitBlock(nil, kind: nil)
            limited = true
        }
        if limited {
            settle(context)
            current = nil
            isRunning = false
            next()
            return
        }

        let failureText = context.systemText ?? context.result?.text ?? ""
        let failed = context.result?.isError == true || (context.result == nil && status != 0)

        // Nicht angemeldet: vielleicht liegt die Anmeldung unter einer anderen Schreibweise von CLAUDE_CONFIG_DIR.
        if failed, !context.sawText, Self.looksLikeNotLoggedIn(failureText + " " + stderr),
           context.configIndex + 1 < context.configCount {
            configIndex[account.id] = context.configIndex + 1
            settle(context)
            current = nil
            isRunning = false
            start(account, resume: true)
            return
        }

        // Die gemerkte Sitzung gibt es nicht mehr: einmal ohne sie neu anfangen, mit vollem Verlauf.
        if failed, context.resumed, !context.sawText, Self.looksLikeMissingSession(failureText + " " + stderr) {
            cliSessions[account.id] = nil
            settle(context)
            current = nil
            isRunning = false
            start(account, resume: false)
            return
        }

        if timedOut {
            end(context, error: "Claude Code hat \(Int(ClaudeRun.idleLimit / 60)) Minuten lang nichts gemeldet und wurde beendet.")
        } else if failed {
            end(context, error: Self.explain(failure: failureText, stderr: stderr, account: account))
        } else {
            if !context.sawText, let text = context.result?.text, !text.isEmpty {
                update(context.assistantID) { $0.text = text }
            }
            end(context, error: nil)
        }
    }

    /// Durchgang abschließen. Bei Erfolg merkt sich der Chat die Sitzung dieses Kontos. Bei einem Fehler
    /// bleibt die Nachricht stehen und wartet auf „Erneut versuchen“ oder „Abbrechen“.
    private func end(_ context: RunContext, error: String?) {
        settle(context)
        current = nil
        isRunning = false
        if let error {
            append(ChatMessage(role: .notice, text: error, tone: .error, actions: [.retry, .cancelTurn]))
        } else {
            answeringID = context.account.id
            configIndex[context.account.id] = context.configIndex
            if let sid = context.result?.sessionID ?? context.sessionID {
                cliSessions[context.account.id] = CLISession(id: sid, covered: transcript().count, folder: context.folder)
            }
            turn = nil
            isBusy = false
        }
        bump()
    }

    /// Die Antwort nicht mehr als laufend zeigen. Ist nichts angekommen, verschwindet die leere Zeile.
    private func settle(_ context: RunContext) {
        update(context.assistantID) {
            $0.isStreaming = false
            $0.activity = nil
        }
        dropPlaceholder(context)
    }

    /// Stoppt die laufende Antwort. Was schon da ist, bleibt stehen.
    func stop() {
        guard let context = current else { return }
        current = nil
        context.run.cancel()
        settle(context)
        turn = nil
        isRunning = false
        isBusy = false
        bump()
    }

    func newChat() {
        stop()
        removeActionNotices()
        messages.removeAll()
        cliSessions.removeAll()
        reserveForThisChat.removeAll()
        seeded.removeAll()
        contextStart = 0
        folderOverride = nil
        answeringID = nil
        turn = nil
        isBusy = false
        bump()
    }

    /// Beim Beenden der App.
    func shutdown() {
        current?.run.cancel()
        current = nil
    }

    // MARK: - Übernahme aus einer Sitzung

    /// Ein Konto, das einspringen kann: angemeldet, nicht am Limit und nicht das mit dem Limit.
    /// `requireReserve`: nur eines, das du als Reserve erlaubt hast (für die automatische Übernahme).
    func takeoverTarget(excluding id: String, requireReserve: Bool) -> ClaudeAccount? {
        accounts.first { account in
            account.id != id && account.signedIn() != nil && blockInfo(for: account) == nil
                && (!requireReserve || prefs.chatReserveIDs.contains(account.id))
        }
    }

    /// Merkt sich, dass ein Konto sein Limit erreicht hat (Meldung eines Hooks), ohne es selbst abzufragen.
    func noteBlocked(accountID: String, until: Date?) {
        blocks[accountID] = limitBlock(until, kind: nil)
        LimitFile.shared.publish()
    }

    /// Bis wann das Konto am Limit ist (nil: frei oder nicht bekannt). Für den Wrapper der Editoren, siehe LimitFile.
    func blockedUntil(_ account: ClaudeAccount) -> Date? {
        blockInfo(for: account)?.until
    }

    /// Übernimmt eine Sitzung: Das erste Konto bleibt das gewählte, das andere springt ein, bekommt die letzte
    /// Anfrage samt Verlauf und darf im Projektordner lesen. Läuft schon eine Antwort, passiert nichts.
    @discardableResult
    func takeOver(_ handoff: ChatHandoff, using targetID: String) -> Bool {
        guard !isBusy, let target = account(targetID), let blocked = account(handoff.blockedAccountID) else { return false }
        if !messages.isEmpty {
            append(ChatMessage(role: .notice, text: "Neues Thema: eine Sitzung wurde übernommen. Frühere Nachrichten gehen nicht mehr mit."))
        }
        contextStart = messages.count
        cliSessions.removeAll()
        seeded = handoff.history
        reserveForThisChat = [target.id]
        noteBlocked(accountID: blocked.id, until: handoff.blockedUntil)
        preferredAccountID = blocked.id
        folderOverride = handoff.folder.flatMap { Self.folderProblem($0) == nil ? $0 : nil }

        var text = "Übernommen aus „\(handoff.source)“: \(blocked.name) hat sein Limit erreicht. \(target.name) bekommt deine letzte Anfrage"
        text += handoff.history.isEmpty ? "" : " und die letzten \(handoff.history.count) Nachrichten"
        if let folder = folderOverride {
            text += ". Claude darf im Projektordner „\(Self.folderTitle(folder))“ lesen, aber nichts ändern. Änderungen an Dateien macht die Sitzung selbst, sobald \(blocked.name) wieder frei ist"
        }
        append(ChatMessage(role: .notice, text: text + ".", tone: .switched))
        draft = handoff.prompt
        send()
        return true
    }

    // MARK: - Verlauf

    typealias Entry = (role: ChatMessage.Role, text: String)

    /// Alle Nachrichten (deine und Claudes) vor einer bestimmten, ohne Hinweise der App.
    private func transcript(before id: UUID? = nil) -> [Entry] {
        var entries: [Entry] = seeded
        for message in messages.dropFirst(contextStart) {
            if message.id == id { break }
            guard message.role != .notice, !message.text.isEmpty else { continue }
            entries.append((message.role, message.text))
        }
        return entries
    }

    enum HistoryKind { case full, missed }

    /// Der Text, den Claude bekommt: bei einem neuen Konto der bisherige Verlauf, bei einem bekannten nur
    /// das, was es noch nicht gesehen hat. Ältere Nachrichten fallen weg, wenn es zu viel wird.
    nonisolated static func compose(history: [Entry], kind: HistoryKind, text: String) -> String {
        guard !history.isEmpty else { return text }
        var budget = 48_000
        var kept: [String] = []
        var cut = false
        for entry in history.reversed() {
            let line = (entry.role == .user ? "Nutzer: " : "Assistent: ") + entry.text
            if line.count > budget {
                if kept.isEmpty { kept.append(String(line.suffix(budget))) }
                cut = true
                break
            }
            budget -= line.count
            kept.append(line)
        }
        let intro: String
        switch kind {
        case .full:
            intro = "Bisheriger Verlauf dieses Chats (zur Orientierung, hier geht das Gespräch weiter)"
        case .missed:
            intro = "Seit deiner letzten Antwort in diesem Chat ist Folgendes passiert (ein anderes Konto hat teilweise geantwortet)"
        }
        return """
        \(intro)\(cut ? ", ältere Nachrichten sind gekürzt" : ""):

        \(kept.reversed().joined(separator: "\n\n"))

        ---
        Neue Nachricht des Nutzers:
        \(text)
        """
    }

    nonisolated static func systemPrompt(useFolder: Bool) -> String {
        var text = """
        Du bist ein hilfsbereiter Assistent im Chatfenster der Mac-App Notchwerk. Antworte in der Sprache des Nutzers, standardmäßig auf Deutsch. \
        Erkläre Schritt für Schritt und sauber, schreibe Formeln und Rechenwege nachvollziehbar und gib auf Wunsch Übungsaufgaben mit Lösungen. \
        Sag ehrlich, wenn du etwas nicht weißt oder die Unterlagen etwas nicht hergeben, und erfinde nichts. \
        Der Verlauf kann Abschnitte enthalten, die ein anderes Konto beantwortet hat; setze das Gespräch einfach fort.
        """
        if useFolder {
            text += """

            Im Arbeitsordner liegen Unterlagen des Nutzers (z.B. Skripte, Folien, Altklausuren). Du darfst sie mit Read, Glob und Grep lesen, \
            aber nichts ändern und keine Befehle ausführen. Wenn du aus den Unterlagen zitierst oder dich darauf stützt, nenne die Datei und die Stelle.
            """
        } else {
            text += "\n\nDu hast in diesem Chat keinen Zugriff auf Dateien."
        }
        return text
    }

    // MARK: - Fehlertexte

    nonisolated static func looksLikeLimit(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("limit") && (lower.contains("hit your") || lower.contains("reached") || lower.contains("resets"))
    }

    nonisolated static func looksLikeNotLoggedIn(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("not logged in") || lower.contains("please run /login")
    }

    nonisolated static func looksLikeMissingSession(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("no conversation found") || lower.contains("session id")
    }

    /// Eine Meldung der CLI für den Chat: ohne Steuerzeichen, gekürzt. Nicht angemeldet bekommt einen Hinweis.
    nonisolated static func explain(failure: String, stderr: String, account: ClaudeAccount) -> String {
        let lower = (failure + " " + stderr).lowercased()
        if lower.contains("not logged in") || lower.contains("/login") {
            return "\(account.name) ist in Claude Code nicht angemeldet. Einstellungen › Konten › „Anmelden …“, dann in Claude Code /login eingeben."
        }
        let raw = failure.isEmpty ? stderr : failure
        let scalars = raw.unicodeScalars.filter { $0 == "\n" || !CharacterSet.controlCharacters.contains($0) }
        let clean = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "Claude Code hat nicht geantwortet." }
        return "Claude Code meldet: " + (clean.count > 400 ? String(clean.prefix(400)) + "…" : clean)
    }

    nonisolated static func resetClock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: date)
    }

    // MARK: - Hilfen

    private func append(_ message: ChatMessage) {
        messages.append(message)
        bump()
    }

    private func update(_ id: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[i])
        bump()
    }

    private func dropPlaceholder(_ context: RunContext) {
        messages.removeAll { $0.id == context.assistantID && $0.text.isEmpty }
    }

    private func removeActionNotices() {
        messages.removeAll { $0.role == .notice && !$0.actions.isEmpty }
    }

    private func bump() { revision &+= 1 }

    func requestFocus() { focusRequest &+= 1 }
}
