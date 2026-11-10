// Subway widget + Live Activity, checked against REAL saved server output (fixtures/): nearby_start.json and
// nearby_update.json are two GET /subway/nearby responses ~95s apart at Times Sq, apns_update.json is what the server's
// liveActivityPayload() (location-server/lib/apns.mjs) builds around the second one. SubwayShared.swift and
// SubwayWidget.swift are compiled straight into this bundle (scripts/add_subway_tests_target.rb).
import ActivityKit
import SwiftUI
import UIKit
import WidgetKit
import XCTest

private let fixtureDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures")
private let outDir = URL(fileURLWithPath: "/tmp/subway-out")

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureDir.appendingPathComponent(name))
}

final class SubwayDecodeTests: XCTestCase {
    func testNearbyResponseDecodes() throws {
        let s = try JSONDecoder().decode(SubwayState.self, from: fixture("nearby_start.json"))
        XCTAssertEqual(s.station, "Times Sq-42 St/Port Authority Bus Terminal")
        XCTAssertEqual(s.walkSec, 9)
        XCTAssertEqual(s.walkMin, 0)
        XCTAssertEqual(s.rows.count, 24)
        XCTAssertFalse(s.rows.contains { $0.verdict == "miss" }, "server drops missed trains")
        // Server invariant the UI relies on (floor, so a train 1-59 s past can be -1): minutes is the whole minutes from ts to arrive.
        for r in s.rows { XCTAssertEqual(r.mins, Int(((r.arrive - s.ts) / 60).rounded(.down)), "\(r.line) \(r.dest)") }
        XCTAssertEqual(s.rows[0].minsLabel, s.rows[0].sched ? "~\(s.rows[0].mins)" : "\(s.rows[0].mins)")
    }

    /// The point of the whole file: the server's APNs `content-state` must decode into the Live Activity's ContentState.
    func testServerApnsPayloadDecodesIntoContentState() throws {
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("apns_update.json")) as? [String: Any])
        let aps = try XCTUnwrap(raw["aps"] as? [String: Any])
        XCTAssertEqual(aps["event"] as? String, "update")
        XCTAssertNotNil(aps["timestamp"] as? Int)
        let contentState = try JSONSerialization.data(withJSONObject: try XCTUnwrap(aps["content-state"]))
        let state = try JSONDecoder().decode(SubwayAttributes.ContentState.self, from: contentState)
        let fromNearby = try JSONDecoder().decode(SubwayState.self, from: fixture("nearby_update.json"))
        XCTAssertEqual(state, fromNearby)
        let start = try JSONDecoder().decode(SubwayState.self, from: fixture("nearby_start.json"))
        XCTAssertNotEqual(state.rows, start.rows, "update fixture must carry different times than the start fixture")
    }

    /// Falsifiers: a renamed or dropped key on either level must break the decode, so the test above can fail.
    func testRenamedOrMissingKeysFailDecode() throws {
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("nearby_update.json")) as? [String: Any])
        for key in ["station", "walkMin", "walkSec", "rows", "ts"] {
            var d = base
            d[key + "_renamed"] = d.removeValue(forKey: key)
            XCTAssertThrowsError(try JSONDecoder().decode(SubwayState.self, from: JSONSerialization.data(withJSONObject: d)), "top-level \(key)")
        }
        for key in ["line", "dest", "mins", "verdict", "sched", "arrive"] {
            var d = base
            var rows = try XCTUnwrap(d["rows"] as? [[String: Any]])
            rows[0][key + "_renamed"] = rows[0].removeValue(forKey: key)
            d["rows"] = rows
            XCTAssertThrowsError(try JSONDecoder().decode(SubwayState.self, from: JSONSerialization.data(withJSONObject: d)), "row \(key)")
        }
    }
}

final class SubwayAlertTests: XCTestCase {
    private let now = 1_800_000_000.0
    private func alert(_ kind: String = "delays", severe: Bool = false, since: Double, active: Bool = true, ended: Double? = nil, line: String = "J") -> SubwayState.Alert {
        .init(line: line, kind: kind, severe: severe, since: since, active: active, ended: ended, text: "t")
    }

