import Foundation

struct ArtworkLoadRequestTracker {
    private(set) var activeIdentifier: String?
    private(set) var activeAttempt: UUID?

    mutating func begin(_ identifier: String) {
        activeIdentifier = identifier
        activeAttempt = nil
    }

    mutating func beginAttempt(_ identifier: String) -> UUID {
        let attempt = UUID()
        activeIdentifier = identifier
        activeAttempt = attempt
        return attempt
    }

    mutating func beginIfIdle(_ identifier: String) -> UUID? {
        guard activeIdentifier != identifier else { return nil }
        return beginAttempt(identifier)
    }

    mutating func reset() {
        activeIdentifier = nil
        activeAttempt = nil
    }

    func accepts(_ identifier: String, isCancelled: Bool = Task.isCancelled) -> Bool {
        !isCancelled && activeIdentifier == identifier
    }

    func accepts(
        _ identifier: String,
        attempt: UUID,
        isCancelled: Bool = Task.isCancelled
    ) -> Bool {
        !isCancelled && activeIdentifier == identifier && activeAttempt == attempt
    }

    mutating func finish(_ identifier: String) {
        guard activeIdentifier == identifier else { return }
        activeIdentifier = nil
        activeAttempt = nil
    }

    mutating func finish(_ identifier: String, attempt: UUID) {
        guard activeIdentifier == identifier, activeAttempt == attempt else { return }
        activeIdentifier = nil
        activeAttempt = nil
    }
}
