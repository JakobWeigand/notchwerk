import AppKit
import ServiceManagement
import SwiftUI

/// Das Einstellungsfenster. Erreichbar über das Zahnrad in der aufgeklappten Liste
/// und über „Einstellungen …“ im Menü der Menüleiste.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(prefs: Preferences.shared, model: NotchModel.shared))
            let w = NSWindow(contentViewController: host)
            w.title = "Notchwerk"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 500, height: 700))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var model: NotchModel
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    /// Wird nach Verbinden oder Trennen erhöht, damit der Stand neu aus den settings.json gelesen wird.
    @State private var hookTick = 0
    @State private var errorText: String?

    private let timeouts = [1, 2, 5, 10, 30]

    var body: some View {
        Form {
            Section {
                Toggle("Notchwerk eingeschaltet", isOn: $prefs.enabled)
                Text(prefs.enabled
                     ? "Ausschalten pausiert die Anzeige. Claude Code fragt dann wie gewohnt im Terminal, die Verbindung bleibt bestehen."
                     : "Pausiert. Nichts wird angezeigt, Claude Code fragt wie gewohnt im Terminal.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Anzeige") {
                Picker("Anzeigeart", selection: $prefs.displayMode) {
                    ForEach(Preferences.DisplayMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if prefs.displayMode == .floating {
                    Text("Den Reiter mit gedrückter Maustaste an eine beliebige Stelle ziehen. Er bleibt im Vordergrund und wandert auf jeden Schreibtisch mit. Überfahren öffnet die Liste.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Reiter zurück nach oben rechts") { prefs.floatingPosition = nil }
                } else {
                    Picker("Auf Bildschirmen ohne Notch", selection: $prefs.placementWithoutNotch) {
                        ForEach(Preferences.Placement.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Abstand unter dem Notch", selection: $prefs.notchExtension) {
                        ForEach(Preferences.extensionChoices, id: \.value) { Text($0.title).tag($0.value) }
                    }
                    Toggle("Orangener Rand immer sichtbar", isOn: $prefs.alwaysShowRim)
                }
                Toggle("Auf allen Bildschirmen zeigen", isOn: $prefs.showOnAllScreens)
                if prefs.displayMode == .floating || prefs.placementWithoutNotch == .topRight {
                    LabeledContent("Größe des Maskottchens") {
                        HStack(spacing: 8) {
                            Image(systemName: "a.circle").font(.system(size: 9)).foregroundStyle(.secondary)
                            Slider(value: $prefs.mascotSize, in: Preferences.mascotSizeRange, step: 4)
                                .frame(width: 170)
                            Image(systemName: "a.circle").font(.system(size: 16)).foregroundStyle(.secondary)
                        }
                    }
                    .help("Gilt für das Maskottchen oben rechts und beim schwebenden Reiter.")
                }
                Toggle("Maskottchen in der Menüleiste animieren", isOn: $prefs.animateMenuBarIcon)
            }

            Section("Sitzungen") {
                Toggle("Beim Überfahren aufklappen", isOn: $prefs.expandOnHover)
                Toggle("Arbeitende Sitzungen dauerhaft unter dem Notch zeigen", isOn: $prefs.showSessionsInNotch)
                Picker("Größe der aufgeklappten Liste", selection: $prefs.listSize) {
                    ForEach(Preferences.ListSize.allCases, id: \.self) { size in
                        Text("\(size.title) (\(size.rows) Sitzungen)").tag(size)
                    }
                }
                if prefs.showSessionsInNotch {
                    Picker("Zeilen unter dem Notch", selection: $prefs.compactRows) {
                        ForEach(1...3, id: \.self) { Text("\($0)").tag($0) }
                    }
                }
                Toggle("Nutzung (Sitzungs- und Wochenlimit) zeigen", isOn: $prefs.showUsage)
                Text("Für die Nutzung liest die App den Claude Code Login aus dem Schlüsselbund und fragt nur die Limits bei api.anthropic.com ab, so wie /usage in Claude Code. Das kostet nichts und zählt nicht gegen die Limits. Hinweis: Anthropic sieht den Login-Token laut Nutzungsbedingungen nur für Claude Code und claude.ai vor. Diese reine Lese-Abfrage ist formal eine Grauzone, deshalb ist sie standardmäßig aus und auf eigene Verantwortung.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            AccountsSection(prefs: prefs, hookTick: $hookTick, errorText: $errorText)

            WidgetsSection(prefs: prefs)

            UpdatesSection(prefs: prefs)

            Section("Freigaben und Fragen") {
                Toggle("Freigaben im Notch beantworten", isOn: $prefs.answerInNotch)
                Toggle("Fragen im Notch beantworten (experimentell)", isOn: $prefs.answerQuestionsInNotch)
                Picker("Wartezeit für Freigaben", selection: $prefs.permissionTimeout) {
                    ForEach(timeouts, id: \.self) { minutes in
                        Text("\(minutes) Minute\(minutes == 1 ? "" : "n")").tag(Double(minutes * 60))
                    }
                }
            }

            Section("Sonstiges") {
                Toggle("Begrüßung beim Start der Claude App", isOn: $prefs.greetOnClaudeLaunch)
                Toggle("Töne", isOn: $prefs.playSounds)
                Toggle("Beim Anmelden starten", isOn: Binding(
                    get: { loginEnabled },
                    set: { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            errorText = error.localizedDescription
                        }
                        loginEnabled = SMAppService.mainApp.status == .enabled
                    }))
                connectionRow
                HStack {
                    Button("Demo abspielen") { model.runDemo() }
                    Spacer()
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                        .foregroundStyle(.secondary)
                }
                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
    }

    /// Verbindung mit Claude Code, über alle Konten.
    @ViewBuilder
    private var connectionRow: some View {
        let _ = hookTick
        let total = prefs.accounts.count
        let connected = prefs.accounts.filter(HookInstaller.isInstalled(in:)).count
        HStack {
            if connected == 0 {
                Text("Nicht mit Claude Code verbunden")
            } else if connected == total {
                Text("Mit Claude Code verbunden ✓")
            } else {
                Text("Verbunden mit \(connected) von \(total) Konten")
            }
            Spacer()
            if connected < total {
                Button(connected == 0 ? "Verbinden" : "Alle verbinden") { hookAction { try HookInstaller.install() } }
            }
            if connected > 0 {
                Button("Verbindung entfernen") { hookAction { try HookInstaller.uninstall() } }
            }
        }
    }

    private func hookAction(_ action: () throws -> Void) {
        do {
            try action()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
        hookTick += 1
    }
}

// MARK: - Konten

/// Mehrere Claude Code Konten. Claude Code trennt sie über den Konfigurationsordner
/// (CLAUDE_CONFIG_DIR). Jedes Konto hat seine eigene Anmeldung und seine eigenen Limits.
private struct AccountsSection: View {
    @ObservedObject var prefs: Preferences
    @Binding var hookTick: Int
    @Binding var errorText: String?
    @State private var candidates: [String] = []
    @State private var newName = ""

    var body: some View {
        Section {
            ForEach(prefs.accounts) { account in
                AccountRow(account: account, prefs: prefs, hookTick: $hookTick, errorText: $errorText,
                           onRemove: { remove(account) })
            }
            ForEach(candidates, id: \.self) { dir in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gefunden: \(ClaudeAccount.make(name: "", configDir: dir).displayPath)")
                        Text("Sieht nach einem weiteren Claude Code Konto aus.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Übernehmen") { add(dir: dir, name: ClaudeAccount.suggestedName(forDir: dir)) }
                }
            }
            HStack {
                TextField("Neues Konto", text: $newName, prompt: Text("Name, z.B. Arbeit"))
                    .onSubmit(create)
                Button("Anlegen und anmelden …", action: create)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Button("Vorhandenen Ordner wählen …", action: pickFolder)
                Spacer()
            }
            Text("Claude Code trennt Konten über einen eigenen Ordner. „Anlegen und anmelden“ legt ~/.claude-<name> an, verbindet ihn mit Notchwerk und öffnet ein Terminal, in dem du dich mit dem zweiten Konto anmeldest. Danach startest du es mit dem Befehl, den du hier kopieren kannst. Sitzungen tragen dann den Kontonamen, und die Nutzung erscheint je Konto.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } header: {
            Text("Konten")
        }
        .onAppear(perform: rescan)
    }

    private func rescan() {
        candidates = AccountDiscovery.candidates(excluding: prefs.accounts)
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let dir = AccountDiscovery.suggestedDir(for: name)
        guard let account = add(dir: dir, name: name) else { return }
        do {
            try account.openInTerminal()
        } catch {
            errorText = "Terminal ließ sich nicht öffnen: \(error.localizedDescription)"
        }
        newName = ""
    }

    @discardableResult
    private func add(dir: String, name: String) -> ClaudeAccount? {
        let account = ClaudeAccount.make(name: name, configDir: dir)
        guard !prefs.accounts.contains(where: { $0.configDir == account.configDir }) else {
            errorText = "\(account.displayPath) ist schon eingetragen."
            return nil
        }
        prefs.accounts.append(account)
        // Wer Notchwerk schon mit Claude Code verbunden hat, will das auch für das neue Konto.
        if HookInstaller.isInstalled {
            do {
                try HookInstaller.install(into: account)
                errorText = nil
            } catch {
                errorText = error.localizedDescription
            }
        }
        hookTick += 1
        rescan()
        return account
    }

    private func remove(_ account: ClaudeAccount) {
        guard !account.isDefault else { return }
        // Den Hook nehmen wir mit, sonst meldet sich das Konto weiter.
        if HookInstaller.isInstalled(in: account) {
            do {
                try HookInstaller.uninstall(from: account)
            } catch {
                errorText = error.localizedDescription
                return
            }
        }
        prefs.accounts.removeAll { $0.id == account.id }
        hookTick += 1
        rescan()
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: ClaudeAccount.home)
        panel.message = "Konfigurationsordner des Kontos wählen, z.B. ~/.claude-arbeit"
        panel.prompt = "Übernehmen"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(dir: url.path, name: ClaudeAccount.suggestedName(forDir: url.path))
    }
}

/// Ein Konto: Name (änderbar), Ordner, wer angemeldet ist, Verbindung und Nutzung.
private struct AccountRow: View {
    let account: ClaudeAccount
    @ObservedObject var prefs: Preferences
    @ObservedObject private var monitor = UsageMonitor.shared
    @Binding var hookTick: Int
    @Binding var errorText: String?
    let onRemove: () -> Void

    @State private var draft = ""
    @State private var signedIn: ClaudeAccount.SignedIn?
    @State private var copied = false
    @FocusState private var editing: Bool

    var body: some View {
        let _ = hookTick
        let connected = HookInstaller.isInstalled(in: account)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .focused($editing)
                    .onSubmit(commitName)
                    .onChange(of: editing) { focused in if !focused { commitName() } }
                Spacer()
                if !account.isDefault {
                    Button(role: .destructive, action: onRemove) {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Konto aus Notchwerk entfernen. Der Ordner und die Anmeldung bleiben erhalten.")
                }
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let usage = usageText {
                Text(usage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Label(connected ? "Verbunden" : "Nicht verbunden",
                      systemImage: connected ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(connected ? Color.green : Color.secondary)
                    .font(.caption)
                Button(connected ? "Trennen" : "Verbinden") {
                    do {
                        if connected { try HookInstaller.uninstall(from: account) } else { try HookInstaller.install(into: account) }
                        errorText = nil
                    } catch {
                        errorText = error.localizedDescription
                    }
                    hookTick += 1
                }
                .controlSize(.small)
                Spacer()
                if prefs.widgetsEnabled && prefs.accounts.count > 1 {
                    Toggle("In Widgets", isOn: Binding(
                        get: { account.showInWidgets },
                        set: { on in update { $0.showInWidgets = on } }))
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                }
                if !account.isDefault {
                    Button(copied ? "Kopiert ✓" : "Befehl kopieren") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(account.aliasLine, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    }
                    .controlSize(.small)
                    .help("Kurzbefehl für ~/.zshrc: \(account.aliasLine)")
                }
                Button(signedIn == nil ? "Anmelden …" : "Im Terminal öffnen") {
                    do {
                        try account.openInTerminal()
                    } catch {
                        errorText = "Terminal ließ sich nicht öffnen: \(error.localizedDescription)"
                    }
                }
                .controlSize(.small)
                .help("Startet Claude Code mit diesem Konto in einem neuen Terminal-Fenster.")
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            draft = account.name
            signedIn = account.signedIn()
        }
        .onChange(of: account.name) { draft = $0 }
    }

    private var subtitle: String {
        guard let signedIn else { return "\(account.displayPath) · nicht angemeldet" }
        let who = signedIn.organization.map { "\(signedIn.email) (\($0))" } ?? signedIn.email
        return "\(account.displayPath) · \(who)"
    }

    /// Kurz die Nutzung, wenn sie abgefragt wird.
    private var usageText: String? {
        guard prefs.showUsage || prefs.widgetsEnabled else { return nil }
        let state = monitor.state(for: account)
        if let snap = state.snapshot {
            return snap.windows.prefix(3).map { "\($0.title) \(Int($0.percent.rounded())) %" }.joined(separator: " · ")
        }
        return "Nutzung: \(state.status.text)"
    }

    private func commitName() {
        let name = draft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            draft = account.name
            return
        }
        guard name != account.name else { return }
        update { $0.name = name }
    }

    private func update(_ change: (inout ClaudeAccount) -> Void) {
        guard let i = prefs.accounts.firstIndex(where: { $0.id == account.id }) else { return }
        change(&prefs.accounts[i])
    }
}

// MARK: - Widgets

private struct WidgetsSection: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var monitor = UsageMonitor.shared

    var body: some View {
        Section("Widgets") {
            Toggle("Widgets mit Nutzungsdaten versorgen", isOn: $prefs.widgetsEnabled)
            if prefs.widgetsEnabled {
                Picker("Im Hintergrund aktualisieren", selection: $prefs.widgetRefreshMinutes) {
                    ForEach(Preferences.widgetRefreshChoices, id: \.self) { minutes in
                        Text(minutes == 60 ? "jede Stunde" : "alle \(minutes) Minuten").tag(minutes)
                    }
                }
                HStack {
                    Text(lastUpdate)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Jetzt aktualisieren") { monitor.refreshNow() }
                }
            }
            Text("Auf den Schreibtisch holen: Rechtsklick auf den Schreibtisch › „Widgets bearbeiten …“ › nach „Notchwerk“ suchen. Zur Wahl stehen Sitzungslimit, Wochenlimit, Fable-5-Limit, Übersicht, Übersicht mit Fable 5 und Alle Konten, jeweils in mehreren Größen. Ein Klick auf ein Widget klappt die Liste auf.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Die Widgets selbst haben weder Netz noch Schlüsselbund. Sie lesen nur Prozentwerte und Zeitpunkte, die Notchwerk in ~/.claude-notch/widget ablegt. Für die Abfrage gilt derselbe Hinweis wie bei der Nutzung oben.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var lastUpdate: String {
        let dates = prefs.accounts.compactMap { monitor.state(for: $0).snapshot?.fetchedAt }
        guard let latest = dates.max() else { return "Noch keine Daten" }
        return "Stand \(latest.formatted(date: .omitted, time: .shortened))"
    }
}

// MARK: - Updates

private struct UpdatesSection: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Section("Updates") {
            LabeledContent("Installiert") {
                Text(installed).foregroundStyle(.secondary).textSelection(.enabled)
            }
            LabeledContent("Quelle") {
                switch updater.source {
                case .project(let dir):
                    Text(ClaudeAccount.make(name: "", configDir: dir).displayPath)
                        .foregroundStyle(.secondary)
                        .help("Aktualisieren holt die Änderungen mit git pull und baut die App neu, wie scripts/install.sh.")
                case .releases:
                    Text("GitHub Releases").foregroundStyle(.secondary)
                }
            }
            HStack {
                status
                Spacer()
                Button("Nach Updates suchen") { updater.check() }
                    .disabled(updater.isBusy)
                Button(updateTitle) { updater.update() }
                    .disabled(updater.isBusy || !(updater.isAvailable || isProject))
                    .keyboardShortcut(updater.isAvailable ? .defaultAction : .none)
            }
            Toggle("Einmal am Tag automatisch nachsehen", isOn: Binding(
                get: { prefs.autoCheckUpdates },
                set: { prefs.autoCheckUpdates = $0; updater.configureTimer() }))
            HStack {
                Button(isProject ? "Anderen Projektordner wählen …" : "Projektordner wählen …", action: pickFolder)
                if isProject {
                    Button("GitHub Releases nutzen") { prefs.sourceDir = nil }
                }
                Spacer()
            }
            Text(isProject
                 ? "Aktualisieren holt neue Änderungen von GitHub, baut die App in deinem Projektordner neu (wie scripts/install.sh), ersetzt sie und startet sie neu. Dafür müssen die Command Line Tools installiert sein."
                 : "Aktualisieren lädt die neueste Version von GitHub, prüft Prüfsumme und Signatur, ersetzt die App und startet sie neu. Wer aus dem Quellcode installiert hat, wählt den Projektordner, dann wird von dort gebaut.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var isProject: Bool {
        if case .project = updater.source { return true }
        return false
    }

    private var installed: String {
        if let commit = updater.builtCommit { return "Version \(updater.currentVersion) (\(commit))" }
        return "Version \(updater.currentVersion)"
    }

    private var updateTitle: String {
        if isProject && !updater.isAvailable { return "Neu bauen" }
        return "Jetzt aktualisieren"
    }

    @ViewBuilder
    private var status: some View {
        switch updater.phase {
        case .idle:
            Text(updater.lastCheck == nil ? "Noch nicht nachgesehen" : "").foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Sehe nach …") }
        case .upToDate(let text):
            Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .available(let text):
            Label(text, systemImage: "arrow.down.circle.fill").foregroundStyle(Theme.orange)
        case .working(let text):
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(text) }
        case .failed(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Ordner mit dem Quellcode von Notchwerk wählen (dort, wo scripts/install.sh liegt)"
        panel.prompt = "Wählen"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if Updater.isProject(url.path) {
            prefs.sourceDir = url.path
        } else {
            let alert = NSAlert()
            alert.messageText = "Kein Notchwerk-Projektordner"
            alert.informativeText = "In \(url.path) fehlen .git, Package.swift oder scripts/build-app.sh."
            alert.runModal()
        }
    }
}
