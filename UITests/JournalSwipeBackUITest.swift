import XCTest

// Simulator UI test (.github/workflows/journal-swipe-back.yml). Reproduces the
// user report: "I opened the journal tab with a shortcut, then accidentally
// swiped back, and I couldn't tap it anymore to get into it. I tried the
// shortcut again and couldn't get in, and lost what I had written."
//
// Journal lives in the More overflow and wraps itself in a
// UINavigationController. The left-edge swipe pops it off the More stack, and
// afterwards neither the More tile nor the shortcut could bring it back. Both
// re-open paths are asserted separately, and both must show the SAME draft
// text (same view controller instance, not a rebuilt one).
//
// Launch env: UITEST_OPEN_URL opens overland://journal/text through the real
// URL routing (the shortcut path); UITEST_OPEN_URL_TRIGGER_FILE re-opens it when the
// test creates that file, because an XCUITest cannot deliver a second URL
// itself on iOS 26.
final class JournalSwipeBackUITest: XCTestCase {

    private let draft = "swipe-back draft 12345"

    private let triggerFile = "/tmp/glnav-open-url-trigger"

    private func launchJournal(shortcutTrigger: Bool) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_OPEN_URL"] = "overland://journal/text"
        app.launchEnvironment["UITEST_STATE_LOG"] = "/tmp/glnav.log"
        if shortcutTrigger { app.launchEnvironment["UITEST_OPEN_URL_TRIGGER_FILE"] = triggerFile }
        app.launch()

        let textView = app.textViews["AutoJournalNoteTextView"]
        if !textView.waitForExistence(timeout: 20) {
            print("PROBE journal never opened: \(app.debugDescription)")
            add(XCTAttachment(screenshot: app.screenshot()))
            XCTFail("Journal never opened from the shortcut URL")
            return (app, textView)
        }
        // The URL open and its tab transition can still be settling when the
        // text view first exists; a tap during it gets no keyboard focus
        // (observed: "Neither element nor any descendant has keyboard focus").
        // Tap until the keyboard is actually up.
        var focused = false
        for _ in 0..<5 {
            sleep(2)
            textView.tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 3) { focused = true; break }
        }
        XCTAssertTrue(focused, "Journal text view never got keyboard focus")
        textView.typeText(draft)
        print("PROBE after typing: \(app.debugDescription)")
        XCTAssertEqual(textView.value as? String, draft, "typed text did not land in the Journal text view")
        return (app, textView)
    }

    private func swipeBack(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    func testShortcutReopensJournalAfterBackSwipeKeepingDraft() {
        let (app, textView) = launchJournal(shortcutTrigger: true)
        swipeBack(app)
        print("PROBE after swipe: \(app.debugDescription)")
        // The shortcut arrives now: the app consumes this file and re-opens
        // overland://journal/text through the real URL routing.
        FileManager.default.createFile(atPath: triggerFile, contents: Data())

        // Journal must come back with the draft intact.
        let reopened = app.textViews["AutoJournalNoteTextView"]
        let deadline = Date().addingTimeInterval(20)
        var back = false
        while Date() < deadline {
            // A fresh swipe-back leaves the text view absent until the shortcut
            // brings Journal back, so wait for it to exist AND be hittable.
            if reopened.exists && reopened.isHittable { back = true; break }
            usleep(500_000)
        }
        XCTAssertTrue(back, "shortcut did not bring Journal back after the back-swipe")
        XCTAssertEqual(reopened.value as? String, draft, "draft text was lost after re-opening via shortcut")
        _ = textView
    }

    func testMoreTileReopensJournalAfterBackSwipeKeepingDraft() {
        let (app, _) = launchJournal(shortcutTrigger: false)
        swipeBack(app)

        // Back on the More grid (a web page): the Journal tile is a web element.
        let tile = app.webViews.staticTexts["Journal"].firstMatch
        print("PROBE more grid: \(app.debugDescription)")
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "More grid with a Journal tile is not showing after the back-swipe")
        tile.tap()

        let reopened = app.textViews["AutoJournalNoteTextView"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 10) && reopened.isHittable,
                      "tapping the Journal tile did not bring Journal back after the back-swipe")
        XCTAssertEqual(reopened.value as? String, draft, "draft text was lost after re-opening via the tile")
    }

    // A long paste must leave Save above the keyboard and the keyboard
    // dismissable: Save was pinned to the safe-area bottom, under the
    // keyboard, and Return only adds newlines.
    func testLongNoteKeepsSaveReachableAndKeyboardDismissable() {
        let (app, textView) = launchJournal(shortcutTrigger: false)
        textView.typeText(String(repeating: "\nline of a long pasted entry", count: 25))

        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.exists, "keyboard should still be up after typing")
        let save = app.buttons["AutoJournalTextSaveButton"]
        print("PROBE save=\(save.frame) keyboard=\(keyboard.frame)")
        XCTAssertLessThanOrEqual(save.frame.maxY, keyboard.frame.minY, "Save is under the keyboard")
        XCTAssertTrue(save.isHittable, "Save is not tappable with the keyboard up")

        // Interactive dismissal: a drag down the field that continues into the keyboard.
        let from = textView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: keyboard.frame.midY))
        from.press(forDuration: 0.05, thenDragTo: to)
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: keyboard)
        waitForExpectations(timeout: 5)

        // A tap on blank page left of Save also puts the keyboard away.
        textView.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "keyboard did not come back on tapping the note")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: 30, dy: save.frame.midY)).tap()
        expectation(for: gone, evaluatedWith: keyboard)
        waitForExpectations(timeout: 5)
    }
}
