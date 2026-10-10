import NotchwerkShared
import SwiftUI
import WidgetKit

/// Die Limits, die ein Widget zeigen kann. Codable ist Pflicht: macOS speichert Widgets als
/// archivierte Ansicht, und IDs in ForEach müssen sich dabei sichern lassen. Sonst bleibt das
/// Widget leer („ID type is not Encodable“).
enum LimitSpec: String, Hashable, Codable {
    case session, week, fable

    var kind: LimitKind {
        switch self {
        case .session: return .session
        case .week: return .week
        case .fable: return .fable
        }
    }

    var title: String {
        switch self {
        case .session: return "Sitzung"
        case .week: return "Woche"
        case .fable: return "Fable 5"
        }
    }

    var longTitle: String {
        switch self {
        case .session: return "Sitzungslimit"
        case .week: return "Wochenlimit"
        case .fable: return "Fable-5-Limit"
        }
    }

    /// Wenn die Antwort für ein Konto kein solches Limit enthält.
    var missingText: String {
        switch self {
        case .fable: return "Kein eigenes Fable-Limit"
        default: return "Keine Daten"
        }
    }
}

extension WidgetFeed.Account {
    /// Das Fenster eines Limits zum Zeitpunkt des Eintrags (nach dem Zurücksetzen wieder 0 %).
    func window(_ limit: LimitSpec, at date: Date) -> WidgetFeed.Window? {
        window(limit.kind)?.projected(at: date)
    }

    var problemText: String? {
        guard status != .ok else { return nil }
        if !message.isEmpty { return message }
        switch status {
        case .ok: return nil
        case .loading: return "Wird geladen …"
        case .noCredentials: return "Nicht angemeldet"
        case .expired: return "Anmeldung abgelaufen"
        case .denied: return "Kein Zugriff auf den Schlüsselbund"
        case .failed: return "Gerade nicht verfügbar"
        }
    }
}

// MARK: - Hintergrund

/// Hintergrund im Stil von Claude: warmes Creme im hellen, warmes Fast-Schwarz im dunklen
/// Erscheinungsbild, oben links ein Hauch Orange.
struct WidgetBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            scheme == .dark
                ? Color(red: 0.125, green: 0.122, blue: 0.114)  // #201F1D
                : Color(red: 0.980, green: 0.976, blue: 0.961)  // #FAF9F5
            RadialGradient(colors: [Brand.orange.opacity(scheme == .dark ? 0.16 : 0.10), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 240)
        }
    }
}

extension View {
    /// Ab macOS 14 verlangt WidgetKit containerBackground, sonst zeigt das System einen Hinweis statt des Widgets.
    @ViewBuilder
    func notchwerkWidgetBackground() -> some View {
        if #available(macOS 14.0, *) {
            containerBackground(for: .widget) { WidgetBackdrop() }
        } else {
            padding().background(WidgetBackdrop())
        }
    }
}

// MARK: - Bausteine

