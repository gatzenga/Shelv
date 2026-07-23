import Foundation
import GRDB

nonisolated struct DownloadAlbumMembershipReconciliation: Sendable {
    let removedSongIDs: Set<String>
    let missingSongs: [Song]

    static func make(
        localSongIDs: Set<String>,
        serverSongs: [Song]
    ) -> DownloadAlbumMembershipReconciliation {
        let serverSongIDs = Set(serverSongs.map(\.id))
        return DownloadAlbumMembershipReconciliation(
            removedSongIDs: localSongIDs.subtracting(serverSongIDs),
            missingSongs: serverSongs.filter { !localSongIDs.contains($0.id) }
        )
    }
}

// MARK: - Records

nonisolated struct DownloadRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    var songId: String
    var serverId: String
    var albumId: String
    var artistId: String?
    var title: String
    var albumTitle: String
    var artistName: String
    var track: Int?
    var disc: Int?
    var duration: Int?
    var year: Int?
    var genre: String?
    var playCount: Int?
    var explicitStatus: String?
    var bytes: Int64
    var coverArtId: String?
    var artistCoverArtId: String?
    var albumArtistName: String?
    var albumCoverArtId: String?
    var isFavorite: Bool
    var filePath: String
    var fileExtension: String
    var contentType: String?
    var bitRate: Int?
    var bitDepth: Int?
    var samplingRate: Int?
    var channelCount: Int?
    var bpm: Int?
    var replayGainTrackGain: Float?
    var replayGainAlbumGain: Float?
    var addedAt: Double

    static let databaseTableName = "downloads"

    func toDownloadedSong() -> DownloadedSong {
        DownloadedSong(
            songId: songId,
            serverId: serverId,
            albumId: albumId,
            artistId: artistId,
            title: title,
            albumTitle: albumTitle,
            artistName: artistName,
            albumArtistName: albumArtistName,
            albumCoverArtId: albumCoverArtId,
            track: track,
            disc: disc,
            duration: duration,
            year: year,
            genre: genre,
            playCount: playCount,
            explicitStatus: explicitStatus,
            bytes: bytes,
            coverArtId: coverArtId,
            artistCoverArtId: artistCoverArtId,
            isFavorite: isFavorite,
            filePath: filePath,
            fileExtension: fileExtension,
            contentType: contentType,
            bitRate: bitRate,
            bitDepth: bitDepth,
            samplingRate: samplingRate,
            channelCount: channelCount,
            bpm: bpm,
            replayGainTrackGain: replayGainTrackGain,
            replayGainAlbumGain: replayGainAlbumGain,
            addedAt: Date(timeIntervalSince1970: addedAt)
        )
    }
}

struct MissingStrikeRecord: Codable, FetchableRecord, PersistableRecord {
    var songId: String
    var serverId: String
    var strikeCount: Int
    var lastStrikeAt: Double

    static let databaseTableName = "missing_song_strikes"
}

nonisolated enum DownloadCollectionKind: String, Sendable {
    case album
    case playlist
}

nonisolated struct DownloadCollectionObservation: Sendable {
    let id: String
    let signature: String
}

nonisolated struct DownloadAlbumMetadata: Sendable {
    let id: String
    let name: String
    let artist: String?
    let artistId: String?
    let coverArt: String?
    let songCount: Int?
    let duration: Int?
    let year: Int?
    let genre: String?
}

nonisolated struct DownloadRecordMetadataChange: Sendable {
    let previous: DownloadRecord
    let updated: DownloadRecord
}

nonisolated struct DownloadMetadataUpdate: Sendable {
    let changes: [DownloadRecordMetadataChange]

    static let empty = DownloadMetadataUpdate(changes: [])
    var isEmpty: Bool { changes.isEmpty }
}

// MARK: - DownloadDatabase

