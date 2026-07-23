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

    /// Replaces one server's entries without disturbing an intent that may
    /// already be preparing another server in parallel.
    func replace(serverId: String, pathsBySongId: [String: String]) {
        let prefix = "\(serverId)::"
        lock.lock()
        pathById = pathById.filter { !$0.key.hasPrefix(prefix) }
        for (songId, path) in pathsBySongId {
            pathById[Self.key(songId: songId, serverId: serverId)] = path
        }
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

nonisolated struct LocalDownloadSnapshot: Sendable {
    let records: [DownloadRecord]
    let pathsBySongId: [String: String]
}

nonisolated struct OfflinePlaylistDescriptor: Sendable {
    let id: String
    let name: String?
    let songIds: [String]
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

    static func descriptors(
        serverId: String,
        serverConfigID: UUID? = nil
    ) async -> [OfflinePlaylistDescriptor] {
        let songIdsByPlaylist = songIds(serverId: serverId)
        #if os(iOS)
        let ids = Set(
            UserDefaults.standard.stringArray(
                forKey: "shelv_offline_playlists_\(serverId)"
            ) ?? []
        ).union(songIdsByPlaylist.keys)
        var names = UserDefaults.standard.dictionary(
            forKey: "shelv_offline_playlist_names_\(serverId)"
        ) as? [String: String] ?? [:]
        if let serverConfigID {
            let cachedNames = LibraryStore.cachedPlaylistNamesForSystemIntent(
                serverID: serverConfigID
            )
            var changed = false
            for id in ids {
                if let cachedName = cachedNames[id], names[id] != cachedName {
                    names[id] = cachedName
                    changed = true
                }
            }
            if changed {
                UserDefaults.standard.set(
                    names,
                    forKey: "shelv_offline_playlist_names_\(serverId)"
                )
            }
        }
        return ids.sorted().map {
            OfflinePlaylistDescriptor(id: $0, name: names[$0], songIds: songIdsByPlaylist[$0] ?? [])
        }
        #elseif os(macOS)
        let markers = await DownloadDatabase.shared.loadDownloadedPlaylistMarkers(serverId: serverId)
        let names = Dictionary(
            markers.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        // Song maps are server-scoped while the legacy marker table is not.
        // Never surface a marker that has no entry for the active server.
        let ids = Set(songIdsByPlaylist.keys)
        return ids.sorted().map {
            OfflinePlaylistDescriptor(id: $0, name: names[$0], songIds: songIdsByPlaylist[$0] ?? [])
        }
        #else
        return []
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

/// Loads, validates and repairs local download records without depending on a
/// platform UI store. System intents can therefore play downloads in a cold
/// background process where `DownloadStore.reload()` has never run.
nonisolated enum LocalDownloadCatalog {
    static func load(serverId: String) async -> LocalDownloadSnapshot {
        let rawRecords = await DownloadDatabase.shared.allRecords(serverId: serverId)
        let result = await Task.detached(priority: .utility) {
            () -> (records: [DownloadRecord], updates: [(DownloadRecord, String)], deletions: [DownloadRecord]) in
            var records: [DownloadRecord] = []
            var updates: [(DownloadRecord, String)] = []
            var deletions: [DownloadRecord] = []

            for var record in rawRecords {
                if FileManager.default.fileExists(atPath: record.filePath) {
                    records.append(record)
                    continue
                }

                let directory = DownloadService.serverDirectory(serverId: record.serverId)
                let originalPath = record.filePath
                let candidates = record.songId.pathSafeDownloadFileNameCandidates(
                    fileExtension: record.fileExtension,
                    storedFilePath: record.filePath
                )
                if let replacement = candidates
                    .map({ directory.appendingPathComponent($0) })
                    .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                    record.filePath = replacement.path
                    updates.append((record, originalPath))
                    records.append(record)
                } else {
                    deletions.append(record)
                }
            }
            return (records, updates, deletions)
        }.value

        for (record, originalPath) in result.updates {
            await DownloadDatabase.shared.repairFilePath(
                songId: record.songId,
                serverId: record.serverId,
                expectedPath: originalPath,
                expectedAddedAt: record.addedAt,
                replacementPath: record.filePath
            )
        }
        for record in result.deletions {
            await DownloadDatabase.shared.deleteIfFilePathMatches(
                songId: record.songId,
                serverId: record.serverId,
                expectedPath: record.filePath,
                expectedAddedAt: record.addedAt
            )
        }

        // CAS may legitimately lose to a concurrent re-download. Re-read the
        // authoritative rows so the returned snapshot and in-memory index can
        // never overwrite that fresher record with the original scan.
        let currentRecords = await DownloadDatabase.shared.allRecords(serverId: serverId)
        let validRecords = await Task.detached(priority: .utility) {
            currentRecords.filter { FileManager.default.fileExists(atPath: $0.filePath) }
        }.value
        let paths = Dictionary(
            validRecords.map { ($0.songId, $0.filePath) },
            uniquingKeysWith: { first, _ in first }
        )
        return LocalDownloadSnapshot(records: validRecords, pathsBySongId: paths)
    }
}
