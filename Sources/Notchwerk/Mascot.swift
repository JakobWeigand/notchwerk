import NotchwerkShared
import SwiftUI

/// Das Claude-Maskottchen in Orange, genau wie das Logo. Im Ruhezustand blinzelt es, schaut sich
/// ab und zu um und winkt. Arbeitet Claude, läuft es. Braucht Claude dich, hüpft es und rudert mit
/// den Armen. Ist etwas fertig, freut es sich.
struct Mascot: View {
    enum Mood { case idle, working, attention, happy }

    var mood: Mood = .idle
    var size: CGFloat = 22
    /// Augen als Löcher statt dunkler Felder, wie im Logo. Für die Anzeige ohne Kasten,
    /// bei der das Maskottchen direkt auf dem Schreibtisch sitzt.
    var cutOutEyes = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.frameInterval(mood))) { context in
            let (pose, hop) = Self.pose(mood, at: context.date.timeIntervalSinceReferenceDate)
            Canvas { ctx, canvasSize in
                let rect = CGRect(origin: .zero, size: canvasSize)
                ctx.fill(Path(ClaudeLogo.path(pose, in: rect)), with: .color(Theme.orange))
                guard !cutOutEyes else { return }
                let px = min(canvasSize.width / CGFloat(ClaudeLogo.columns), canvasSize.height / CGFloat(ClaudeLogo.rows))
                let ox = (canvasSize.width - px * CGFloat(ClaudeLogo.columns)) / 2
                let oy = (canvasSize.height - px * CGFloat(ClaudeLogo.rows)) / 2
                for eye in ClaudeLogo.eyeRects(pose) {
                    let r = CGRect(x: ox + eye.minX * px, y: oy + eye.minY * px, width: eye.width * px, height: eye.height * px)
                    ctx.fill(Path(r), with: .color(Theme.ink))
                }
            }
            .offset(y: -hop * size / CGFloat(ClaudeLogo.rows))
        }
        .frame(width: size * ClaudeLogo.aspect, height: size)
        .accessibilityHidden(true)
    }

    static func frameInterval(_ mood: Mood) -> TimeInterval {
        mood == .idle ? 0.1 : 1.0 / 15
    }

    /// Haltung zum Zeitpunkt `t` (Sekunden) und wie hoch das Maskottchen gerade springt (in Feldern).
    /// Auch für das Symbol in der Menüleiste, das aber nicht springt.
    static func pose(_ mood: Mood, at t: TimeInterval) -> (ClaudeLogo.Pose, hop: CGFloat) {
        switch mood {
        case .idle:
            var pose = ClaudeLogo.Pose()
            // Alle 4,7 Sekunden blinzeln, jedes dritte Mal doppelt.
            let blink = t.truncatingRemainder(dividingBy: 4.7)
            let double = Int(t / 4.7) % 3 == 0
            if blink < 0.13 || (double && blink > 0.26 && blink < 0.39) { pose.eyes = .closed }
            // Ab und zu nach links und rechts schauen.
            let look = t.truncatingRemainder(dividingBy: 13)
            if look >= 6.0 && look < 7.2 { pose.look = -0.5 }
            if look >= 7.4 && look < 8.6 { pose.look = 0.5 }
            // Und gelegentlich winken, dabei lächeln.
            let wave = t.truncatingRemainder(dividingBy: 19)
            if wave >= 15.0 && wave < 16.6 {
                pose.rightArm = Int(wave * 6) % 2 == 0 ? 1 : 0
                pose.eyes = .happy
                pose.look = 0
            }
            return (pose, 0)
        case .working:
            // Auf der Stelle laufen: Beine paarweise, Arme gegengleich, bei jedem Schritt ein kleiner Wipper.
            let step = Int(t / 0.16) % 2
            var pose = ClaudeLogo.Pose(leftArm: step == 0 ? 0.5 : 0, rightArm: step == 0 ? 0 : 0.5,
                                       liftedLegs: step == 0 ? [0, 2] : [1, 3])
            if t.truncatingRemainder(dividingBy: 3.9) < 0.12 { pose.eyes = .closed }
            return (pose, step == 0 ? 0 : 0.25)
        case .attention:
            // Hüpfen und abwechselnd mit den Armen winken.
            let k = Int(t / 0.18) % 2
            let pose = ClaudeLogo.Pose(leftArm: k == 0 ? 1 : 0, rightArm: k == 0 ? 0 : 1)
            return (pose, abs(sin(t * 7)) * 1.2)
        case .happy:
            let pose = ClaudeLogo.Pose(eyes: .happy, leftArm: 1, rightArm: 1)
            return (pose, abs(sin(t * 6)) * 0.8)
        }
    }
}

/// Rotierender, pulsierender Funke als Aktivitätsanzeige.
struct SparkSpinner: View {
    var active: Bool = true
    var size: CGFloat = 14
    var color: Color = Theme.orange

    var body: some View {
        if active {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                SparkShape()
                    .fill(color)
                    .rotationEffect(.radians(t * 1.6))
                    .scaleEffect(0.86 + 0.14 * sin(t * 4))
                    .frame(width: size, height: size)
            }
        } else {
            SparkShape()
                .fill(color)
                .frame(width: size, height: size)
        }
    }
}
