import XCTest

final class ScrobbleDeliveryCoordinatorTests: XCTestCase {
    private enum TestError: Error { case rejected }

    private actor Harness {
        var online = true
        var items: [PendingScrobbleDelivery]
        var failingIds = Set<Int64>()
        var attempts: [Int64] = []
        var delivered: [Int64] = []
        var failureCounts: [Int64: Int] = [:]
        var submitDelayNanoseconds: UInt64 = 0

        init(items: [PendingScrobbleDelivery]) {
            self.items = items
        }

        func canDeliver() -> Bool { online }

        func load(afterId: Int64?, limit: Int) -> [PendingScrobbleDelivery] {
            Array(items.filter { $0.id > (afterId ?? 0) }.prefix(limit))
        }

        func submit(_ item: PendingScrobbleDelivery) async throws {
            attempts.append(item.id)
            if submitDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: submitDelayNanoseconds)
            }
            if failingIds.contains(item.id) { throw TestError.rejected }
        }

        func markDelivered(_ id: Int64) {
            delivered.append(id)
            items.removeAll { $0.id == id }
        }

        func markFailed(_ id: Int64) {
            failureCounts[id, default: 0] += 1
        }

        func setOnline(_ value: Bool) { online = value }
        func setFailingIds(_ ids: Set<Int64>) { failingIds = ids }
        func setSubmitDelay(_ nanoseconds: UInt64) { submitDelayNanoseconds = nanoseconds }
        func append(_ item: PendingScrobbleDelivery) { items.append(item) }
        func remainingIds() -> [Int64] { items.map(\.id) }
        func attemptedIds() -> [Int64] { attempts }
        func failureCount(for id: Int64) -> Int { failureCounts[id, default: 0] }
    }

    func testFlushDrainsEveryBatchBeyondFiftyEntries() async {
        let harness = Harness(items: (1...125).map(makeItem))
        let coordinator = makeCoordinator(harness: harness)

        await coordinator.flush()

        let remaining = await harness.remainingIds()
        let attempts = await harness.attemptedIds()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(attempts, Array(1...125).map(Int64.init))
    }

    func testOfflineFlushKeepsOutboxUntilConnectivityReturns() async {
        let harness = Harness(items: [makeItem(1)])
        await harness.setOnline(false)
        let coordinator = makeCoordinator(harness: harness)

        await coordinator.flush()
        let attemptsWhileOffline = await harness.attemptedIds()
        let remainingWhileOffline = await harness.remainingIds()
        XCTAssertTrue(attemptsWhileOffline.isEmpty)
        XCTAssertEqual(remainingWhileOffline, [1])

        await harness.setOnline(true)
        await coordinator.flush()
        let remainingAfterReconnect = await harness.remainingIds()
        XCTAssertTrue(remainingAfterReconnect.isEmpty)
    }

    func testFailuresAreRetainedBeyondLegacyFiveRetryLimit() async {
        let harness = Harness(items: [makeItem(1)])
        await harness.setFailingIds([1])
        let coordinator = makeCoordinator(harness: harness)

        for _ in 0..<7 { await coordinator.flush() }

        let remaining = await harness.remainingIds()
        let failures = await harness.failureCount(for: 1)
        XCTAssertEqual(remaining, [1])
        XCTAssertEqual(failures, 7)
    }

    func testConcurrentFlushTriggersDoNotSubmitSameEventTwice() async {
        let harness = Harness(items: [makeItem(1)])
        await harness.setSubmitDelay(20_000_000)
        let coordinator = makeCoordinator(harness: harness)

        async let first: Void = coordinator.flush()
        async let second: Void = coordinator.flush()
        _ = await (first, second)

        let attempts = await harness.attemptedIds()
        XCTAssertEqual(attempts, [1])
    }

    func testTriggerDuringFinalBatchRunsAnotherPassForNewEvent() async throws {
        let harness = Harness(items: [makeItem(1)])
        await harness.setSubmitDelay(30_000_000)
        let coordinator = makeCoordinator(harness: harness)

        async let firstPass: Void = coordinator.flush()
        try await Task.sleep(nanoseconds: 5_000_000)
        await harness.append(makeItem(2))
        await coordinator.flush()
        _ = await firstPass

        let attempts = await harness.attemptedIds()
        let remaining = await harness.remainingIds()
        XCTAssertEqual(attempts, [1, 2])
        XCTAssertTrue(remaining.isEmpty)
    }

    func testCoalescedPassDoesNotImmediatelyRetryFailedEvent() async throws {
        let harness = Harness(items: [makeItem(1)])
        await harness.setFailingIds([1])
        await harness.setSubmitDelay(30_000_000)
        let coordinator = makeCoordinator(harness: harness)

        async let firstPass: Void = coordinator.flush()
        try await Task.sleep(nanoseconds: 5_000_000)
        await harness.append(makeItem(2))
        await coordinator.flush()
        _ = await firstPass

        let attempts = await harness.attemptedIds()
        let remaining = await harness.remainingIds()
        XCTAssertEqual(attempts, [1, 2])
        XCTAssertEqual(remaining, [1])
    }

    private func makeCoordinator(harness: Harness) -> ScrobbleDeliveryCoordinator {
        ScrobbleDeliveryCoordinator(
            canDeliver: { await harness.canDeliver() },
            loadBatch: { afterId, limit in await harness.load(afterId: afterId, limit: limit) },
            submit: { item in try await harness.submit(item) },
            markDelivered: { id in await harness.markDelivered(id) },
            markFailed: { id in await harness.markFailed(id) }
        )
    }

    private func makeItem(_ id: Int) -> PendingScrobbleDelivery {
        PendingScrobbleDelivery(
            id: Int64(id),
            songId: "song-\(id)",
            serverId: "server-a",
            serverConfigId: "config-a",
            playedAt: Double(id),
            retries: 0
        )
    }
}
