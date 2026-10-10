import NotchwerkShared
import SwiftUI
import WidgetKit

/// Die Limits, die ein Widget zeigen kann.
enum LimitSpec: Hashable {
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

/// „neu in 2 Std., 13 Min.“: zählt von selbst herunter, ohne dass das Widget neu laden muss.
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
                Text(prefix) + Text(date, style: .relative)
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
