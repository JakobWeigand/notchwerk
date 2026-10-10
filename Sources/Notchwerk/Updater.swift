import AppKit
import CryptoKit
import Foundation

/// Aktualisiert Notchwerk per Klick, ohne Terminal. Zwei Wege:
/// - Aus dem Projektordner (wer aus dem Quellcode installiert hat): `git pull`, dann
///   `scripts/build-app.sh`, also dasselbe wie `scripts/install.sh`.
/// - Über GitHub Releases (wer die fertige App geladen hat): neueste Notchwerk.zip laden,
///   Prüfsumme und Signatur prüfen.
/// Danach tauscht ein kleines Skript die App aus, sobald sie sich beendet hat, und startet sie neu.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repository = "JakobWeigand/notchwerk"

    enum Source: Equatable {
        case project(String)
        case releases
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(String)
        case working(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastCheck: Date?

    private let prefs = Preferences.shared
    private var release: Release?
    private var timer: Timer?
    private var started = false

    private init() {}

    var isBusy: Bool {
        switch phase {
        case .checking, .working: return true
        default: return false
        }
    }

    var isAvailable: Bool {
        if case .available = phase { return true }
        return false
    }

    var source: Source {
        if let dir = prefs.sourceDir, Self.isProject(dir) { return .project(dir) }
        return .releases
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Commit, aus dem diese App gebaut wurde (trägt build-app.sh ein), z.B. „5259539“ oder „5259539-dirty“.
    var builtCommit: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "NotchwerkCommit") as? String,
              !value.isEmpty, !value.hasPrefix("__") else { return nil }
        return value
    }

    /// Ein git-Checkout von Notchwerk mit Build-Skript.
    static func isProject(_ dir: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir + "/.git")
            && fm.fileExists(atPath: dir + "/Package.swift")
            && fm.isExecutableFile(atPath: dir + "/scripts/build-app.sh")
    }

    nonisolated static var logURL: URL { HookInstaller.dir.appendingPathComponent("update.log") }

    // MARK: - Start und Zeitplan

    func start() {
        guard !started else { return }
        started = true
        // Läuft die App direkt aus dist/ eines Projektordners, kennen wir den Ordner auch ohne install.sh.
        if prefs.sourceDir == nil {
            let app = Bundle.main.bundleURL
            let dir = app.deletingLastPathComponent().deletingLastPathComponent().path
            if app.deletingLastPathComponent().lastPathComponent == "dist", Self.isProject(dir) {
                prefs.sourceDir = dir
            }
        }
        configureTimer()
    }

    func configureTimer() {
        timer?.invalidate()
        timer = nil
        guard prefs.autoCheckUpdates else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.prefs.autoCheckUpdates else { return }
            self.check(quietly: true)
        }
        let t = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check(quietly: true) }
        }
        t.tolerance = 3600
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Nachsehen

    /// Nachsehen, ob es etwas Neues gibt. `quietly`: im Hintergrund, meldet sich nur bei einem Update.
    func check(quietly: Bool = false, then: ((Phase) -> Void)? = nil) {
        guard !isBusy else { return }
        phase = .checking
        Task {
            let result: Phase
            switch source {
            case .project(let dir): result = await checkProject(dir)
            case .releases: result = await checkReleases()
            }
            lastCheck = Date()
            if quietly, case .failed = result {
                phase = .idle
            } else {
                phase = result
            }
            if quietly, case .available(let what) = result {
                NotchModel.shared.showBanner(Banner(style: .info, title: "Update für Notchwerk",
                                                    subtitle: "\(what). Im Menü: Jetzt aktualisieren"), duration: 6)
            }
            then?(result)
        }
    }

    private func checkProject(_ dir: String) async -> Phase {
        // Offline oder ohne Upstream ist kein Fehler: dann zählt nur der lokale Stand.
        _ = await Shell.run(["git", "fetch", "--quiet"], in: dir, timeout: 30)
        let upstream = await Shell.run(["git", "rev-parse", "--abbrev-ref", "@{u}"], in: dir)
        var behind = 0
        if upstream.ok {
            let count = await Shell.run(["git", "rev-list", "--count", "HEAD..@{u}"], in: dir)
            behind = Int(count.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        let head = await Shell.run(["git", "rev-parse", "--short", "HEAD"], in: dir)
        guard head.ok else { return .failed("Projektordner ist kein git-Checkout") }
        let headShort = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = await Shell.run(["git", "status", "--porcelain", "--untracked-files=no"], in: dir)
        let dirty = !status.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let built = builtCommit ?? ""
        let builtBase = built.replacingOccurrences(of: "-dirty", with: "")
        let sameCommit = !builtBase.isEmpty && (headShort.hasPrefix(builtBase) || builtBase.hasPrefix(headShort))

        var news: [String] = []
        if behind > 0 { news.append("\(behind) neue Änderung\(behind == 1 ? "" : "en") auf GitHub") }
        if !sameCommit { news.append("neuer Stand im Projektordner (\(headShort))") }
        if dirty && sameCommit && !built.hasSuffix("-dirty") { news.append("ungesicherte Änderungen im Projektordner") }
        if news.isEmpty { return .upToDate("Aktuell (\(headShort))") }
        return .available(news.joined(separator: ", ").capitalizedFirst)
    }

    private func checkReleases() async -> Phase {
        do {
            let latest = try await Release.latest(repository: Self.repository)
            release = latest
            if Release.isNewer(latest.version, than: currentVersion) {
                return .available("Version \(latest.version) ist da")
            }
            return .upToDate("Aktuell (Version \(currentVersion))")
        } catch {
            return .failed("GitHub nicht erreichbar (\(error.localizedDescription))")
        }
    }

    // MARK: - Aktualisieren

    /// Neue Version holen oder bauen, prüfen, einsetzen und neu starten.
    func update() {
        guard !isBusy else { return }
        Task {
            do {
                let app: URL
                switch source {
                case .project(let dir): app = try await buildProject(dir)
                case .releases: app = try await downloadRelease()
                }
                try installAndRelaunch(app)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func buildProject(_ dir: String) async throws -> URL {
        try? FileManager.default.removeItem(at: Self.logURL)
        if await Shell.run(["git", "rev-parse", "--abbrev-ref", "@{u}"], in: dir).ok {
            phase = .working("Hole Änderungen von GitHub …")
            let pull = await Shell.run(["git", "pull", "--ff-only"], in: dir, timeout: 120, log: true)
            guard pull.ok else {
                throw UpdateError("git pull ging nicht: \(pull.lastLine). Details in ~/.claude-notch/update.log")
            }
        }
        phase = .working("Baue die App … (dauert meist unter einer Minute)")
        let build = await Shell.run(["./scripts/build-app.sh"], in: dir, timeout: 20 * 60, log: true)
        guard build.ok else {
            throw UpdateError("Bauen ging nicht: \(build.lastLine). Details in ~/.claude-notch/update.log")
        }
        let app = URL(fileURLWithPath: dir).appendingPathComponent("dist/Notchwerk.app")
        try await verify(app)
        return app
    }

    private func downloadRelease() async throws -> URL {
        phase = .working("Lade die neue Version …")
        let rel: Release
        if let release { rel = release } else { rel = try await Release.latest(repository: Self.repository) }
        guard let zipURL = rel.assets["Notchwerk.zip"], let sumURL = rel.assets["Notchwerk.zip.sha256"] else {
            throw UpdateError("Im Release \(rel.tag) fehlt Notchwerk.zip oder die Prüfsumme")
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("notchwerk-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        let (zipTemp, zipResponse) = try await URLSession.shared.download(from: zipURL)
        guard (zipResponse as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Download fehlgeschlagen") }
        let zip = work.appendingPathComponent("Notchwerk.zip")
        try fm.moveItem(at: zipTemp, to: zip)
        let (sumData, sumResponse) = try await URLSession.shared.data(from: sumURL)
        guard (sumResponse as? HTTPURLResponse)?.statusCode == 200,
              let expected = String(data: sumData, encoding: .utf8)?.split(separator: " ").first.map(String.init)?.lowercased(),
              expected.count == 64 else {
            throw UpdateError("Prüfsumme ließ sich nicht laden")
        }

        phase = .working("Prüfe die neue Version …")
        let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw UpdateError("Prüfsumme stimmt nicht, Download verworfen") }
        let unpack = await Shell.run(["/usr/bin/ditto", "-x", "-k", zip.path, work.path], in: nil, timeout: 120)
        guard unpack.ok else { throw UpdateError("Entpacken ging nicht: \(unpack.lastLine)") }
        let app = work.appendingPathComponent("Notchwerk.app")
        try await verify(app)
        return app
    }

    /// Die neue App muss vollständig signiert sein und dieselbe Kennung haben.
    private func verify(_ app: URL) async throws {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("Die neue App ist nicht Notchwerk")
        }
        let check = await Shell.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app.path], in: nil, timeout: 60)
        guard check.ok else { throw UpdateError("Signatur der neuen App ist ungültig: \(check.lastLine)") }
    }

    /// Startet das Austausch-Skript und beendet die App. Das Skript wartet, bis sie weg ist,
    /// ersetzt sie und öffnet die neue. Geht dabei etwas schief, startet es die alte wieder.
    private func installAndRelaunch(_ newApp: URL) throws {
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent) else {
            throw UpdateError("Keine Schreibrechte für \(parent)")
        }
        phase = .working("Starte neu …")
        let script = HookInstaller.dir.appendingPathComponent("update.sh")
        try FileManager.default.createDirectory(at: HookInstaller.dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data(Self.swapScript.utf8).write(to: script, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), newApp.path, target.path]
        process.standardInput = FileHandle.nullDevice
        if let log = Shell.appendHandle(Self.logURL) {
            process.standardOutput = log
            process.standardError = log
        }
        try process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
    }

    static let swapScript = """
    #!/bin/bash
    # Von Notchwerk angelegt: tauscht die App aus, sobald die alte beendet ist, und startet sie neu.
    PID="$1"; NEW="$2"; TARGET="$3"
    for _ in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
    echo "$(date '+%F %T') Ersetze $TARGET durch $NEW"
    STAGE="$TARGET.neu"
    rm -rf "$STAGE" "$TARGET.alt"
    if ! /usr/bin/ditto "$NEW" "$STAGE"; then
      echo "Kopieren ging nicht, alte Version bleibt."; rm -rf "$STAGE"; open "$TARGET"; exit 1
    fi
    if ! mv "$TARGET" "$TARGET.alt"; then
      echo "Alte Version ließ sich nicht verschieben."; rm -rf "$STAGE"; open "$TARGET"; exit 1
    fi
    if ! mv "$STAGE" "$TARGET"; then
      echo "Neue Version ließ sich nicht einsetzen, stelle die alte wieder her."
      mv "$TARGET.alt" "$TARGET"; open "$TARGET"; exit 1
    fi
    rm -rf "$TARGET.alt"
    xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
    open "$TARGET"
    echo "$(date '+%F %T') Fertig."

    """

    struct UpdateError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

// MARK: - GitHub Releases

struct Release {
    let tag: String
    let assets: [String: URL]

    /// „v0.4.0“ → „0.4.0“
    var version: String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }

    static func latest(repository: String) async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Notchwerk", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else {
            throw Updater.UpdateError("Antwort von GitHub unerwartet")
        }
        var assets: [String: URL] = [:]
        for asset in obj["assets"] as? [[String: Any]] ?? [] {
            if let name = asset["name"] as? String, let link = asset["browser_download_url"] as? String,
               let url = URL(string: link), url.scheme == "https" {
                assets[name] = url
            }
        }
        return Release(tag: tag, assets: assets)
    }

    /// Vergleicht Versionen Zahl für Zahl: 0.10.0 ist neuer als 0.9.3.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

// MARK: - Befehle ausführen

enum Shell {
    struct Result {
        let status: Int32
        let output: String
        var ok: Bool { status == 0 }
        var lastLine: String {
            output.split(whereSeparator: \.isNewline).last.map(String.init) ?? "Fehler \(status)"
        }
    }

    /// Wie im Terminal, aber ohne Rückfragen: git fragt nie nach Passwörtern.
    private static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }

    /// Führt einen Befehl abseits des Main-Threads aus. Die Ausgabe landet in einer Datei, damit
    /// lange Ausgaben (Build) nichts blockieren; mit `log` zusätzlich in ~/.claude-notch/update.log.
    static func run(_ arguments: [String], in dir: String?, timeout: TimeInterval = 20, log: Bool = false) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSync(arguments, in: dir, timeout: timeout, log: log))
            }
        }
    }

    nonisolated static func runSync(_ arguments: [String], in dir: String? = nil, timeout: TimeInterval = 20,
                                    log: Bool = false) -> Result {
        let fm = FileManager.default
        let out = fm.temporaryDirectory.appendingPathComponent("notchwerk-\(UUID().uuidString).log")
        guard fm.createFile(atPath: out.path, contents: nil), let handle = try? FileHandle(forWritingTo: out) else {
            return Result(status: -1, output: "Temporäre Datei ließ sich nicht anlegen")
        }
        defer { try? fm.removeItem(at: out) }

        let process = Process()
        if arguments[0].hasPrefix("/") || arguments[0].hasPrefix(".") {
            process.executableURL = URL(fileURLWithPath: arguments[0], relativeTo: dir.map { URL(fileURLWithPath: $0, isDirectory: true) })
            process.arguments = Array(arguments.dropFirst())
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
        }
        if let dir { process.currentDirectoryURL = URL(fileURLWithPath: dir, isDirectory: true) }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: error.localizedDescription)
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 5)
            try? handle.close()
            return Result(status: -1, output: "Abgebrochen nach \(Int(timeout)) Sekunden")
        }
        try? handle.close()
        let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        if log, let logHandle = appendHandle(Updater.logURL) {
            let header = "\n$ \(arguments.joined(separator: " "))\n"
            logHandle.write(Data((header + text).utf8))
            try? logHandle.close()
        }
        return Result(status: process.terminationStatus, output: text)
    }

    /// Datei zum Anhängen öffnen (wird bei Bedarf angelegt, nur für dich lesbar).
    nonisolated static func appendHandle(_ url: URL) -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
