// The Superapp's Subway screen (Modules/Subway/SubwayModule.m hosts SubwayScreenHost.makeViewController()): station +
// walk, every catchable train, line chips that show/hide a line at this station, and the full text of each alert.
// SubwayScreenContent is the pure layout (rendered by SubwayTests); SubwayScreenModel does the fetching, the cache and
// the pending-chip bookkeeping. Compiled into the Superapp (iOS 15 target), so nothing here may need iOS 16+.

import CoreLocation
import SwiftUI
import UIKit

/// Pure layout of the screen for a given state. `pending` is the set of lines whose toggle the server has not confirmed.
struct SubwayScreenContent: View {
    let state: SubwayState
    let now: Double
    var pending: Set<String> = []
    /// Set when the shown state is the cached one because the last fetch failed: the epoch seconds it was fetched.
    var offlineSince: Double?
    var onToggle: (SubwayState.LineEntry) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = SubwayPalette(dark: scheme == .dark)
        let rows = state.allCatchable(now: now)
        // Alerts for lines at this station, worst first. Hidden lines keep their alert: it is still true of the line.
        let lines = Set(state.lines.map(\.line))
        let alerts = state.alerts.filter { lines.isEmpty || lines.contains($0.line) }.sorted { $0.worse(than: $1) }
        VStack(alignment: .leading, spacing: 18) {
            if let since = offlineSince {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.slash").font(.system(size: 12, weight: .bold))
                    Text("Offline · updated \(SubwayState.Alert.relative(now - since))")
                }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.mut)
            }
            HStack(spacing: 8) {
                Text(state.station).font(.system(size: 24, weight: .bold)).foregroundStyle(palette.fg)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Glyph(name: "figure.walk", size: 14).foregroundStyle(palette.mut)
                Text("\(state.walkMin) min").font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.mut)
            }
            if !state.lines.isEmpty {
                HStack(spacing: 8) {
                    ForEach(state.lines, id: \.line) { l in
                        Button { onToggle(l) } label: {
                            LineChip(line: l.line, hidden: l.hidden, pending: pending.contains(l.line), size: 34, palette: palette)
                                .padding(2).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(pending.contains(l.line))
                    }
                    Spacer(minLength: 0)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if rows.isEmpty {
                    Text("No trains soon").font(.system(size: 15, weight: .medium)).foregroundStyle(palette.mut)
                        .padding(.vertical, 8)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    TrainRow(row: row, walkSec: state.walkSec, now: now, density: .medium, palette: palette,
                             highlighted: i == 0, alert: state.alert(for: row.line))
                        .padding(.vertical, 2)
                }
            }
            if !alerts.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(alerts.enumerated()), id: \.offset) { _, a in
                        HStack(alignment: .top, spacing: 10) {
                            Bullet(line: a.line, size: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(palette.alertColor(a.tone))
                                    Text(a.footer(now: now)).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.mut)
                                }
                                Text(a.text).font(.system(size: 14)).foregroundStyle(palette.fg)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Fetches, caches and toggles. A chip stays `pending` until the server has answered the PUT and the refetch after it
/// has landed, so the spinner means "not confirmed yet" and the screen never shows an unconfirmed state as done.
@MainActor
final class SubwayScreenModel: ObservableObject {
    @Published var state: SubwayState?
    @Published var pending: Set<String> = []
    @Published var offlineSince: Double?
    @Published var error: String?
    @Published var loading = false

    private static let cacheKey = "subway.lastState"
    private var fetchedAt: Double = 0

    init() {
        // Last fetched state, so the screen is useful with no connection (the subway is where signal drops).
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(CachedState.self, from: data) {
            state = cached.state
            fetchedAt = cached.fetchedAt
        }
    }

    private struct CachedState: Codable {
        var state: SubwayState
        var fetchedAt: Double
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        do {
            let loc = try await OneShotLocation.current()
            let fresh = try await SubwayAPI.nearby(loc, all: true)
            state = fresh
            fetchedAt = Date().timeIntervalSince1970
            offlineSince = nil
            error = nil
            if let data = try? JSONEncoder().encode(CachedState(state: fresh, fetchedAt: fetchedAt)) {
                UserDefaults.standard.set(data, forKey: Self.cacheKey)
            }
        } catch {
            self.error = "\(error)"
            if state != nil { offlineSince = fetchedAt }
        }
    }

    func toggle(_ entry: SubwayState.LineEntry) async {
        guard let station = state?.station else { return }
        pending.insert(entry.line)
        defer { pending.remove(entry.line) }
        do {
            try await SubwayAPI.setLine(station: station, line: entry.line, hide: !entry.hidden)
        } catch {
            self.error = "\(error)"
            return
        }
        await refresh()
    }
}

struct SubwayScreenView: View {
    @StateObject private var model = SubwayScreenModel()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = SubwayPalette(dark: scheme == .dark)
        // TimelineView re-evaluates the clock every 30 s so minutes/leave-by stay right between fetches.
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let state = model.state {
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        SubwayScreenContent(state: state, now: ctx.date.timeIntervalSince1970, pending: model.pending,
                                            offlineSince: model.offlineSince) { entry in
                            Task { await model.toggle(entry) }
                        }
                    }
                } else if model.loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                }
                if let e = model.error {
                    Text(e).font(.system(size: 12)).foregroundStyle(palette.mut)
                }
            }
            .padding(16)
        }
        .background(palette.bg.ignoresSafeArea())
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
    }
}

/// ObjC entry point for Modules/Subway/SubwayModule.m (Swift only reaches Objective-C through an @objc class).
@objc public final class GLSubwayScreen: NSObject {
    @objc public static func makeViewController() -> UIViewController {
        let host = UIHostingController(rootView: SubwayScreenView())
        host.title = "Subway"
        return host
    }
}