/// Kopfzeile: Maskottchen, Titel und rechts optional ein Zusatz (z.B. der Kontoname).
struct WidgetHeader: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(spacing: 5) {
            ClaudeLogoShape()
                .fill(Brand.orange)
                .widgetAccentable()
                .frame(width: 15, height: 12)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Ring wie bei `/usage`: wie viel vom Limit genutzt ist. Ohne Wert ein leerer Ring mit Strich.
struct UsageRing: View {
    let percent: Double?
    var lineWidth: CGFloat = 8
    var labelSize: CGFloat = 20
    var showsLabel = true

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.1), lineWidth: lineWidth)
            if let percent, percent > 0 {
                Circle()
                    .trim(from: 0, to: CGFloat(min(percent, 100) / 100))
                    .stroke(Brand.usageTint(percent), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .widgetAccentable()
            }
            if showsLabel {
                if let percent {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(Int(percent.rounded()))")
                            .font(.system(size: labelSize, weight: .bold, design: .rounded))
                        Text("%")
                            .font(.system(size: labelSize * 0.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, lineWidth)
                } else {
                    Text("–")
                        .font(.system(size: labelSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(lineWidth / 2)
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Waagrechter Balken für die Übersichten.
struct UsageBar: View {
    let percent: Double?
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                if let percent, percent > 0 {
                    Capsule()
                        .fill(Brand.usageTint(percent))
                        .frame(width: max(height, geo.size.width * CGFloat(min(percent, 100) / 100)))
                        .widgetAccentable()
                }
            }
        }
        .frame(height: height)
    }
}

/// Titel, Prozent und Balken in einer Zeile, darunter optional wann es sich zurücksetzt.
struct UsageBarRow: View {
    let title: String
    let window: WidgetFeed.Window?
    let date: Date
    var showsReset = false
    var titleSize: CGFloat = 11

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: titleSize, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if showsReset, let window {
                    ResetText(date: window.resetsAt, now: date)
                        .font(.system(size: titleSize - 1.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(window.map { "\(Int($0.percent.rounded())) %" } ?? "–")
                    .font(.system(size: titleSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            UsageBar(percent: window?.percent)
        }
    }
}

/// „neu in 2:13:45“: zählt jede Sekunde herunter, ohne dass das Widget neu laden muss.
/// Mehr als einen Tag entfernt stehen Wochentag und Uhrzeit da.
struct ResetText: View {
    let date: Date?
    let now: Date
    var prefix = "neu in "

    var body: some View {
        if let date {
            if date <= now {
                Text("gerade zurückgesetzt")
            } else if date.timeIntervalSince(now) < 24 * 3600 {
                Text(prefix) + Text(date, style: .timer)
            } else {
                Text("neu ") + Text(date, format: .dateTime.weekday(.abbreviated).hour().minute())
            }
        } else {
            Text(" ")
        }
    }
}

/// Hinweis, wenn ein Konto gerade keine Zahlen liefert.
struct ProblemNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

/// Wenn die Zahlen schon länger nicht aktualisiert wurden: von wann sie sind.
struct StaleNote: View {
    let updatedAt: Date

    var body: some View {
        Label {
            Text("Stand ") + Text(updatedAt, format: .dateTime.hour().minute())
        } icon: {
            Image(systemName: "clock")
        }
        .font(.system(size: 9.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// Wie frisch die Zahlen sind: „aktualisiert vor 4:12“, zählt jede Sekunde mit. Ist der Stand
/// zu alt, steht stattdessen die Uhrzeit des letzten Abrufs da.
struct FreshnessNote: View {
    let entry: UsageEntry
    let updatedAt: Date

    var body: some View {
        if entry.isStale {
            StaleNote(updatedAt: updatedAt)
        } else {
            HStack(spacing: 4) {
                Circle()
                    .fill(Brand.allow)
                    .frame(width: 5, height: 5)
                (Text("aktualisiert vor ") + Text(updatedAt, style: .timer))
                    .monospacedDigit()
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

/// Noch keine Daten: kurz erklären, wo man die Widgets einschaltet.
struct EmptyFeedView: View {
    var body: some View {
        VStack(spacing: 8) {
            ClaudeLogoShape()
                .fill(Brand.orange)
                .widgetAccentable()
                .frame(width: 40, height: 32)
            Text("Widgets in Notchwerk einschalten")
                .font(.system(size: 12, weight: .semibold))
                .multilineTextAlignment(.center)
            Text("Einstellungen › Widgets")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Ein Konto mit Balken

/// Ein Konto als Abschnitt: der Name als Überschrift, darunter je Limit eine Zeile mit Balken.
/// So stehen mehrere Konten untereinander, z.B. „Privat“ und darunter „Arbeit“.
struct AccountSection: View {
    let account: WidgetFeed.Account
    let limits: [LimitSpec]
    let date: Date
    var style: LimitLine.Style = .compact

    var body: some View {
        VStack(alignment: .leading, spacing: style == .compact ? 3 : 5) {
            HStack(spacing: 6) {
                Text(account.name)
                    .font(.system(size: style == .compact ? 12 : 13.5, weight: .bold))
                    .foregroundStyle(Brand.orange)
                    .widgetAccentable()
                    .lineLimit(1)
                Spacer(minLength: 4)
                // Zahlen vom letzten Abruf, gerade klappt es nicht: nur ein kleines Zeichen.
                if account.problemText != nil, !account.windows.isEmpty {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if let problem = account.problemText, account.windows.isEmpty {
                ProblemNote(text: problem)
            } else {
                ForEach(limits, id: \.self) { limit in
                    LimitLine(limit: limit, window: account.window(limit, at: date), date: date, style: style)
                }
            }
        }
    }
}

/// Eine Zeile: Name des Limits, Balken, Prozent. Je nach Platz mit „neu in …“ daneben oder darunter.
struct LimitLine: View {
    enum Style {
        /// Klein: alles in einer Zeile.
        case compact
        /// Wie compact, nur größer, wo der Platz reicht.
        case comfortable
        /// Mittel: in einer Zeile, rechts wann es neu losgeht.
        case wide
        /// Groß: dickerer Balken, darunter wann es neu losgeht.
        case roomy
    }

    let limit: LimitSpec
    let window: WidgetFeed.Window?
    let date: Date
    var style: Style = .compact

    var body: some View {
        let roomy = style == .roomy
        let big = style != .compact
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(limit.title)
                    .font(.system(size: big ? 11.5 : 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: roomy ? 52 : (big ? 46 : 42), alignment: .leading)
                UsageBar(percent: window?.percent, height: big ? 8.5 : 7)
                Text(window.map { "\(Int($0.percent.rounded())) %" } ?? "–")
                    .font(.system(size: big ? 13 : 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: big ? 38 : 32, alignment: .trailing)
                if style == .wide {
                    reset
                        .frame(width: 92, alignment: .trailing)
                }
            }
            if roomy {
                reset
                    .padding(.leading, 58)
            }
        }
    }

    @ViewBuilder
    private var reset: some View {
        Group {
            if let window {
                ResetText(date: window.resetsAt, now: date)
            } else {
                Text(limit.missingText)
            }
        }
        .font(.system(size: 9.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}