actor DownloadDatabase {
    static let shared = DownloadDatabase(databaseURL: DownloadDatabase.dbURL)

    private var pool: DatabasePool?
    private let databaseURL: URL

    private init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    #if SHELV_LOGIC_TESTS
    init(testDatabaseURL: URL) {
        self.databaseURL = testDatabaseURL
    }
    #endif

    static var dbURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shelv_downloads/downloads.db")
    }

    func setup() {
        // Startup owns more than one independent initialization pipeline.  The actor
        // serializes those calls, but without this guard it still reopened and
        // migrated the same database twice.
        guard pool == nil else { return }
        let url = databaseURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.applyDataProtection(at: url)
        if let p = try? openAndMigrate(at: url) {
            pool = p
            Self.applyDataProtection(at: url) // erneut nach WAL/SHM-Erstellung
            return
        }
        // Recovery: DB + WAL + SHM löschen und neu versuchen
        DBErrorLog.logPlayLog("DownloadDatabase: opening DB failed — recovering by deleting files")
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        do {
            pool = try openAndMigrate(at: url)
            Self.applyDataProtection(at: url)
        } catch {
            DBErrorLog.logPlayLog("DownloadDatabase setup totally failed: \(error.localizedDescription)")
        }
    }

    /// Erlaubt SQLite-Zugriff auch bei gesperrtem Screen (für Background-Downloads).
    /// iOS-Default ist `.complete` → DB nicht zugänglich wenn Screen lockt → I/O-Errors.
    private static func applyDataProtection(at url: URL) {
        #if os(iOS)
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: path
            )
        }
        // Kein iCloud-Backup für die DB
        var dirURL = url.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dirURL.setResourceValues(values)
        #endif
    }

    private func openAndMigrate(at url: URL) throws -> DatabasePool {
        var config = Configuration()
        config.label = "shelv.db.downloads"
        // Download state is also read by interactive library and search surfaces.
        // Match their priority so they never block on a lower-priority GRDB queue.
        config.qos = .userInitiated
        #if os(iOS)
        // Avoid closing idle readers from GRDB's main-thread lifecycle callback.
        config.persistentReadOnlyConnections = true
        #endif
        let p = try DatabasePool(path: url.path, configuration: config)
        var m = DatabaseMigrator()
        m.registerMigration("v1_create") { db in
            try db.create(table: "downloads", ifNotExists: true) { t in
                t.column("songId", .text).notNull()
                t.column("serverId", .text).notNull()
                t.column("albumId", .text).notNull()
                t.column("artistId", .text)
                t.column("title", .text).notNull()
                t.column("albumTitle", .text).notNull()
                t.column("artistName", .text).notNull()
                t.column("track", .integer)
                t.column("disc", .integer)
                t.column("duration", .integer)
                t.column("bytes", .integer).notNull()
                t.column("coverArtId", .text)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("filePath", .text).notNull()
                t.column("fileExtension", .text).notNull()
                t.column("addedAt", .double).notNull()
                t.primaryKey(["songId", "serverId"])
            }
            try db.create(index: "idx_downloads_album", on: "downloads",
                          columns: ["serverId", "albumId"], ifNotExists: true)
            try db.create(index: "idx_downloads_artist", on: "downloads",
                          columns: ["serverId", "artistId"], ifNotExists: true)
            try db.create(index: "idx_downloads_favorite", on: "downloads",
                          columns: ["serverId", "isFavorite"], ifNotExists: true)
            try db.create(table: "missing_song_strikes", ifNotExists: true) { t in
                t.column("songId", .text).notNull()
                t.column("serverId", .text).notNull()
                t.column("strikeCount", .integer).notNull()
                t.column("lastStrikeAt", .double).notNull()
                t.primaryKey(["songId", "serverId"])
            }
        }
        m.registerMigration("v2_add_artist_cover") { db in
            let cols = try db.columns(in: "downloads").map(\.name)
            guard !cols.contains("artistCoverArtId") else { return }
            try db.alter(table: "downloads") { t in
                t.add(column: "artistCoverArtId", .text)
            }
        }
        m.registerMigration("v3_add_album_artist") { db in
            let cols = try db.columns(in: "downloads").map(\.name)
            guard !cols.contains("albumArtistName") || !cols.contains("albumCoverArtId") else { return }
            try db.alter(table: "downloads") { t in
                if !cols.contains("albumArtistName") {
                    t.add(column: "albumArtistName", .text)
                }
                if !cols.contains("albumCoverArtId") {
                    t.add(column: "albumCoverArtId", .text)
                }
            }
        }
        // Stammt aus der alten Desktop-App: Playlist-Download-Marker leben dort in
        // der DB (iOS nutzt UserDefaults). Tabelle existiert auf iOS einfach mit.
        m.registerMigration("v4_add_playlist_registry") { db in
            try db.create(table: "downloaded_playlists", ifNotExists: true) { t in
                t.column("playlist_id", .text).primaryKey()
                t.column("playlist_name", .text).notNull()
                t.column("downloaded_at", .integer).notNull()
            }
        }
        m.registerMigration("v5_add_song_detail_metadata") { db in
            let cols = try db.columns(in: "downloads").map(\.name)
            try db.alter(table: "downloads") { t in
                if !cols.contains("year") {
                    t.add(column: "year", .integer)
                }
                if !cols.contains("genre") {
                    t.add(column: "genre", .text)
                }
                if !cols.contains("playCount") {
                    t.add(column: "playCount", .integer)
                }
                if !cols.contains("explicitStatus") {
                    t.add(column: "explicitStatus", .text)
                }
                if !cols.contains("contentType") {
                    t.add(column: "contentType", .text)
                }
                if !cols.contains("bitRate") {
                    t.add(column: "bitRate", .integer)
                }
                if !cols.contains("bitDepth") {
                    t.add(column: "bitDepth", .integer)
                }
                if !cols.contains("samplingRate") {
                    t.add(column: "samplingRate", .integer)
                }
                if !cols.contains("channelCount") {
                    t.add(column: "channelCount", .integer)
                }
                if !cols.contains("bpm") {
                    t.add(column: "bpm", .integer)
                }
                if !cols.contains("replayGainTrackGain") {
                    t.add(column: "replayGainTrackGain", .double)
                }
                if !cols.contains("replayGainAlbumGain") {
                    t.add(column: "replayGainAlbumGain", .double)
                }
            }
        }
        m.registerMigration("v6_scope_playlist_registry_to_server") { db in
            try db.execute(sql: """
                CREATE TABLE downloaded_playlists_v6 (
                    server_id TEXT NOT NULL,
                    playlist_id TEXT NOT NULL,
                    playlist_name TEXT NOT NULL,
                    downloaded_at INTEGER NOT NULL,
                    PRIMARY KEY (server_id, playlist_id)
                )
                """)
            try db.execute(sql: """
                INSERT INTO downloaded_playlists_v6 (
                    server_id, playlist_id, playlist_name, downloaded_at
                )
                SELECT '', playlist_id, playlist_name, downloaded_at
                FROM downloaded_playlists
                """)
            try db.drop(table: "downloaded_playlists")
            try db.rename(table: "downloaded_playlists_v6", to: "downloaded_playlists")
        }
        m.registerMigration("v7_add_collection_reconciliation") { db in
            try db.create(table: "downloaded_albums", ifNotExists: true) { t in
                t.column("server_id", .text).notNull()
                t.column("album_id", .text).notNull()
                t.column("album_name", .text).notNull()
                t.column("downloaded_at", .double).notNull()
                t.primaryKey(["server_id", "album_id"])
            }
            try db.create(table: "download_collection_sync", ifNotExists: true) { t in
                t.column("server_id", .text).notNull()
                t.column("collection_kind", .text).notNull()
                t.column("collection_id", .text).notNull()
                t.column("summary_signature", .text).notNull()
                t.column("last_detail_sync", .double).notNull()
                t.primaryKey(["server_id", "collection_kind", "collection_id"])
            }
        }
        try m.migrate(p)
        return p
    }

    private var consecutiveIOErrors = 0
    private var circuitOpenUntil: Date?
    private var hasLoggedCircuitOpen = false
    private var walProtectionApplied = false
    private static let maxConsecutiveIOErrors = 3
    private static let circuitCooldown: TimeInterval = 30

    private func safeWrite(_ label: String = #function, _ block: (Database) throws -> Void) {
        if let until = circuitOpenUntil, Date() < until {
            return
        }
        if circuitOpenUntil != nil {
            circuitOpenUntil = nil
            hasLoggedCircuitOpen = false
            reopenPool(deleteCorruptFiles: true)
        }
        guard let pool else {
            tripCircuit(label: label, error: "pool not initialized")
            return
        }
        do {
            try pool.write(block)
            consecutiveIOErrors = 0
            // WAL wird von GRDB lazy beim ersten Write erstellt — Schutz einmalig nachholen
            if !walProtectionApplied {
                Self.applyDataProtection(at: databaseURL)
                walProtectionApplied = true
            }
        } catch {
            let isIOError = "\(error)".contains("disk I/O") || "\(error)".contains("error 10")
            if isIOError {
                consecutiveIOErrors += 1
                if consecutiveIOErrors == 1 {
                    DBErrorLog.logPlayLog("DownloadDatabase \(label): \(error.localizedDescription) — attempting reopen")
                    reopenPool(deleteCorruptFiles: false)
                    if let p = self.pool {
                        do {
                            try p.write(block)
                            consecutiveIOErrors = 0
                            return
                        } catch {
                            // fall through
                        }
                    }
                }
                if consecutiveIOErrors >= Self.maxConsecutiveIOErrors {
                    tripCircuit(label: label, error: error.localizedDescription)
                }
            } else {
                DBErrorLog.logPlayLog("DownloadDatabase \(label): \(error.localizedDescription)")
            }
        }
    }

    private func tripCircuit(label: String, error: String) {
        circuitOpenUntil = Date().addingTimeInterval(Self.circuitCooldown)
        if !hasLoggedCircuitOpen {
            DBErrorLog.logPlayLog("DownloadDatabase \(label): \(error) — circuit open for \(Int(Self.circuitCooldown))s, suppressing further writes")
            hasLoggedCircuitOpen = true
        }
        pool = nil
    }

    private func reopenPool(deleteCorruptFiles: Bool) {
        let url = databaseURL
        pool = nil
        walProtectionApplied = false
        if deleteCorruptFiles {
            for suffix in ["-wal", "-shm"] {
                let path = url.path + suffix
                if FileManager.default.fileExists(atPath: path) {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
        }
        Self.applyDataProtection(at: url)
        if let p = try? openAndMigrate(at: url) {
            pool = p
            Self.applyDataProtection(at: url)
        }
    }

    // MARK: - Insert / Update

    func upsert(_ record: DownloadRecord) {
        safeWrite { db in try record.insert(db, onConflict: .replace) }
    }

    func setFavorite(songId: String, serverId: String, isFavorite: Bool) {
        safeWrite { db in
            try db.execute(
                sql: "UPDATE downloads SET isFavorite = ? WHERE songId = ? AND serverId = ?",
                arguments: [isFavorite, songId, serverId]
            )
        }
    }

    func syncFavorites(serverId: String, starredSongIds: Set<String>) {
        safeWrite { db in
            // Alle auf 0
            try db.execute(
                sql: "UPDATE downloads SET isFavorite = 0 WHERE serverId = ?",
                arguments: [serverId]
            )
            guard !starredSongIds.isEmpty else { return }
            let placeholders = starredSongIds.map { _ in "?" }.joined(separator: ",")
            var args: [DatabaseValueConvertible] = [serverId]
            for id in starredSongIds { args.append(id) }
            try db.execute(
                sql: "UPDATE downloads SET isFavorite = 1 WHERE serverId = ? AND songId IN (\(placeholders))",
                arguments: StatementArguments(args)
            )
        }
    }

    // MARK: - Server Metadata Reconciliation

    func updateObservedSongs(
        _ songs: [Song],
        serverId: String,
        albumMetadata: DownloadAlbumMetadata? = nil
    ) -> DownloadMetadataUpdate {
        guard !songs.isEmpty else { return .empty }
        let songsByID = Dictionary(
            songs.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var result = DownloadMetadataUpdate.empty
        safeWrite { db in
            let songIDs = Array(songsByID.keys)
            let placeholders = songIDs.map { _ in "?" }.joined(separator: ",")
            var arguments: [DatabaseValueConvertible] = [serverId]
            arguments.append(contentsOf: songIDs)
            let records = try DownloadRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM downloads
                    WHERE serverId = ? AND songId IN (\(placeholders))
                    """,
                arguments: StatementArguments(arguments)
            )
            var changes: [DownloadRecordMetadataChange] = []
            for var record in records {
                guard let song = songsByID[record.songId] else { continue }
                let previous = record
                Self.applyServerSongMetadata(
                    song,
                    albumMetadata: albumMetadata,
                    to: &record
                )
                guard record != previous else { continue }
                try record.insert(db, onConflict: .replace)
                changes.append(.init(previous: previous, updated: record))
            }
            result = DownloadMetadataUpdate(changes: changes)
        }
        return result
    }

    func updateAlbumSummaries(
        _ albums: [Album],
        serverId: String
    ) -> DownloadMetadataUpdate {
        guard !albums.isEmpty else { return .empty }
        let albumsByID = Dictionary(
            albums.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var result = DownloadMetadataUpdate.empty
        safeWrite { db in
            let albumIDs = Array(albumsByID.keys)
            let placeholders = albumIDs.map { _ in "?" }.joined(separator: ",")
            var arguments: [DatabaseValueConvertible] = [serverId]
            arguments.append(contentsOf: albumIDs)
            let records = try DownloadRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM downloads
                    WHERE serverId = ? AND albumId IN (\(placeholders))
                    """,
                arguments: StatementArguments(arguments)
            )
            var changes: [DownloadRecordMetadataChange] = []
            for var record in records {
                guard let album = albumsByID[record.albumId] else { continue }
                let previous = record
                Self.applyServerAlbumMetadata(album, to: &record)
                guard record != previous else { continue }
                try record.insert(db, onConflict: .replace)
                changes.append(.init(previous: previous, updated: record))
            }
            result = DownloadMetadataUpdate(changes: changes)
        }
        return result
    }

    func updateArtistSummaries(
        _ artists: [Artist],
        serverId: String
    ) -> DownloadMetadataUpdate {
        guard !artists.isEmpty else { return .empty }
        let artistsByID = Dictionary(
            artists.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var result = DownloadMetadataUpdate.empty
        safeWrite { db in
            let artistIDs = Array(artistsByID.keys)
            let placeholders = artistIDs.map { _ in "?" }.joined(separator: ",")
            var arguments: [DatabaseValueConvertible] = [serverId]
            arguments.append(contentsOf: artistIDs)
            let records = try DownloadRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM downloads
                    WHERE serverId = ? AND artistId IN (\(placeholders))
                    """,
                arguments: StatementArguments(arguments)
            )
            var changes: [DownloadRecordMetadataChange] = []
            for var record in records {
                guard let artistID = record.artistId,
                      let artist = artistsByID[artistID]
                else { continue }
                let previous = record
                let oldArtistName = record.artistName
                record.artistName = artist.name
                record.artistCoverArtId = artist.coverArt
                if record.albumArtistName == oldArtistName {
                    record.albumArtistName = artist.name
                }
                guard record != previous else { continue }
                try record.insert(db, onConflict: .replace)
                changes.append(.init(previous: previous, updated: record))
            }
            result = DownloadMetadataUpdate(changes: changes)
        }
        return result
    }

    nonisolated static func albumSignature(_ album: Album) -> String {
        signature([
            album.id,
            album.name,
            album.artist,
            album.artistId,
            album.coverArt,
            album.songCount.map(String.init),
            album.duration.map(String.init),
            album.year.map(String.init),
            album.genre,
        ])
    }

    nonisolated static func albumSignature(_ album: DownloadAlbumMetadata) -> String {
        signature([
            album.id,
            album.name,
            album.artist,
            album.artistId,
            album.coverArt,
            album.songCount.map(String.init),
            album.duration.map(String.init),
            album.year.map(String.init),
            album.genre,
        ])
    }

    nonisolated static func playlistSignature(_ playlist: Playlist) -> String {
        signature([
            playlist.id,
            playlist.name,
            playlist.comment,
            playlist.songCount.map(String.init),
            playlist.duration.map(String.init),
            playlist.coverArt,
            playlist.changed.map { String($0.timeIntervalSince1970) },
        ])
    }

    // MARK: - Managed Collections

    func markAlbumDownloaded(
        id: String,
        name: String,
        serverId: String
    ) {
        guard !id.isEmpty, !serverId.isEmpty else { return }
        safeWrite { db in
            try db.execute(
                sql: """
                    INSERT INTO downloaded_albums (
                        server_id, album_id, album_name, downloaded_at
                    ) VALUES (?, ?, ?, ?)
                    ON CONFLICT(server_id, album_id) DO UPDATE SET
                        album_name = excluded.album_name
                    """,
                arguments: [serverId, id, name, Date().timeIntervalSince1970]
            )
        }
    }

    func unmarkAlbumDownloaded(id: String, serverId: String) {
        guard !id.isEmpty, !serverId.isEmpty else { return }
        safeWrite { db in
            try db.execute(
                sql: "DELETE FROM downloaded_albums WHERE server_id = ? AND album_id = ?",
                arguments: [serverId, id]
            )
            try db.execute(
                sql: """
                    DELETE FROM download_collection_sync
                    WHERE server_id = ? AND collection_kind = ? AND collection_id = ?
                    """,
                arguments: [serverId, DownloadCollectionKind.album.rawValue, id]
            )
        }
    }

    func managedAlbumIds(serverId: String) -> Set<String> {
        guard let pool else { return [] }
        let ids: [String] = (try? pool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT album_id FROM downloaded_albums WHERE server_id = ?",
                arguments: [serverId]
            )
        }) ?? []
        return Set(ids)
    }

    func collectionRefreshCandidates(
        kind: DownloadCollectionKind,
        observations: [DownloadCollectionObservation],
        serverId: String,
        managedIds: Set<String>,
        staleBefore: Double?,
        staleLimit: Int
    ) -> [String] {
        guard let pool, !observations.isEmpty, !managedIds.isEmpty else { return [] }
        let observationsByID = Dictionary(
            observations
                .filter { managedIds.contains($0.id) }
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard !observationsByID.isEmpty else { return [] }

        struct SyncState {
            let signature: String
            let lastDetailSync: Double
        }

        let states: [String: SyncState] = (try? pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT collection_id, summary_signature, last_detail_sync
                    FROM download_collection_sync
                    WHERE server_id = ? AND collection_kind = ?
                    """,
                arguments: [serverId, kind.rawValue]
            )
            return Dictionary(
                uniqueKeysWithValues: rows.map { row in
                    (
                        row["collection_id"] as String,
                        SyncState(
                            signature: row["summary_signature"] as String,
                            lastDetailSync: row["last_detail_sync"] as Double
                        )
                    )
                }
            )
        }) ?? [:]

        let changed = observationsByID.values
            .filter { states[$0.id]?.signature != $0.signature }
            .map(\.id)
            .sorted()
        guard let staleBefore, staleLimit > 0 else { return changed }
        let changedIds = Set(changed)
        let stale = observationsByID.values
            .compactMap { observation -> (id: String, date: Double)? in
                guard !changedIds.contains(observation.id),
                      let state = states[observation.id],
                      state.lastDetailSync < staleBefore
                else { return nil }
                return (observation.id, state.lastDetailSync)
            }
            .sorted { $0.date < $1.date }
            .prefix(staleLimit)
            .map(\.id)
        return changed + stale
    }

    func noteCollectionDetail(
        kind: DownloadCollectionKind,
        id: String,
        serverId: String,
        signature: String,
        date: Double = Date().timeIntervalSince1970
    ) {
        guard !id.isEmpty, !serverId.isEmpty else { return }
        safeWrite { db in
            try db.execute(
                sql: """
                    INSERT INTO download_collection_sync (
                        server_id, collection_kind, collection_id,
                        summary_signature, last_detail_sync
                    ) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(server_id, collection_kind, collection_id) DO UPDATE SET
                        summary_signature = excluded.summary_signature,
                        last_detail_sync = excluded.last_detail_sync
                    """,
                arguments: [serverId, kind.rawValue, id, signature, date]
            )
        }
    }

    private nonisolated static func signature(_ values: [String?]) -> String {
        values.map { value in
            guard let value else { return "-1:" }
            return "\(value.utf8.count):\(value)"
        }.joined(separator: "|")
    }

    private nonisolated static func applyServerAlbumMetadata(
        _ album: Album,
        to record: inout DownloadRecord
    ) {
        let previousAlbumArtist = record.albumArtistName
        let previousAlbumCover = record.albumCoverArtId

        record.albumTitle = album.name
        if let artist = album.artist {
            record.albumArtistName = artist
        }
        if let coverArt = album.coverArt {
            record.albumCoverArtId = coverArt
        }
        record.year = album.year
        record.genre = album.genre

        if record.artistName == previousAlbumArtist, let artist = album.artist {
            record.artistName = artist
            record.artistId = album.artistId ?? record.artistId
        }
        if record.coverArtId == nil || record.coverArtId == previousAlbumCover {
            record.coverArtId = album.coverArt
        }
    }

    private nonisolated static func applyServerSongMetadata(
        _ song: Song,
        albumMetadata: DownloadAlbumMetadata?,
        to record: inout DownloadRecord
    ) {
        let resolvedAlbumArtist = song.displayAlbumArtist
            ?? song.albumArtists?.first?.name
            ?? albumMetadata?.artist
        let resolvedAlbumCover = albumMetadata?.coverArt
            ?? record.albumCoverArtId
            ?? song.coverArt

        record.albumId = song.albumId ?? albumMetadata?.id ?? record.albumId
        record.artistId = song.artistId ?? record.artistId
        record.title = song.title
        record.albumTitle = song.album ?? albumMetadata?.name ?? record.albumTitle
        record.artistName = song.artist
            ?? song.displayArtist
            ?? albumMetadata?.artist
            ?? record.artistName
        if let resolvedAlbumArtist {
            record.albumArtistName = resolvedAlbumArtist
        }
        if let resolvedAlbumCover {
            record.albumCoverArtId = resolvedAlbumCover
        }
        record.track = song.track
        record.disc = song.discNumber
        record.duration = song.duration
        record.year = song.year ?? albumMetadata?.year
        record.genre = song.genre ?? albumMetadata?.genre
        record.playCount = song.playCount
        record.explicitStatus = song.explicitStatus
        if let coverArt = song.coverArt ?? albumMetadata?.coverArt {
            record.coverArtId = coverArt
        }
        record.bpm = song.bpm
        record.replayGainTrackGain = song.replayGain?.trackGain
        record.replayGainAlbumGain = song.replayGain?.albumGain
        // filePath, bytes and codec properties describe the local audio file.
        // They must never be replaced by metadata describing the server source.
    }

    // MARK: - Delete

    func delete(songId: String, serverId: String) {
        safeWrite { db in
            try db.execute(
                sql: "DELETE FROM downloads WHERE songId = ? AND serverId = ?",
                arguments: [songId, serverId]
            )
            try db.execute(
                sql: "DELETE FROM missing_song_strikes WHERE songId = ? AND serverId = ?",
                arguments: [songId, serverId]
            )
        }
    }

    func deleteAlbum(albumId: String, serverId: String) {
        safeWrite { db in
            try db.execute(
                sql: "DELETE FROM downloads WHERE albumId = ? AND serverId = ?",
                arguments: [albumId, serverId]
            )
            try db.execute(
                sql: "DELETE FROM downloaded_albums WHERE server_id = ? AND album_id = ?",
                arguments: [serverId, albumId]
            )
            try db.execute(
                sql: """
                    DELETE FROM download_collection_sync
                    WHERE server_id = ? AND collection_kind = ? AND collection_id = ?
                    """,
                arguments: [serverId, DownloadCollectionKind.album.rawValue, albumId]
            )
        }
    }

    func deleteArtist(artistId: String, serverId: String) {
        safeWrite { db in
            let albumIds = try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT albumId FROM downloads
                    WHERE artistId = ? AND serverId = ? AND albumId != ''
                    """,
                arguments: [artistId, serverId]
            )
            try db.execute(
                sql: "DELETE FROM downloads WHERE artistId = ? AND serverId = ?",
                arguments: [artistId, serverId]
            )
            for albumId in albumIds {
                try db.execute(
                    sql: "DELETE FROM downloaded_albums WHERE server_id = ? AND album_id = ?",
                    arguments: [serverId, albumId]
                )
                try db.execute(
                    sql: """
                        DELETE FROM download_collection_sync
                        WHERE server_id = ? AND collection_kind = ? AND collection_id = ?
                        """,
                    arguments: [serverId, DownloadCollectionKind.album.rawValue, albumId]
                )
            }
        }
    }

    func deleteAllForServer(_ serverId: String) {
        safeWrite { db in
            try db.execute(
                sql: "DELETE FROM downloads WHERE serverId = ?",
                arguments: [serverId]
            )
            try db.execute(
                sql: "DELETE FROM missing_song_strikes WHERE serverId = ?",
                arguments: [serverId]
            )
            try db.execute(
                sql: "DELETE FROM downloaded_playlists WHERE server_id = ?",
                arguments: [serverId]
            )
            try db.execute(
                sql: "DELETE FROM downloaded_albums WHERE server_id = ?",
                arguments: [serverId]
            )
            try db.execute(
                sql: "DELETE FROM download_collection_sync WHERE server_id = ?",
                arguments: [serverId]
            )
        }
    }

    func deleteAll() {
        safeWrite { db in
            try db.execute(sql: "DELETE FROM downloads")
            try db.execute(sql: "DELETE FROM missing_song_strikes")
            try db.execute(sql: "DELETE FROM downloaded_playlists")
            try db.execute(sql: "DELETE FROM downloaded_albums")
            try db.execute(sql: "DELETE FROM download_collection_sync")
        }
    }

    // MARK: - Queries

    func record(songId: String, serverId: String) -> DownloadRecord? {
        guard let pool else { return nil }
        return try? pool.read { db in
            try DownloadRecord
                .filter(Column("songId") == songId && Column("serverId") == serverId)
                .fetchOne(db)
        }
    }

    func allRecords(serverId: String) -> [DownloadRecord] {
        guard let pool else { return [] }
        return (try? pool.read { db in
            try DownloadRecord
                .filter(Column("serverId") == serverId)
                .order(
                    Column("artistName").asc,
                    Column("albumTitle").asc,
                    Column("disc").asc,
                    Column("track").asc
                )
                .fetchAll(db)
        }) ?? []
    }

    func records(serverId: String, albumId: String) -> [DownloadRecord] {
        guard let pool else { return [] }
        return (try? pool.read { db in
            try DownloadRecord
                .filter(Column("serverId") == serverId && Column("albumId") == albumId)
                .order(Column("disc").asc, Column("track").asc)
                .fetchAll(db)
        }) ?? []
    }

    func records(serverId: String, albumIds: Set<String>) -> [DownloadRecord] {
        guard let pool, !albumIds.isEmpty else { return [] }
        let ids = Array(albumIds)
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        var arguments: [DatabaseValueConvertible] = [serverId]
        arguments.append(contentsOf: ids)
        return (try? pool.read { db in
            try DownloadRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM downloads
                    WHERE serverId = ? AND albumId IN (\(placeholders))
                    ORDER BY albumId ASC, disc ASC, track ASC
                    """,
                arguments: StatementArguments(arguments)
            )
        }) ?? []
    }

    func allAlbumIds(serverId: String) -> Set<String> {
        guard let pool else { return [] }
        let ids: [String] = (try? pool.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT albumId FROM downloads WHERE serverId = ? AND albumId != ''",
                                arguments: [serverId])
        }) ?? []
        return Set(ids)
    }

    func songIdsByAlbum(serverId: String, albumId: String) -> [String] {
        guard let pool else { return [] }
        return (try? pool.read { db in
            try String.fetchAll(db, sql: "SELECT songId FROM downloads WHERE serverId = ? AND albumId = ?",
                                arguments: [serverId, albumId])
        }) ?? []
    }

    func allSongIds(serverId: String) -> Set<String> {
        guard let pool else { return [] }
        let ids: [String] = (try? pool.read { db in
            try String.fetchAll(db, sql: "SELECT songId FROM downloads WHERE serverId = ?",
                                arguments: [serverId])
        }) ?? []
        return Set(ids)
    }

    func songCountsByAlbum(serverId: String) -> [String: Int] {
        guard let pool else { return [:] }
        return (try? pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT albumId, COUNT(*) AS count
                FROM downloads
                WHERE serverId = ? AND albumId != ''
                GROUP BY albumId
                """,
                arguments: [serverId]
            )
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                (row["albumId"] as String, row["count"] as Int)
            })
        }) ?? [:]
    }

    func isDownloaded(songId: String, serverId: String) -> Bool {
        guard let pool else { return false }
        let count: Int = (try? pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM downloads WHERE songId = ? AND serverId = ?",
                             arguments: [songId, serverId])
        }) ?? 0
        return count > 0
    }

    func filePath(songId: String, serverId: String) -> String? {
        guard let pool else { return nil }
        return try? pool.read { db in
            try String.fetchOne(db, sql: "SELECT filePath FROM downloads WHERE songId = ? AND serverId = ?",
                                arguments: [songId, serverId])
        } ?? nil
    }

    func totalBytes(serverId: String) -> Int64 {
        guard let pool else { return 0 }
        return (try? pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(bytes), 0) FROM downloads WHERE serverId = ?",
                               arguments: [serverId])
        }) ?? 0
    }

    func topArtistsByBytes(serverId: String, limit: Int) -> [(name: String, bytes: Int64)] {
        guard let pool else { return [] }
        return (try? pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT artistName AS name, SUM(bytes) AS total
                FROM downloads
                WHERE serverId = ?
                GROUP BY artistName
                ORDER BY total DESC
                LIMIT ?
                """, arguments: [serverId, limit])
            .map { (name: $0["name"] as String, bytes: $0["total"] as Int64) }
        }) ?? []
    }

    func search(serverId: String, query: String, limit: Int = 50) -> [DownloadRecord] {
        guard let pool else { return [] }
        let q = "%\(query.lowercased())%"
        return (try? pool.read { db in
            try DownloadRecord.fetchAll(db, sql: """
                SELECT * FROM downloads
                WHERE serverId = ?
                  AND (LOWER(title) LIKE ? OR LOWER(albumTitle) LIKE ? OR LOWER(artistName) LIKE ?)
                ORDER BY artistName ASC, albumTitle ASC, track ASC
                LIMIT ?
                """, arguments: [serverId, q, q, q, limit])
        }) ?? []
    }

    // MARK: - Playlist Registry (macOS: Marker in der DB; iOS nutzt UserDefaults)

    func markPlaylistDownloaded(id: String, name: String, serverId: String) {
        safeWrite { db in
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO downloaded_playlists (
                    server_id, playlist_id, playlist_name, downloaded_at
                ) VALUES (?, ?, ?, ?)
                """,
                arguments: [serverId, id, name, Int(Date().timeIntervalSince1970)]
            )
        }
    }

    func unmarkPlaylistDownloaded(id: String, serverId: String) {
        safeWrite { db in
            try db.execute(
                sql: "DELETE FROM downloaded_playlists WHERE server_id = ? AND playlist_id = ?",
                arguments: [serverId, id]
            )
            try db.execute(
                sql: """
                    DELETE FROM download_collection_sync
                    WHERE server_id = ? AND collection_kind = ? AND collection_id = ?
                    """,
                arguments: [serverId, DownloadCollectionKind.playlist.rawValue, id]
            )
        }
    }

    func loadDownloadedPlaylistIds(serverId: String) -> Set<String> {
        guard let pool else { return [] }
        let ids: [String] = (try? pool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT playlist_id FROM downloaded_playlists WHERE server_id = ?",
                arguments: [serverId]
            )
        }) ?? []
        return Set(ids)
    }

    func adoptLegacyPlaylistMarkers(serverId: String, playlistIds: Set<String>) {
        guard !playlistIds.isEmpty else { return }
        safeWrite { db in
            for id in playlistIds {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO downloaded_playlists (
                        server_id, playlist_id, playlist_name, downloaded_at
                    )
                    SELECT ?, playlist_id, playlist_name, downloaded_at
                    FROM downloaded_playlists
                    WHERE server_id = '' AND playlist_id = ?
                    """,
                    arguments: [serverId, id]
                )
            }
        }
    }

    // MARK: - Missing Song Strikes

    @discardableResult
    func incrementStrike(songId: String, serverId: String) -> Int {
        guard let pool else { return 0 }
        var result = 1
        do {
            try pool.write { db in
                if let existing = try MissingStrikeRecord
                    .filter(Column("songId") == songId && Column("serverId") == serverId)
                    .fetchOne(db) {
                    result = existing.strikeCount + 1
                    try db.execute(
                        sql: "UPDATE missing_song_strikes SET strikeCount = ?, lastStrikeAt = ? WHERE songId = ? AND serverId = ?",
                        arguments: [result, Date().timeIntervalSince1970, songId, serverId]
                    )
                } else {
                    let r = MissingStrikeRecord(
                        songId: songId, serverId: serverId,
                        strikeCount: 1, lastStrikeAt: Date().timeIntervalSince1970
                    )
                    try r.insert(db)
                }
            }
        } catch {
            DBErrorLog.logPlayLog("incrementStrike: \(error.localizedDescription)")
        }
        return result
    }

    func resetStrikes(songIds: [String], serverId: String) {
        guard !songIds.isEmpty else { return }
        safeWrite { db in
            let placeholders = songIds.map { _ in "?" }.joined(separator: ",")
            var args: [DatabaseValueConvertible] = [serverId]
            args.append(contentsOf: songIds)
            try db.execute(
                sql: "DELETE FROM missing_song_strikes WHERE serverId = ? AND songId IN (\(placeholders))",
                arguments: StatementArguments(args)
            )
        }
    }

    // MARK: - Stats

    func stats(serverId: String) -> (songs: Int, albums: Int, artists: Int) {
        guard let pool else { return (0, 0, 0) }
        return (try? pool.read { db -> (Int, Int, Int) in
            let songs = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM downloads WHERE serverId = ?",
                                          arguments: [serverId])) ?? 0
            let albums = (try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT albumId) FROM downloads WHERE serverId = ?",
                                           arguments: [serverId])) ?? 0
            let artists = (try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT artistId) FROM downloads WHERE serverId = ? AND artistId IS NOT NULL",
                                            arguments: [serverId])) ?? 0
            return (songs, albums, artists)
        }) ?? (0, 0, 0)
    }
}
