import Foundation
import XCTest

final class DownloadProgressCoalescerTests: XCTestCase {
    func testManyCallbacksProduceOneLatestSamplePerWindow() {
        let harness = Harness()
        let coalescer = harness.makeCoalescer()

        for value in 1...10_000 {
            coalescer.record(DownloadProgressSample(
                taskIdentifier: 7,
                written: Int64(value),
                total: 10_000
            ))
        }

        XCTAssertEqual(harness.scheduledCount, 1)
        harness.runNextScheduledFlush()
        XCTAssertEqual(
            harness.emissions,
            [[DownloadProgressSample(taskIdentifier: 7, written: 10_000, total: 10_000)]]
        )
    }

    func testMultipleTasksShareOneFlush() {
        let harness = Harness()
        let coalescer = harness.makeCoalescer()

        coalescer.record(DownloadProgressSample(taskIdentifier: 2, written: 20, total: 100))
        coalescer.record(DownloadProgressSample(taskIdentifier: 1, written: 10, total: 100))
        coalescer.record(DownloadProgressSample(taskIdentifier: 2, written: 40, total: 100))
        harness.runNextScheduledFlush()

        XCTAssertEqual(
            harness.emissions,
            [[
                DownloadProgressSample(taskIdentifier: 1, written: 10, total: 100),
                DownloadProgressSample(taskIdentifier: 2, written: 40, total: 100),
            ]]
        )
    }

    func testDiscardRemovesTerminalTaskFromPendingFlush() {
        let harness = Harness()
        let coalescer = harness.makeCoalescer()
        let terminal = DownloadProgressSample(taskIdentifier: 1, written: 100, total: 100)

        coalescer.record(terminal)
        coalescer.record(DownloadProgressSample(taskIdentifier: 2, written: 50, total: 100))

        XCTAssertEqual(coalescer.discard(taskIdentifier: 1), terminal)
        harness.runNextScheduledFlush()
        XCTAssertEqual(
            harness.emissions,
            [[DownloadProgressSample(taskIdentifier: 2, written: 50, total: 100)]]
        )
    }

    func testNewWindowSchedulesAnotherFlush() {
        let harness = Harness()
        let coalescer = harness.makeCoalescer()

        coalescer.record(DownloadProgressSample(taskIdentifier: 1, written: 10, total: 100))
        harness.runNextScheduledFlush()
        coalescer.record(DownloadProgressSample(taskIdentifier: 1, written: 20, total: 100))

        XCTAssertEqual(harness.scheduledCount, 1)
        harness.runNextScheduledFlush()
        XCTAssertEqual(harness.emissions.count, 2)
    }
}

private nonisolated final class Harness: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled: [@Sendable () -> Void] = []
    private(set) var emissions: [[DownloadProgressSample]] = []

    var scheduledCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return scheduled.count
    }

    func makeCoalescer() -> DownloadProgressCoalescer {
        DownloadProgressCoalescer(
            schedule: { [weak self] work in
                self?.appendScheduled(work)
            },
            emit: { [weak self] samples in
                self?.appendEmission(samples.sorted { $0.taskIdentifier < $1.taskIdentifier })
            }
        )
    }

    func runNextScheduledFlush() {
        let work: (@Sendable () -> Void)?
        lock.lock()
        work = scheduled.isEmpty ? nil : scheduled.removeFirst()
        lock.unlock()
        work?()
    }

    private func appendScheduled(_ work: @escaping @Sendable () -> Void) {
        lock.lock()
        scheduled.append(work)
        lock.unlock()
    }

    private func appendEmission(_ samples: [DownloadProgressSample]) {
        lock.lock()
        emissions.append(samples)
        lock.unlock()
    }
}
