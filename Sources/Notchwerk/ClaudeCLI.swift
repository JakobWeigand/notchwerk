import Foundation

/// Startet die offizielle `claude`-CLI im Headless-Modus (`-p`) für den Chat. Die App spricht nie selbst
/// mit der Anthropic-API und benutzt keinen Anmelde-Token für Anfragen: Claude Code meldet sich mit
/// dem Konto an, dessen Konfigurationsordner (CLAUDE_CONFIG_DIR) wir mitgeben, genau wie im Terminal.
enum ClaudeCLI {
    // MARK: Programm finden

    private static let lock = NSLock()
    private static var cachedBinary: URL?

    /// Wo `claude` üblicherweise liegt. Eine App aus dem Finder kennt den PATH deiner Shell nicht.
    private static var knownPlaces: [String] {
        let home = ClaudeAccount.home
        return [
            home + "/.local/bin/claude",
            home + "/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            home + "/.npm-global/bin/claude",
            home + "/.volta/bin/claude",
            home + "/.bun/bin/claude",
        ]
    }

    /// Pfad zu `claude` oder nil. Blockiert kurz, wenn die Login-Shell gefragt werden muss: nicht auf dem Main-Thread aufrufen.
    static func locate() -> URL? {
        lock.lock()
        if let cached = cachedBinary, FileManager.default.isExecutableFile(atPath: cached.path) {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var found = knownPlaces.first { FileManager.default.isExecutableFile(atPath: $0) }
        if found == nil { found = askLoginShell() }
        guard let path = found else { return nil }
        let url = URL(fileURLWithPath: path)
        lock.lock()
        cachedBinary = url
        lock.unlock()
        return url
    }

    /// `command -v claude` in einer Login-Shell. Der Befehl ist fest, nichts davon kommt von außen.
    private static func askLoginShell() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "command -v claude"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // Beim Start einer Login-Shell kann Text davor stehen. Gültig ist nur die letzte Zeile mit absolutem Pfad.
        let line = text.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        guard line.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: line) else { return nil }
        return line
    }

    // MARK: Aufruf

    /// Der Chat darf nur lesen. Ohne Ordner ist es ein reiner Chat ohne Werkzeuge.
    static let readTools = "Read,Glob,Grep"

    /// Argumente für einen Chat-Durchgang. Der Prompt geht über die Standardeingabe, nicht über die
    /// Argumente, damit er in keiner Prozessliste steht.
    ///
    /// * `--safe-mode`: keine Hooks, Plugins, MCP-Server oder CLAUDE.md. So läuft nichts von deiner
    ///   Konfiguration mit, und der Chat taucht nicht als Sitzung im Notch auf.
    /// * `--tools`: nur Lesen (Read, Glob, Grep), nichts schreiben, keine Befehle, kein Netz.
    /// * `--permission-prompts none`: was eine Rückfrage bräuchte (z.B. Dateien außerhalb des Ordners), wird abgelehnt.
    static func arguments(sessionID: String?, readOnlyFolder: Bool, systemPrompt: String) -> [String] {
        var args = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--safe-mode",
            "--tools", readOnlyFolder ? readTools : "",
            "--permission-prompts", "none",
            "--name", "Notchwerk Chat",
            "--append-system-prompt", systemPrompt,
        ]
        if let sessionID { args += ["--resume", sessionID] }
        return args
    }

    /// Mögliche Werte für CLAUDE_CONFIG_DIR, in der Reihenfolge, in der sie probiert werden (nil: Variable
    /// ungesetzt). Claude Code leitet aus der Variable den Namen des Schlüsselbund-Eintrags ab. Beim Standardkonto
    /// liegt die Anmeldung normalerweise unter dem Namen ohne Variable; ein Eintrag mit Variable kann zwar
    /// existieren, aber nur MCP-Daten enthalten, sodass Claude Code das Konto dann nicht findet („Not logged in“).
    /// Darum zuerst ohne, und erst wenn das nicht klappt, mit der Schreibweise, die ein Hook zuletzt gemeldet hat.
    /// Bei weiteren Konten ist die Variable nötig: erst die gemeldete Schreibweise, dann der Ordner.
    static func configChoices(for account: ClaudeAccount) -> [String?] {
        let raw = account.envValue ?? ""
        var choices: [String?] = []
        if account.isDefault { choices.append(nil) }
        if !raw.isEmpty { choices.append(raw) }
        if !account.isDefault { choices.append(account.configDir) }
        var seen = Set<String>()
        return choices.filter { seen.insert($0 ?? "\u{0}unset").inserted }
    }

    /// Umgebung für einen Aufruf. Variablen, die ändern würden, wer angemeldet ist oder wer bezahlt (API-Schlüssel,
    /// Cloud-Anbieter), werden entfernt, damit der Chat nie versehentlich über einen API-Schlüssel statt über das Abo läuft.
    static func environment(config: String?, base: [String: String]) -> [String: String] {
        var env = base
        for key in ["CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
                    "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] {
            env[key] = nil
        }
        if let config, !config.isEmpty { env["CLAUDE_CONFIG_DIR"] = config }
        // Eine App aus dem Finder hat einen schmalen PATH. Die üblichen Orte ergänzen.
        let extra = [ClaudeAccount.home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let current = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (current + extra.filter { !current.contains($0) }).joined(separator: ":")
        return env
    }
}

