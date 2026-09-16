import Foundation

nonisolated enum DownloadIdentityRepairResult: Equatable, Sendable {
    case unchanged
    case repaired(Int)
    case blocked(unresolvedSongs: Int, totalSongs: Int)
}

nonisolated enum DownloadIdentityRepairPolicy {
    // Deliberately conservative: ordinary album edits/removals must continue to
    // use the existing reconciliation path. This recovery path is reserved for
    // broad identity churn that looks like a backend/database rebuild.
    static let churnRatio = 0.50
    static let minimumChurnSongs = 20

    static func isLargeIdentityChurn(orphanedSongs: Int, totalSongs: Int) -> Bool {
        guard totalSongs > 0, orphanedSongs >= minimumChurnSongs else { return false }
        return Double(orphanedSongs) / Double(totalSongs) >= churnRatio
    }

    static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func matchingAlbum(
        for records: [DownloadRecord],
        in albums: [Album]
    ) -> Album? {
        guard let first = records.first else { return nil }

        // When the album identity survived, prefer it. This matters after a
        // stable-ID rotation where only song identities may have changed.
        if let exact = albums.first(where: { $0.id == first.albumId }) {
            if let songCount = exact.songCount, songCount > 0, songCount < records.count {
                return nil
            }
            return exact
        }

        let oldAlbumName = normalized(first.albumTitle)
        let oldArtist = normalized(first.albumArtistName ?? first.artistName)
        let candidates = albums.filter { album in
            guard normalized(album.name) == oldAlbumName else { return false }
            let candidateArtist = normalized(album.artist ?? "")
            guard oldArtist.isEmpty || candidateArtist.isEmpty || candidateArtist == oldArtist else {
                return false
            }
            if let songCount = album.songCount, songCount > 0 {
                return songCount >= records.count
            }
            return true
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    static func suspectedReidentifiedAlbums(
        _ localAlbums: [String: [DownloadRecord]],
        in albums: [Album]
    ) -> [String: [DownloadRecord]] {
        var result: [String: [DownloadRecord]] = [:]
        for (albumId, records) in localAlbums {
            if matchingAlbum(for: records, in: albums) != nil {
                result[albumId] = records
            }
        }
        return result
    }

    static func matchAlbum(
        records: [DownloadRecord],
        songs: [Song],
        existingSongIds: Set<String> = []
    ) -> [(DownloadRecord, Song)]? {
        guard !records.isEmpty, songs.count >= records.count else { return nil }

        var unusedSongs = songs
        var result: [(DownloadRecord, Song)] = []
        for record in records {
            let candidates = unusedSongs.filter { song in
                guard normalized(song.title) == normalized(record.title),
                      (song.discNumber ?? 1) == (record.disc ?? 1),
                      song.track == record.track
                else { return false }

                if let localDuration = record.duration, let remoteDuration = song.duration {
                    return abs(localDuration - remoteDuration) <= 2
                }
                return true
            }
            guard candidates.count == 1, let match = candidates.first else { return nil }
            guard !existingSongIds.contains(match.id) || match.id == record.songId else { return nil }
            result.append((record, match))
            unusedSongs.removeAll { $0.id == match.id }
        }
        return result.count == records.count ? result : nil
    }

    static func reboundRecord(
        _ record: DownloadRecord,
        to song: Song,
        album: DownloadAlbumMetadata
    ) -> DownloadRecord {
        var updated = record
        updated.songId = song.id
        updated.albumId = song.albumId ?? album.id
        updated.artistId = song.artistId ?? album.artistId ?? record.artistId
        updated.title = song.title
        updated.albumTitle = song.album ?? album.name
        updated.artistName = song.artist
            ?? song.displayArtist
            ?? album.artist
            ?? record.artistName
        updated.albumArtistName = song.displayAlbumArtist
            ?? song.albumArtists?.first?.name
            ?? album.artist
            ?? record.albumArtistName
        updated.track = song.track
        updated.disc = song.discNumber
        updated.duration = song.duration
        updated.year = song.year ?? album.year
        updated.genre = song.genre ?? album.genre
        updated.playCount = song.playCount
        updated.explicitStatus = song.explicitStatus
        updated.coverArtId = song.coverArt ?? album.coverArt ?? record.coverArtId
        updated.albumCoverArtId = album.coverArt ?? record.albumCoverArtId
        updated.isFavorite = song.starred != nil
        updated.bpm = song.bpm
        updated.replayGainTrackGain = song.replayGain?.trackGain
        updated.replayGainAlbumGain = song.replayGain?.albumGain

        // Intentionally untouched: filePath, bytes, extension/content type,
        // local codec properties and addedAt describe the already-downloaded file.
        return updated
    }
}

private nonisolated struct DownloadIdentityAlbumRepair: Sendable {
    let oldAlbumId: String
    let newAlbum: AlbumDetail
    let matches: [(DownloadRecord, Song)]
}

actor DownloadIdentityRepairService {
    static let shared = DownloadIdentityRepairService()

    private static let scopeKeyPrefix = "shelv_download_scope_server_id_"
    private static let pendingScopeKeyPrefix = "shelv_pending_download_scope_migration_"
    private static let identityAuditKeyPrefix = "shelv_download_identity_audit_"
    private static let pendingPlaylistRebindKeyPrefix = "shelv_pending_offline_playlist_song_rebind_"
    private static let albumFetchConcurrency = 8

    private init() {}

    /// Remembers the download scope used by a configured server. If Navidrome
    /// later rotates the remote user/stable ID, the previous scope is queued for
    /// migration instead of making the existing downloads disappear.
    @discardableResult
    nonisolated static func prepareScopeMigration(serverId: String) -> String? {
        guard !serverId.isEmpty,
              let server = SubsonicAPIService.shared.activeServer,
              server.stableId == serverId
        else { return nil }

        let defaults = UserDefaults.standard
        let scopeKey = scopeKeyPrefix + server.id.uuidString
        guard let previous = defaults.string(forKey: scopeKey), !previous.isEmpty else {
            defaults.set(serverId, forKey: scopeKey)
            return nil
        }
        guard previous != serverId else { return nil }

        guard prepareKnownServerScopeMigration(
            from: previous,
            to: serverId,
            configurationID: server.id
        ) else {
            return nil
        }
        return previous
    }

    /// Records a known stable-ID rotation synchronously. ServerStore calls this
    /// before publishing the changed identity or launching background migration
    /// work, so Keep Library Offline can never observe the new scope as empty and
    /// enqueue a duplicate library first.
    @discardableResult
    nonisolated static func prepareKnownServerScopeMigration(
        from previous: String,
        to serverId: String,
        configurationID: UUID? = nil
    ) -> Bool {
        guard !previous.isEmpty, !serverId.isEmpty, previous != serverId else { return false }
        migrateServerScopedDefaults(from: previous, to: serverId)
        let defaults = UserDefaults.standard
        defaults.set(previous, forKey: pendingScopeKeyPrefix + serverId)
        if let configurationID {
            defaults.set(serverId, forKey: scopeKeyPrefix + configurationID.uuidString)
        }
        // Set this before async database work as well. If the process exits after
        // the rows move but before the identity audit runs, the next launch still
        // checks song/album identities before planning replacement downloads.
        defaults.set(true, forKey: identityAuditKeyPrefix + serverId)
        return true
    }

    /// Convenience entry point for callers that already know both identities.
    func migrateKnownServerScope(from previous: String, to serverId: String) async {
        guard Self.prepareKnownServerScopeMigration(from: previous, to: serverId) else { return }
        _ = await migratePendingServerScopeIfNeeded(serverId: serverId)
    }

    /// Returns false only when a queued migration could not be completed. Callers
    /// that might enqueue downloads must stop in that case and retry later.
    @discardableResult
    func migratePendingServerScopeIfNeeded(serverId: String) async -> Bool {
        let defaults = UserDefaults.standard
        let pendingKey = Self.pendingScopeKeyPrefix + serverId
        guard let previous = defaults.string(forKey: pendingKey),
              !previous.isEmpty,
              previous != serverId
        else { return true }

        let completed = await migrateServerScope(from: previous, to: serverId)
        if completed {
            defaults.removeObject(forKey: pendingKey)
        }
        return completed
    }

    /// Resumable and idempotent: the source scope is only cleared after every
    /// destination row/marker has been verified. No media file is moved or deleted.
    /// A failed/interrupted run leaves the pending marker in place for retry.
    @discardableResult
    private func migrateServerScope(from previous: String, to serverId: String) async -> Bool {
        guard !previous.isEmpty, !serverId.isEmpty, previous != serverId else { return true }

        Self.migrateServerScopedDefaults(from: previous, to: serverId)

        let database = DownloadDatabase.shared
        let oldRecords = await database.allRecords(serverId: previous)
        let newSongIds = await database.allSongIds(serverId: serverId)

        for record in oldRecords {
            if !newSongIds.contains(record.songId) {
                var migrated = record
                migrated.serverId = serverId
                await database.upsert(migrated)
            }

            guard let destination = await database.record(
                songId: record.songId,
                serverId: serverId
            ),
            destination.filePath == record.filePath,
            destination.bytes == record.bytes,
            destination.addedAt == record.addedAt
            else {
                continue
            }

            // Only database ownership changes. Conditional deletion protects a
            // concurrent redownload that may have replaced the source snapshot.
            await database.deleteIfFilePathMatches(
                songId: record.songId,
                serverId: previous,
                expectedPath: record.filePath,
                expectedAddedAt: record.addedAt
            )
        }

        let oldManagedAlbums = await database.managedAlbumIds(serverId: previous)
        let recordsByAlbum = Dictionary(grouping: oldRecords, by: \.albumId)
        for albumId in oldManagedAlbums {
            let albumName = recordsByAlbum[albumId]?.first?.albumTitle ?? ""
            await database.markAlbumDownloaded(
                id: albumId,
                name: albumName,
                serverId: serverId
            )
        }
        let newManagedAlbums = await database.managedAlbumIds(serverId: serverId)
        for albumId in oldManagedAlbums where newManagedAlbums.contains(albumId) {
            await database.unmarkAlbumDownloaded(id: albumId, serverId: previous)
        }

        let oldPlaylists = await database.loadDownloadedPlaylistMarkers(serverId: previous)
        for playlist in oldPlaylists {
            await database.markPlaylistDownloaded(
                id: playlist.id,
                name: playlist.name,
                serverId: serverId
            )
        }
        let newPlaylistIds = await database.loadDownloadedPlaylistIds(serverId: serverId)
        for playlist in oldPlaylists where newPlaylistIds.contains(playlist.id) {
            await database.unmarkPlaylistDownloaded(id: playlist.id, serverId: previous)
        }

        let remainingRecords = await database.allRecords(serverId: previous)
        let remainingAlbums = await database.managedAlbumIds(serverId: previous)
        let remainingPlaylists = await database.loadDownloadedPlaylistIds(serverId: previous)
        let completed = remainingRecords.isEmpty
            && remainingAlbums.isEmpty
            && remainingPlaylists.isEmpty

        if completed {
            // Clears transient strike/reconciliation state that is intentionally
            // rebuilt under the new identity. There are no media records left in
            // the old scope at this point, so this cannot delete audio files.
            await database.deleteAllForServer(previous)
            await MainActor.run {
                NotificationCenter.default.post(name: .downloadsLibraryChanged, object: nil)
            }
        }
        return completed
    }

    /// Detects the destructive case where a large portion of downloaded album
    /// IDs vanished after a server rescan. Exact metadata matches are rebound to
    /// the new IDs while keeping filePath/bytes/local codec metadata untouched.
    /// If the bulk change cannot be matched safely, the caller must not enqueue
    /// a replacement full-library download.
    func repairLibraryIdentityIfNeeded(
        serverId: String,
        libraryAlbums: [Album]
    ) async -> DownloadIdentityRepairResult {
        let database = DownloadDatabase.shared
        await applyPendingOfflinePlaylistSongRebindsIfReady(
            serverId: serverId,
            database: database
        )

        let localRecords = await database.allRecords(serverId: serverId)
        guard !localRecords.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.identityAuditKeyPrefix + serverId)
            return .unchanged
        }

        let currentAlbumIds = Set(libraryAlbums.map(\.id))
        let localByAlbum = Dictionary(
            grouping: localRecords.filter { !$0.albumId.isEmpty },
            by: \.albumId
        )
        let orphanedAlbums = localByAlbum.filter { !currentAlbumIds.contains($0.key) }
        let orphanedSongCount = orphanedAlbums.values.reduce(0) { $0 + $1.count }
        let forcedAudit = UserDefaults.standard.bool(
            forKey: Self.identityAuditKeyPrefix + serverId
        )
        let largeChurn = DownloadIdentityRepairPolicy.isLargeIdentityChurn(
            orphanedSongs: orphanedSongCount,
            totalSongs: localRecords.count
        )

        guard forcedAudit || largeChurn else { return .unchanged }

        let candidateAlbums: [String: [DownloadRecord]]
        if forcedAudit {
            // A stable-ID rotation is strong evidence that surviving albums may
            // have regenerated song IDs. Audit local albums that still have a
            // unique counterpart; albums genuinely removed from the server are
            // left to the normal reconciliation path instead of blocking forever.
            candidateAlbums = DownloadIdentityRepairPolicy.suspectedReidentifiedAlbums(
                localByAlbum,
                in: libraryAlbums
            )
        } else {
            // Ordinary removals can also produce many orphaned downloads. Only
            // treat them as an identity reset when a large share has a unique,
            // metadata-equivalent replacement album in the current library.
            candidateAlbums = DownloadIdentityRepairPolicy.suspectedReidentifiedAlbums(
                orphanedAlbums,
                in: libraryAlbums
            )
            let suspectedSongCount = candidateAlbums.values.reduce(0) { $0 + $1.count }
            guard DownloadIdentityRepairPolicy.isLargeIdentityChurn(
                orphanedSongs: suspectedSongCount,
                totalSongs: localRecords.count
            ) else {
                return .unchanged
            }
        }

        guard !candidateAlbums.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.identityAuditKeyPrefix + serverId)
            return .unchanged
        }

        let repairs = await buildRepairs(
            serverId: serverId,
            candidateAlbums: candidateAlbums,
            libraryAlbums: libraryAlbums,
            existingSongIds: await database.allSongIds(serverId: serverId)
        )

        var repairedSongs = 0
        let managedAlbumIds = await database.managedAlbumIds(serverId: serverId)
        var repairedAlbumIds = Set<String>()

        for repair in repairs {
            let albumMetadata = DownloadAlbumMetadata(
                id: repair.newAlbum.id,
                name: repair.newAlbum.name,
                artist: repair.newAlbum.artist,
                artistId: repair.newAlbum.artistId,
                coverArt: repair.newAlbum.coverArt,
                songCount: repair.newAlbum.songCount,
                duration: repair.newAlbum.duration,
                year: repair.newAlbum.year,
                genre: repair.newAlbum.genre
            )

            var replacements: [DownloadIdentityRecordReplacement] = []
            var albumSongIdMap: [String: String] = [:]
            for (oldRecord, song) in repair.matches {
                let updated = DownloadIdentityRepairPolicy.reboundRecord(
                    oldRecord,
                    to: song,
                    album: albumMetadata
                )
                replacements.append(
                    DownloadIdentityRecordReplacement(
                        previous: oldRecord,
                        updated: updated
                    )
                )
                if oldRecord.songId != song.id {
                    albumSongIdMap[oldRecord.songId] = song.id
                }
            }

            if !albumSongIdMap.isEmpty {
                Self.queuePendingOfflinePlaylistSongRebind(
                    serverId: serverId,
                    songIdMap: albumSongIdMap
                )
            }

            let rebound = await database.rebindAlbumIdentity(
                replacements: replacements,
                serverId: serverId,
                oldAlbumId: repair.oldAlbumId,
                newAlbumId: repair.newAlbum.id,
                newAlbumName: repair.newAlbum.name,
                migrateManagedAlbum: managedAlbumIds.contains(repair.oldAlbumId)
            )
            guard rebound else { continue }

            repairedSongs += replacements.count
            repairedAlbumIds.insert(repair.oldAlbumId)
            await applyPendingOfflinePlaylistSongRebindsIfReady(
                serverId: serverId,
                database: database
            )
        }

        if repairedSongs > 0 {
            await MainActor.run {
                NotificationCenter.default.post(name: .downloadsLibraryChanged, object: nil)
            }
        }

        let unresolvedAlbumIds = Set(candidateAlbums.keys).subtracting(repairedAlbumIds)
        let unresolvedSongs = unresolvedAlbumIds.reduce(0) {
            $0 + (candidateAlbums[$1]?.count ?? 0)
        }
        if unresolvedSongs > 0 {
            return .blocked(
                unresolvedSongs: unresolvedSongs,
                totalSongs: localRecords.count
            )
        }

        await applyPendingOfflinePlaylistSongRebindsIfReady(
            serverId: serverId,
            database: database
        )
        UserDefaults.standard.removeObject(forKey: Self.identityAuditKeyPrefix + serverId)
        return repairedSongs > 0 ? .repaired(repairedSongs) : .unchanged
    }

    private func buildRepairs(
        serverId: String,
        candidateAlbums: [String: [DownloadRecord]],
        libraryAlbums: [Album],
        existingSongIds: Set<String>
    ) async -> [DownloadIdentityAlbumRepair] {
        var requests: [(String, [DownloadRecord], Album)] = []

        for (oldAlbumId, records) in candidateAlbums {
            guard let candidate = DownloadIdentityRepairPolicy.matchingAlbum(
                for: records,
                in: libraryAlbums
            ) else { continue }
            requests.append((oldAlbumId, records, candidate))
        }

        guard !requests.isEmpty else { return [] }

        return await withTaskGroup(of: DownloadIdentityAlbumRepair?.self) { group in
            var nextIndex = 0
            var repairs: [DownloadIdentityAlbumRepair] = []

            func enqueue(_ request: (String, [DownloadRecord], Album)) {
                group.addTask {
                    guard SubsonicAPIService.shared.activeServer?.stableId == serverId,
                          let detail = try? await SubsonicAPIService.shared.getAlbum(id: request.2.id),
                          let songs = detail.song,
                          let matches = DownloadIdentityRepairPolicy.matchAlbum(
                              records: request.1,
                              songs: songs,
                              existingSongIds: existingSongIds
                          )
                    else { return nil }
                    return DownloadIdentityAlbumRepair(
                        oldAlbumId: request.0,
                        newAlbum: detail,
                        matches: matches
                    )
                }
            }

            for request in requests.prefix(Self.albumFetchConcurrency) {
                enqueue(request)
                nextIndex += 1
            }

            for await repair in group {
                if let repair { repairs.append(repair) }
                if nextIndex < requests.count {
                    enqueue(requests[nextIndex])
                    nextIndex += 1
                }
            }
            return repairs
        }
    }

    private func applyPendingOfflinePlaylistSongRebindsIfReady(
        serverId: String,
        database: DownloadDatabase
    ) async {
        let pending = Self.pendingOfflinePlaylistSongRebind(serverId: serverId)
        guard !pending.isEmpty else { return }

        let existingSongIds = await database.allSongIds(serverId: serverId)
        let ready = pending.filter { oldId, newId in
            existingSongIds.contains(newId) && !existingSongIds.contains(oldId)
        }
        guard !ready.isEmpty else { return }

        Self.rebindOfflinePlaylistSongIds(serverId: serverId, songIdMap: ready)
        var remaining = pending
        for oldId in ready.keys {
            remaining.removeValue(forKey: oldId)
        }
        Self.storePendingOfflinePlaylistSongRebind(
            serverId: serverId,
            songIdMap: remaining
        )
    }

    private nonisolated static func migrateServerScopedDefaults(from old: String, to new: String) {
        let defaults = UserDefaults.standard
        let prefixes = [
            "shelv_keep_library_offline_",
            "shelv_keep_library_offline_low_storage_signature_",
            "shelv_keep_library_offline_storage_pause_",
            "shelv_keep_library_offline_fully_paused_",
            "shelv_offline_playlists_",
            "shelv_offline_playlist_songs_",
            "shelv_offline_playlist_names_",
            "shelv_mac_playlist_song_ids_",
            "shelv_artist_cover_by_name_",
        ]
        for prefix in prefixes {
            let oldKey = prefix + old
            let newKey = prefix + new
            guard defaults.object(forKey: newKey) == nil,
                  let value = defaults.object(forKey: oldKey)
            else { continue }
            defaults.set(value, forKey: newKey)
            defaults.removeObject(forKey: oldKey)
        }
    }

    private nonisolated static func pendingOfflinePlaylistSongRebind(
        serverId: String
    ) -> [String: String] {
        let key = pendingPlaylistRebindKeyPrefix + serverId
        guard let data = UserDefaults.standard.data(forKey: key),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }

    private nonisolated static func queuePendingOfflinePlaylistSongRebind(
        serverId: String,
        songIdMap: [String: String]
    ) {
        guard !songIdMap.isEmpty else { return }
        var pending = pendingOfflinePlaylistSongRebind(serverId: serverId)
        pending.merge(songIdMap) { _, new in new }
        storePendingOfflinePlaylistSongRebind(
            serverId: serverId,
            songIdMap: pending
        )
    }

    private nonisolated static func storePendingOfflinePlaylistSongRebind(
        serverId: String,
        songIdMap: [String: String]
    ) {
        let defaults = UserDefaults.standard
        let key = pendingPlaylistRebindKeyPrefix + serverId
        guard !songIdMap.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(songIdMap) {
            defaults.set(data, forKey: key)
        }
    }

    private nonisolated static func rebindOfflinePlaylistSongIds(
        serverId: String,
        songIdMap: [String: String]
    ) {
        guard !songIdMap.isEmpty else { return }
        let playlists = LocalOfflinePlaylistCatalog.songIds(serverId: serverId)
        for (playlistId, songIds) in playlists {
            let rebound = songIds.map { songIdMap[$0] ?? $0 }
            if rebound != songIds {
                LocalOfflinePlaylistCatalog.updateSongIds(
                    serverId: serverId,
                    id: playlistId,
                    songIds: rebound
                )
            }
        }
    }
}
