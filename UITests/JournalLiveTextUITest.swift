import XCTest

// Journal recorder live transcript preview. The simulator has no microphone, so the app is launched with
// UITEST_JOURNAL_LIVE_TEXT / UITEST_JOURNAL_LIVE_PT (see -startLiveTranscript in AutoJournalViewController.m):
// the display shows that text while the real AVAudioEngine + SFSpeechRecognizer path still starts next to the
// AVAudioRecorder and logs whether it coexists ("live transcript probe" lines in app.log).
//
// Proves the layout: the live line and the PT line show while recording, the Cancel / Save row and the attach
// row stay below them, and a 1-line preview leaves everything exactly where a 2-line one does. Screenshots land
// in /tmp/journal-live-shots for the workflow to upload.
final class JournalLiveTextUITest: XCTestCase {

    private let longEN = "so this morning I walked to the market and bought bread and some tomatoes for lunch, then I called my sister about the trip"
    private let longPT = "então esta manhã eu fui andando até o mercado e comprei pão e alguns tomates para o almoço, depois liguei para minha irmã sobre a viagem"

    private func shot(_ name: String) throws {
        let png = XCUIScreen.main.screenshot()
        let dir = "/tmp/journal-live-shots"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try png.pngRepresentation.write(to: URL(fileURLWithPath: dir + "/" + name + ".png"))
        let attachment = XCTAttachment(screenshot: png)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // Launches with the injected text, taps the header (which triggers the permission monitor and the
    // autostart), and waits until recording is under way.
    private func launchRecording(en: String, pt: String) -> XCUIApplication {
        let app = XCUIApplication()
        // Skips the launcher's full-photo-library alert, which otherwise covers the header (see GLWebBridge withPhotoLibraryAccess).
        app.launchArguments += ["-UITestSkipPhotoPrompt", "YES"]
        app.launchEnvironment["UITEST_JOURNAL_AUTOSTART"] = "1"
        app.launchEnvironment["UITEST_JOURNAL_LIVE_TEXT"] = en
        app.launchEnvironment["UITEST_JOURNAL_LIVE_PT"] = pt
        // The sim mic is silent; this looped dB list drives the level meter (see -sampleLevel).
        app.launchEnvironment["UITEST_JOURNAL_LEVELS"] = "-50,-38,-25,-12,-6,-20,-34,-45,-15,-8,-30,-42"

        addUIInterruptionMonitor(withDescription: "Microphone / Speech Permission") { alert in
            // The app also asks for location right after the mic; run 44978986928 died on that unhandled alert.
            for label in ["OK", "Allow", "Allow While Using App", "Keep Only While Using"] {
                let btn = alert.buttons[label]
                if btn.exists { btn.tap(); return true }
            }
            return false
        }

        app.launch()

        sleep(2)
        // Tap the header, not the window centre: the centre is now the "+ Add Photo" row, which raised a Photos prompt.
        app.staticTexts["AutoJournalHeaderTitle"].tap()
        sleep(1)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            for label in ["OK", "Allow", "Allow While Using App", "Keep Only While Using"] {
                let btn = springboard.buttons[label]
                if btn.waitForExistence(timeout: 3) { btn.tap(); break }
            }
        }

        let statusLabel = app.staticTexts["AutoJournalStatusLabel"]
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 10), "journal tab never selected")

        let recordingDeadline = Date().addingTimeInterval(15)
        while Date() < recordingDeadline && statusLabel.label == "Tap to record" { usleep(500_000) }
        XCTAssertNotEqual(statusLabel.label, "Tap to record", "recording never started")
        return app
    }

    // The recorder keeps an unsaved draft across launches (run 44980544247: tests 2 and 3 came up on a paused
    // "Unsaved recording" instead of autostarting). Every test discards its draft so the next starts clean.
    private func discardDraft(_ app: XCUIApplication) {
        let cancel = app.buttons["AutoJournalCancelButton"]
        if cancel.exists { cancel.tap() }
    }

    func testLiveAndPTLinesShowWhileRecording() throws {
        let app = launchRecording(en: longEN, pt: longPT)
        defer { discardDraft(app) }
        let statusLabel = app.staticTexts["AutoJournalStatusLabel"]

        let live = app.staticTexts["AutoJournalLiveLabel"]
        XCTAssertTrue(live.waitForExistence(timeout: 5), "live transcript line should show while recording")
        XCTAssertTrue(live.label.contains("tomatoes") || live.label.contains("sister"), "live line shows the tail of the text: \(live.label)")

        let pt = app.staticTexts["AutoJournalLivePTLabel"]
        XCTAssertTrue(pt.waitForExistence(timeout: 5), "PT line should show under the live line")
        XCTAssertTrue(pt.label.contains("irmã") || pt.label.contains("viagem"), "PT line shows the translation: \(pt.label)")
        // The injected PT is longer than two lines. It must arrive already cut to its tail: a multi-line UILabel
        // head-truncates only its last line, which drew "…mercado e …almoço" mid-text (sim screenshot, 2026-11-21).
        XCTAssertTrue(pt.label.hasPrefix("…") && pt.label.components(separatedBy: "…").count == 2,
                      "PT line is the tail with one leading ellipsis: \(pt.label)")

        // Option E layout: record button centred, photo icon left and PT chip right of it, captions below,
        // Cancel / Save pinned at the bottom above the tab bar. Shots are taken BEFORE the assertions so a
        // failing layout still leaves a picture.
        try shot("journal-e-recording-pt")

        let record = app.buttons["AutoJournalRecordButton"]
        let photo = app.buttons["AutoJournalPhotoButton"]
        let toggle = app.buttons["AutoJournalPTToggle"]
        let cancel = app.buttons["AutoJournalCancelButton"]
        let save = app.buttons["AutoJournalSaveButton"]
        XCTAssertTrue(photo.exists && toggle.exists && cancel.exists && save.exists)
        XCTAssertLessThanOrEqual(photo.frame.maxX, record.frame.minX, "photo icon is left of the record button")
        XCTAssertGreaterThanOrEqual(toggle.frame.minX, record.frame.maxX - 1, "PT chip is right of the record button")
        XCTAssertGreaterThanOrEqual(photo.frame.width, 44, "photo icon is at least a 44pt target")
        XCTAssertGreaterThanOrEqual(photo.frame.height, 44)
        XCTAssertGreaterThanOrEqual(cancel.frame.height, 44, "Cancel is at least a 44pt target")
        XCTAssertGreaterThanOrEqual(save.frame.height, 44, "Save is at least a 44pt target")

        let summary = app.buttons["AutoJournalSummaryLine"]
        XCTAssertTrue(summary.exists, "summary line replaces the title/switch block while recording")
        XCTAssertEqual(summary.label, "Title (optional)")
        XCTAssertFalse(app.switches["AutoJournalTweetSwitch"].exists, "switches are collapsed into the sheet while recording")

        // Nothing collides: captions are below the record button, Cancel / Save below the captions.
        XCTAssertGreaterThanOrEqual(live.frame.minY, record.frame.maxY - 1, "captions start below the record button")
        XCTAssertLessThanOrEqual(live.frame.maxY, pt.frame.minY + 1, "PT line starts below the live line")
        XCTAssertLessThanOrEqual(pt.frame.maxY, cancel.frame.minY + 1, "Cancel starts below the PT line")
        XCTAssertLessThanOrEqual(pt.frame.maxY, save.frame.minY + 1, "Save starts below the PT line")
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.exists)
        XCTAssertLessThanOrEqual(save.frame.maxY, tabBar.frame.minY, "Save is not hidden behind the tab bar")
        XCTAssertLessThanOrEqual(cancel.frame.maxY, tabBar.frame.minY, "Cancel is not hidden behind the tab bar")

        // Level meter: beside the timer (above the record button), small.
        let meter = app.descendants(matching: .any)["AutoJournalLevelMeter"]
        XCTAssertTrue(meter.waitForExistence(timeout: 5), "level meter should show while recording")
        XCTAssertLessThanOrEqual(meter.frame.maxY, record.frame.minY, "meter sits above the record button, beside the timer")
        XCTAssertEqual(meter.frame.height, 28, accuracy: 1, "meter is ~28pt tall")
        XCTAssertLessThanOrEqual(meter.frame.width, 60, "meter is small now")

        // Paused: the record button and Cancel / Save must not move or resize.
        let recordFrame = record.frame
        let cancelFrame = cancel.frame
        record.tap()
        let pausedDeadline = Date().addingTimeInterval(8)
        while Date() < pausedDeadline && statusLabel.label != "Paused" { usleep(300_000) }
        XCTAssertEqual(statusLabel.label, "Paused")
        try shot("journal-e-paused")
        XCTAssertEqual(record.frame, recordFrame, "record button does not move or resize on pause")
        XCTAssertEqual(cancel.frame, cancelFrame, "Cancel does not move on pause")
        XCTAssertTrue(summary.exists, "summary line stays while paused")

        // Settings sheet: opens from the summary line, edits flow back into it.
        summary.tap()
        let tweet = app.switches["AutoJournalTweetSwitch"]
        XCTAssertTrue(tweet.waitForExistence(timeout: 5), "settings sheet shows Save as tweet")
        XCTAssertTrue(app.switches["AutoJournalEsmeSwitch"].exists, "settings sheet shows About Esme")
        XCTAssertTrue(app.textFields["AutoJournalTitleField"].exists, "settings sheet shows the title field")
        try shot("journal-e-settings-sheet")
        tweet.tap()
        app.buttons["AutoJournalSettingsDone"].tap()
        XCTAssertEqual(summary.label, "Title (optional) \u{00B7} Tweet", "summary line reflects the switch")
    }

    // Idle screen of Option E: title field + both switches as before, the 96pt record button with the photo
    // icon and PT chip beside it, no Cancel / Save.
    func testIdleShot() throws {
        let app = XCUIApplication()
        // Skips the launcher's full-photo-library alert, which otherwise covers the header (see GLWebBridge withPhotoLibraryAccess).
        app.launchArguments += ["-UITestSkipPhotoPrompt", "YES"]
        app.launch()
        sleep(2)
        let header = app.staticTexts["AutoJournalHeaderTitle"]
        let tab = app.tabBars.buttons["Journal"]
        if !header.exists && tab.exists { tab.tap() }
        XCTAssertTrue(header.waitForExistence(timeout: 10), "journal tab not shown")
        try shot("journal-e-idle")
        XCTAssertTrue(app.buttons["AutoJournalPhotoButton"].exists)
        XCTAssertTrue(app.buttons["AutoJournalPTToggle"].exists)
        XCTAssertFalse(app.buttons["AutoJournalSummaryLine"].exists, "summary line only while recording")
        XCTAssertFalse(app.buttons["AutoJournalRetryButton"].exists)
    }

    // Dark appearance while recording (only changes the shot when the app theme follows the system).
    func testDarkRecordingShot() throws {
        let app = launchRecording(en: longEN, pt: longPT)
        defer { XCUIDevice.shared.appearance = .light; discardDraft(app) }
        XCUIDevice.shared.appearance = .dark
        sleep(1)
        try shot("journal-e-dark-recording")
        XCTAssertTrue(app.buttons["AutoJournalSummaryLine"].exists)
    }

    func testPTOffShowsOnlyEnglish() throws {
        let app = launchRecording(en: longEN, pt: longPT)
        defer { discardDraft(app) }
        let toggle = app.buttons["AutoJournalPTToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        sleep(1)
        XCTAssertEqual(toggle.value as? String, "off")
        XCTAssertFalse(app.staticTexts["AutoJournalLivePTLabel"].isHittable, "PT line hidden when PT is off")
        XCTAssertTrue(app.staticTexts["AutoJournalLiveLabel"].exists)
        try shot("journal-live-ptoff")
    }

    // Stability: a 1-line and a 2-line preview leave Cancel / Save / the record button / the status line and
    // the top of the PT line exactly where they are (the PT label's own height legitimately differs).
    func testShortAndLongTextLeaveLayoutIdentical() throws {
        var frames: [[CGRect]] = []
        var ptTops: [CGFloat] = []
        for (en, pt) in [("so this morning", "então esta manhã"), (longEN, longPT)] {
            let app = launchRecording(en: en, pt: pt)
            frames.append([app.buttons["AutoJournalCancelButton"].frame,
                           app.buttons["AutoJournalSaveButton"].frame,
                           app.buttons["AutoJournalRecordButton"].frame,
                           app.staticTexts["AutoJournalStatusLabel"].frame,
                           app.buttons["AutoJournalPhotoButton"].frame,
                           app.buttons["AutoJournalPTToggle"].frame,
                           app.descendants(matching: .any)["AutoJournalLevelMeter"].frame])
            ptTops.append(app.staticTexts["AutoJournalLivePTLabel"].frame.minY)
            try shot(frames.count == 1 ? "journal-live-short" : "journal-live-long")
            discardDraft(app)
            app.terminate()
        }
        XCTAssertEqual(frames[0], frames[1], "Cancel/Save/record/status (incl. the level meter) do not move between 1-line and 2-line text")
        XCTAssertEqual(ptTops[0], ptTops[1], "PT line starts at the same y for 1-line and 2-line text")
    }
}
