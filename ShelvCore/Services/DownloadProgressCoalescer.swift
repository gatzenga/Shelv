import Foundation

nonisolated struct DownloadProgressSample: Equatable, Sendable {
    let taskIdentifier: Int
    let written: Int64
    let total: Int64
}

/// Coalesces raw URLSession progress callbacks before they create Swift tasks
/// or enter DownloadService's actor. All mutable state is protected by `lock`.
nonisolated final class DownloadProgressCoalescer: @unchecked Sendable {
    typealias Schedule = @Sendable (@escaping @Sendable () -> Void) -> Void
    typealias Emit = @Sendable ([DownloadProgressSample]) -> Void

    private let lock = NSLock()
    private let schedule: Schedule
    private var emit: Emit
    private var pendingByTaskIdentifier: [Int: DownloadProgressSample] = [:]
    private var isFlushScheduled = false

    init(schedule: @escaping Schedule, emit: @escaping Emit) {
        self.schedule = schedule
        self.emit = emit
    }

    func setEmit(_ emit: @escaping Emit) {
        lock.lock()
        self.emit = emit
        lock.unlock()
    }

    func record(_ sample: DownloadProgressSample) {
        let shouldSchedule: Bool
        lock.lock()
        pendingByTaskIdentifier[sample.taskIdentifier] = sample
        shouldSchedule = !isFlushScheduled
        if shouldSchedule {
            isFlushScheduled = true
        }
        lock.unlock()

        guard shouldSchedule else { return }
        schedule { [weak self] in
            self?.flush()
        }
    }

    @discardableResult
    func discard(taskIdentifier: Int) -> DownloadProgressSample? {
        lock.lock()
        let sample = pendingByTaskIdentifier.removeValue(forKey: taskIdentifier)
        lock.unlock()
        return sample
    }

    private func flush() {
        let samples: [DownloadProgressSample]
        let emit: Emit
        lock.lock()
        samples = Array(pendingByTaskIdentifier.values)
        pendingByTaskIdentifier.removeAll(keepingCapacity: true)
        isFlushScheduled = false
        emit = self.emit
        lock.unlock()

        guard !samples.isEmpty else { return }
        emit(samples)
    }
}
