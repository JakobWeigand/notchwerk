import AppKit
import Combine
import IOKit.pwr_mgt

/// Hält den Mac wach, so wie `caffeinate -i`: Er schläft nicht ein, solange Claude arbeitet
/// (oder dauerhaft, je nach Einstellung). Der Bildschirm darf trotzdem ausgehen und sperrt sich
/// wie gewohnt. Nur wenn in den erweiterten Einstellungen „Bildschirm anlassen“ an ist, bleibt
/// auch er an. Wer gerade wach hält, steht für jeden sichtbar in `pmset -g assertions`.
///
/// Zugeklappt und ohne externen Bildschirm schläft ein MacBook trotzdem ein, das kann eine App
/// ohne Administratorrechte nicht verhindern.
@MainActor
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    /// Hält den Mac gerade wach.
    @Published private(set) var active = false
    /// Hält gerade auch den Bildschirm an.
    @Published private(set) var displayActive = false

    private let prefs = Preferences.shared
    private let model = NotchModel.shared
    private var systemAssertion: IOPMAssertionID?
    private var displayAssertion: IOPMAssertionID?
    /// Nach dem Ende der Arbeit noch kurz wach bleiben, damit eine kurze Pause zwischen zwei
    /// Schritten den Mac nicht gleich schlafen lässt.
    private var lingerUntil: Date?
    private var lingerCheck: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    private var started = false

    private static let linger: TimeInterval = 120

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        // objectWillChange kommt vor der Änderung, also erst danach auswerten.
        let changed: () -> Void = { [weak self] in DispatchQueue.main.async { self?.update() } }
        prefs.objectWillChange.sink { _ in changed() }.store(in: &cancellables)
        model.objectWillChange.sink { _ in changed() }.store(in: &cancellables)
        FollowUps.shared.objectWillChange.sink { _ in changed() }.store(in: &cancellables)
        // Limits und geplante Nachrichten verfallen mit der Zeit, ohne dass sich sonst etwas ändert.
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        update()
    }

    func stop() {
        setSystem(false)
        setDisplay(false)
    }

    /// Gibt es gerade etwas zu tun, für das der Mac wach bleiben soll?
    private var busy: Bool {
        model.isWorking || model.hasLimitWait || FollowUps.shared.hasScheduled
    }

    private func update() {
        let want: Bool
        switch prefs.keepAwake {
        case .off:
            want = false
            lingerUntil = nil
        case .always:
            want = true
        case .whileWorking:
            if busy {
                lingerUntil = Date().addingTimeInterval(Self.linger)
                want = true
            } else if let until = lingerUntil, until > Date() {
                want = true
                scheduleLingerCheck(at: until)
            } else {
                lingerUntil = nil
                want = false
            }
        }
        setSystem(want)
        setDisplay(want && prefs.keepDisplayAwake)
    }

    private func scheduleLingerCheck(at date: Date) {
        lingerCheck?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.update() }
        lingerCheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, date.timeIntervalSinceNow + 0.5), execute: item)
    }

    private func setSystem(_ on: Bool) {
        systemAssertion = toggle(systemAssertion, on: on, type: "PreventUserIdleSystemSleep",
                                 reason: "Notchwerk hält den Mac wach, solange Claude Code arbeitet")
        active = systemAssertion != nil
    }

    private func setDisplay(_ on: Bool) {
        displayAssertion = toggle(displayAssertion, on: on, type: "PreventUserIdleDisplaySleep",
                                  reason: "Notchwerk lässt den Bildschirm an (erweiterte Einstellung)")
        displayActive = displayAssertion != nil
    }

    /// Legt eine Assertion an oder gibt sie frei. Gibt die aktuelle ID zurück (nil = keine).
    private func toggle(_ current: IOPMAssertionID?, on: Bool, type: String, reason: String) -> IOPMAssertionID? {
        if on {
            if let current { return current }
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     reason as CFString, &id)
            if result != kIOReturnSuccess {
                NSLog("Notchwerk: Wachhalten ging nicht (\(result))")
                return nil
            }
            return id
        }
        if let current { IOPMAssertionRelease(current) }
        return nil
    }
}
