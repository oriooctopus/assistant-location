import XCTest

// Journal recorder live transcript preview. The simulator has no microphone, so the app is launched with
// UITEST_JOURNAL_LIVE_TEXT / UITEST_JOURNAL_LIVE_PT (see -startLiveTranscript in AutoJournalViewController.m):
// the display shows that text while the real AVAudioEngine + SFSpeechRecognizer path still starts next to the
// AVAudioRecorder and logs whether it coexists ("live transcript probe" lines in app.log).
//
// Proves the layout: the live line and the PT line show while recording, and the Cancel / Save row and the
// attach row stay below them. The screenshot lands in /tmp/journal-live-shots for the workflow to upload.
final class JournalLiveTextUITest: XCTestCase {

    func testLiveAndPTLinesShowWhileRecording() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_JOURNAL_AUTOSTART"] = "1"
        app.launchEnvironment["UITEST_JOURNAL_LIVE_TEXT"] =
            "so this morning I walked to the market and bought bread and some tomatoes for lunch, then I called my sister about the trip"
        app.launchEnvironment["UITEST_JOURNAL_LIVE_PT"] =
            "então esta manhã eu fui andando até o mercado e comprei pão e alguns tomates para o almoço, depois liguei para minha irmã sobre a viagem"

        addUIInterruptionMonitor(withDescription: "Microphone / Speech Permission") { alert in
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
        for _ in 0..<2 {
            for label in ["OK", "Allow"] {
                let btn = springboard.buttons[label]
                if btn.waitForExistence(timeout: 3) { btn.tap(); break }
            }
        }

        let statusLabel = app.staticTexts["AutoJournalStatusLabel"]
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 10), "journal tab never selected")

        let recordingDeadline = Date().addingTimeInterval(15)
        while Date() < recordingDeadline && statusLabel.label == "Tap to record" { usleep(500_000) }
        XCTAssertNotEqual(statusLabel.label, "Tap to record", "recording never started")

        let live = app.staticTexts["AutoJournalLiveLabel"]
        XCTAssertTrue(live.waitForExistence(timeout: 5), "live transcript line should show while recording")
        XCTAssertTrue(live.label.contains("tomatoes") || live.label.contains("sister"), "live line shows the tail of the text: \(live.label)")

        let pt = app.staticTexts["AutoJournalLivePTLabel"]
        XCTAssertTrue(pt.waitForExistence(timeout: 5), "PT line should show under the live line")
        XCTAssertTrue(pt.label.contains("irmã") || pt.label.contains("viagem"), "PT line shows the translation: \(pt.label)")

        let toggle = app.buttons["AutoJournalPTToggle"]
        XCTAssertTrue(toggle.exists, "PT toggle should sit beside the record button")

        // Nothing collides: the Cancel/Save row is below the PT line, the live block is below the status line.
        let cancel = app.buttons["AutoJournalCancelButton"]
        let save = app.buttons["AutoJournalSaveButton"]
        XCTAssertTrue(cancel.exists && save.exists)
        XCTAssertLessThanOrEqual(statusLabel.frame.maxY, live.frame.minY + 1, "live line starts below the status line")
        XCTAssertLessThanOrEqual(live.frame.maxY, pt.frame.minY + 1, "PT line starts below the live line")
        XCTAssertLessThanOrEqual(pt.frame.maxY, cancel.frame.minY + 1, "Cancel starts below the PT line")
        XCTAssertLessThanOrEqual(pt.frame.maxY, save.frame.minY + 1, "Save starts below the PT line")
        let screen = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(save.frame.maxY, screen.maxY, "Save is on screen")
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.exists)
        XCTAssertLessThanOrEqual(save.frame.maxY, tabBar.frame.minY, "Save is not hidden behind the tab bar")
        XCTAssertLessThanOrEqual(cancel.frame.maxY, tabBar.frame.minY, "Cancel is not hidden behind the tab bar")

        let png = XCUIScreen.main.screenshot()
        let dir = "/tmp/journal-live-shots"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try png.pngRepresentation.write(to: URL(fileURLWithPath: dir + "/journal-live.png"))
        let attachment = XCTAttachment(screenshot: png)
        attachment.name = "journal-live"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
