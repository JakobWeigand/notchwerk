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

// MARK: - Farben

/// Farben der Widgets, passend zum Erscheinungsbild und zu „Kontrast erhöhen“.
enum Palette {
    /// Orange für Schrift. Im Hellen dunkler, das Markenorange hätte auf Creme nur 3 : 1 Kontrast
    /// (nötig sind 4,5 : 1), so sind es gut 5 : 1. Im Dunklen bleibt es das Markenorange.
    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Brand.orange : Color(red: 0.690, green: 0.290, blue: 0.165)  // #B04A2A
    }

    /// Füllung von Ring und Balken. Im Dunklen wird sie mit steigender Nutzung heller, im Hellen
    /// dunkler. Beides hebt sie stärker hervor, und Hellorange wäre auf Creme kaum zu sehen (2,1 : 1).
    static func usageTint(_ percent: Double, _ scheme: ColorScheme) -> Color {
        guard scheme == .light else { return Brand.usageTint(percent) }
        if percent >= 85 { return Brand.deny }
        if percent >= 60 { return Brand.orangeDeep }
        return Brand.orange
    }

    /// Spur unter Ring und Balken. Mit „Kontrast erhöhen“ deutlich kräftiger.
    static func track(_ contrast: ColorSchemeContrast, base: Double = 0.1) -> Color {
        Color.primary.opacity(contrast == .increased ? 0.3 : base)
    }
}

/// Schrift in Orange, hell und dunkel jeweils gut lesbar.
private struct AccentText: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.foregroundStyle(Palette.accent(scheme))
    }
}

extension View {
    func accentText() -> some View { modifier(AccentText()) }

    /// Ab macOS 14 rollen Prozentzahlen beim Wechsel auf den neuen Wert, wie in Apples eigenen Widgets.
    @ViewBuilder
    func numericTransition(_ value: Double?) -> some View {
        if #available(macOS 14.0, *), let value {
            contentTransition(.numericText(value: value))
        } else {
            self
        }
    }
}

// MARK: - Hintergrund

/// Hintergrund im Stil von Claude: warmes Creme im hellen, warmes Fast-Schwarz im dunklen
/// Erscheinungsbild, oben links ein Hauch Orange.
struct WidgetBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            scheme == .dark
                ? Color(red: 0.125, green: 0.122, blue: 0.114)  // #201F1D
                : Color(red: 0.980, green: 0.976, blue: 0.961)  // #FAF9F5
            // Mit „Kontrast erhöhen“ ein ruhiger, einfarbiger Grund.
            if contrast != .increased {
                RadialGradient(colors: [Brand.orange.opacity(scheme == .dark ? 0.16 : 0.10), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 240)
            }
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
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.track(contrast), lineWidth: lineWidth)
            if let percent, percent > 0 {
                Circle()
                    .trim(from: 0, to: CGFloat(min(percent, 100) / 100))
                    .stroke(Palette.usageTint(percent, scheme), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .widgetAccentable()
            }
            if showsLabel {
                if let percent {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(Int(percent.rounded()))")
                            .font(.system(size: labelSize, weight: .bold, design: .rounded))
                            .numericTransition(percent)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Genutzt")
        .accessibilityValue(percent.map { "\(Int($0.rounded())) Prozent" } ?? "keine Daten")
        .accessibilityHidden(!showsLabel)
    }
}

/// Waagrechter Balken für die Übersichten.
struct UsageBar: View {
    let percent: Double?
    /// Ohne Höhe füllt der Balken den Platz, den man ihm gibt (z.B. mit frame(minHeight:maxHeight:)).
    var height: CGFloat? = 6
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track(contrast))
                if let percent, percent > 0 {
                    Capsule()
                        .fill(Palette.usageTint(percent, scheme))
                        .frame(width: max(geo.size.height, geo.size.width * CGFloat(min(percent, 100) / 100)))
                        .widgetAccentable()
                }
            }
        }
        .frame(height: height)
        // Die Zahl steht immer daneben, VoiceOver liest sie dort.
        .accessibilityHidden(true)
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
                    .numericTransition(window?.percent)
                    .lineLimit(1)
            }
            UsageBar(percent: window?.percent)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Zeiten

/// Restzeit in ganzen Minuten, aufgerundet: Solange das Limit noch nicht frei ist, steht nie „0 Min.“ da.
private func minutesLeft(until date: Date, from now: Date) -> Int {
    max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
}

