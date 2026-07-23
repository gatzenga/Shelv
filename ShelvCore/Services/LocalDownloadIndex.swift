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

nonisolated enum LocalOfflinePlaylistCatalog {
    static func songIds(serverId: String) -> [String: [String]] {
        #if os(iOS) || os(macOS)
        #if os(iOS)
        let key = "shelv_offline_playlist_songs_\(serverId)"
        #else
        let key = "shelv_mac_playlist_song_ids_\(serverId)"
        #endif
        return UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        #else
        return [:]
        #endif
    }

    static func updateName(serverId: String, id: String, name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, songIds(serverId: serverId)[id] != nil else { return }
        #if os(iOS)
        let key = "shelv_offline_playlist_names_\(serverId)"
        var names = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        guard names[id] != trimmed else { return }
        names[id] = trimmed
        UserDefaults.standard.set(names, forKey: key)
        #elseif os(macOS)
        await DownloadDatabase.shared.markPlaylistDownloaded(
            id: id,
            name: trimmed,
            serverId: serverId
        )
        #endif
    }

    static func updateSongIds(
        serverId: String,
        id: String,
        songIds updatedSongIds: [String]
    ) {
        #if os(iOS) || os(macOS)
        #if os(iOS)
        let key = "shelv_offline_playlist_songs_\(serverId)"
        #else
        let key = "shelv_mac_playlist_song_ids_\(serverId)"
        #endif
        var stored = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        guard stored[id] != nil else { return }
        stored[id] = updatedSongIds
        UserDefaults.standard.set(stored, forKey: key)
        #endif
    }
}
