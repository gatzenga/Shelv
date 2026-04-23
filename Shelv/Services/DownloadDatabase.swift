import Foundation
import GRDB

// MARK: - Records

struct DownloadRecord: Codable, FetchableRecord, PersistableRecord {
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
    var bytes: Int64
    var coverArtId: String?
    var artistCoverArtId: String?
    var albumArtistName: String?
    var albumCoverArtId: String?
    var isFavorite: Bool
    var filePath: String
    var fileExtension: String
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
            bytes: bytes,
            coverArtId: coverArtId,
            artistCoverArtId: artistCoverArtId,
            isFavorite: isFavorite,
            filePath: filePath,
            fileExtension: fileExtension,
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

// MARK: - DownloadDatabase

actor DownloadDatabase {
    static let shared = DownloadDatabase()

    private var pool: DatabasePool?
    private init() {}

    static var dbURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shelv_downloads/downloads.db")
    }

    func setup() {
        let url = Self.dbURL
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
        let p = try DatabasePool(path: url.path)
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
            try db.alter(table: "downloads") { t in
                t.add(column: "artistCoverArtId", .text)
            }
        }
        m.registerMigration("v3_add_album_artist") { db in
            try db.alter(table: "downloads") { t in
                t.add(column: "albumArtistName", .text)
                t.add(column: "albumCoverArtId", .text)
            }
        }
        try m.migrate(p)
        return p
    }

    private var consecutiveIOErrors = 0
    private var circuitOpenUntil: Date?
    private var hasLoggedCircuitOpen = false
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
        let url = Self.dbURL
        pool = nil
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
                .order(Column("artistName").asc, Column("albumTitle").asc, Column("track").asc)
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
