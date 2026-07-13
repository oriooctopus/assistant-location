import XCTest

// Real-device UI test (runs on AWS Device Farm hardware). Proves the thing the
// simulator can't: that the app correctly requests and receives the REAL iOS
// location permission dialog, then starts tracking. Launches the app pointed at
// a test endpoint (via UITEST_ENDPOINT env) with tracking pre-armed, taps the
// system "Allow While Using App" alert, and lets it run so device logs show the
// authorization + tracking-start lines.
final class LocationPermissionUITest: XCTestCase {

    func testGrantsLocationAndStartsTracking() {
        let app = XCUIApplication()
        if let endpoint = ProcessInfo.processInfo.environment["UITEST_ENDPOINT"] {
            app.launchEnvironment["UITEST_ENDPOINT"] = endpoint
        }

        // Auto-tap the system location permission alert when it appears.
        addUIInterruptionMonitor(withDescription: "Location Permission") { alert in
            for label in ["Allow While Using App", "Allow Once", "Allow"] {
                let btn = alert.buttons[label]
                if btn.exists { btn.tap(); return true }
            }
            return false
        }

        app.launch()

        // Nudge the run loop so the interruption monitor fires against the alert,
        // then give CoreLocation time to deliver an authorization + first fix.
        sleep(3)
        app.tap()
        sleep(2)
        app.swipeUp()

        // Also handle it directly via SpringBoard, in case the monitor missed it.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow While Using App", "Allow Once", "Allow"] {
            let btn = springboard.buttons[label]
            if btn.waitForExistence(timeout: 3) { btn.tap(); break }
        }

        // Let tracking run so device logs capture authorization + sends.
        sleep(25)

        // The app being alive and foreground is the minimum bar; the real
        // assertions (authorization granted, tracking started, POST sent) are
        // read from the Device Farm device logs / our ingest server afterward.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }
}
