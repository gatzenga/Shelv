import Foundation
import GRDB

// MARK: - Records

struct DownloadRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
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

nonisolated struct DownloadedPlaylistMarker: Sendable {
    let id: String
    let name: String
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
        // The actor serializes setup calls. Once the pool exists, reopening it is
        // unnecessary and can introduce GRDB queue churn during cold App Intent
        // launches where several stores initialize at the same time.
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
        config.qos = .userInitiated
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

    func repairFilePath(
        songId: String,
        serverId: String,
        expectedPath: String,
        expectedAddedAt: Double,
        replacementPath: String
    ) {
        safeWrite { db in
            try db.execute(
                sql: """
                UPDATE downloads
                SET filePath = ?
                WHERE songId = ? AND serverId = ? AND filePath = ? AND addedAt = ?
                """,
                arguments: [replacementPath, songId, serverId, expectedPath, expectedAddedAt]
            )
        }
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

    func deleteIfFilePathMatches(
        songId: String,
        serverId: String,
        expectedPath: String,
        expectedAddedAt: Double
    ) {
        safeWrite { db in
            try db.execute(
                sql: """
                DELETE FROM downloads
                WHERE songId = ? AND serverId = ? AND filePath = ? AND addedAt = ?
                """,
                arguments: [songId, serverId, expectedPath, expectedAddedAt]
            )
        }
    }

    func deleteAlbum(albumId: String, serverId: String) {
        safeWrite { db in
            try db.execute(
                sql: "DELETE FROM downloads WHERE albumId = ? AND serverId = ?",
                arguments: [albumId, serverId]
            )
        }
    }

    func deleteArtist(artistId: String, serverId: String) {
        safeWrite { db in
            try db.execute(
                sql: "DELETE FROM downloads WHERE artistId = ? AND serverId = ?",
                arguments: [artistId, serverId]
            )
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
        }
    }

    func deleteAll() {
        safeWrite { db in
            try db.execute(sql: "DELETE FROM downloads")
            try db.execute(sql: "DELETE FROM missing_song_strikes")
            try db.execute(sql: "DELETE FROM downloaded_playlists")
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

    func loadDownloadedPlaylistMarkers(serverId: String) -> [DownloadedPlaylistMarker] {
        guard let pool else { return [] }
        return (try? pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT playlist_id, playlist_name
                FROM downloaded_playlists
                WHERE server_id = ?
                ORDER BY playlist_name COLLATE NOCASE ASC
                """,
                arguments: [serverId]
            ).map {
                DownloadedPlaylistMarker(
                    id: $0["playlist_id"],
                    name: $0["playlist_name"]
                )
            }
        }) ?? []
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
