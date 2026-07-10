import XCTest

final class RecapSyncLogicTests: XCTestCase {
    func testPlaylistMutationReplacesMissingExtraAndMisorderedSongsAtOnce() throws {
        let current = ["extra", "most-played", "existing"]
        let expected = ["most-played", "missing", "existing"]

        let plan = try XCTUnwrap(
            RecapPlaylistMutationPlan(currentIds: current, expectedIds: expected)
        )

        XCTAssertEqual(plan.songIdsToAdd, expected)
        XCTAssertEqual(plan.songIndicesToRemove, [0, 1, 2])
        XCTAssertNil(RecapPlaylistMutationPlan(currentIds: expected, expectedIds: expected))
    }

    func testPlaylistVerificationRequiresExactContentOrderNameAndComment() {
        let expected = ["first", "second", "third"]

        XCTAssertTrue(RecapSyncLogic.playlistMatches(
            ids: expected,
            name: "June 2026",
            comment: "Shelv Recap",
            expectedIds: expected,
            expectedName: "June 2026"
        ))
        XCTAssertFalse(RecapSyncLogic.playlistMatches(
            ids: ["second", "first", "third"],
            name: "June 2026",
            comment: "Shelv Recap",
            expectedIds: expected,
            expectedName: "June 2026"
        ))
        XCTAssertFalse(RecapSyncLogic.playlistMatches(
            ids: expected,
            name: "Wrong name",
            comment: "Shelv Recap",
            expectedIds: expected,
            expectedName: "June 2026"
        ))
        XCTAssertFalse(RecapSyncLogic.playlistMatches(
            ids: expected,
            name: "June 2026",
            comment: nil,
            expectedIds: expected,
            expectedName: "June 2026"
        ))
    }

    func testStabilizationRemovesNewlyExposedDeadIDsBeforeReturning() async throws {
        var scanCount = 0
        var cleanupCalls: [[String]] = []

        let result: [String] = try await RecapSyncLogic.stabilized(
            scan: {
                scanCount += 1
                switch scanCount {
                case 1:
                    return (["dead-a"], Set(["dead-a"]))
                case 2:
                    return (["dead-b"], Set(["dead-b"]))
                default:
                    return (["valid"], Set<String>())
                }
            },
            removeDeadSongIds: { ids in
                cleanupCalls.append(ids)
                return ids.count
            }
        )

        XCTAssertEqual(result, ["valid"])
        XCTAssertEqual(scanCount, 3)
        XCTAssertEqual(cleanupCalls, [["dead-a"], ["dead-b"]])
    }

    func testStabilizationPropagatesInspectionFailureWithoutCleaning() async {
        var cleanupCalled = false

        do {
            let _: [String] = try await RecapSyncLogic.stabilized(
                scan: { throw TestError.inspectionFailed },
                removeDeadSongIds: { _ in
                    cleanupCalled = true
                    return 1
                }
            )
            XCTFail("Expected the inspection error to be propagated")
        } catch TestError.inspectionFailed {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(cleanupCalled)
    }

    func testStabilizationDoesNotReturnDeadIDsWhenCleanupCannotRemoveRows() async {
        do {
            let _: [String] = try await RecapSyncLogic.stabilized(
                scan: { (["dead"], Set(["dead"])) },
                removeDeadSongIds: { _ in 0 }
            )
            XCTFail("Expected cleanup failure")
        } catch RecapSyncLogicError.deadSongCleanupFailed {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNotFoundClassificationOnlyAcceptsDefinitiveServerResponses() {
        XCTAssertTrue(RecapSyncLogic.isDefinitiveNotFound(code: 70, message: nil))
        XCTAssertTrue(RecapSyncLogic.isDefinitiveNotFound(code: 0, message: "Song not found"))
        XCTAssertFalse(RecapSyncLogic.isDefinitiveNotFound(code: 0, message: "Temporary failure"))
        XCTAssertFalse(RecapSyncLogic.isDefinitiveNotFound(code: 40, message: "Wrong credentials"))
    }

    func testDeletionQueueOnlyCompletesDeletedOrAlreadyMissingRecords() {
        let dispositions: [String: PendingDeletionDisposition] = [
            "deleted": .completed,
            "already-missing": .completed,
            "network-failure": .retry,
            "missing-result": .retry
        ]

        XCTAssertEqual(
            RecapSyncLogic.completedDeletionIDs(from: dispositions),
            Set(["deleted", "already-missing"])
        )
    }

    private enum TestError: Error {
        case inspectionFailed
    }
}
