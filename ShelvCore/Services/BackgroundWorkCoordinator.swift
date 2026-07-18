import Foundation

/// Automatic maintenance jobs share one serial, coalescing queue. The newest
/// request for a job replaces older pending work, while every caller still waits
/// until that coalesced operation has finished.
nonisolated enum AutomaticBackgroundJob: Hashable, Sendable {
    case cloudSync
    case keepLibraryOffline
}

actor BackgroundWorkCoordinator {
    static let shared = BackgroundWorkCoordinator()

    typealias Operation = @Sendable () async -> Void

    private struct Request {
        let job: AutomaticBackgroundJob
        var operation: Operation
        var waiters: [UUID: CheckedContinuation<Void, Never>]
    }

    private var active: Request?
    private var pendingOrder: [AutomaticBackgroundJob] = []
    private var pending: [AutomaticBackgroundJob: Request] = [:]
    private var isDraining = false

    func run(
        _ job: AutomaticBackgroundJob,
        operation: @escaping Operation
    ) async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                enqueue(
                    job: job,
                    operation: operation,
                    waiterID: waiterID,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task.detached(priority: .utility) {
                await self.cancelWaiter(waiterID)
            }
        }
    }

    private func enqueue(
        job: AutomaticBackgroundJob,
        operation: @escaping Operation,
        waiterID: UUID,
        continuation: CheckedContinuation<Void, Never>
    ) {
        if var request = pending[job] {
            request.operation = operation
            request.waiters[waiterID] = continuation
            pending[job] = request
        } else {
            pendingOrder.append(job)
            pending[job] = Request(
                job: job,
                operation: operation,
                waiters: [waiterID: continuation]
            )
        }

        guard !isDraining else { return }
        isDraining = true
        Task.detached(priority: .utility) { [self] in
            await drain()
        }
    }

    private func drain() async {
        while !pendingOrder.isEmpty {
            let job = pendingOrder.removeFirst()
            guard let request = pending.removeValue(forKey: job) else { continue }
            active = request
            await request.operation()
            let waiters = active.map { Array($0.waiters.values) } ?? []
            active = nil
            waiters.forEach { $0.resume() }
        }
        isDraining = false
    }

    private func cancelWaiter(_ waiterID: UUID) {
        if let continuation = active?.waiters.removeValue(forKey: waiterID) {
            continuation.resume()
            return
        }
        for job in pendingOrder {
            if let continuation = pending[job]?.waiters.removeValue(forKey: waiterID) {
                continuation.resume()
                return
            }
        }
    }

    func pendingRequestCount(for job: AutomaticBackgroundJob) -> Int {
        pending[job]?.waiters.count ?? 0
    }

    func isIdleForTesting() -> Bool {
        active == nil && pending.isEmpty && !isDraining
    }
}
