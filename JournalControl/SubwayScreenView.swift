// The Superapp's Subway screen (Modules/Subway/SubwayModule.m hosts SubwayScreenHost.makeViewController()): station +
// walk, every catchable train, line chips that show/hide a line at this station, and the full text of each alert.
// SubwayScreenContent is the pure layout (rendered by SubwayTests); SubwayScreenModel does the fetching, the cache and
// the pending-chip bookkeeping. Compiled into the Superapp (iOS 15 target), so nothing here may need iOS 16+.

import ActivityKit
import CoreLocation
import EventKit
import MapKit
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
    /// A fetch is in flight: spinner beside the walk time.
    var refreshing = false
    /// Live Activity switch state; nil hides the row (iOS 16 and older).
    var liveActivity: Bool?
    var onLiveActivity: (Bool) -> Void = { _ in }
    /// Clear button spinner while the server has not confirmed the clear/set.
    var destinationSaving = false
    var onClearDestination: () -> Void = {}
    /// Search field, paste button and calendar toggle (live-only controls, so the pure layout renders in tests without them).
    var destinationControls: () -> AnyView = { AnyView(EmptyView()) }
    @Environment(\.colorScheme) private var scheme
    /// "More trains" tapped: the nearest station's list is no longer cut short for the nearby sections.
    @State private var expanded = false

    var body: some View {
        let palette = SubwayPalette(dark: scheme == .dark)
        // With other stations in walking range, the nearest one's list is cut short so those sit above the fold.
        let allRows = state.allCatchable(now: now)
        let rows = state.nearby.isEmpty || expanded ? allRows : Array(allRows.prefix(Self.rowsWithNearby))
        // Alerts for lines at this station, worst first. Hidden lines keep their alert: it is still true of the line.
        let lines = Set(state.lines.map(\.line))
        let alerts = state.alerts.filter { lines.isEmpty || lines.contains($0.line) }.sorted { $0.worse(than: $1) }
        let stale = state.isStale(now: now)
        let rowOpacity = stale ? 0.4 : 1.0
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
                if refreshing { ProgressView() }
                if stale {
                    Text(state.updatedLabel()).font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.mut)
                } else {
                    Glyph(name: "figure.walk", size: 14).foregroundStyle(palette.mut)
                    Text("\(state.walkMin) min").font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.mut)
                }
            }
            if let on = liveActivity {
                Toggle("Live Activity", isOn: Binding(get: { on }, set: onLiveActivity))
                    .font(.system(size: 14)).foregroundColor(palette.mut)
            }
            if let d = state.destination {
                HStack(spacing: 10) {
                    Image(systemName: "location.north.circle.fill").font(.system(size: 20)).foregroundStyle(palette.mut)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.fg).lineLimit(1)
                        Text(Self.sourceLabel(d)).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.mut)
                    }
                    Spacer(minLength: 4)
                    Button(action: onClearDestination) {
                        ZStack {
                            if destinationSaving { ProgressView() }
                            else { Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(palette.mut) }
                        }
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(destinationSaving)
                }
            }
            destinationControls()
            if !state.lines.isEmpty {
                HStack(spacing: 8) {
                    Text("Lines").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.mut)
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
                        .padding(.vertical, 2).opacity(rowOpacity)
                }
                if rows.count < allRows.count {
                    Button { expanded = true } label: {
                        HStack(spacing: 4) {
                            Text("More trains")
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                        }
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.mut)
                        .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            ForEach(state.nearby, id: \.station) { n in
                let nRows = n.rows.filter { $0.arrive - n.walkSec - now >= -SubwayTiming.lateGraceSec }.sorted { $0.arrive < $1.arrive }
                if !nRows.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(n.station).font(.system(size: 18, weight: .bold)).foregroundStyle(palette.fg).lineLimit(1)
                            Spacer(minLength: 4)
                            Glyph(name: "figure.walk", size: 13).foregroundStyle(palette.mut)
                            Text("\(n.walkMin) min").font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.mut)
                        }
                        .padding(.bottom, 2)
                        ForEach(Array(nRows.enumerated()), id: \.offset) { _, row in
                            TrainRow(row: row, walkSec: n.walkSec, now: now, density: .medium, palette: palette,
                                     highlighted: false, alert: state.alert(for: row.line))
                                .padding(.vertical, 2).opacity(rowOpacity)
                        }
                    }
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

extension SubwayScreenContent {
    static let rowsWithNearby = 8

