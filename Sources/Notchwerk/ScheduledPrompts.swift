import AppKit
import Foundation

/// Geplante Prompts (erweiterte Einstellung „Nachrichten an Claude planen“): ein Prompt, den die App
/// zu einer Uhrzeit oder nach dem Zurücksetzen des Limits an Claude Code gibt, in einem neuen Chat
/// oder als Fortsetzung eines alten Chats.
///
/// Gestartet wird in einem neuen Terminal-Fenster mit `claude -- "<prompt>"` bzw.
/// `claude --resume <id> -- "<prompt>"`. Prompt, Ordner und Konto liegen in eigenen Dateien und
/// werden vom Startskript nur als Text gelesen. Das Skript selbst ist immer gleich, nur die
/// zufällige Auftrags-ID steht darin. So landet nichts, was du schreibst, als Befehl in einer Shell.
/// In ein schon offenes Fenster tippt die App nie (siehe README, „Nachrichten an Claude planen“).
///
/// Aufträge liegen nur im Arbeitsspeicher. Beendest du Notchwerk, sind sie weg.
@MainActor
final class ScheduledPrompts: ObservableObject {
    static let shared = ScheduledPrompts()

    enum Target: Equatable {
        /// Neuer Chat in diesem Ordner.
        case newChat(folder: String)
        /// Einen vorhandenen Chat fortsetzen. Claude Code findet ihn nur im Ordner, in dem er lief.
        case resume(sessionId: String, folder: String, title: String)

        var folder: String {
            switch self {
            case .newChat(let f), .resume(_, let f, _): return f
            }
        }
    }

    enum Trigger: Equatable {
        case limitReset
        case time
    }

    struct Job: Identifiable, Equatable {
        let id: String
        let accountID: String
        let target: Target
        let trigger: Trigger
        let due: Date
        let text: String
    }

    /// Ein Chat, den man fortsetzen kann, aus den Transkripten des Kontos.
    struct RecentChat: Identifiable, Hashable {
        let id: String
        let folder: String
        let title: String?
        let modified: Date

        var label: String {
            let project = SessionInfo.readable((folder as NSString).lastPathComponent)
            let when = modified.formatted(date: .abbreviated, time: .shortened)
            return "\(project) › \(title ?? "Chat vom \(when)")"
        }
    }

    nonisolated static let maxJobs = 10
    /// Weiter im Voraus plant man nicht. Nach einem Neustart der App wäre der Auftrag ohnehin weg.
    static let maxLead: TimeInterval = 7 * 24 * 3600
    /// Nach dem Zurücksetzen etwas warten, damit das neue Limit sicher gilt.
    static let resetDelay: TimeInterval = 90
    /// Hat der Mac zum geplanten Zeitpunkt geschlafen und ist erst viel später wach, startet nichts mehr.
    /// Claude soll nicht Stunden später überraschend loslegen.
    static let maxLateness: TimeInterval = 30 * 60

    @Published private(set) var jobs: [Job] = []

    private let prefs = Preferences.shared
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    private init() {}

    /// Wartet etwas auf den Start? Hält den Mac wach und verschiebt automatische Updates.
    var hasScheduled: Bool { prefs.followUpsEnabled && !jobs.isEmpty }

    // MARK: Planen

    enum PlanError: LocalizedError {
        case disabled, empty, tooMany, noAccount, noFolder, badSession, noReset, past, tooFar, notOpened

        var errorDescription: String? {
            switch self {
            case .disabled: return "Planen ist aus. Einschalten unter Einstellungen › Erweitert."
            case .empty: return "Bitte einen Prompt schreiben."
            case .tooMany: return "Höchstens \(ScheduledPrompts.maxJobs) geplante Prompts gleichzeitig."
            case .noAccount: return "Das Konto gibt es nicht mehr."
            case .noFolder: return "Der Ordner existiert nicht."
            case .badSession: return "Dieser Chat lässt sich nicht fortsetzen."
            case .noReset: return "Wann sich das Limit zurücksetzt, ist nicht bekannt. Dafür muss die Nutzungsanzeige an sein."
            case .past: return "Der Zeitpunkt liegt in der Vergangenheit."
            case .tooFar: return "Höchstens 7 Tage im Voraus."
            case .notOpened: return "Das Terminal ließ sich nicht öffnen."
            }
        }
    }

