import XCTest

// sim-repro: drives REAL touch input on the More page and dumps what the app
// saw (UITEST_WEB_DIAG probe views, see GLWebModuleViewController.m). Prints
// "REPRO ..." lines; asserts the intended behavior so a red test == bug present.
final class MoreReproUITest: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = true
        app.launchEnvironment["UITEST_WEB_DIAG"] = "1"
        app.launch()
        app.tabBars.buttons["More"].tap()
    }

    func probe(_ name: String) -> XCUIElement {
        app.descendants(matching: .any)["uitest-diag-" + name].firstMatch
    }

    func diag(_ name: String) -> [String: Any] {
        let el = probe(name)
        guard el.waitForExistence(timeout: 10), let v = el.value as? String,
              let d = try? JSONSerialization.jsonObject(with: Data(v.utf8)) as? [String: Any] else { return [:] }
        return d
    }

    func js(_ d: [String: Any]) -> [String: Any] { d["js"] as? [String: Any] ?? [:] }
    func native(_ d: [String: Any]) -> [String: Any] { d["native"] as? [String: Any] ?? [:] }

    func waitForTiles() -> [String: Any] {
        for _ in 0..<40 {
            let d = diag("more.html")
            if let t = js(d)["tiles"] as? [[String: Any]], t.count > 0 { Thread.sleep(forTimeInterval: 1); return diag("more.html") }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return diag("more.html")
    }

    func dump(_ label: String, _ d: [String: Any]) {
        var j = js(d); let log = j.removeValue(forKey: "log") as? [String] ?? []
        j.removeValue(forKey: "tiles")
        print("REPRO [\(label)] native=\(native(d))")
        print("REPRO [\(label)] js=\(j)")
        for l in log.suffix(25) { print("REPRO [\(label)] log: \(l)") }
    }

    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func tiles(_ d: [String: Any]) -> [[String: Any]] { js(d)["tiles"] as? [[String: Any]] ?? [] }

    // web-view-relative CSS point -> screen coordinate
    func coord(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        let web = app.webViews.firstMatch
        return web.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    func testBug1_scroll() {
        var d = waitForTiles()
        dump("scroll/initial", d)
        shot("scroll-0-initial")
        let ts = tiles(d)
        XCTAssertGreaterThan(ts.count, 0, "no tiles rendered")
        let web = app.webViews.firstMatch
        print("REPRO webView frame=\(web.frame) app frame=\(app.frame)")
        let ih = js(d)["innerHeight"] as? CGFloat ?? 600
        let sh = js(d)["scrollHeight"] as? CGFloat ?? 0
        print("REPRO scrollHeight=\(sh) innerHeight=\(ih) -> content taller than viewport: \(sh > ih)")

        func dragUp(_ label: String, x: CGFloat, fromY: CGFloat, toY: CGFloat) {
            let before = js(diag("more.html"))["scrollY"] as? CGFloat ?? -1
            coord(x, fromY).press(forDuration: 0.05, thenDragTo: coord(x, toY), withVelocity: .slow, thenHoldForDuration: 0)
            Thread.sleep(forTimeInterval: 2.5)
            d = diag("more.html")
            let after = js(d)["scrollY"] as? CGFloat ?? -1
            print("REPRO drag[\(label)] x=\(x) \(fromY)->\(toY) scrollY \(before) -> \(after) contentOffsetY=\(native(d)["contentOffsetY"] ?? "?") maxOffsetY=\(native(d)["maxOffsetY"] ?? "?")")
            dump("scroll/after-\(label)", d)
            shot("scroll-\(label)")
        }

        // pick a point ON a tile (row 2, left) and a point in a GUTTER between columns
        let t = ts.count > 1 ? ts[1] : ts[0]
        let tx = (t["x"] as! CGFloat) + (t["w"] as! CGFloat) / 2
        let ty = (t["y"] as! CGFloat) + (t["h"] as! CGFloat) / 2
        let gx = (t["x"] as! CGFloat) + (t["w"] as! CGFloat) + 6  // 12px gutter centre
        dragUp("on-tile", x: tx, fromY: min(ty, ih - 40), toY: max(min(ty, ih - 40) - 300, 20))
        XCTAssertGreaterThan(native(d)["maxOffsetY"] as? Double ?? 0, 0, "ON-TILE drag did not scroll")
        // reset to top
        coord(tx, 60).press(forDuration: 0.05, thenDragTo: coord(tx, ih - 40), withVelocity: .slow, thenHoldForDuration: 0)
        Thread.sleep(forTimeInterval: 1)
        dragUp("in-gutter", x: gx, fromY: min(ty, ih - 40), toY: max(min(ty, ih - 40) - 300, 20))
        // stock fast flick
        web.swipeUp()
        Thread.sleep(forTimeInterval: 2.5)
        d = diag("more.html")
        print("REPRO swipeUp() scrollY=\(js(d)["scrollY"] ?? "?") contentOffsetY=\(native(d)["contentOffsetY"] ?? "?") maxOffsetY=\(native(d)["maxOffsetY"] ?? "?")")
        dump("scroll/after-swipeUp", d)
        shot("scroll-swipeUp")
        let maxY = (native(d)["maxOffsetY"] as? Double) ?? 0
        let maxScrollY = (js(d)["scrollY"] as? Double) ?? 0
        XCTAssertTrue(sh <= ih || maxY > 0 || maxScrollY > 0, "content taller than viewport (\(sh) > \(ih)) but no scroll happened")
    }

    func testBug2_holdGrowth() {
        var d = waitForTiles()
        dump("hold/initial", d)
        guard let g = tiles(d).first(where: { ($0["id"] as? String) == "GLModule.GrowthModule" }) else {
            XCTFail("no Growth tile in DOM"); return
        }
        let ih = js(d)["innerHeight"] as? CGFloat ?? 600
        let top = g["y"] as! CGFloat, h = g["h"] as! CGFloat
        let gx = (g["x"] as! CGFloat) + (g["w"] as! CGFloat) / 2
        let visTop = max(top, 0), visBottom = min(top + h, ih)
        print("REPRO growth tile rect=\(g) visible y-range=\(visTop)...\(visBottom) innerHeight=\(ih)")
        XCTAssertGreaterThan(visBottom - visTop, 20, "Growth tile not reachable on screen without scrolling")
        let gy = (visTop + visBottom) / 2
        shot("hold-0-before")
        coord(gx, gy).press(forDuration: 0.8)
        Thread.sleep(forTimeInterval: 3)
        shot("hold-1-after")
        dump("hold/after-press", diag("more.html"))
        let gd = diag("GrowthViewController")
        print("REPRO growth VC diag native=\(native(gd))")
        let webURL = native(gd)["webURL"] as? String ?? "(no Growth VC diag: Growth was not opened)"
        print("REPRO growth webURL after hold = \(webURL)")
        XCTAssertTrue(webURL.contains("demo=1"), "hold did not open Growth in demo mode: \(webURL)")
    }

    func testBug2_control_tapGrowth() {
        let d = waitForTiles()
        guard let g = tiles(d).first(where: { ($0["id"] as? String) == "GLModule.GrowthModule" }) else { XCTFail("no Growth tile"); return }
        let ih = js(d)["innerHeight"] as? CGFloat ?? 600
        let visTop = max(g["y"] as! CGFloat, 0), visBottom = min((g["y"] as! CGFloat) + (g["h"] as! CGFloat), ih)
        coord((g["x"] as! CGFloat) + (g["w"] as! CGFloat) / 2, (visTop + visBottom) / 2).tap()
        Thread.sleep(forTimeInterval: 3)
        dump("tap/after-tap", diag("more.html"))
        let gd = diag("GrowthViewController")
        print("REPRO control tap: growth webURL = \(native(gd)["webURL"] ?? "(Growth not opened)")")
        XCTAssertNotNil(native(gd)["webURL"], "plain tap did not open Growth")
    }

    // Phone scenario: stale cache seeded, server has current pages. The
    // background check must promote AND (with the fix) reload the live page.
    func testStaleCacheHealsWithoutRelaunch() {
        var d = diag("more.html")
        var healed = false
        for i in 0..<30 {   // up to ~45s
            d = diag("more.html")
            print("REPRO heal-poll[\(i)] loadCount=\(native(d)["loadCount"] ?? "?") hasGrowthId=\(js(d)["hasGrowthId"] ?? "?") url=\((native(d)["url"] as? String ?? "").suffix(60))")
            if (js(d)["hasGrowthId"] as? Bool) == true { healed = true; break }
            Thread.sleep(forTimeInterval: 1.5)
        }
        let url = native(d)["url"] as? String ?? ""
        print("REPRO (1) loaded from cache=\(url.contains("WebPagesCache/current")) hasGrowthId=\(healed) loadCount=\(native(d)["loadCount"] ?? "?")")
        XCTAssertTrue(url.contains("WebPagesCache/current"), "page not from WebPagesCache/current: \(url)")
        XCTAssertTrue(healed, "(1) live page never picked up the promoted more.html (no GROWTH_ID)")
        d = waitForTiles()
        let ts = tiles(d)
        guard ts.count > 1 else { XCTFail("no tiles"); return }
        let ih = js(d)["innerHeight"] as? CGFloat ?? 600
        let t = ts[1]
        let tx = (t["x"] as! CGFloat) + (t["w"] as! CGFloat) / 2
        let ty = min((t["y"] as! CGFloat) + (t["h"] as! CGFloat) / 2, ih - 40)
        coord(tx, ty).press(forDuration: 0.05, thenDragTo: coord(tx, max(ty - 300, 20)), withVelocity: .slow, thenHoldForDuration: 0)
        Thread.sleep(forTimeInterval: 2.5)
        d = diag("more.html")
        let sy = js(d)["scrollY"] as? Double ?? 0
        print("REPRO (2) on-tile drag scrollY=\(sy)")
        XCTAssertGreaterThan(sy, 0, "(2) on-tile drag did not scroll")
        // reset to top, then hold Growth
        coord(tx, 60).press(forDuration: 0.05, thenDragTo: coord(tx, ih - 40), withVelocity: .slow, thenHoldForDuration: 0)
        Thread.sleep(forTimeInterval: 2.5)
        d = diag("more.html")
        guard let g = tiles(d).first(where: { ($0["id"] as? String) == "GLModule.GrowthModule" }) else { XCTFail("no Growth tile"); return }
        let vt = max(g["y"] as! CGFloat, 0), vb = min((g["y"] as! CGFloat) + (g["h"] as! CGFloat), ih)
        coord((g["x"] as! CGFloat) + (g["w"] as! CGFloat) / 2, (vt + vb) / 2).press(forDuration: 0.8)
        Thread.sleep(forTimeInterval: 3)
        let gd = diag("GrowthViewController")
        let webURL = native(gd)["webURL"] as? String ?? "(Growth not opened)"
        print("REPRO (3) growth webURL after hold = \(webURL)")
        XCTAssertTrue(webURL.contains("demo=1"), "(3) hold did not open Growth in demo mode: \(webURL)")
    }
}