    /// "Set by you", "From Google Maps", "From calendar", plus a note when no direct train goes there.
    static func sourceLabel(_ d: SubwayState.Destination) -> String {
        let base = d.source == "share" ? "From Google Maps" : d.source == "calendar" ? "From calendar" : "Set by you"
        return d.noDirect == true ? "\(base) \u{00B7} no direct train" : base
    }
}

/// A place the destination field can set: a station from the server or a MapKit result.
struct DestinationChoice: Identifiable, Hashable {
    var id: String { "\(name)|\(lat)|\(lon)" }
    var name: String
    var lat: Double
    var lon: Double
    var isStation = false
    var address: String?
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
    /// Live Activity switch: nil below iOS 17. Reconciled from the running activities on every refresh.
    @Published var liveActivityOn: Bool?
    private var liveActivityBusy = false

    // Destination UI state.
    @Published var query = ""
    @Published var results: [DestinationChoice] = []
    @Published var destinationSaving = false
    @Published var searching = false
    @Published var useCalendar: Bool = UserDefaults.standard.bool(forKey: "subway.useCalendar")
    private var lastLocation: CLLocation?
    private var searchTask: Task<Void, Never>?

    private static let cacheKey = "subway.lastState"
    private var fetchedAt: Double = 0

    init() {
        syncLiveActivityFlag()
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

    /// The automatic triggers (appearance, foreground, 30 s tick) skip while a fetch is in flight; user actions call refresh().
    func refreshIfIdle() async {
        guard !loading else { return }
        await refresh()
    }

    private func syncLiveActivityFlag() {
        guard #available(iOS 17.0, *), !liveActivityBusy else { return }
        liveActivityOn = !Activity<SubwayAttributes>.activities.isEmpty
    }

    func setLiveActivity(_ on: Bool) async {
        guard #available(iOS 17.0, *) else { return }
        liveActivityOn = on
        liveActivityBusy = true
        defer { liveActivityBusy = false }
        if on {
            do { try await SubwayActivity.startTracking() } catch {
                liveActivityOn = false
                self.error = "\(error)"
            }
        } else {
            await SubwayActivity.endAll()
        }
    }

    func refresh() async {
        loading = true
        defer { loading = false; syncLiveActivityFlag() }
        do {
            let loc = try await OneShotLocation.current()
            lastLocation = loc
            if #available(iOS 17.0, *) { await SubwayActivity.reconcile(loc) }
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
                                            offlineSince: model.offlineSince, onToggle: { entry in
                            Task { await model.toggle(entry) }
                        }, refreshing: model.loading, liveActivity: model.liveActivityOn, onLiveActivity: { on in
                            Task { await model.setLiveActivity(on) }
                        }, destinationSaving: model.destinationSaving, onClearDestination: {
                            Task { await model.clearDestination() }
                        }, destinationControls: { AnyView(SubwayDestinationControls(model: model, palette: palette)) })
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
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await model.refreshIfIdle() }
        }
        // SwiftUI cancels this on disappear, which ends the 30 s loop.
        .task {
            await model.refreshIfIdle()
            await model.syncCalendar()
            while true {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { break }
                await model.refreshIfIdle()
            }
        }
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

// MARK: Destination (search, paste, calendar)

extension SubwayScreenModel {
    /// Debounced search on the server: matching stations, then Google Places hits near here (MapKit missed named venues).
    func search(_ text: String) {
        searchTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { results = []; searching = false; return }
        searching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                let hits = try await SubwayAPI.stations(matching: q, near: self.lastLocation)
                guard !Task.isCancelled else { return }
                self.results = hits.map { DestinationChoice(name: $0.name, lat: $0.lat, lon: $0.lon, isStation: $0.kind == "station", address: $0.address) }
            } catch {
                guard !Task.isCancelled else { return }
                self.results = []
                self.error = "\(error)"
            }
            self.searching = false
        }
    }

    static func mapSearch(_ q: String, near: CLLocation?) async -> [DestinationChoice] {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        if let c = near?.coordinate { req.region = MKCoordinateRegion(center: c, latitudinalMeters: 40_000, longitudinalMeters: 40_000) }
        guard let resp = try? await MKLocalSearch(request: req).start() else { return [] }
        return resp.mapItems.prefix(5).compactMap { item in
            guard let name = item.name else { return nil }
            let c = item.placemark.coordinate
            return DestinationChoice(name: name, lat: c.latitude, lon: c.longitude)
        }
    }

    /// First MapKit match for a bare name or address (a shared link without coordinates, a calendar event's location).
    func geocode(_ text: String) async -> DestinationChoice? {
        await Self.mapSearch(text, near: lastLocation).first
    }

    func choose(_ c: DestinationChoice, source: String = "manual", expiresAt: Double? = nil) async {
        destinationSaving = true
        defer { destinationSaving = false }
        do {
            try await SubwayAPI.setDestination(lat: c.lat, lon: c.lon, name: c.name, source: source, expiresAt: expiresAt)
            query = ""
            results = []
        } catch { self.error = "\(error)"; return }
        await refresh()
    }

    func clearDestination() async {
        destinationSaving = true
        defer { destinationSaving = false }
        do { try await SubwayAPI.clearDestination() } catch { self.error = "\(error)"; return }
        await refresh()
    }

    /// The user's Paste tap: reads the copied Google Maps link/text, lets the server extract the destination, and
    /// geocodes the name when the link carried no coordinates.
    func pasteLink() async {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { error = "Nothing copied"; return }
        destinationSaving = true
        do {
            let place = try await SubwayAPI.parseShare(text: text)
            if let lat = place.lat, let lon = place.lon {
                destinationSaving = false
                await choose(DestinationChoice(name: place.name ?? "Dropped pin", lat: lat, lon: lon), source: "share")
            } else if let name = place.name, let hit = await geocode(name) {
                destinationSaving = false
                await choose(DestinationChoice(name: name, lat: hit.lat, lon: hit.lon), source: "share")
            } else { error = "Couldn't place that link" }
        } catch { self.error = "\(error)" }
        destinationSaving = false
    }

    func setUseCalendar(_ on: Bool) async {
        useCalendar = on
        UserDefaults.standard.set(on, forKey: "subway.useCalendar")
        if on { await syncCalendar(prompt: true) }
        else if (try? await SubwayAPI.destination())?.source == "calendar" { await clearDestination() }
    }

    /// Next event starting within 3 h that has a location becomes a "calendar" destination (the server ignores it while
    /// a manual/share one is active). Runs when the screen opens and when the toggle goes on; there is no background
    /// refresh in the app to hang it on.
    func syncCalendar(prompt: Bool = false) async {
        guard useCalendar else { return }
        let store = EKEventStore()
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            granted = await withCheckedContinuation { cont in store.requestAccess(to: .event) { ok, _ in cont.resume(returning: ok) } }
        }
        guard granted else {
            useCalendar = false
            UserDefaults.standard.set(false, forKey: "subway.useCalendar")
            error = "Calendar access is off"
            return
        }
        let now = Date()
        let events = store.events(matching: store.predicateForEvents(withStart: now, end: now.addingTimeInterval(3 * 3600), calendars: nil))
            .filter { !$0.isAllDay && $0.startDate >= now && !($0.location ?? "").isEmpty }
            .sorted { $0.startDate < $1.startDate }
        guard let ev = events.first, let place = ev.location, let hit = await geocode(place) else { return }
        await choose(DestinationChoice(name: ev.title ?? hit.name, lat: hit.lat, lon: hit.lon), source: "calendar",
                     expiresAt: ev.endDate.timeIntervalSince1970)
    }
}