    /// Zeitpunkt, zu dem sich das Limit des Kontos als Nächstes zurücksetzt: ein ausgeschöpftes
    /// Limit zuerst, sonst das Sitzungslimit (5 Stunden). Nur mit Nutzungsanzeige bekannt.
    func nextReset(for account: ClaudeAccount) -> Date? {
        guard let snap = UsageMonitor.shared.state(for: account).snapshot else { return nil }
        let windows = snap.windows.filter { ($0.resetsAt ?? .distantPast) > Date() }
        if let full = windows.filter({ $0.percent >= 99.5 }).compactMap(\.resetsAt).max() { return full }
        return windows.first { $0.id == "five_hour" }?.resetsAt
    }

    @discardableResult
    func plan(text: String, accountID: String, target: Target, trigger: Trigger, at time: Date) throws -> Job {
        guard prefs.followUpsEnabled else { throw PlanError.disabled }
        let clean = FollowUps.sanitize(text)
        guard !clean.isEmpty else { throw PlanError.empty }
        guard jobs.count < Self.maxJobs else { throw PlanError.tooMany }
        guard let account = prefs.account(id: accountID) else { throw PlanError.noAccount }
        guard Self.isFolder(target.folder) else { throw PlanError.noFolder }
        if case .resume(let sid, _, _) = target, !Self.isSessionID(sid) { throw PlanError.badSession }

        let due: Date
        switch trigger {
        case .limitReset:
            guard let reset = nextReset(for: account) else { throw PlanError.noReset }
            due = reset.addingTimeInterval(Self.resetDelay)
        case .time:
            // Auf die Minute genau, Sekunden zählen nicht.
            due = Calendar.current.dateInterval(of: .minute, for: time)?.start ?? time
            guard due > Date().addingTimeInterval(-60) else { throw PlanError.past }
        }
        guard due <= Date().addingTimeInterval(Self.maxLead) else { throw PlanError.tooFar }

        let job = Job(id: UUID().uuidString, accountID: accountID, target: target,
                      trigger: trigger, due: due, text: clean)
        jobs.append(job)
        jobs.sort { $0.due < $1.due }
        updateTimer()
        return job
    }

    func cancel(_ id: String) {
        jobs.removeAll { $0.id == id }
        updateTimer()
    }

    func cancelAll() {
        jobs.removeAll()
        updateTimer()
    }

    // MARK: Auslösen

