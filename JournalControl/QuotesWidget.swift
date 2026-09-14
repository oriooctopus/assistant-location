// Home Screen widget for Stage 2 of the Quotes feature (see MODULES.md /
// Modules/Quotes/ for Stage 1's tab). Picks EXACTLY the same quote
// QuotesViewController's "Right Now" preview shows for the same
// wall-clock minute -- both read through QuotesRuleEngine's pure
// selection/rotation math (see SharedTests/QuotesRuleEngineTests.m), never
// a separate Swift reimplementation of that logic, so there is exactly one
// place a selection bug could hide. Bridged in via
// JournalControl-Bridging-Header.h; QuotesStore.m/QuotesModels.m/
// QuotesRuleEngine.m and this target's own QuotesWidgetLoader.m are
// compiled into this extension target by
// scripts/add_quotes_to_journalcontrol.rb.
//
// No network calls here, ever -- everything this needs (quotes, rules,
// default rotation) is already local, in the shared keychain item
// QuotesWidgetLoader reads.

import WidgetKit
import SwiftUI

struct QuoteEntry: TimelineEntry {
    let date: Date
    let quoteText: String?
    let quoteAuthor: String?
    /// Set only when the matched rule's pool is empty right now (e.g. an
    /// AI rule still waiting on its server-side resolution, or a filter
    /// rule that legitimately matched nothing) -- distinct from
    /// `quoteText == nil` meaning "the store couldn't be read at all",
    /// which `unavailableMessage` covers instead.
    let waitingRuleName: String?
    /// Non-nil when QuotesWidgetLoader couldn't fully read the store (see
    /// its own header comment for the two ways that happens) -- rendered
    /// instead of a blank tile, mirroring QuotesViewController's own
    /// banner for the identical condition on the app side.
    let unavailableMessage: String?
}

struct QuoteTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuoteEntry {
        QuoteEntry(date: Date(),
                   quoteText: "No one can make you feel inferior without your consent.",
                   quoteAuthor: "Eleanor Roosevelt",
                   waitingRuleName: nil,
                   unavailableMessage: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuoteEntry) -> Void) {
        completion(makeTimeline().entries.first ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuoteEntry>) -> Void) {
        completion(makeTimeline())
    }

    // Shared by both getSnapshot and getTimeline so a snapshot (the widget
    // gallery / transient system previews) always matches what the real
    // timeline would show right now, rather than a hardcoded placeholder
    // that could visibly disagree with the tile a second later.
    private func makeTimeline() -> Timeline<QuoteEntry> {
        let snapshot = QuotesWidgetLoader.loadSnapshot()
        let quotes = snapshot.quotes
        let rules = snapshot.rules
        let defaultRotate = snapshot.defaultRotateMinutes

        let calendar = Calendar.current
        let now = Date()
        // "Next ~12h, at most ~100 entries" per the Stage 2 brief: a
        // widget timeline's entry budget is finite (WidgetKit silently
        // drops entries past a system-enforced cap), and a tile nobody has
        // looked at in 12h refreshes anyway once .atEnd is reached below.
        let horizon = calendar.date(byAdding: .hour, value: 12, to: now) ?? now.addingTimeInterval(12 * 3600)

        var entryDates = [now]
        let changeDates = QuotesRuleEngine.changeDates(from: now,
                                                         to: horizon,
                                                         rules: rules,
                                                         quotes: quotes,
                                                         defaultRotateMinutes: defaultRotate,
                                                         calendar: calendar)
        entryDates.append(contentsOf: changeDates.prefix(99)) // + `now` itself = 100 max

        let entries = entryDates.map { date in
            makeEntry(at: date, quotes: quotes, rules: rules, defaultRotate: defaultRotate,
                      calendar: calendar, unavailableMessage: snapshot.unavailableMessage)
        }
        return Timeline(entries: entries, policy: .atEnd)
    }

    private func makeEntry(at date: Date, quotes: [GLQuote], rules: [GLQuoteRule], defaultRotate: Int,
                            calendar: Calendar, unavailableMessage: String?) -> QuoteEntry {
        // Same weekday/minuteOfDay/epochMinute derivation
        // QuotesViewController.m's -reloadPreview uses, so the two never
        // disagree about what "now" (or any later instant on this
        // timeline) maps to.
        let comps = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        let weekday = comps.weekday ?? 1
        let minuteOfDay = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let selection = QuotesRuleEngine.selection(forWeekday: weekday,
                                                     minuteOfDay: minuteOfDay,
                                                     rules: rules,
                                                     quotes: quotes,
                                                     defaultRotateMinutes: defaultRotate)
        let epochMinute = Int64(date.timeIntervalSince1970 / 60.0)
        let quote = QuotesRuleEngine.currentQuote(for: selection, epochMinute: epochMinute)

        if let quote {
            return QuoteEntry(date: date, quoteText: quote.text, quoteAuthor: quote.author,
                               waitingRuleName: nil, unavailableMessage: unavailableMessage)
        }
        return QuoteEntry(date: date, quoteText: nil, quoteAuthor: nil,
                           waitingRuleName: selection.matchedRule?.name ?? "This rule",
                           unavailableMessage: unavailableMessage)
    }
}

struct QuoteWidgetView: View {
    var entry: QuoteEntry
    @Environment(\.widgetFamily) private var family

    // .systemSmall has the least room; .systemMedium is wide but still
    // short; .systemLarge can afford a much longer quote before truncating
    // mid-word matters. minimumScaleFactor below is the other half of
    // "nothing clips mid-word at the tile edge" -- line limits alone still
    // truncate long words, scaling shrinks the whole block first.
    private var quoteLineLimit: Int {
        switch family {
        case .systemSmall: return 5
        case .systemMedium: return 4
        default: return 10
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = entry.unavailableMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(family == .systemSmall ? 2 : 3)
                    .minimumScaleFactor(0.8)
            }

            if let text = entry.quoteText {
                Text("“\(text)”")
                    .font(.system(.body, design: .serif))
                    .lineLimit(quoteLineLimit)
                    .minimumScaleFactor(0.55)
                    .fixedSize(horizontal: false, vertical: true)
                if let author = entry.quoteAuthor {
                    Text("— \(author)")
                        .font(.system(.caption, design: .serif))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            } else {
                // Empty pool -- see QuoteEntry.waitingRuleName's doc.
                Text(entry.waitingRuleName ?? "Quotes")
                    .font(.system(.caption, design: .serif))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("No quotes match yet")
                    .font(.system(.body, design: .serif))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Deep-links to the Quotes tab specifically (see QuotesModule.m's
        // +moduleHandleURL:), not just the app in general.
        .widgetURL(URL(string: "overland://quotes"))
        .containerBackground(.background, for: .widget)
    }
}

struct QuotesWidget: Widget {
    let kind: String = "com.oliverullman.assistantlocation.quoteswidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuoteTimelineProvider()) { entry in
            QuoteWidgetView(entry: entry)
        }
        .configurationDisplayName("Quote")
        .description("Shows the quote your Quotes schedule picks right now.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