/// Search field + results + "Paste link" + "Use calendar".
struct SubwayDestinationControls: View {
    @ObservedObject var model: SubwayScreenModel
    let palette: SubwayPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.mut)
                TextField("Where to?", text: $model.query)
                    .font(.system(size: 15)).autocapitalization(.none).disableAutocorrection(true)
                    .onChange(of: model.query) { model.search($0) }
                if model.searching { ProgressView() }
                Button { Task { await model.pasteLink() } } label: {
                    Text("Paste link").font(.system(size: 13, weight: .semibold))
                }
                .disabled(model.destinationSaving)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(palette.chip, in: RoundedRectangle(cornerRadius: 10))
            ForEach(model.results) { r in
                Button { Task { await model.choose(r) } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: r.isStation ? "tram.fill" : "mappin.circle.fill").font(.system(size: 13))
                            .foregroundStyle(palette.mut).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.name).font(.system(size: 14)).foregroundStyle(palette.fg).lineLimit(1)
                            if let a = r.address {
                                Text(a).font(.system(size: 12)).foregroundStyle(palette.mut).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Toggle("Use calendar", isOn: Binding(get: { model.useCalendar }, set: { on in Task { await model.setUseCalendar(on) } }))
                .font(.system(size: 14)).foregroundColor(palette.mut)
        }
    }
}