    /// Real server response with an active J delay alert; and the older fixtures without the field still decode.
    func testAlertsDecodeAndAreOptional() throws {
        let s = try JSONDecoder().decode(SubwayState.self, from: fixture("nearby_alerts.json"))
        let a = try XCTUnwrap(s.alerts.first)
        XCTAssertEqual(s.alerts.count, 1)
        XCTAssertEqual(a.line, "J")
        XCTAssertEqual(a.kind, "delays")
        XCTAssertTrue(a.active)
        XCTAssertNil(a.ended)
        XCTAssertEqual(a.tone, .warning)
        XCTAssertEqual(try JSONDecoder().decode(SubwayState.self, from: fixture("nearby_start.json")).alerts, [])
    }

    func testLinesDecodeAndAreOptional() throws {
        let s = try JSONDecoder().decode(SubwayState.self, from: fixture("nearby_all.json"))
        XCTAssertEqual(s.lines, [.init(line: "J", hidden: false), .init(line: "M", hidden: false)])
        XCTAssertEqual(s.rows.count, 26)
        // An older server without `lines` still decodes.
        XCTAssertEqual(try JSONDecoder().decode(SubwayState.self, from: fixture("nearby_start.json")).lines, [])
    }

    func testAllCatchableKeepsEveryTrainButDropsMissedOnes() throws {
        let s = try JSONDecoder().decode(SubwayState.self, from: fixture("nearby_all.json"))
        let at = s.ts
        let all = s.allCatchable(now: at)
        XCTAssertGreaterThan(all.count, s.catchable(now: at).count, "all mode keeps repeat trains on the same line+destination")
        XCTAssertEqual(all.map(\.arrive), all.map(\.arrive).sorted())
        // Far in the future every train is missed.
        XCTAssertTrue(s.allCatchable(now: at + 24 * 3600).isEmpty)
    }

    func testFooterText() {
        XCTAssertEqual(alert(since: now - 12 * 60 - 5).footer(now: now), "Delays · 12 min ago")
        XCTAssertEqual(alert(since: now - 20).footer(now: now), "Delays · now")
        XCTAssertEqual(alert("suspended", severe: true, since: now - 3700).footer(now: now), "Suspended · 1 hr ago")
        XCTAssertEqual(alert(since: now - 3000, active: false, ended: now - 8 * 60).footer(now: now), "Delays ended 8 min ago")
        XCTAssertEqual(alert("reroute", since: now - 300, active: false, ended: now - 30).footer(now: now), "Rerouted ended now")
    }

    func testToneColorChoice() {
        XCTAssertEqual(alert(since: now).tone, .warning)
        XCTAssertEqual(alert(severe: true, since: now).tone, .severe)
        XCTAssertEqual(alert("suspended", since: now).tone, .severe)
        XCTAssertEqual(alert(severe: true, since: now - 900, active: false, ended: now - 60).tone, .ended)
        let p = SubwayPalette(dark: false)
        XCTAssertEqual(p.alertColor(.severe), p.color(.now))
        XCTAssertEqual(p.alertColor(.warning), p.color(.soon))
        XCTAssertEqual(p.alertColor(.ended), p.mut)
    }

    func testWorstAlertAmongShownLines() {
        let s = SubwayState(station: "X", walkMin: 1, walkSec: 60, rows: [], alerts: [
            alert(since: now - 600, line: "J"), alert("suspended", severe: true, since: now - 900, line: "M"),
            alert(severe: true, since: now - 60, active: false, ended: now - 30, line: "Z"), alert(since: now - 60, line: "A"),
        ], ts: now)
        XCTAssertEqual(s.worstAlert(among: ["J", "M", "Z"])?.line, "M")
        XCTAssertEqual(s.worstAlert(among: ["J", "Z"])?.line, "J", "active beats ended")
        XCTAssertEqual(s.worstAlert(among: ["J", "A"])?.line, "A", "newest of equals")
        XCTAssertNil(s.worstAlert(among: ["Q"]))
    }
}

