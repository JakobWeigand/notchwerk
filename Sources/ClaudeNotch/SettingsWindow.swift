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
            w.title = "Claude Notch"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 480, height: 620))
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
    @State private var hookInstalled = HookInstaller.isInstalled
    @State private var errorText: String?

    private let timeouts = [1, 2, 5, 10, 30]

    var body: some View {
        Form {
            Section {
                Toggle("Claude Notch eingeschaltet", isOn: $prefs.enabled)
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
            }

            Section("Sitzungen") {
                Toggle("Beim Überfahren aufklappen", isOn: $prefs.expandOnHover)
                Toggle("Arbeitende Sitzungen dauerhaft unter dem Notch zeigen", isOn: $prefs.showSessionsInNotch)
                Picker("Zeilen in der Liste", selection: $prefs.compactRows) {
                    ForEach(1...3, id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("Nutzung (Sitzungs- und Wochenlimit) zeigen", isOn: $prefs.showUsage)
                Text("Für die Nutzung liest die App den Claude Code Login aus dem Schlüsselbund und fragt die Limits bei api.anthropic.com ab, so wie /usage in Claude Code. Das kostet nichts und zählt nicht gegen die Limits.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

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
                HStack {
                    Text(hookInstalled ? "Mit Claude Code verbunden ✓" : "Nicht mit Claude Code verbunden")
                    Spacer()
                    Button(hookInstalled ? "Verbindung entfernen" : "Verbinden") {
                        do {
                            if hookInstalled { try HookInstaller.uninstall() } else { try HookInstaller.install() }
                        } catch {
                            errorText = error.localizedDescription
                        }
                        hookInstalled = HookInstaller.isInstalled
                    }
                }
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
        .frame(width: 480)
    }
}
