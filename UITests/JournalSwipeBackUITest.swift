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
// URL routing (the shortcut path); UITEST_OPEN_URL_REPEAT re-opens it every 4s
// because an XCUITest cannot deliver a second URL itself on iOS 26.
final class JournalSwipeBackUITest: XCTestCase {

    private let draft = "swipe-back draft 12345"

    private func launchJournal(repeatingShortcut: Bool) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_OPEN_URL"] = "overland://journal/text"
        if repeatingShortcut { app.launchEnvironment["UITEST_OPEN_URL_REPEAT"] = "1" }
        app.launch()

        let textView = app.textViews["AutoJournalNoteTextView"]
        XCTAssertTrue(textView.waitForExistence(timeout: 20), "Journal never opened from the shortcut URL")
        textView.tap()
        textView.typeText(draft)
        XCTAssertEqual(textView.value as? String, draft, "typed text did not land in the Journal text view")
        return (app, textView)
    }

    private func swipeBack(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    func testShortcutReopensJournalAfterBackSwipeKeepingDraft() {
        let (app, textView) = launchJournal(repeatingShortcut: true)
        // Dismiss the keyboard-less edge case: nothing to do, the swipe starts
        // at the screen edge, outside the keyboard.
        swipeBack(app)
        print("PROBE after swipe: \(app.debugDescription)")

        // The repeating shortcut fires within 4s of the swipe; Journal must come
        // back on its own with the draft intact.
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
        let (app, _) = launchJournal(repeatingShortcut: false)
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
}