/// Leave-by, ring and urgency are pure functions of absolute times (relative to `now`), checked with exact numbers.
final class SubwayTimingTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let now = 1_800_000_000.0   // 2027-01-15 08:00:00 UTC

    func testLeaveNowWhenLeaveByIsPast() {
        // Train in 4 min, walk 4 min: leave-by is exactly now -> "Now", red, empty ring.
        let t = SubwayTiming(arrive: now + 240, walkSec: 240, now: now)
        XCTAssertTrue(t.leaveNow)
        XCTAssertEqual(t.urgency, .now)
        XCTAssertEqual(t.fraction, 0)
        XCTAssertEqual(t.minsToTrain, 4)
        let late = SubwayTiming(arrive: now + 200, walkSec: 240, now: now)   // 40 s late, still "run"
        XCTAssertEqual(late.urgency, .now)
        XCTAssertEqual(late.fraction, 0)
    }

    func testRingFractionAndUrgencyThresholds() {
        // walk 4 min. 60 s to spare: orange, 25 % of the walk still available.
        let soon = SubwayTiming(arrive: now + 300, walkSec: 240, now: now)
        XCTAssertEqual(soon.urgency, .soon)
        XCTAssertEqual(soon.fraction, 0.25, accuracy: 1e-9)
        // exactly 2 min to spare is still orange, one second more is green.
        XCTAssertEqual(SubwayTiming(arrive: now + 360, walkSec: 240, now: now).urgency, .soon)
        XCTAssertEqual(SubwayTiming(arrive: now + 361, walkSec: 240, now: now).urgency, .ok)
        // 3 min to spare: green, 75 %. 4 min or more: full ring.
        XCTAssertEqual(SubwayTiming(arrive: now + 420, walkSec: 240, now: now).fraction, 0.75, accuracy: 1e-9)
        XCTAssertEqual(SubwayTiming(arrive: now + 900, walkSec: 240, now: now).fraction, 1)
    }

    func testTimeMovesTheRowWithoutANewPush() {
        let arrive = now + 600
        XCTAssertEqual(SubwayTiming(arrive: arrive, walkSec: 240, now: now).urgency, .ok)
        XCTAssertEqual(SubwayTiming(arrive: arrive, walkSec: 240, now: now + 300).urgency, .soon)
        XCTAssertEqual(SubwayTiming(arrive: arrive, walkSec: 240, now: now + 360).urgency, .now)
        XCTAssertEqual(SubwayTiming(arrive: arrive, walkSec: 240, now: now + 300).minsToTrain, 5)
    }

    func testClockAndLeaveLabels() {
        let row = SubwayState.Row(line: "J", dest: "Broad St", mins: 6, verdict: "x", sched: false, arrive: now + 360)
        XCTAssertEqual(row.clock(timeZone: utc), "8:06")
        XCTAssertEqual(row.leaveLabel(walkSec: 120, now: now, timeZone: utc), "8:04")
        XCTAssertEqual(row.leaveLabel(walkSec: 360, now: now, timeZone: utc), "Now")
        XCTAssertEqual(row.leaveLabel(walkSec: 400, now: now, timeZone: utc), "Now")
    }

    func testCatchableDropsMissedAndDedupes() {
        func row(_ line: String, _ dest: String, _ off: Double) -> SubwayState.Row {
            .init(line: line, dest: dest, mins: 0, verdict: "", sched: false, arrive: now + off)
        }
        let s = SubwayState(station: "X", walkMin: 4, walkSec: 240, rows: [
            row("M", "A", 100), row("M", "A", 400), row("J", "B", 200), row("J", "B", 700), row("Z", "C", 10),
        ], ts: now)
        // M@100 and Z@10 are unreachable (leave-by more than 60 s ago); J@200 is 40 s late, within grace.
        XCTAssertEqual(s.catchable(now: now).map { "\($0.line)\(Int($0.arrive - now))" }, ["J200", "M400"])
    }

    func testShortDest() {
        XCTAssertEqual(subwayShortDest("Jamaica Center-Parsons/Archer"), "Jamaica Ctr")
        XCTAssertEqual(subwayShortDest("Middle Village-Metropolitan Av"), "Middle Vlg")
        XCTAssertEqual(subwayShortDest("Broad St"), "Broad St")
    }

    func testLiveFixtureRowsAllHaveConsistentTiming() throws {
        let s = try JSONDecoder().decode(SubwayState.self, from: fixture("nearby_update.json"))
        let rows = s.catchable(now: s.ts)
        XCTAssertFalse(rows.isEmpty)
        for r in rows { XCTAssertEqual(r.timing(walkSec: s.walkSec, now: s.ts).minsToTrain, max(0, r.mins)) }
    }
}

