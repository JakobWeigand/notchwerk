import AppKit
import Foundation

/// Holt das Fenster nach vorn, in dem eine Sitzung läuft.
enum SessionFocus {
    @MainActor
    static func open(_ session: SessionInfo) {
        let origin = session.origin
        switch origin.host {
        case .claudeApp:
            // Genau diesen Chat öffnen, wenn wir ihn kennen. Sonst wenigstens die App.
            if let link = session.desktop?.deepLink {
                NSWorkspace.shared.open(link)
                return
            }
            activate(origin)

        case .vscode, .cursor:
            // Den Projektordner in der laufenden App öffnen: VS Code holt dann das Fenster
            // nach vorn, in dem dieser Ordner schon offen ist.
            if let bundle = origin.appBundlePath, !session.cwd.isEmpty,
               FileManager.default.fileExists(atPath: session.cwd) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.open([URL(fileURLWithPath: session.cwd)],
                                        withApplicationAt: URL(fileURLWithPath: bundle),
                                        configuration: config) { _, _ in }
                return
            }
            activate(origin)

        case .terminal, .other, .unknown:
            if let tty = origin.tty, selectTerminalTab(appName: origin.appName, tty: tty) { return }
            activate(origin)
        }
    }

    @MainActor
    private static func activate(_ origin: SessionOrigin) {
        if let pid = origin.appPID, let app = NSRunningApplication(processIdentifier: pid) {
            bringToFront(app)
            return
        }
        if let path = origin.appBundlePath {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config) { _, _ in }
        }
    }

    @MainActor
    private static func bringToFront(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: app)
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    /// Terminal.app und iTerm2 kennen das tty jedes Tabs. Darüber finden wir den richtigen Tab.
    /// Beim ersten Mal fragt macOS, ob Notchwerk das Terminal steuern darf.
    private static func selectTerminalTab(appName: String, tty: String) -> Bool {
        // Nur echte Gerätenamen ins Skript lassen, nichts anderes darf in den AppleScript-Text.
        guard tty.range(of: #"^/dev/tty[A-Za-z0-9.]{1,32}$"#, options: .regularExpression) != nil else { return false }
        let source: String
        switch appName.lowercased() {
        case "terminal":
            source = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected tab of w to t
                            set index of w to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """
        case "iterm", "iterm2":
            source = """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                tell w to select
                                tell t to select
                                tell s to select
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
            """
        default:
            return false
        }
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
            if let error { NSLog("Notchwerk: Terminal-Tab nicht gefunden: \(error)") }
            return false
        }
        return result.booleanValue
    }
}