/// Ein Durchgang: `claude -p` starten, Prompt über stdin geben, die Ausgabe als Ereignisse liefern.
/// Alles Blockierende läuft auf eigenen Warteschlangen. Die Ereignisse kommen der Reihe nach über `events`.
final class ClaudeRun: @unchecked Sendable {
    enum Output {
        case event(ChatStreamEvent)
        /// Prozess beendet. `stderr` ist gekürzt und nur zum Anzeigen bei Fehlern gedacht.
        case exited(status: Int32, stderr: String, timedOut: Bool)
        case failedToStart(String)
    }

    /// Länger als so viele Sekunden ohne jede Ausgabe: abbrechen.
    static let idleLimit: TimeInterval = 300
    /// Eine einzelne Zeile der Ausgabe darf nicht unbegrenzt wachsen.
    private static let maxLine = 8 * 1024 * 1024

    let outputs: AsyncStream<Output>
    private let continuation: AsyncStream<Output>.Continuation
    private let state = NSLock()
    private var process: Process?
    private var cancelled = false
    private var lastActivity = Date()
    private var timedOut = false

    private let config: String?
    private let folder: String
    private let useFolder: Bool
    private let sessionID: String?
    private let prompt: String
    private let systemPrompt: String

    init(config: String?, folder: String, useFolder: Bool, sessionID: String?, prompt: String, systemPrompt: String) {
        var cont: AsyncStream<Output>.Continuation!
        outputs = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
        self.config = config
        self.folder = folder
        self.useFolder = useFolder
        self.sessionID = sessionID
        self.prompt = prompt
        self.systemPrompt = systemPrompt
    }

    /// Schreibt man an ein Programm, das schon beendet ist (z.B. weil es nicht angemeldet ist), beendet
    /// SIGPIPE sonst die ganze App. So bekommt das Schreiben stattdessen einen Fehler, den wir abfangen.
    private static let ignoreBrokenPipes: Void = { signal(SIGPIPE, SIG_IGN) }()

    func start() {
        _ = Self.ignoreBrokenPipes
        DispatchQueue.global(qos: .userInitiated).async { [self] in run() }
    }

    func cancel() {
        state.lock()
        cancelled = true
        let p = process
        state.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    private var isCancelled: Bool {
        state.lock(); defer { state.unlock() }
        return cancelled
    }

    private func touch() {
        state.lock(); lastActivity = Date(); state.unlock()
    }

    private func run() {
        defer { continuation.finish() }
        if isCancelled { return }
        guard let binary = ClaudeCLI.locate() else {
            continuation.yield(.failedToStart("Claude Code (claude) wurde nicht gefunden. Bitte zuerst installieren."))
            return
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = ClaudeCLI.arguments(sessionID: sessionID, readOnlyFolder: useFolder, systemPrompt: systemPrompt)
        process.environment = ClaudeCLI.environment(config: config, base: ProcessInfo.processInfo.environment)
        process.currentDirectoryURL = URL(fileURLWithPath: folder, isDirectory: true)
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        state.lock()
        let alreadyCancelled = cancelled
        if !alreadyCancelled { self.process = process }
        state.unlock()
        if alreadyCancelled { return }

        do {
            try process.run()
        } catch {
            continuation.yield(.failedToStart("Claude Code ließ sich nicht starten."))
            return
        }
        touch()

        // Prompt über stdin, dann schließen: ohne Ende der Eingabe wartet claude weiter.
        let promptData = Data(prompt.utf8)
        DispatchQueue.global(qos: .userInitiated).async {
            try? stdin.fileHandleForWriting.write(contentsOf: promptData)
            try? stdin.fileHandleForWriting.close()
        }

        // Fehlerausgabe getrennt sammeln (nur der Anfang, nur zum Anzeigen).
        let errorBox = ErrorBox()
        let errorDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let handle = stderr.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                errorBox.append(chunk)
            }
            errorDone.signal()
        }

        // Ohne Ausgabe zu lange: beenden.
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + 15, repeating: 15)
        watchdog.setEventHandler { [weak self] in
            guard let self, process.isRunning else { return }
            self.state.lock()
            let idle = Date().timeIntervalSince(self.lastActivity)
            if idle > Self.idleLimit { self.timedOut = true }
            let stop = self.timedOut
            self.state.unlock()
            if stop { process.terminate() }
        }
        watchdog.resume()

        let reader = stdout.fileHandleForReading
        var buffer = Data()
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            touch()
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                for event in ChatStream.parse(line: line) { continuation.yield(.event(event)) }
            }
            if buffer.count > Self.maxLine { buffer.removeAll() }
        }
        if !buffer.isEmpty {
            for event in ChatStream.parse(line: buffer) { continuation.yield(.event(event)) }
        }

        process.waitUntilExit()
        _ = errorDone.wait(timeout: .now() + 2)
        watchdog.cancel()
        state.lock()
        let timeout = timedOut
        state.unlock()
        continuation.yield(.exited(status: process.terminationStatus, stderr: errorBox.text, timedOut: timeout))
    }

    /// Sammelt die Fehlerausgabe, höchstens 16 KB.
    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            if data.count < 16 * 1024 { data.append(chunk.prefix(16 * 1024 - data.count)) }
        }

        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