    private func updateTimer() {
        if jobs.isEmpty {
            timer?.invalidate()
            timer = nil
            return
        }
        if timer == nil {
            let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            t.tolerance = 3
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
    }

    private func tick() {
        guard prefs.followUpsEnabled else {
            cancelAll()
            return
        }
        let now = Date()
        let due = jobs.filter { $0.due <= now }
        guard !due.isEmpty else { return }
        jobs.removeAll { job in due.contains { $0.id == job.id } }
        for job in due {
            if now.timeIntervalSince(job.due) > Self.maxLateness {
                notify("Geplanter Prompt nicht gestartet",
                       "Der Mac hat um \(job.due.formatted(date: .omitted, time: .shortened)) geschlafen. Nichts wurde an Claude geschickt.")
                continue
            }
            do {
                try launch(job)
                notify("Geplanter Prompt gestartet", Self.summary(of: job))
            } catch {
                notify("Geplanter Prompt fehlgeschlagen", error.localizedDescription)
            }
        }
        updateTimer()
    }

    private func notify(_ title: String, _ subtitle: String) {
        NotchModel.shared.showBanner(Banner(style: .info, title: title, subtitle: subtitle), duration: 6)
    }

    static func summary(of job: Job) -> String {
        switch job.target {
        case .newChat(let folder):
            return "Neuer Chat in \(SessionInfo.readable((folder as NSString).lastPathComponent))"
        case .resume(_, _, let title):
            return "Fortsetzung von „\(title)“"
        }
    }

    // MARK: Starten

    private static var jobDir: URL { HookInstaller.dir.appendingPathComponent("geplant", isDirectory: true) }

    private func launch(_ job: Job) throws {
        guard let account = prefs.account(id: job.accountID) else { throw PlanError.noAccount }
        guard Self.isFolder(job.target.folder) else { throw PlanError.noFolder }
        let fm = FileManager.default
        let dir = Self.jobDir
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        // Beim Standardkonto ohne eigenen Ordner bleibt CLAUDE_CONFIG_DIR ungesetzt, wie im Terminal.
        let env = account.envValue ?? ""
        let config = account.isDefault && env.isEmpty ? "" : (env.isEmpty ? account.configDir : env)
        var session = ""
        if case .resume(let sid, _, _) = job.target {
            guard Self.isSessionID(sid) else { throw PlanError.badSession }
            session = sid
        }

        let base = dir.appendingPathComponent(job.id)
        let parts: [(ext: String, value: String)] = [
            ("prompt", job.text), ("folder", job.target.folder), ("config", config), ("session", session),
        ]
        let script = base.appendingPathExtension("command")
        let cleanUp = { for ext in parts.map(\.ext) + ["command"] { try? fm.removeItem(at: base.appendingPathExtension(ext)) } }
        do {
            for part in parts {
                let url = base.appendingPathExtension(part.ext)
                try Data(part.value.utf8).write(to: url, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            try Data(Self.script(id: job.id).utf8).write(to: script, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            cleanUp()
            throw error
        }
        guard NSWorkspace.shared.open(script) else {
            cleanUp()
            throw PlanError.notOpened
        }
    }

    /// Das Startskript. Außer der ID (eine UUID, von der App erzeugt) steht nichts Veränderliches darin.
    private static func script(id: String) -> String {
        """
        #!/bin/zsh
        # Von Notchwerk angelegt: startet einen geplanten Prompt in Claude Code.
        # Prompt, Ordner und Konto stehen in eigenen Dateien daneben und werden nur als Text gelesen,
        # nie als Befehl ausgeführt. Nach dem Lesen löscht das Skript alle Dateien dieses Auftrags.
        j="${0:A:h}/\(id)"
        prompt="$(<"$j.prompt")"
        folder="$(<"$j.folder")"
        config="$(<"$j.config")"
        session="$(<"$j.session")"
        rm -f -- "$j.prompt" "$j.folder" "$j.config" "$j.session" "$j.command"
        if [[ -n "$config" ]]; then export CLAUDE_CONFIG_DIR="$config"; fi
        if ! cd -- "$folder" 2>/dev/null; then
          print -r -- "Der Ordner für den geplanten Prompt fehlt: $folder"
          read -k 1 "?Taste drücken zum Schließen …"
          exit 1
        fi
        if ! command -v claude >/dev/null 2>&1; then
          print -r -- "Claude Code (claude) wurde nicht gefunden. Bitte zuerst installieren."
          read -k 1 "?Taste drücken zum Schließen …"
          exit 1
        fi
        print -r -- "Geplanter Prompt von Notchwerk"
        if [[ -n "$session" ]]; then
          exec claude --resume "$session" -- "$prompt"
        else
          exec claude -- "$prompt"
        fi

        """
    }

    // MARK: Prüfen

    /// Absoluter Pfad zu einem vorhandenen Ordner, ohne Steuerzeichen.
    nonisolated static func isFolder(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count < 1024,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Claude Code vergibt UUIDs. Mehr als Buchstaben, Ziffern und Bindestriche lassen wir nicht zu.
    nonisolated static func isSessionID(_ id: String) -> Bool {
        (8...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    // MARK: Alte Chats finden

    /// Die letzten Chats eines Kontos, neueste zuerst. Liest nur Dateinamen, Änderungszeit, den
    /// Arbeitsordner (Feld „cwd“) und den Titel. Läuft abseits des Main-Threads.
    nonisolated static func recentChats(in account: ClaudeAccount, limit: Int = 15) -> [RecentChat] {
        let fm = FileManager.default
        let projects = account.configURL.appendingPathComponent("projects", isDirectory: true)
        guard let folders = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return [] }
        var files: [(url: URL, modified: Date)] = []
        for folder in folders {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for url in items where url.pathExtension == "jsonl" {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                files.append((url, modified))
            }
        }
        files.sort { $0.modified > $1.modified }
        var chats: [RecentChat] = []
        for file in files {
            guard chats.count < limit else { break }
            let id = file.url.deletingPathExtension().lastPathComponent
            guard isSessionID(id), let folder = workingDirectory(of: file.url), isFolder(folder) else { continue }
            let title = SessionTitles.scan(path: file.url.path, from: .init()).title
            chats.append(RecentChat(id: id, folder: folder, title: title, modified: file.modified))
        }
        return chats
    }

    /// Erstes Feld „cwd“ in den ersten 256 KB des Transkripts.
    nonisolated private static func workingDirectory(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 256 * 1024)
        for line in data.split(separator: 0x0A) where line.count < 65536 {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let cwd = obj["cwd"] as? String, !cwd.isEmpty else { continue }
            return cwd
        }
        return nil
    }
}
