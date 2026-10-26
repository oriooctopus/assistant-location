import XCTest

// Real-device UI test. Covers the "About Esme" switch (AutoJournalEsmeSwitch)
// under "Save as tweet" in AutoJournalViewController: it exists and toggles.
// Like JournalTweetSwitchUITest this cannot prove the upload-time "-esme-"
// filename marker (GL_BAKED_HOST is unbaked in CI); that contract is covered
// by location-server's test_server.mjs. Reuses UITEST_JOURNAL_AUTOSTART to
// land on the Journal tab.
final class JournalEsmeSwitchUITest: XCTestCase {

    func testEsmeSwitchExistsAndToggles() {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_JOURNAL_AUTOSTART"] = "1"

        addUIInterruptionMonitor(withDescription: "Microphone Permission") { alert in
            for label in ["OK", "Allow"] {
                let btn = alert.buttons[label]
                if btn.exists { btn.tap(); return true }
            }
            return false
        }

        app.launch()

        sleep(2)
        app.tap()
        sleep(1)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["OK", "Allow"] {
            let btn = springboard.buttons[label]
            if btn.waitForExistence(timeout: 3) { btn.tap(); break }
        }

        let statusLabel = app.staticTexts["AutoJournalStatusLabel"]
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 10),
                       "AutoJournalStatusLabel should exist once the journal tab is selected")

        // Wait for recording to actually start (same poll JournalControlUITest
        // uses) before touching the switch -- the recording state this
        // test relies on only exists while recordingState == Recording.
        let recordingDeadline = Date().addingTimeInterval(15)
        while Date() < recordingDeadline && statusLabel.label == "Tap to record" {
            usleep(500_000)
        }
        XCTAssertNotEqual(statusLabel.label, "Tap to record",
                           "recording never started; nothing to assert the Esme switch against")

        let esmeSwitch = app.switches["AutoJournalEsmeSwitch"]
        XCTAssertTrue(esmeSwitch.waitForExistence(timeout: 5), "AutoJournalEsmeSwitch should exist")
        XCTAssertEqual(esmeSwitch.value as? String, "0", "switch should start off")

        esmeSwitch.tap()
        XCTAssertEqual(esmeSwitch.value as? String, "1")

        esmeSwitch.tap()
        XCTAssertEqual(esmeSwitch.value as? String, "0")
    }
}
