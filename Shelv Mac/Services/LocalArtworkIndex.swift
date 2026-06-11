import Foundation

final class LocalArtworkIndex {
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

    func localPath(for artId: String) -> String? {
        lock.lock()
        let p = index[artId]
        lock.unlock()
        guard let p, FileManager.default.fileExists(atPath: p) else { return nil }
        return p
    }
}
