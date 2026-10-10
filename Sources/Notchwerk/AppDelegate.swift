import AppKit
import Combine
import NotchwerkShared
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = NotchModel.shared
    private let prefs = Preferences.shared
    private var controller: NotchController?
    private var server: EventServer?
    private var statusItem: NSStatusItem?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var iconTimer: Timer?
    private var iconMood: Mascot.Mood?
    private var iconPose: ClaudeLogo.Pose?

    static let claudeBundleIDs: Set<String> = ["com.anthropic.claudefordesktop", "com.anthropic.claude"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        startServer()
        controller = NotchController(model: model, prefs: prefs)
        controller?.start()
        setupStatusItem()
        watchClaudeApp()
        UsageMonitor.shared.start()
        Updater.shared.start()

        if !HookInstaller.isInstalled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                Task { @MainActor in self?.offerHookInstall() }
            }
        } else {
            model.greet()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        HookInstaller.cleanupRuntime()
    }

    /// notchwerk://usage, z.B. nach einem Klick auf ein Widget: die Liste mit der Nutzung aufklappen.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "notchwerk" && $0.host == "usage" }) else { return }
        if prefs.showUsage {
            controller?.showList()
        } else {
            SettingsWindowController.shared.show()
        }
    }

    // MARK: - Server

    private func startServer() {
        let token = Secrets.randomToken()
        let server = EventServer(token: token)
        server.onEvent = { [weak self] json, reply, onClose in
            Task { @MainActor in
                guard let self else { reply(nil); return }
                self.model.handle(event: json, reply: reply, onClose: onClose)
            }
        }
        do {
            try server.start { port in
                HookInstaller.prepareRuntime(port: port, token: token)
            }
            self.server = server
        } catch {
            NSLog("Notchwerk: Server konnte nicht starten: \(error)")
        }
    }

    // MARK: - Claude App

    private func watchClaudeApp() {
        model.claudeAppRunning = NSWorkspace.shared.runningApplications.contains {
            AppDelegate.claudeBundleIDs.contains($0.bundleIdentifier ?? "")
        }

        let ws = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                 object: nil, queue: .main) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier ?? ""
            Task { @MainActor in
                guard let self, AppDelegate.claudeBundleIDs.contains(bundleID) else { return }
                self.model.claudeAppRunning = true
                if self.prefs.greetOnClaudeLaunch { self.model.greet() }
            }
        })
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                 object: nil, queue: .main) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier ?? ""
            Task { @MainActor in
                guard let self, AppDelegate.claudeBundleIDs.contains(bundleID) else { return }
                self.model.claudeAppRunning = false
            }
        })
    }

    // MARK: - Hooks

    private func offerHookInstall() {
        let alert = NSAlert()
        alert.messageText = "Mit Claude Code verbinden?"
        alert.informativeText = """
        Notchwerk trägt dafür einen Hook in ~/.claude/settings.json ein. Vorher wird eine Sicherheitskopie angelegt.

        Alles bleibt lokal auf deinem Mac. Die App lauscht nur auf 127.0.0.1 und prüft bei jeder Nachricht einen geheimen Token.

        Die App startet danach automatisch beim Anmelden. Das lässt sich im Menü jederzeit abschalten.
        """
        alert.addButton(withTitle: "Verbinden")
        alert.addButton(withTitle: "Später")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            installHooks()
        }
    }

    @objc private func installHooks() {
        do {
            try HookInstaller.install()
            // Erst jetzt, mit Zustimmung, als Anmeldeobjekt eintragen.
            try? SMAppService.mainApp.register()
            model.showBanner(Banner(style: .greeting, title: "Mit Claude Code verbunden",
                                    subtitle: "Neue Claude Code Sitzungen melden sich jetzt hier."), duration: 3.5)
        } catch {
            showError(error)
        }
    }

    @objc private func uninstallHooks() {
        do {
            try HookInstaller.uninstall()
            model.showBanner(Banner(style: .info, title: "Verbindung entfernt",
                                    subtitle: "Claude Code meldet sich nicht mehr hier."), duration: 3)
        } catch {
            showError(error)
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Menüleiste

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        item.button?.appearsDisabled = !prefs.enabled
        setMenuBarPose(.logo)
        prefs.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.statusItem?.button?.appearsDisabled = !self.prefs.enabled
                    self.updateMenuBarIcon()
                }
            }
            .store(in: &cancellables)
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateMenuBarIcon() }
            }
            .store(in: &cancellables)
    }

    /// Das Maskottchen in der Menüleiste läuft, solange Claude arbeitet, und winkt, wenn Claude
    /// dich braucht. Sonst steht es still, damit die App im Ruhezustand nicht ständig zeichnet.
    private func updateMenuBarIcon() {
        var mood = Mascot.Mood.idle
        if prefs.enabled && prefs.animateMenuBarIcon {
            if model.needsAttention || model.currentRequest != nil {
                mood = .attention
            } else if model.isWorking {
                mood = .working
            }
        }
        guard mood != iconMood else { return }
        iconMood = mood
        iconTimer?.invalidate()
        iconTimer = nil
        guard mood != .idle else {
            setMenuBarPose(.logo)
            return
        }
        setMenuBarPose(Mascot.pose(mood, at: Date.timeIntervalSinceReferenceDate).0)
        let timer = Timer(timeInterval: Mascot.frameInterval(mood), repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.setMenuBarPose(Mascot.pose(mood, at: Date.timeIntervalSinceReferenceDate).0)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        iconTimer = timer
    }

    private func setMenuBarPose(_ pose: ClaudeLogo.Pose) {
        guard pose != iconPose else { return }
        iconPose = pose
        statusItem?.button?.image = ClaudeLogo.menuBarImage(pose)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "Notchwerk", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let count = model.sessions.count
        let status = NSMenuItem(title: count == 0 ? "Keine aktive Sitzung" : "\(count) aktive Sitzung\(count == 1 ? "" : "en")",
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if prefs.showUsage || prefs.widgetsEnabled {
            let accounts = prefs.accounts
            for account in accounts {
                guard let snap = UsageMonitor.shared.state(for: account).snapshot else { continue }
                let parts = snap.windows.prefix(3).map { "\($0.title) \(Int($0.percent.rounded())) %" }
                let label = accounts.count > 1 ? "\(account.name): " : "Nutzung: "
                let usage = NSMenuItem(title: label + parts.joined(separator: " · "), action: nil, keyEquivalent: "")
                usage.isEnabled = false
                menu.addItem(usage)
            }
        }
        for s in model.activeSessions {
            let text = s.detail.isEmpty ? s.displayName : "\(s.displayName)  ·  \(s.detail)"
            let mi = item(text, #selector(focusSession(_:)))
            mi.representedObject = s.id
            mi.indentationLevel = 1
            mi.toolTip = "Fenster nach vorn holen (\(s.origin.label.isEmpty ? s.cwd : s.origin.label))"
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        menu.addItem(item("Einstellungen …", #selector(openSettings), key: ","))
        menu.addItem(toggle("Anzeige pausieren", !prefs.enabled, #selector(togglePause)))
        menu.addItem(.separator())

        let accounts = prefs.accounts
        let connected = accounts.filter(HookInstaller.isInstalled(in:)).count
        if connected == 0 {
            menu.addItem(item("Mit Claude Code verbinden …", #selector(installHooks)))
        } else {
            let title = connected == accounts.count
                ? "Mit Claude Code verbunden ✓"
                : "Verbunden mit \(connected) von \(accounts.count) Konten"
            menu.addItem(item(title, #selector(noop), enabled: false))
            if connected < accounts.count {
                menu.addItem(item("Alle Konten verbinden", #selector(installHooks)))
            }
            menu.addItem(item("Verbindung entfernen", #selector(uninstallHooks)))
        }
        menu.addItem(item("Demo abspielen", #selector(playDemo), key: "d"))
        let updater = Updater.shared
        switch updater.phase {
        case .checking:
            menu.addItem(item("Sehe nach Updates …", #selector(noop), enabled: false))
        case .working(let text):
            menu.addItem(item("Update: \(text)", #selector(noop), enabled: false))
        case .available(let text):
            menu.addItem(item("Jetzt aktualisieren (\(text))", #selector(runUpdate)))
        default:
            menu.addItem(item("Nach Updates suchen …", #selector(checkForUpdates)))
        }
        menu.addItem(.separator())

        menu.addItem(toggle("Orangener Rand immer sichtbar", prefs.alwaysShowRim, #selector(toggleRim)))
        menu.addItem(toggle("Beim Überfahren aufklappen", prefs.expandOnHover, #selector(toggleHover)))
        menu.addItem(toggle("Arbeitende Sitzungen unter dem Notch zeigen", prefs.showSessionsInNotch, #selector(toggleShowSessions)))
        menu.addItem(toggle("Nutzung (Sitzungs- und Wochenlimit) zeigen", prefs.showUsage, #selector(toggleUsage)))
        menu.addItem(toggle("Widgets mit Nutzung versorgen", prefs.widgetsEnabled, #selector(toggleWidgets)))
        menu.addItem(toggle("Maskottchen in der Menüleiste animieren", prefs.animateMenuBarIcon, #selector(toggleMenuBarAnimation)))

        let rowsItem = NSMenuItem(title: "Zeilen unter dem Notch", action: nil, keyEquivalent: "")
        let rowsMenu = NSMenu()
        for n in 1...3 {
            let mi = toggle("\(n) Zeile\(n == 1 ? "" : "n")", prefs.compactRows == n, #selector(chooseRows(_:)))
            mi.representedObject = n
            rowsMenu.addItem(mi)
        }
        rowsItem.submenu = rowsMenu
        menu.addItem(rowsItem)

        let listItem = NSMenuItem(title: "Größe der Liste", action: nil, keyEquivalent: "")
        let listMenu = NSMenu()
        for size in Preferences.ListSize.allCases {
            let mi = toggle(size.title, prefs.listSize == size, #selector(chooseListSize(_:)))
            mi.representedObject = size.rawValue
            listMenu.addItem(mi)
        }
        listItem.submenu = listMenu
        menu.addItem(listItem)

        let sizeItem = NSMenuItem(title: "Größe des Maskottchens", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for choice in Preferences.mascotSizeChoices {
            let mi = toggle(choice.title, prefs.mascotSize == choice.value, #selector(chooseMascotSize(_:)))
            mi.representedObject = choice.value
            sizeMenu.addItem(mi)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let extItem = NSMenuItem(title: "Abstand unter dem Notch", action: nil, keyEquivalent: "")
        let extMenu = NSMenu()
        for choice in Preferences.extensionChoices {
            let mi = toggle(choice.title, prefs.notchExtension == choice.value, #selector(chooseExtension(_:)))
            mi.representedObject = choice.value
            extMenu.addItem(mi)
        }
        extItem.submenu = extMenu
        menu.addItem(extItem)
        menu.addItem(toggle("Freigaben im Notch beantworten", prefs.answerInNotch, #selector(toggleAnswer)))
        menu.addItem(toggle("Fragen im Notch beantworten (experimentell)", prefs.answerQuestionsInNotch, #selector(toggleQuestions)))
        menu.addItem(toggle("Begrüßung beim Start der Claude App", prefs.greetOnClaudeLaunch, #selector(toggleGreet)))
        menu.addItem(toggle("Töne", prefs.playSounds, #selector(toggleSounds)))

        let screensItem = NSMenuItem(title: "Bildschirme", action: nil, keyEquivalent: "")
        let screensMenu = NSMenu()
        screensMenu.addItem(toggle("Auf allen Bildschirmen zeigen", prefs.showOnAllScreens, #selector(toggleAllScreens)))
        screensMenu.addItem(.separator())
        let caption = NSMenuItem(title: "Ohne Notch (z.B. MacBook zugeklappt):", action: nil, keyEquivalent: "")
        caption.isEnabled = false
        screensMenu.addItem(caption)
        for placement in Preferences.Placement.allCases {
            let mi = toggle(placement.title, prefs.placementWithoutNotch == placement, #selector(choosePlacement(_:)))
            mi.representedObject = placement.rawValue
            screensMenu.addItem(mi)
        }
        screensItem.submenu = screensMenu
        menu.addItem(screensItem)

        let timeoutItem = NSMenuItem(title: "Wartezeit für Freigaben", action: nil, keyEquivalent: "")
        let timeoutMenu = NSMenu()
        for minutes in [1, 2, 5, 10, 30] {
            let mi = toggle("\(minutes) Minute\(minutes == 1 ? "" : "n")", Int(prefs.permissionTimeout) == minutes * 60,
                            #selector(chooseTimeout(_:)))
            mi.representedObject = minutes * 60
            timeoutMenu.addItem(mi)
        }
        timeoutItem.submenu = timeoutMenu
        menu.addItem(timeoutItem)

        menu.addItem(.separator())
        menu.addItem(toggle("Beim Anmelden starten", SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        menu.addItem(item("Ordner ~/.claude-notch öffnen", #selector(openFolder)))
        menu.addItem(.separator())
        menu.addItem(item("Notchwerk beenden", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", enabled: Bool = true) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: key)
        mi.target = self
        mi.isEnabled = enabled
        return mi
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let mi = item(title, action)
        mi.state = on ? .on : .off
        return mi
    }

    @objc private func noop() {}
    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func togglePause() { prefs.enabled.toggle() }
    @objc private func playDemo() { model.runDemo() }
    @objc private func toggleRim() { prefs.alwaysShowRim.toggle() }
    @objc private func toggleHover() { prefs.expandOnHover.toggle() }
    @objc private func toggleAnswer() { prefs.answerInNotch.toggle() }
    @objc private func toggleQuestions() { prefs.answerQuestionsInNotch.toggle() }
    @objc private func toggleGreet() { prefs.greetOnClaudeLaunch.toggle() }
    @objc private func toggleSounds() { prefs.playSounds.toggle() }
    @objc private func toggleAllScreens() { prefs.showOnAllScreens.toggle() }
    @objc private func toggleShowSessions() { prefs.showSessionsInNotch.toggle() }
    @objc private func toggleWidgets() { prefs.widgetsEnabled.toggle() }
    @objc private func toggleMenuBarAnimation() { prefs.animateMenuBarIcon.toggle() }
    @objc private func toggleUsage() {
        prefs.showUsage.toggle()
        if !prefs.showUsage { UsageMonitor.shared.stop() }
    }

    @objc private func focusSession(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String, let session = model.sessions[id] {
            model.focus(session)
        }
    }

    @objc private func chooseListSize(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let size = Preferences.ListSize(rawValue: raw) {
            prefs.listSize = size
        }
    }

    @objc private func chooseMascotSize(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double { prefs.mascotSize = value }
    }

    @objc private func runUpdate() { Updater.shared.update() }

    /// Aus dem Menü: nachsehen und das Ergebnis gleich zeigen, bei einem Update mit „Jetzt aktualisieren“.
    @objc private func checkForUpdates() {
        Updater.shared.check { [weak self] result in
            self?.showUpdateResult(result)
        }
    }

    private func showUpdateResult(_ result: Updater.Phase) {
        let alert = NSAlert()
        switch result {
        case .available(let text):
            alert.messageText = "Update für Notchwerk"
            alert.informativeText = "\(text). Notchwerk wird dafür kurz beendet und startet von selbst neu."
            alert.addButton(withTitle: "Jetzt aktualisieren")
            alert.addButton(withTitle: "Später")
        case .upToDate(let text):
            alert.messageText = "Notchwerk ist aktuell"
            alert.informativeText = text
        case .failed(let text):
            alert.messageText = "Nachsehen ging nicht"
            alert.informativeText = text
        default:
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, case .available = result {
            Updater.shared.update()
        }
    }

    @objc private func chooseRows(_ sender: NSMenuItem) {
        if let n = sender.representedObject as? Int { prefs.compactRows = n }
    }

    @objc private func chooseExtension(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double { prefs.notchExtension = value }
    }

    @objc private func choosePlacement(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let p = Preferences.Placement(rawValue: raw) {
            prefs.placementWithoutNotch = p
        }
    }

    @objc private func chooseTimeout(_ sender: NSMenuItem) {
        if let seconds = sender.representedObject as? Int { prefs.permissionTimeout = Double(seconds) }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showError(error)
        }
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(HookInstaller.dir)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
