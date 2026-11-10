// Home-screen subway widget (nearest station, next trains, button that starts the Live Activity) and the Live
// Activity UI itself (lock screen + Dynamic Island). Extension-only; shared types are in SubwayShared.swift.

import ActivityKit
import AppIntents
import CoreLocation
import SwiftUI
import WidgetKit

/// The one-line alert summary: "M Suspended · 3 min ago".
struct AlertFooter: View {
    let alert: SubwayState.Alert
    let now: Double
    let palette: SubwayPalette
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10, weight: .bold))
                .foregroundStyle(palette.alertColor(alert.tone))
            Text(alert.line).fontWeight(.bold).foregroundStyle(palette.fg)
            Text(alert.footer(now: now)).foregroundStyle(palette.mut)
        }
        .font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
    }
}

/// The redesigned board (header + 3 rows), shared by the home-screen widget and the Live Activity.
struct SubwayBoard: View {
    let state: SubwayState
    let now: Double
    let density: SubwayDensity
    var trackButton = false
    /// Live Activity only: one tappable chip per line at the station (shows/hides it via ToggleSubwayLineIntent).
    var chips = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = SubwayPalette(dark: scheme == .dark)
        let all = state.catchable(now: now)
        // The lock screen caps a Live Activity at ~160pt: header + 3 rows already fill it, so the chip line takes the
        // place of the third row, and the alert footer shares that line with the chips. Without chips (medium widget),
        // the footer alone takes the third row's place.
        let showChips = chips && !state.lines.isEmpty
        let fullRows = showChips ? density.maxRows - 1 : density.maxRows
        let footerAlert = density == .small ? nil : state.worstAlert(among: Array(all.prefix(fullRows)).map(\.line))
        let rows = Array(all.prefix(footerAlert == nil || showChips ? fullRows : fullRows - 1))
        VStack(alignment: .leading, spacing: density.rowGap) {
            HStack(spacing: 6) {
                Text(state.station).font(.system(size: density.titleFont, weight: .bold)).lineLimit(1)
                    .minimumScaleFactor(0.8).foregroundStyle(palette.fg)
                Spacer(minLength: 2)
                HStack(spacing: 4) {
                    Glyph(name: "figure.walk", size: 11)
                    Text(density == .small ? "\(state.walkMin)" : "\(state.walkMin) min").lineLimit(1).fixedSize()
                }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.mut)
                if trackButton {
                    if #available(iOS 26.0, *) {
                        Button(intent: StartSubwayActivityIntent()) {
                            Glyph(name: "tram.fill", size: 11)
                                .foregroundStyle(palette.mut)
                                .frame(width: 20, height: 20)
                                .background(palette.chip, in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 22)
            .padding(.bottom, 4)
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                TrainRow(row: row, walkSec: state.walkSec, now: now, density: density, palette: palette, highlighted: i == 0, alert: state.alert(for: row.line))
            }
            Spacer(minLength: 0)
            if showChips {
                HStack(spacing: 4) {
                    // At most 6 so the footer keeps room; a busy station's rest is reachable from the Subway screen.
                    ForEach(Array(state.lines.prefix(6)), id: \.line) { l in
                        Button(intent: ToggleSubwayLineIntent(station: state.station, line: l.line, hide: !l.hidden)) {
                            LineChip(line: l.line, hidden: l.hidden, size: 22, palette: palette)
                                .padding(2).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 6)
                    if let a = footerAlert { AlertFooter(alert: a, now: now, palette: palette) }
                }
                .padding(.top, 2)
                Spacer(minLength: 0)
            } else if let a = footerAlert {
                AlertFooter(alert: a, now: now, palette: palette).padding(.top, 2)
                Spacer(minLength: 0)
            }
        }
    }
}

/// Background colour for the real widget/Live Activity surfaces (matches the mockup's white / #1c1c1e).
let subwaySurface = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.11, green: 0.11, blue: 0.118, alpha: 1) : .white })

// MARK: Live Activity

struct SubwayLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SubwayAttributes.self) { context in
            SubwayBoard(state: context.state, now: Date().timeIntervalSince1970, density: .live, chips: true)
                .widgetURL(subwayScreenURL)
                .padding(.horizontal, SubwayDensity.live.hPad)
                .padding(.vertical, SubwayDensity.live.vPad)
                .activityBackgroundTint(subwaySurface)
        } dynamicIsland: { context in
            let now = Date().timeIntervalSince1970
            let top = context.state.catchable(now: now).first
            return DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    SubwayBoard(state: context.state, now: now, density: .live, chips: true)
                }
            } compactLeading: {
                if let row = top { Bullet(line: row.line, size: 20) }
            } compactTrailing: {
                if let row = top { Text("\(row.timing(walkSec: context.state.walkSec, now: now).minsToTrain)").monospacedDigit() }
            } minimal: {
                if let row = top { Bullet(line: row.line, size: 20) }
            }
            .widgetURL(subwayScreenURL)
        }
    }
}

// MARK: Home-screen widget

struct SubwayEntry: TimelineEntry {
    let date: Date
    let state: SubwayState?
    let error: String?
}

struct SubwayProvider: TimelineProvider {
    func placeholder(in context: Context) -> SubwayEntry {
        let now = Date.now
        return SubwayEntry(date: now, state: SubwayState(station: "Station", walkMin: 3, walkSec: 180, rows: [
            .init(line: "A", dest: "Uptown", mins: 6, verdict: "3 min spare", sched: false, arrive: now.timeIntervalSince1970 + 380),
        ], ts: now.timeIntervalSince1970), error: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (SubwayEntry) -> Void) {
        completion(placeholder(in: context))
    }

    // Refetches every 2 min (the system throttles widget reloads anyway); the Live Activity is the real-time surface.
    func getTimeline(in context: Context, completion: @escaping (Timeline<SubwayEntry>) -> Void) {
        Task { @MainActor in
            let entries: [SubwayEntry]
            let start = Date.now
            do {
                let loc = try await OneShotLocation.current()
                let state = try await SubwayAPI.nearby(loc)
                // One entry a minute from the same response: minutes, leave-by and rings stay right until the refetch.
                entries = (0..<2).map { SubwayEntry(date: start.addingTimeInterval(Double($0) * 60), state: state, error: nil) }
            } catch {
                entries = [SubwayEntry(date: start, state: nil, error: "\(error)")]
            }
            completion(Timeline(entries: entries, policy: .after(start.addingTimeInterval(120))))
        }
    }
}

struct SubwayWidgetView: View {
    let entry: SubwayEntry
    @Environment(\.widgetFamily) private var family

    var body: some View { SubwayWidgetContent(entry: entry, family: family) }
}

/// The widget's layout, with the family passed in so tests can render both sizes (the environment value is read-only).
struct SubwayWidgetContent: View {
    let entry: SubwayEntry
    let family: WidgetFamily

    var body: some View {
        Group {
            if let state = entry.state {
                SubwayBoard(state: state, now: entry.date.timeIntervalSince1970,
                            density: family == .systemSmall ? .small : .medium, trackButton: true)
            } else {
                Text(entry.error ?? "").font(.caption2)
            }
        }
        .padding(14)
        .widgetURL(subwayScreenURL)
        .containerBackground(subwaySurface, for: .widget)
    }
}

struct SubwayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.oliverullman.assistantlocation.subway", provider: SubwayProvider()) { entry in
            SubwayWidgetView(entry: entry)
        }
        .configurationDisplayName("Subway")
        .description("Nearest station and next trains.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}
