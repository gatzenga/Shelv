struct ArtworkLoadRequestTracker {
    private(set) var activeIdentifier: String?

    mutating func begin(_ identifier: String) {
        activeIdentifier = identifier
    }

    mutating func reset() {
        activeIdentifier = nil
    }

    func accepts(_ identifier: String, isCancelled: Bool = Task.isCancelled) -> Bool {
        !isCancelled && activeIdentifier == identifier
    }

    mutating func finish(_ identifier: String) {
        guard activeIdentifier == identifier else { return }
        activeIdentifier = nil
    }
}
