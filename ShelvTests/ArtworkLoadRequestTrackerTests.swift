import XCTest

final class ArtworkLoadRequestTrackerTests: XCTestCase {
    func testLateOlderRequestCannotReplaceNewestArtwork() {
        var tracker = ArtworkLoadRequestTracker()

        tracker.begin("cover-a")
        tracker.begin("cover-b")
        tracker.begin("cover-c")

        XCTAssertTrue(tracker.accepts("cover-c", isCancelled: false))
        XCTAssertFalse(tracker.accepts("cover-a", isCancelled: false))
        XCTAssertFalse(tracker.accepts("cover-b", isCancelled: false))
    }

    func testFinishingOlderRequestDoesNotClearNewestRequest() {
        var tracker = ArtworkLoadRequestTracker()

        tracker.begin("cover-a")
        tracker.begin("cover-c")
        tracker.finish("cover-a")

        XCTAssertEqual(tracker.activeIdentifier, "cover-c")
        XCTAssertTrue(tracker.accepts("cover-c", isCancelled: false))
    }

    func testCancelledCurrentRequestIsRejected() {
        var tracker = ArtworkLoadRequestTracker()
        tracker.begin("cover-a")

        XCTAssertFalse(tracker.accepts("cover-a", isCancelled: true))
    }

    func testResetRejectsOutstandingRequest() {
        var tracker = ArtworkLoadRequestTracker()
        tracker.begin("cover-a")
        tracker.reset()

        XCTAssertNil(tracker.activeIdentifier)
        XCTAssertFalse(tracker.accepts("cover-a", isCancelled: false))
    }
}
