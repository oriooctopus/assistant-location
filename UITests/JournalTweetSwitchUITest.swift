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

        let tweetSwitch = app.switches["AutoJournalTweetSwitch"]
        XCTAssertTrue(tweetSwitch.waitForExistence(timeout: 5), "AutoJournalTweetSwitch should exist while recording")

        // XCUIElement.value for a UISwitch is "0" or "1" -- standard XCTest
        // behavior for UISwitch, not a project-specific quirk, so this is
        // asserted directly rather than probed first.
        XCTAssertEqual(tweetSwitch.value as? String, "0", "switch should start off")

        tweetSwitch.tap()
        let armedDeadline = Date().addingTimeInterval(5)
        while Date() < armedDeadline && statusLabel.label != "Recording tweet…" {
            usleep(200_000)
        }
        XCTAssertEqual(statusLabel.label, "Recording tweet…",
                        "status text should switch to \"Recording tweet…\" once the switch is armed mid-recording")
        XCTAssertEqual(tweetSwitch.value as? String, "1")

        tweetSwitch.tap()
        let disarmedDeadline = Date().addingTimeInterval(5)
        while Date() < disarmedDeadline && statusLabel.label != "Recording…" {
            usleep(200_000)
        }
        XCTAssertEqual(statusLabel.label, "Recording…",
                        "status text should return to plain \"Recording…\" once the switch is disarmed")
        XCTAssertEqual(tweetSwitch.value as? String, "0")
    }
}
