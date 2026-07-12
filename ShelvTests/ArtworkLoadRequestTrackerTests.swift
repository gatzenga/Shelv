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

    func testNewAttemptForSameArtworkSupersedesOlderAttempt() {
        var tracker = ArtworkLoadRequestTracker()

        let first = tracker.beginAttempt("cover-a")
        let retry = tracker.beginAttempt("cover-a")

        XCTAssertFalse(tracker.accepts("cover-a", attempt: first, isCancelled: false))
        XCTAssertTrue(tracker.accepts("cover-a", attempt: retry, isCancelled: false))

        tracker.finish("cover-a", attempt: first)
        XCTAssertTrue(tracker.accepts("cover-a", attempt: retry, isCancelled: false))
    }

    func testRetryDoesNotReplaceAnActiveAttemptForSameArtwork() {
        var tracker = ArtworkLoadRequestTracker()

        let active = tracker.beginIfIdle("cover-a")
        let duplicate = tracker.beginIfIdle("cover-a")

        XCTAssertNotNil(active)
        XCTAssertNil(duplicate)
        XCTAssertTrue(tracker.accepts("cover-a", attempt: active!, isCancelled: false))
    }

    func testRetryStartsAfterPreviousAttemptFinishes() {
        var tracker = ArtworkLoadRequestTracker()

        let first = tracker.beginIfIdle("cover-a")!
        tracker.finish("cover-a", attempt: first)
        let retry = tracker.beginIfIdle("cover-a")

        XCTAssertNotNil(retry)
        XCTAssertNotEqual(first, retry)
    }

    func testNewArtworkCanReplaceAnActiveOlderArtworkAttempt() {
        var tracker = ArtworkLoadRequestTracker()

        let old = tracker.beginIfIdle("cover-a")!
        let current = tracker.beginIfIdle("cover-b")!

        XCTAssertFalse(tracker.accepts("cover-a", attempt: old, isCancelled: false))
        XCTAssertTrue(tracker.accepts("cover-b", attempt: current, isCancelled: false))
    }
}
