import Foundation
import NotchwerkShared
import WidgetKit

/// Ein Stand für die Widgets. Ohne `feed` hat die App noch keine Daten abgelegt.
struct UsageEntry: TimelineEntry {
    let date: Date
    let feed: WidgetFeed?
    /// Beispieldaten für die Widget-Galerie, solange es noch keine echten gibt.
    var isSample = false

    /// Älter als `feed.staleAfter` gilt der Stand als veraltet und das Widget zeigt, von wann er ist.
    var isStale: Bool {
        guard let feed, !isSample else { return false }
        return date.timeIntervalSince(feed.updatedAt) > feed.staleAfter
    }
}

/// Liest die Datei, die Notchwerk ablegt. Die App stößt nach jedem Abruf ein Neuladen an.
/// Zusätzlich gibt es einen Eintrag zu jedem anstehenden Zurücksetzen, damit ein Ring pünktlich
/// auf 0 springt, auch wenn die App gerade keine neuen Zahlen geholt hat.
struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), feed: .sample, isSample: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        if let feed = WidgetFeedStore.read() {
            completion(UsageEntry(date: Date(), feed: feed))
        } else {
            completion(UsageEntry(date: Date(), feed: context.isPreview ? .sample : nil, isSample: context.isPreview))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let now = Date()
        let feed = WidgetFeedStore.read()
        var dates: Set<Date> = [now]
        // Jede volle Minute ein Eintrag, damit „neu in 2 Std. 27 Min.“ ohne Sekundenzähler aktuell bleibt.
        // Eine Stunde reicht: Notchwerk lädt nach jedem Abruf neu, spätestens nach 30 Minuten das System.
        let minute = (now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60
        for i in 1...60 { dates.insert(Date(timeIntervalSinceReferenceDate: minute + Double(i) * 60)) }
        if let feed {
            let horizon = now.addingTimeInterval(24 * 3600)
            for account in feed.accounts {
                for window in account.windows {
                    if let reset = window.resetsAt, reset > now, reset < horizon { dates.insert(reset) }
                }
            }
            // Ab hier gilt der Stand als veraltet: dann einen Hinweis zeigen.
            let stale = feed.updatedAt.addingTimeInterval(feed.staleAfter + 1)
            if stale > now, stale < horizon { dates.insert(stale) }
        }
        let entries = dates.sorted().map { UsageEntry(date: $0, feed: feed) }
        // Notchwerk lädt nach jedem Abruf selbst neu. Das hier ist nur das Sicherheitsnetz.
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

extension WidgetFeed {
    /// Beispiel für die Widget-Galerie.
    static var sample: WidgetFeed {
        let now = Date()
        return WidgetFeed(updatedAt: now, refreshMinutes: 15, accounts: [
            Account(id: "sample", name: "Claude", status: .ok, message: "", fetchedAt: now, windows: [
                Window(key: "five_hour", title: "Sitzung", percent: 34, resetsAt: now.addingTimeInterval(2 * 3600 + 13 * 60)),
                Window(key: "seven_day", title: "Woche", percent: 58, resetsAt: now.addingTimeInterval(3 * 86400 + 5 * 3600)),
                Window(key: "sample_fable", title: "Fable 5", percent: 21, resetsAt: now.addingTimeInterval(3 * 86400 + 5 * 3600)),
            ]),
        ])
    }
}
