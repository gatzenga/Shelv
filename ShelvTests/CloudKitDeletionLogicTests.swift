import XCTest

final class CloudKitDeletionLogicTests: XCTestCase {
    func testNotFoundClassificationOnlyAcceptsDefinitiveServerResponses() {
        XCTAssertTrue(CloudKitDeletionLogic.isDefinitiveNotFound(code: 70, message: nil))
        XCTAssertTrue(CloudKitDeletionLogic.isDefinitiveNotFound(code: 0, message: "Song not found"))
        XCTAssertFalse(CloudKitDeletionLogic.isDefinitiveNotFound(code: 0, message: "Temporary failure"))
        XCTAssertFalse(CloudKitDeletionLogic.isDefinitiveNotFound(code: 40, message: "Wrong credentials"))
    }

    func testDeletionQueueOnlyCompletesDeletedOrAlreadyMissingRecords() {
        let dispositions: [String: PendingDeletionDisposition] = [
            "deleted": .completed,
            "already-missing": .completed,
            "network-failure": .retry,
            "missing-result": .retry
        ]

        XCTAssertEqual(
            CloudKitDeletionLogic.completedDeletionIDs(from: dispositions),
            Set(["deleted", "already-missing"])
        )
    }
}
