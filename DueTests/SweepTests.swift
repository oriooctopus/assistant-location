import XCTest

/// Pure prune decisions in Sweep (DueApp/Sweep.swift, compiled straight into this bundle, no host app). The notification-center
/// and network halves of Sweep are not covered here; they need a device.
final class SweepTests: XCTestCase {
    private let state = Sweep.ServerState(live: ["open": 2000, "moved": 3000], closed: ["done"])
    private func backup(_ id: String, _ dueAt: Double?) -> [AnyHashable: Any] {
        var i: [AnyHashable: Any] = ["reminderId": id, "nagId": "\(id):1"]
        if let d = dueAt { i["dueAt"] = NSNumber(value: d) }
        return i
    }

    func testClosedReminderBackupIsPruned() { XCTAssertTrue(Sweep.shouldPruneBackup(backup("done", 1000), state: state)) }
    func testServerMovedPastBackupIsPruned() { XCTAssertTrue(Sweep.shouldPruneBackup(backup("moved", 2000), state: state)) }
    func testBackupAtServerDueAtIsKept() { XCTAssertFalse(Sweep.shouldPruneBackup(backup("open", 2000), state: state)) }
    func testBackupLaterThanServerIsKeptAsOfflineSnooze() { XCTAssertFalse(Sweep.shouldPruneBackup(backup("open", 5000), state: state)) }
    func testUnknownReminderIsKept() { XCTAssertFalse(Sweep.shouldPruneBackup(backup("offline-new", 1000), state: state)) }
    func testBackupWithoutDueAtIsKept() { XCTAssertFalse(Sweep.shouldPruneBackup(backup("open", nil), state: state)) }
    func testBackupWithoutReminderIdIsKept() { XCTAssertFalse(Sweep.shouldPruneBackup(["dueAt": NSNumber(value: 1)], state: state)) }

    func testDeliveredAlertStaleWhenClosedMovedOrUndated() {
        XCTAssertTrue(Sweep.isStaleDelivered(backup("done", 1000), live: state.live))
        XCTAssertTrue(Sweep.isStaleDelivered(backup("open", 1000), live: state.live))
        XCTAssertTrue(Sweep.isStaleDelivered(backup("open", nil), live: state.live))
        XCTAssertFalse(Sweep.isStaleDelivered(backup("open", 2000), live: state.live))
    }

    func testParseSplitsLiveAndClosed() {
        let body = #"{"reminders":{"a":{"completedAt":null,"deletedAt":null,"dueAt":10},"b":{"completedAt":5,"deletedAt":null,"dueAt":10},"c":{"completedAt":null,"deletedAt":7,"dueAt":10}}}"#
        XCTAssertEqual(Sweep.parse(Data(body.utf8)), Sweep.ServerState(live: ["a": 10], closed: ["b", "c"]))
    }

    func testParseRejectsUnexpectedShape() { XCTAssertNil(Sweep.parse(Data(#"{"nope":1}"#.utf8))) }
}