/// „2 Std. 27 Min.“, unter einer Stunde „27 Min.“. Ohne Sekunden: Das Widget bekommt jede Minute
/// einen neuen Eintrag (siehe UsageProvider), so bleibt die Angabe aktuell.
func durationText(until date: Date, from now: Date) -> String {
    let minutes = minutesLeft(until: date, from: now)
    let h = minutes / 60, m = minutes % 60
    if h == 0 { return "\(m) Min." }
    return m == 0 ? "\(h) Std." : "\(h) Std. \(m) Min."
}

/// Kurz für unter einem Ring: „2:27 h“, unter einer Stunde „27 Min.“.
func shortDurationText(until date: Date, from now: Date) -> String {
    let minutes = minutesLeft(until: date, from: now)
    let h = minutes / 60, m = minutes % 60
    if h == 0 { return "\(m) Min." }
    return "\(h):" + (m < 10 ? "0\(m)" : "\(m)") + " h"
}

/// Seit wann die Zahlen da sind, in ganzen Minuten.
func ageText(since date: Date, now: Date) -> String {
    let minutes = Int(now.timeIntervalSince(date) / 60)
    return minutes < 1 ? "gerade eben" : "vor \(minutes) Min."
}

/// „neu in 2 Std. 27 Min.“. Mehr als einen Tag entfernt stehen Wochentag und Uhrzeit da.
struct ResetText: View {
    let date: Date?
    let now: Date
    var prefix = "neu in "

