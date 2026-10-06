import SwiftUI

/// Kleines Pixel-Maskottchen in Orange. Läuft wenn Claude arbeitet,
/// hüpft wenn eine Antwort gebraucht wird und blinzelt im Ruhezustand.
struct Mascot: View {
    enum Mood { case idle, working, attention, happy }

    var mood: Mood = .idle
    var size: CGFloat = 22

    // . = leer, X = Körper, E = Auge, L/R = Beine (wechseln beim Laufen)
    private static let sprite: [String] = [
        "...XXXXXX...",
        "..XXXXXXXX..",
        "XXXEXXXXEXXX",
        "XXXEXXXXEXXX",
        "..XXXXXXXX..",
        "..XXXXXXXX..",
        "..L.R..L.R..",
    ]
    private static let happyEyes: [String] = [
        "...XXXXXX...",
        "..XXXXXXXX..",
        "XXEXEXXEXEXX",
        "XXXXXXXXXXXX",
        "..XXXXXXXX..",
        "..XXXXXXXX..",
        "..L.R..L.R..",
    ]

    var body: some View {
        TimelineView(.periodic(from: .now, by: mood == .idle ? 0.25 : 0.14)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let frame = Int(t / (mood == .idle ? 0.25 : 0.14))
            Canvas { ctx, canvasSize in
                let rows = mood == .happy ? Self.happyEyes : Self.sprite
                let cols = rows[0].count
                let px = min(canvasSize.width / CGFloat(cols), canvasSize.height / CGFloat(rows.count))
                let ox = (canvasSize.width - px * CGFloat(cols)) / 2
                var oy = (canvasSize.height - px * CGFloat(rows.count)) / 2
                if mood == .attention { oy -= abs(sin(t * 7)) * px * 1.2 }
                if mood == .working { oy -= (frame % 2 == 0 ? 0 : px * 0.35) }
                let blink = mood == .idle && frame % 17 == 0
                let walkPhase = mood == .working ? frame % 2 : 0

                for (y, row) in rows.enumerated() {
                    for (x, ch) in row.enumerated() {
                        var color: Color?
                        switch ch {
                        case "X": color = Theme.orange
                        case "E": color = blink ? Theme.orange : Theme.ink
                        case "L": color = walkPhase == 0 ? Theme.orange : nil
                        case "R": color = walkPhase == 1 || mood != .working ? Theme.orange : nil
                        default: color = nil
                        }
                        guard let c = color else { continue }
                        let rect = CGRect(x: ox + CGFloat(x) * px, y: oy + CGFloat(y) * px,
                                          width: px + 0.3, height: px + 0.3)
                        ctx.fill(Path(rect), with: .color(c))
                    }
                }
            }
        }
        .frame(width: size * 12 / 7, height: size)
        .accessibilityHidden(true)
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
