import Foundation

nonisolated final class LocalArtworkIndex: @unchecked Sendable {
    static let shared = LocalArtworkIndex()
    private let lock = NSLock()
    private var index: [String: String] = [:]

    private init() {}

    func update(paths: [String: String]) {
        lock.lock()
        index = paths
        lock.unlock()
    }

    func set(artId: String, path: String?) {
        lock.lock()
        if let path { index[artId] = path } else { index.removeValue(forKey: artId) }
        lock.unlock()
    }

    func remove(path: String) {
        lock.lock()
        index = index.filter { $0.value != path }
        lock.unlock()
    }

    func localPath(for artId: String) -> String? {
        lock.lock()
        let path = index[artId]
        lock.unlock()
        return path
    }
}