    var body: some View {
        if let date {
            if date <= now {
                Text("gerade zurückgesetzt")
            } else if date.timeIntervalSince(now) < 24 * 3600 {
                Text(prefix + durationText(until: date, from: now))
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

/// Wie frisch die Zahlen sind: „aktualisiert vor 4 Min.“. Ist der Stand zu alt, steht stattdessen
/// die Uhrzeit des letzten Abrufs da.
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
                Text("aktualisiert " + ageText(since: updatedAt, now: entry.date))
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

/// Ein Konto als Abschnitt: der Name als Überschrift, darunter je Limit eine schlichte Zeile mit
/// dünnem Balken. Mehrere Konten stehen untereinander, z.B. „Privat“ und darunter „Arbeit“.
struct AccountSection: View {
    let account: WidgetFeed.Account
    let limits: [LimitSpec]
    let date: Date
    var style: LimitLine.Style = .compact
    /// Nur wenn die Zahlen veraltet sind: rechts neben dem ersten Namen die Uhrzeit des letzten Abrufs.
    var live: (updatedAt: Date, isStale: Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(account.name)
                    .font(.system(size: style == .roomy ? 13 : 12, weight: .semibold))
                    .accentText()
                    .widgetAccentable()
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let live {
                    LiveBadge(updatedAt: live.updatedAt, isStale: live.isStale)
                } else if account.problemText != nil, !account.windows.isEmpty {
                    // Zahlen vom letzten Abruf, gerade klappt es nicht: nur ein kleines Zeichen.
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 8.5, weight: .semibold))
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

/// Klein und unaufdringlich: grüner Punkt und wie alt die Zahlen sind.
/// Ist der Stand alt, stattdessen eine Uhr und die Uhrzeit des letzten Abrufs.
struct LiveBadge: View {
    let updatedAt: Date
    let isStale: Bool

    var body: some View {
        HStack(spacing: 3) {
            if isStale {
                Image(systemName: "clock")
                Text(updatedAt, format: .dateTime.hour().minute())
            } else {
                (Text("●").font(.system(size: 6)).foregroundColor(Brand.allow) + Text(" ")
                    + Text(ageText(since: updatedAt, now: Date())))
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// Eine Zeile: Name des Limits, dünner Balken, Prozent. Je nach Platz mit „neu in …“ daneben oder darunter.
struct LimitLine: View {
    enum Style {
        /// Klein mit drei Limits: so knapp wie möglich.
        case compact
        /// Klein mit zwei Limits.
        case comfortable
        /// Mittel: rechts wann es neu losgeht.
        case wide
        /// Groß: darunter wann es neu losgeht.
        case roomy
    }

    let limit: LimitSpec
    let window: WidgetFeed.Window?
    let date: Date
    var style: Style = .compact

    private var labelSize: CGFloat { style == .compact ? 9.5 : (style == .roomy ? 11 : 10) }
    private var barHeight: CGFloat { style == .compact ? 4 : (style == .roomy ? 6 : 5) }
    private var percentSize: CGFloat { style == .compact ? 10.5 : (style == .roomy ? 13 : 11.5) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(limit.title)
                    .font(.system(size: labelSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: style == .roomy ? 50 : 40, alignment: .leading)
                UsageBar(percent: window?.percent, height: barHeight)
                Text(window.map { "\(Int($0.percent.rounded())) %" } ?? "–")
                    .font(.system(size: percentSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .numericTransition(window?.percent)
                    .lineLimit(1)
                    .frame(width: style == .roomy ? 40 : 32, alignment: .trailing)
                if style == .wide {
                    reset
                        .frame(width: 86, alignment: .trailing)
                }
            }
            if style == .roomy {
                reset
                    .padding(.leading, 56)
            }
        }
        .accessibilityElement(children: .combine)
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
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

// MARK: - Ringe wie im Batterie-Widget

extension LimitSpec {
    /// Symbol in der Mitte des Rings: Uhr für die 5 Stunden, Kalender für die Woche.
    var symbol: String {
        switch self {
        case .session: return "clock"
        case .week: return "calendar"
        case .fable: return "sparkles"
        }
    }
}

/// Ein Limit als Ring im Stil des Batterie-Widgets von Apple: Wie viel genutzt ist, zeigt der Ring,
/// in der Mitte steht nur das Symbol.
struct LimitRing: View {
    let limit: LimitSpec
    let window: WidgetFeed.Window?
    let diameter: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let line = max(3, diameter * 0.09)
        ZStack {
            Circle()
                .stroke(Palette.track(contrast, base: 0.12), lineWidth: line)
            if let percent = window?.percent, percent > 0 {
                Circle()
                    .trim(from: 0, to: CGFloat(min(percent, 100) / 100))
                    .stroke(Palette.usageTint(percent, scheme), style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .widgetAccentable()
            }
            Image(systemName: limit.symbol)
                .font(.system(size: diameter * 0.36, weight: .medium))
                .foregroundStyle(window == nil ? .secondary : .primary)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(limit.longTitle)
        .accessibilityValue(window.map { "\(Int($0.percent.rounded())) Prozent genutzt" } ?? "keine Daten")
        .help(limit.longTitle)
    }
}

/// Unter einem Ring: wann das Limit wieder frei ist, kurz („2:12 h“, mehr als einen Tag entfernt „Di. 10:13“).
struct ResetShort: View {
    let window: WidgetFeed.Window?
    let date: Date

    var body: some View {
        Group {
            if let reset = window?.resetsAt {
                if reset <= date {
                    Text("frei")
                } else if reset.timeIntervalSince(date) < 24 * 3600 {
                    Text(shortDurationText(until: reset, from: date))
                } else {
                    Text(reset, format: .dateTime.weekday(.abbreviated).hour().minute())
                }
            } else {
                Text(" ")
            }
        }
        .font(.system(size: 8.5))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .multilineTextAlignment(.center)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

/// Ein Konto: Überschrift (bei mehreren Konten der Name, sonst „Claude“) mittig über den Ringen.
/// Die Ringe werden so groß, wie der Platz erlaubt, höchstens `maxDiameter`. Name und Ringe bleiben
/// als Block zusammen und stehen mittig im verfügbaren Platz.
struct AccountRings: View {
    let title: String
    let account: WidgetFeed.Account
    let limits: [LimitSpec]
    let date: Date
    var maxDiameter: CGFloat = 64
    var showsReset = false
    var live: (updatedAt: Date, isStale: Bool)?

    /// Höhe der Überschrift samt Abstand, Höhe der Zeile „neu in …“ darunter.
    private let titleHeight: CGFloat = 18
    private let resetHeight: CGFloat = 14
    private var gap: CGFloat { limits.count > 2 ? 6 : 10 }

    var body: some View {
        GeometryReader { geo in
            let count = CGFloat(max(1, limits.count))
            let column = (geo.size.width - gap * (count - 1)) / count
            let height = geo.size.height - titleHeight - (showsReset ? resetHeight : 0)
            let diameter = max(16, min(column, height, maxDiameter))
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .accentText()
                    .widgetAccentable()
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .trailing) {
                        if let live {
                            LiveBadge(updatedAt: live.updatedAt, isStale: live.isStale)
                        }
                    }
                if let problem = account.problemText, account.windows.isEmpty {
                    ProblemNote(text: problem)
                        .frame(height: diameter)
                } else {
                    HStack(spacing: gap) {
                        ForEach(limits, id: \.self) { limit in
                            let window = account.window(limit, at: date)
                            VStack(spacing: 3) {
                                LimitRing(limit: limit, window: window, diameter: diameter)
                                if showsReset { ResetShort(window: window, date: date) }
                            }
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