@MainActor
final class SubwayWidgetRenderTests: XCTestCase {
    private let now = 1_800_000_000.0

    /// Mirrors the mockup: Myrtle Av, 4 min walk; J leave now (red), M 1 min to spare (orange), J 3 min (green).
    private var state: SubwayState {
        func r(_ l: String, _ d: String, _ min: Double) -> SubwayState.Row {
            .init(line: l, dest: d, mins: Int(min), verdict: "", sched: false, arrive: now + min * 60)
        }
        return SubwayState(station: "Myrtle Av", walkMin: 4, walkSec: 240, rows: [
            r("J", "Broad St", 4), r("M", "Middle Village-Metropolitan Av", 5),
            r("J", "Jamaica Center-Parsons/Archer", 7), r("M", "Forest Hills-71 Av", 10),
        ], ts: now)
    }

    private func alerts() -> [SubwayState.Alert] {
        [.init(line: "J", kind: "delays", severe: false, since: now - 12 * 60, active: true, ended: nil, text: "t"),
         .init(line: "M", kind: "suspended", severe: true, since: now - 3 * 60, active: true, ended: nil, text: "t"),
         .init(line: "Z", kind: "delays", severe: false, since: now - 40 * 60, active: false, ended: now - 8 * 60, text: "t")]
    }

