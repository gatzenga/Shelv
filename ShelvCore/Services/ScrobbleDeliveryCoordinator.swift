import Foundation

/// Plattformneutrale Repräsentation eines dauerhaft vorgemerkten Scrobbles.
/// Der Coordinator kennt weder GRDB noch Subsonic und bleibt dadurch isoliert testbar.
nonisolated struct PendingScrobbleDelivery: Sendable, Equatable {
    let id: Int64
    let songId: String
    let serverId: String
    let serverConfigId: String?
    let playedAt: Double
    let retries: Int
}

/// Leert eine persistente Scrobble-Outbox genau einmal pro Eintrag und Flush-Lauf.
/// Mehrere gleichzeitige Trigger werden zusammengefasst; Pagination verhindert,
/// dass Backlogs mit mehr als 50 Einträgen oder mehreren Servern verhungern.
actor ScrobbleDeliveryCoordinator {
    typealias CanDeliver = @Sendable () async -> Bool
    typealias LoadBatch = @Sendable (_ afterId: Int64?, _ limit: Int) async -> [PendingScrobbleDelivery]
    typealias Submit = @Sendable (_ item: PendingScrobbleDelivery) async throws -> Void
    typealias MarkDelivered = @Sendable (_ id: Int64) async -> Void
    typealias MarkFailed = @Sendable (_ id: Int64) async -> Void

    private let batchSize: Int
    private let canDeliver: CanDeliver
    private let loadBatch: LoadBatch
    private let submit: Submit
    private let markDelivered: MarkDelivered
    private let markFailed: MarkFailed
    private var isFlushing = false
    private var needsAnotherPass = false

    init(
        batchSize: Int = 50,
        canDeliver: @escaping CanDeliver,
        loadBatch: @escaping LoadBatch,
        submit: @escaping Submit,
        markDelivered: @escaping MarkDelivered,
        markFailed: @escaping MarkFailed
    ) {
        self.batchSize = max(1, batchSize)
        self.canDeliver = canDeliver
        self.loadBatch = loadBatch
        self.submit = submit
        self.markDelivered = markDelivered
        self.markFailed = markFailed
    }

    func flush() async {
        guard !isFlushing else {
            // Ein neuer Play kann während eines laufenden, kleinen letzten Batches
            // eintreffen. Der aktive Lauf macht danach noch einen Pass, statt den
            // Reconnect-/Insert-Trigger zu verlieren.
            needsAnotherPass = true
            return
        }
        isFlushing = true
        defer { isFlushing = false }

        var highWaterId: Int64?
        repeat {
            needsAnotherPass = false
            highWaterId = await flushPass(afterId: highWaterId)
        } while needsAnotherPass && !Task.isCancelled
    }

    private func flushPass(afterId initialAfterId: Int64?) async -> Int64? {
        guard !Task.isCancelled, await canDeliver() else { return initialAfterId }

        var afterId = initialAfterId
        while !Task.isCancelled, await canDeliver() {
            let batch = await loadBatch(afterId, batchSize)
            guard !batch.isEmpty else { return afterId }

            for item in batch {
                guard await canDeliver() else { return afterId }
                do {
                    try await submit(item)
                    await markDelivered(item.id)
                } catch is CancellationError {
                    return afterId
                } catch {
                    // Nicht löschen: klassische Subsonic-Scrobbles besitzen keinen
                    // Idempotency-Key. At-least-once ist sicherer als Play-Verlust.
                    await markFailed(item.id)
                }
                afterId = item.id
            }

            if batch.count < batchSize { return afterId }
        }
        return afterId
    }
}
