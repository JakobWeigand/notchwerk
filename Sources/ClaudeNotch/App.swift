import AppKit

@main
enum ClaudeNotchApp {
    @MainActor private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // kein Dock-Symbol, nur Menüleiste und Notch
        app.run()
    }
}
