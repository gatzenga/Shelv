import Foundation

/// Synchroner, thread-safer Lookup für lokale Downloads.
/// Wird vom DownloadStore aktualisiert, von AudioPlayerService und Views beim Spielen synchron abgefragt.
final class LocalDownloadIndex {
    static let shared = LocalDownloadIndex()
    private let lock = NSLock()
    private var pathById: [String: String] = [:]

    private init() {}

    static func key(songId: String, serverId: String) -> String {
        "\(serverId)::\(songId)"
    }

    func update(paths: [String: String]) {
        lock.lock()
        pathById = paths
        lock.unlock()
    }

    func setPath(songId: String, serverId: String, path: String?) {
        let k = Self.key(songId: songId, serverId: serverId)
        lock.lock()
        if let path { pathById[k] = path } else { pathById.removeValue(forKey: k) }
        lock.unlock()
    }

    func url(songId: String, serverId: String) -> URL? {
        let k = Self.key(songId: songId, serverId: serverId)
        lock.lock()
        let path = pathById[k]
        lock.unlock()
        guard let path else { return nil }
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    func contains(songId: String, serverId: String) -> Bool {
        let k = Self.key(songId: songId, serverId: serverId)
        lock.lock()
        let exists = pathById[k] != nil
        lock.unlock()
        return exists
    }
}
