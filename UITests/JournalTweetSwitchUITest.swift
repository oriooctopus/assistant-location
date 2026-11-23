import XCTest

// Real-device UI test (runs on AWS Device Farm hardware). Covers the "Save as
// tweet" switch added to AutoJournalViewController (mockup-recording-option-3):
// toggling it while recording should flip the live status text between
// "Recording…" and "Recording tweet…" (see -updateTweetRecordingIndicator /
// -tweetSwitchChanged: in AutoJournalViewController.m).
//
// SCOPE — READ THIS BEFORE TRUSTING A PASS. This only proves the LIVE UI
// reaction to the switch (AutoJournalTweetSwitch -> statusLabel text). It does
// NOT prove the upload-time filename tag ("journal-voice-tweet-...") or the
// one-shot reset-on-success, because GL_BAKED_HOST is unbaked in this CI build
// (see other comments in this target) so a real /drop upload has nowhere to
// go -- there is no server for the app to actually reach from a Device Farm
// device or the simulator here. That upload-time behavior is covered instead
// by this repo's location-server test_recents.mjs suite reading the real
// filename contract on a real (test) server, and by direct code review of
// -uploadFileAtPath:isVoice:isTweet:titleSlug:timestamp:onSuccess:.
//
// Reuses JournalControlUITest's own launch path (UITEST_JOURNAL_AUTOSTART)
// rather than tapping the tab bar directly -- there is no established
// tab-bar-navigation pattern elsewhere in this UI test target to build on,
// and this env var already lands reliably on the Journal tab mid-recording,
// which is exactly the state this test needs.
final class JournalTweetSwitchUITest: XCTestCase {

    func testTweetSwitchTogglesRecordingIndicatorText() {
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
        // uses) before touching the switch -- the "Recording tweet…" text this
        // test checks for only ever appears while recordingState == Recording.
        let recordingDeadline = Date().addingTimeInterval(15)
        while Date() < recordingDeadline && statusLabel.label == "Tap to record" {
            usleep(500_000)
        }
        XCTAssertNotEqual(statusLabel.label, "Tap to record",
                           "recording never started; nothing to assert the tweet switch against")

        // Option E: while recording the switches live in the settings sheet behind the quiet summary line.
        // The sheet covers the status label, so each flip closes the sheet before reading the status text.
        func flipTweetSwitch() -> String? {
            let summary = app.buttons["AutoJournalSummaryLine"]
            XCTAssertTrue(summary.waitForExistence(timeout: 5), "summary line should show while recording")
            summary.tap()
            let tweetSwitch = app.switches["AutoJournalTweetSwitch"]
            XCTAssertTrue(tweetSwitch.waitForExistence(timeout: 5), "AutoJournalTweetSwitch should exist in the settings sheet")
            tweetSwitch.tap()
            let value = tweetSwitch.value as? String
            app.buttons["AutoJournalSettingsDone"].tap()
            return value
        }

        XCTAssertEqual(app.buttons["AutoJournalSummaryLine"].label, "Title (optional)", "switch starts off, so no Tweet suffix")

        XCTAssertEqual(flipTweetSwitch(), "1")
        let armedDeadline = Date().addingTimeInterval(5)
        while Date() < armedDeadline && statusLabel.label != "Recording tweet…" {
            usleep(200_000)
        }
        XCTAssertEqual(statusLabel.label, "Recording tweet…",
                        "status text should switch to \"Recording tweet…\" once the switch is armed mid-recording")
        XCTAssertEqual(app.buttons["AutoJournalSummaryLine"].label, "Title (optional) \u{00B7} Tweet")

        XCTAssertEqual(flipTweetSwitch(), "0")
        let disarmedDeadline = Date().addingTimeInterval(5)
        while Date() < disarmedDeadline && statusLabel.label != "Recording…" {
            usleep(200_000)
        }
        XCTAssertEqual(statusLabel.label, "Recording…",
                        "status text should return to plain \"Recording…\" once the switch is disarmed")
        XCTAssertEqual(app.buttons["AutoJournalSummaryLine"].label, "Title (optional)")

        // The recorder keeps an unsaved draft across launches; discard it so the next test starts clean.
        app.buttons["AutoJournalCancelButton"].tap()
    }
}
