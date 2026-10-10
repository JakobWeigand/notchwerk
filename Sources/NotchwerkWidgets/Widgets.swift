import NotchwerkShared
import SwiftUI
import WidgetKit

/// Alle Widgets von Notchwerk. Jedes erscheint einzeln in der Widget-Galerie von macOS.
@main
struct NotchwerkWidgets: WidgetBundle {
    var body: some Widget {
        SessionLimitWidget()
        WeekLimitWidget()
        FableLimitWidget()
        OverviewWidget()
        OverviewFableWidget()
        AccountsWidget()
    }
}

/// Klick auf ein Widget öffnet in Notchwerk die Liste mit der Nutzung.
let usageURL = URL(string: "notchwerk://usage")

// MARK: - Die Widgets

struct SessionLimitWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "session", provider: UsageProvider()) { entry in
            SingleLimitView(entry: entry, limit: .session)
        }
        .configurationDisplayName("Sitzungslimit")
        .description("Wie viel vom 5-Stunden-Limit genutzt ist und wann es sich zurücksetzt.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct WeekLimitWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "week", provider: UsageProvider()) { entry in
            SingleLimitView(entry: entry, limit: .week)
        }
        .configurationDisplayName("Wochenlimit")
        .description("Das Wochenlimit über alle Modelle.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct FableLimitWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fable", provider: UsageProvider()) { entry in
            SingleLimitView(entry: entry, limit: .fable)
        }
        .configurationDisplayName("Fable-5-Limit")
        .description("Das eigene Wochenlimit für Fable 5.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "overview", provider: UsageProvider()) { entry in
            OverviewView(entry: entry, limits: [.session, .week])
        }
        .configurationDisplayName("Übersicht")
        .description("Sitzungs- und Wochenlimit auf einen Blick.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct OverviewFableWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "overviewFable", provider: UsageProvider()) { entry in
            OverviewView(entry: entry, limits: [.session, .week, .fable])
        }
        .configurationDisplayName("Übersicht mit Fable 5")
        .description("Sitzung, Woche und Fable 5 zusammen.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct AccountsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "accounts", provider: UsageProvider()) { entry in
            AccountsView(entry: entry)
        }
        .configurationDisplayName("Alle Konten")
        .description("Deine Claude-Konten nebeneinander, mit allen Limits.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

// MARK: - Gemeinsamer Rahmen

/// Hintergrund, Klickziel und der Zustand „noch keine Daten“ für alle Widgets.
struct WidgetFrame<Content: View>: View {
    let entry: UsageEntry
    @ViewBuilder let content: (WidgetFeed) -> Content

    var body: some View {
        Group {
            if let feed = entry.feed, !feed.accounts.isEmpty {
                content(feed)
            } else {
                EmptyFeedView()
            }
        }
        .environment(\.locale, Locale(identifier: "de_DE"))
        .notchwerkWidgetBackground()
        .widgetURL(usageURL)
    }
}

// MARK: - Ein Limit

/// Ein Limit (Sitzung, Woche oder Fable 5). Bei einem Konto ein großer Ring, sonst ein Ring je Konto.
struct SingleLimitView: View {
    let entry: UsageEntry
    let limit: LimitSpec
    @Environment(\.widgetFamily) private var family

    var body: some View {
        WidgetFrame(entry: entry) { feed in
            let accounts = Array(feed.accounts.prefix(family == .systemSmall ? 2 : 3))
            if accounts.count == 1 {
                if family == .systemSmall {
                    small(accounts[0], feed: feed)
                } else {
                    medium(accounts[0], feed: feed)
                }
            } else {
                several(accounts, feed: feed)
            }
        }
    }

    private func small(_ account: WidgetFeed.Account, feed: WidgetFeed) -> some View {
        let window = account.window(limit, at: entry.date)
        return VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(title: limit.title)
            UsageRing(percent: window?.percent, lineWidth: 9, labelSize: 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer(account, window: window, feed: feed)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
    }

    private func medium(_ account: WidgetFeed.Account, feed: WidgetFeed) -> some View {
        let window = account.window(limit, at: entry.date)
        return HStack(spacing: 16) {
            UsageRing(percent: window?.percent, lineWidth: 11, labelSize: 28)
            VStack(alignment: .leading, spacing: 3) {
                WidgetHeader(title: limit.longTitle)
                Spacer(minLength: 2)
                if let window {
                    Text("\(window.remainingPercent) % frei")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("\(Int(window.percent.rounded())) % genutzt")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 2)
                    ResetText(date: window.resetsAt, now: entry.date)
                        .font(.system(size: 11, weight: .medium))
                    if let reset = window.resetsAt, reset > entry.date {
                        Text(reset, format: .dateTime.weekday(.wide).hour().minute())
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(account.problemText ?? limit.missingText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 2)
                }
                if entry.isStale { StaleNote(updatedAt: feed.updatedAt) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func footer(_ account: WidgetFeed.Account, window: WidgetFeed.Window?, feed: WidgetFeed) -> some View {
        if let window {
            VStack(spacing: 1) {
                Text("noch \(window.remainingPercent) % frei")
                    .font(.system(size: 10.5, weight: .semibold))
                ResetText(date: window.resetsAt, now: entry.date)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        } else {
            Text(account.problemText ?? limit.missingText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        if entry.isStale { StaleNote(updatedAt: feed.updatedAt) }
    }

    /// Mehrere Konten: Ringe nebeneinander, darunter der Name.
    private func several(_ accounts: [WidgetFeed.Account], feed: WidgetFeed) -> some View {
        let small = family == .systemSmall
        return VStack(alignment: .leading, spacing: small ? 6 : 8) {
            WidgetHeader(title: small ? limit.title : limit.longTitle)
            HStack(alignment: .top, spacing: small ? 8 : 14) {
                ForEach(accounts) { account in
                    let window = account.window(limit, at: entry.date)
                    VStack(spacing: 4) {
                        UsageRing(percent: window?.percent, lineWidth: small ? 6 : 8, labelSize: small ? 14 : 18)
                        Text(account.name)
                            .font(.system(size: small ? 9.5 : 11, weight: .semibold))
                            .lineLimit(1)
                        if !small {
                            Group {
                                if let window {
                                    ResetText(date: window.resetsAt, now: entry.date)
                                } else {
                                    Text(account.problemText ?? limit.missingText)
                                }
                            }
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            if entry.isStale { StaleNote(updatedAt: feed.updatedAt) }
        }
    }
}

// MARK: - Übersicht

/// Mehrere Limits auf einen Blick. Klein: Balken für das erste Konto. Mittel: Ringe (ein Konto)
/// oder Balken je Konto. Groß: je Konto ein Abschnitt.
struct OverviewView: View {
    let entry: UsageEntry
    let limits: [LimitSpec]
    @Environment(\.widgetFamily) private var family

    var body: some View {
        WidgetFrame(entry: entry) { feed in
            switch family {
            case .systemSmall: small(feed)
            case .systemLarge: large(feed)
            default: medium(feed)
            }
        }
    }

    private func small(_ feed: WidgetFeed) -> some View {
        let account = feed.accounts[0]
        return VStack(alignment: .leading, spacing: limits.count > 2 ? 6 : 9) {
            WidgetHeader(title: feed.accounts.count > 1 ? account.name : "Claude")
            Spacer(minLength: 0)
            if let problem = account.problemText, account.windows.isEmpty {
                ProblemNote(text: problem)
            } else {
                ForEach(limits, id: \.self) { limit in
                    UsageBarRow(title: limit.title, window: account.window(limit, at: entry.date), date: entry.date)
                }
            }
            Spacer(minLength: 0)
            if entry.isStale {
                StaleNote(updatedAt: feed.updatedAt)
            } else if let session = account.window(.session, at: entry.date) {
                ResetText(date: session.resetsAt, now: entry.date, prefix: "Sitzung neu in ")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func medium(_ feed: WidgetFeed) -> some View {
        if feed.accounts.count == 1 {
            let account = feed.accounts[0]
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "Claude Nutzung", detail: entry.isStale ? nil : account.problemText)
                HStack(alignment: .top, spacing: 12) {
                    ForEach(limits, id: \.self) { limit in
                        ringColumn(limit, account: account)
                    }
                }
                .frame(maxHeight: .infinity)
                if entry.isStale { StaleNote(updatedAt: feed.updatedAt) }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "Claude Nutzung")
                ForEach(feed.accounts.prefix(2)) { account in
                    accountBars(account, nameWidth: 62)
                }
                Spacer(minLength: 0)
                if entry.isStale { StaleNote(updatedAt: feed.updatedAt) }
            }
        }
    }

    @ViewBuilder
    private func large(_ feed: WidgetFeed) -> some View {
        if feed.accounts.count == 1 {
            let account = feed.accounts[0]
            VStack(alignment: .leading, spacing: 12) {
                WidgetHeader(title: "Claude Nutzung", detail: account.problemText)
                HStack(alignment: .top, spacing: 14) {
                    ForEach(limits, id: \.self) { limit in
                        ringColumn(limit, account: account, large: true)
                    }
                }
                Divider()
                VStack(spacing: 10) {
                    ForEach(limits, id: \.self) { limit in
                        UsageBarRow(title: limit.longTitle, window: account.window(limit, at: entry.date),
                                    date: entry.date, showsReset: true, titleSize: 12)
                    }
                }
                Spacer(minLength: 0)
                if entry.isStale { StaleNote(updatedAt: feed.updatedAt) }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                WidgetHeader(title: "Claude Nutzung")
                ForEach(feed.accounts.prefix(3)) { account in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(account.name)
                                .font(.system(size: 12, weight: .bold))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if let problem = account.problemText {
                                Text(problem)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        ForEach(limits, id: \.self) { limit in
                            UsageBarRow(title: limit.title, window: account.window(limit, at: entry.date),
                                        date: entry.date, showsReset: true)
                        }
                    }
                }
                Spacer(minLength: 0)
                if entry.isStale { StaleNote(updatedAt: feed.updatedAt) }
            }
        }
    }

    private func ringColumn(_ limit: LimitSpec, account: WidgetFeed.Account, large: Bool = false) -> some View {
        let window = account.window(limit, at: entry.date)
        return VStack(spacing: 4) {
            UsageRing(percent: window?.percent, lineWidth: large ? 10 : 8, labelSize: large ? 22 : 17)
            Text(limit.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            Group {
                if let window {
                    ResetText(date: window.resetsAt, now: entry.date)
                } else {
                    Text(limit.missingText)
                }
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    /// Ein Konto als Zeile: Name links, daneben je Limit ein kleiner Balken.
    private func accountBars(_ account: WidgetFeed.Account, nameWidth: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(account.name)
                .font(.system(size: 11, weight: .bold))
                .lineLimit(1)
                .frame(width: nameWidth, alignment: .leading)
            if let problem = account.problemText, account.windows.isEmpty {
                ProblemNote(text: problem)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(limits, id: \.self) { limit in
                    UsageBarRow(title: limit.title, window: account.window(limit, at: entry.date),
                                date: entry.date, titleSize: 10)
                }
            }
        }
    }
}

// MARK: - Alle Konten

/// Tabelle: je Konto eine Zeile, je Limit eine Spalte.
struct AccountsView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        WidgetFrame(entry: entry) { feed in
            let large = family == .systemLarge
            let accounts = Array(feed.accounts.prefix(large ? 6 : 3))
            let limits: [LimitSpec] = accounts.contains { $0.window(.fable) != nil }
                ? [.session, .week, .fable] : [.session, .week]
            VStack(alignment: .leading, spacing: large ? 12 : 8) {
                WidgetHeader(title: "Alle Konten", detail: "\(feed.accounts.count) Konto\(feed.accounts.count == 1 ? "" : "en")")
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: large ? 12 : 7) {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        ForEach(limits, id: \.self) { limit in
                            Text(limit.title)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(accounts) { account in
                        GridRow(alignment: .center) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.name)
                                    .font(.system(size: 11.5, weight: .bold))
                                    .lineLimit(1)
                                if let problem = account.problemText {
                                    Text(problem)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            ForEach(limits, id: \.self) { limit in
                                cell(account.window(limit, at: entry.date), showsReset: large)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                if entry.isStale { StaleNote(updatedAt: feed.updatedAt) }
            }
        }
    }

    private func cell(_ window: WidgetFeed.Window?, showsReset: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                UsageRing(percent: window?.percent, lineWidth: 3.5, showsLabel: false)
                    .frame(width: 18, height: 18)
                Text(window.map { "\(Int($0.percent.rounded())) %" } ?? "–")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            if showsReset, let window {
                ResetText(date: window.resetsAt, now: entry.date)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