    private func render<V: View>(_ content: V, size: CGSize, radius: CGFloat, dark: Bool, name: String) throws {
        let palette = SubwayPalette(dark: dark)
        let view = content
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height)
            .background(palette.bg)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .padding(10)
            .background(dark ? Color(white: 0.2) : Color(red: 0.75, green: 0.78, blue: 0.82))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage, "ImageRenderer returned no image for \(name)")
        XCTAssertGreaterThan(image.size.width, size.width)
        let png = try XCTUnwrap(image.pngData())
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try png.write(to: outDir.appendingPathComponent("\(name).png"))
        let att = XCTAttachment(image: image)
        att.name = name
        att.lifetime = .keepAlways
        add(att)
        XCTAssertGreaterThan(distinctColors(image), 40, "\(name) looks blank")
    }

    private func distinctColors(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var seen = Set<UInt32>()
        for i in stride(from: 0, to: buf.count, by: 4) {
            seen.insert(UInt32(buf[i]) << 16 | UInt32(buf[i + 1]) << 8 | UInt32(buf[i + 2]))
        }
        return seen.count
    }

    private func widget(_ family: WidgetFamily, state: SubwayState, at: Double? = nil) -> some View {
        SubwayWidgetContent(entry: SubwayEntry(date: Date(timeIntervalSince1970: at ?? now), state: state, error: nil), family: family)
    }

    func testWidgetsAndLiveActivityRenderLightAndDark() throws {
        for dark in [false, true] {
            let t = dark ? "dark" : "light"
            try render(widget(.systemSmall, state: state), size: CGSize(width: 170, height: 170), radius: 22, dark: dark, name: "widget_small_\(t)")
            try render(widget(.systemMedium, state: state), size: CGSize(width: 364, height: 170), radius: 22, dark: dark, name: "widget_medium_\(t)")
            try render(SubwayBoard(state: state, now: now, density: .live)
                .padding(.horizontal, 16).padding(.vertical, 12),
                       size: CGSize(width: 400, height: 160), radius: 24, dark: dark, name: "live_\(t)")
        }
    }

    /// Same Myrtle Av board with alerts: J orange, M red, Z (third row) grey; plus an ended-only footer variant.
    func testAlertRendersLightAndDark() throws {
        var s = state
        s.rows[2].line = "Z"
        s.alerts = alerts()
        var ended = state
        ended.alerts = [.init(line: "J", kind: "delays", severe: false, since: now - 40 * 60, active: false, ended: now - 8 * 60, text: "t")]
        for dark in [false, true] {
            let t = dark ? "dark" : "light"
            try render(widget(.systemSmall, state: s), size: CGSize(width: 170, height: 170), radius: 22, dark: dark, name: "alert_small_\(t)")
            try render(widget(.systemMedium, state: s), size: CGSize(width: 364, height: 170), radius: 22, dark: dark, name: "alert_medium_\(t)")
            try render(SubwayBoard(state: s, now: now, density: .live).padding(.horizontal, 16).padding(.vertical, 12),
                       size: CGSize(width: 400, height: 160), radius: 24, dark: dark, name: "alert_live_\(t)")
            try render(widget(.systemMedium, state: ended), size: CGSize(width: 364, height: 170), radius: 22, dark: dark, name: "alert_ended_medium_\(t)")
            try render(SubwayBoard(state: ended, now: now, density: .live).padding(.horizontal, 16).padding(.vertical, 12),
                       size: CGSize(width: 400, height: 160), radius: 24, dark: dark, name: "alert_ended_live_\(t)")
        }
    }

    /// The Superapp's Subway screen on the real Myrtle Av all=1 response: all trains, chips (J hidden, M pending), alerts.
    func testSubwayScreenRendersLightAndDark() throws {
        let s = try JSONDecoder().decode(SubwayState.self, from: fixture("nearby_all.json"))
        var hiddenJ = s
        hiddenJ.lines[0].hidden = true
        hiddenJ.rows = hiddenJ.rows.filter { $0.line != "J" }
        for dark in [false, true] {
            let t = dark ? "dark" : "light"
            try render(SubwayScreenContent(state: s, now: s.ts).padding(16),
                       size: CGSize(width: 390, height: 1500), radius: 0, dark: dark, name: "screen_\(t)")
            try render(SubwayScreenContent(state: hiddenJ, now: s.ts, pending: ["M"], offlineSince: s.ts - 7 * 60).padding(16),
                       size: CGSize(width: 390, height: 900), radius: 0, dark: dark, name: "screen_filtered_offline_\(t)")
        }
    }

    /// Live Activity with the line chips (lock screen size), J visible and J hidden, with and without an alert.
    func testLiveActivityChipsRenderLightAndDark() throws {
        var s = try JSONDecoder().decode(SubwayState.self, from: fixture("nearby_all.json"))
        s.rows = s.topPerLine
        var hidden = s
        hidden.lines[0].hidden = true
        hidden.rows = hidden.rows.filter { $0.line != "J" }
        var noAlert = s
        noAlert.alerts = []
        for dark in [false, true] {
            let t = dark ? "dark" : "light"
            for (name, st) in [("alert", s), ("hiddenJ", hidden), ("plain", noAlert)] {
                try render(SubwayBoard(state: st, now: s.ts, density: .live, chips: true).padding(.horizontal, 16).padding(.vertical, 12),
                           size: CGSize(width: 400, height: 160), radius: 24, dark: dark, name: "live_chips_\(name)_\(t)")
            }
        }
    }

    /// Real Times Sq response (24 rows, long names): must render too.
    func testRealTimesSqFixtureRenders() throws {
        let s = try JSONDecoder().decode(SubwayState.self, from: fixture("nearby_update.json"))
        var shifted = s
        shifted.walkSec = 240
        shifted.walkMin = 4
        try render(widget(.systemSmall, state: shifted, at: s.ts), size: CGSize(width: 170, height: 170), radius: 22, dark: false, name: "real_small_light")
    }
}
