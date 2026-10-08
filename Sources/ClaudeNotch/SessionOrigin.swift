import AppKit
import Foundation

/// Woher eine Claude Code Sitzung kommt: Terminal, VS Code, Claude App …
/// Ermittelt aus der Prozesskette, die hook.sh bei jedem Ereignis mitschickt
/// (eine Zeile pro Prozess, von innen nach außen: "pid<TAB>tty<TAB>programm").
struct SessionOrigin: Equatable {
    enum Host: Equatable {
        case claudeApp   // Code-Tab der Claude Desktop App
        case vscode      // Visual Studio Code (Erweiterung oder Terminal darin)
        case cursor      // Cursor, Windsurf und andere VS-Code-Ableger
        case terminal    // Terminal.app, iTerm2, Warp, ghostty …
        case other       // irgendeine andere App
        case unknown     // keine App gefunden (z.B. tmux, SSH)
    }

    var host: Host = .unknown
    /// Anzeigename der App, z.B. "VS Code", "Terminal", "Claude App".
    var appName: String = ""
    /// Pfad zum .app-Bundle der Host-App.
    var appBundlePath: String?
    /// PID des Hauptprozesses der Host-App, zum Nach-vorn-Holen.
    var appPID: pid_t?
    /// Terminal-Gerät der Sitzung, z.B. "/dev/ttys003". Damit findet man den richtigen Tab.
    var tty: String?
    /// PID des Claude Code Prozesses selbst. Ist er weg, ist die Sitzung weg.
    var cliPID: pid_t?

    static let unknown = SessionOrigin()

    /// Kurzer Name fürs Abzeichen in der Liste.
    var label: String {
        if host == .unknown { return tty == nil ? "" : "Terminal" }
        return appName
    }

    static func parse(_ text: String) -> SessionOrigin {
        struct Entry {
            let pid: pid_t
            let tty: String
            let comm: String
        }
        var entries: [Entry] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3,
                  let pid = pid_t(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            entries.append(Entry(pid: pid,
                                 tty: parts[1].trimmingCharacters(in: .whitespaces),
                                 comm: parts[2].trimmingCharacters(in: .whitespaces)))
        }

        var origin = SessionOrigin()
        let shells: Set<String> = ["sh", "bash", "zsh", "-sh", "-bash", "-zsh", "fish", "login", "dash"]
        origin.cliPID = entries.first(where: { !shells.contains(($0.comm as NSString).lastPathComponent) })?.pid
        if let tty = entries.first(where: { $0.tty != "??" && !$0.tty.isEmpty })?.tty {
            origin.tty = tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
        }

        // Host-App: das erste Glied, das in einem .app-Bundle liegt. Die Claude Code CLI selbst
        // steckt auch in einem "claude.app"-Bundle und wird übersprungen.
        guard let idx = entries.firstIndex(where: { isHostApp($0.comm) }) else { return origin }
        let bundlePath = outermostBundle(entries[idx].comm)
        let bundleName = ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        origin.appBundlePath = bundlePath
        origin.appName = displayName(bundleName)
        origin.host = host(for: bundleName)
        // Hauptprozess der App: das äußerste Glied im selben Bundle (Helfer liegen weiter innen).
        origin.appPID = entries[idx...].last(where: { $0.comm.hasPrefix(bundlePath) })?.pid ?? entries[idx].pid
        return origin
    }

    private static func isHostApp(_ comm: String) -> Bool {
        guard comm.contains(".app/") else { return false }
        if comm.contains("/claude-code/") { return false }
        if comm.hasSuffix("/MacOS/claude") { return false }
        return true
    }

    private static func outermostBundle(_ path: String) -> String {
        guard let range = path.range(of: ".app/") else { return path }
        return String(path[..<range.lowerBound]) + ".app"
    }

    private static func host(for name: String) -> Host {
        let n = name.lowercased()
        if n == "claude" { return .claudeApp }
        if n.contains("visual studio code") || n == "code" || n.contains("vscodium") { return .vscode }
        if n.contains("cursor") || n.contains("windsurf") || n.contains("trae") { return .cursor }
        let terminals = ["terminal", "iterm", "warp", "ghostty", "kitty", "alacritty", "wezterm", "hyper", "tabby", "rio"]
        if terminals.contains(where: { n.contains($0) }) { return .terminal }
        return .other
    }

    private static func displayName(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("visual studio code") { return "VS Code" }
        if n == "claude" { return "Claude App" }
        if n.hasPrefix("iterm") { return "iTerm" }
        return name
    }
}
