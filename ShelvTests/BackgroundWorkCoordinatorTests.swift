import XCTest

final class BackgroundWorkCoordinatorTests: XCTestCase {
    private actor Harness {
        private var values: [Int] = []
        private var firstStartedWaiters: [CheckedContinuation<Void, Never>] = []
        private var firstRelease: CheckedContinuation<Void, Never>?

        func perform(_ value: Int, blockFirst: Bool = false) async {
            values.append(value)
            if values.count == 1 {
                let waiters = firstStartedWaiters
                firstStartedWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
            if blockFirst {
                await withCheckedContinuation { firstRelease = $0 }
            }
        }

        func waitUntilFirstStarted() async {
            guard values.isEmpty else { return }
            await withCheckedContinuation { firstStartedWaiters.append($0) }
        }

        func releaseFirst() {
            firstRelease?.resume()
            firstRelease = nil
        }

        func recordedValues() -> [Int] { values }
    }

    private func waitUntilPendingRequestCount(
        _ expected: Int,
        for job: AutomaticBackgroundJob,
        coordinator: BackgroundWorkCoordinator
    ) async {
        for _ in 0..<1_000 {
            if await coordinator.pendingRequestCount(for: job) == expected { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for \(expected) pending request(s)")
    }

    private func waitUntilValues(
        _ expected: [Int],
        harness: Harness
    ) async {
        for _ in 0..<1_000 {
            if await harness.recordedValues() == expected { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for values \(expected)")
    }

    private func waitUntilIdle(_ coordinator: BackgroundWorkCoordinator) async {
        for _ in 0..<1_000 {
            if await coordinator.isIdleForTesting() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for coordinator to become idle")
    }

    func testOverlappingRequestsKeepOnlyNewestPendingOperation() async {
        let coordinator = BackgroundWorkCoordinator()
        let harness = Harness()

        let active = Task {
            await coordinator.run(.cloudSync) {
                await harness.perform(1, blockFirst: true)
            }
        }
        await harness.waitUntilFirstStarted()

        let olderPending = Task {
            await coordinator.run(.cloudSync) { await harness.perform(2) }
        }
        await waitUntilPendingRequestCount(1, for: .cloudSync, coordinator: coordinator)

        let newestPending = Task {
            await coordinator.run(.cloudSync) { await harness.perform(3) }
        }
        await waitUntilPendingRequestCount(2, for: .cloudSync, coordinator: coordinator)

        await harness.releaseFirst()
        await active.value
        await olderPending.value
        await newestPending.value

        let values = await harness.recordedValues()
        XCTAssertEqual(values, [1, 3])
    }

    func testDifferentJobsRunSeriallyInSubmissionOrder() async {
        let coordinator = BackgroundWorkCoordinator()
        let harness = Harness()

        let active = Task {
            await coordinator.run(.cloudSync) {
                await harness.perform(1, blockFirst: true)
            }
        }
        await harness.waitUntilFirstStarted()

        let queued = Task {
            await coordinator.run(.keepLibraryOffline) {
                await harness.perform(2)
            }
        }
        await waitUntilPendingRequestCount(1, for: .keepLibraryOffline, coordinator: coordinator)
        let valuesWhileFirstJobIsRunning = await harness.recordedValues()
        XCTAssertEqual(valuesWhileFirstJobIsRunning, [1])

        await harness.releaseFirst()
        await active.value
        await queued.value

        let values = await harness.recordedValues()
        XCTAssertEqual(values, [1, 2])
    }

    func testCancellingActiveWaiterDoesNotCancelBackgroundOperation() async {
        let coordinator = BackgroundWorkCoordinator()
        let harness = Harness()

        let waiter = Task {
            await coordinator.run(.cloudSync) {
                await harness.perform(1, blockFirst: true)
            }
        }
        await harness.waitUntilFirstStarted()

        waiter.cancel()
        await waiter.value
        let valuesBeforeRelease = await harness.recordedValues()
        XCTAssertEqual(valuesBeforeRelease, [1])

        await harness.releaseFirst()
        await waitUntilIdle(coordinator)
    }

    func testCancellingPendingWaiterKeepsQueuedOperationReliable() async {
        let coordinator = BackgroundWorkCoordinator()
        let harness = Harness()

        let active = Task {
            await coordinator.run(.cloudSync) {
                await harness.perform(1, blockFirst: true)
            }
        }
        await harness.waitUntilFirstStarted()

        let pending = Task {
            await coordinator.run(.keepLibraryOffline) {
                await harness.perform(2)
            }
        }
        await waitUntilPendingRequestCount(1, for: .keepLibraryOffline, coordinator: coordinator)

        pending.cancel()
        await pending.value
        await waitUntilPendingRequestCount(0, for: .keepLibraryOffline, coordinator: coordinator)

        await harness.releaseFirst()
        await active.value
        await waitUntilValues([1, 2], harness: harness)
        await waitUntilIdle(coordinator)
    }
}
