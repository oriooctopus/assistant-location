import XCTest

// Real-device UI test (runs on AWS Device Farm hardware).
//
// SCOPE — READ THIS BEFORE TRUSTING A PASS. This covers only the second
// half of the Control path: notification -> handler -> selectJournalTab ->
// beginRecordingFlow -> startRecording. It launches the app with
// UITEST_JOURNAL_AUTOSTART set and posts GLJournalStartCapture from inside
// the app (SceneDelegate -sceneDidBecomeActive:).
//
// It CANNOT cover how that notification comes to be posted from a real
// Control tap, because XCUITest can't reach Control Center. That gap hid a
// real bug for days: the Controls used to post the notification from an
// AppIntent's perform(), which runs in the WIDGET EXTENSION's process, so
// the app never received it — while this test kept passing, because it
// posts the notification in-process and never crosses that boundary. The
// Controls now open a URL instead (see JournalIntent.swift), routed via
// SceneDelegate -> AutoJournalModule +moduleHandleURL:.
//
// So: a pass here means "the in-app half still works", NOT "the Control
// works". The cross-process hop is only verifiable by tapping the real
// Control on a real device.
final class JournalControlUITest: XCTestCase {

    func testControlCenterCaptureStartsRecording() {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_JOURNAL_AUTOSTART"] = "1"

        // Auto-tap the system microphone permission alert when it appears
        // (same pattern as LocationPermissionUITest's location alert).
        addUIInterruptionMonitor(withDescription: "Microphone Permission") { alert in
            for label in ["OK", "Allow"] {
                let btn = alert.buttons[label]
                if btn.exists { btn.tap(); return true }
            }
            return false
        }

        app.launch()

        // Nudge the run loop so the interruption monitor fires against the
        // alert, then give the SceneDelegate delay + AVAudioSession +
        // AVAudioRecorder time to actually start.
        sleep(2)
        app.tap()
        sleep(1)

        // Also handle it directly via SpringBoard, in case the monitor missed it.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["OK", "Allow"] {
            let btn = springboard.buttons[label]
            if btn.waitForExistence(timeout: 3) { btn.tap(); break }
        }

        let statusLabel = app.staticTexts["AutoJournalStatusLabel"]
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 10),
                       "AutoJournalStatusLabel should exist once the journal tab is selected")

        // Poll for the label text to flip from the idle state to "Recording…"
        // (or an error state reachable only once startRecording actually
        // ran), proving the notification -> handler -> AVAudioRecorder chain
        // executed, not just that the app stayed alive.
        let deadline = Date().addingTimeInterval(15)
        var lastText = statusLabel.label
        while Date() < deadline {
            lastText = statusLabel.label
            if lastText != "Tap to record" && !lastText.isEmpty {
                break
            }
            usleep(500_000)
        }

        XCTAssertNotEqual(lastText, "Tap to record",
                           "statusLabel never left the idle state; GLJournalStartCapture -> startRecording did not run")
    }
}
