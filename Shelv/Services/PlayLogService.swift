import Foundation
import GRDB

// MARK: - Records

struct PlayLogRecord: Codable, FetchableRecord, PersistableRecord {
    var songId: String
    var serverId: String
    var playedAt: Double       // Date.timeIntervalSince1970
    var songDuration: Double   // Sekunden
    var uuid: String?          // nil für pre-CloudKit-Zeilen
    var syncedAt: Double?      // nil = Upload ausstehend

    static let databaseTableName = "play_log"
}

struct RecapRegistryRecord: Codable, FetchableRecord, PersistableRecord, Hashable {
    var playlistId: String
    var serverId: String
    var periodType: String     // "week" | "month" | "year"
    var periodStart: Double    // Date.timeIntervalSince1970
    var periodEnd: Double      // Date.timeIntervalSince1970
    var ckRecordName: String?  // nil = noch nicht in CloudKit gespiegelt

    static let databaseTableName = "recap_registry"
}

struct ScrobbleQueueRecord: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var songId: String
    var serverId: String
    var playedAt: Double       // Date.timeIntervalSince1970
    var retries: Int

    static let databaseTableName = "scrobble_queue"
}

// MARK: - Query Result

struct RecapSongCount {
    let songId: String
    let count: Int
}

// MARK: - PlayLogService

actor PlayLogService {
    static let shared = PlayLogService()

    private var pool: DatabasePool?
    private init() {}

    // MARK: - Setup

    func shutdown() {
        pool = nil
    }

    private func safeWrite(_ label: String = #function, _ block: (Database) throws -> Void) {
        guard let pool else {
            DBErrorLog.logPlayLog("\(label): pool not initialized")
            return
        }
        do {
            try pool.write(block)
        } catch {
            DBErrorLog.logPlayLog("\(label): \(error.localizedDescription)")
        }
    }

    func setup() {
        let url = Self.dbURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Migrate from legacy caches path
            let legacy = Self.legacyDbURL
            if FileManager.default.fileExists(atPath: legacy.path),
               !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.moveItem(at: legacy, to: url)
            }
            let p = try DatabasePool(path: url.path)
            var m = DatabaseMigrator()
            m.registerMigration("v1_create") { db in
                try db.create(table: "play_log", ifNotExists: true) { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("songId",       .text).notNull()
                    t.column("serverId",     .text).notNull()
                    t.column("playedAt",     .double).notNull()
                    t.column("songDuration", .double).notNull()
                }
                try db.create(table: "recap_registry", ifNotExists: true) { t in
                    t.column("playlistId",   .text).primaryKey()
                    t.column("serverId",     .text).notNull()
                    t.column("periodType",   .text).notNull()
                    t.column("periodStart",  .double).notNull()
                    t.column("periodEnd",    .double).notNull()
                }
            }
            m.registerMigration("v2_cloudkit_play_log") { db in
                // SQLite erlaubt kein UNIQUE auf ALTER TABLE ADD COLUMN.
                // Stattdessen Spalte hinzufügen und partiellen UNIQUE-Index anlegen
                // (NULL-Werte aus pre-CloudKit-Zeilen werden nicht geprüft).
                try db.alter(table: "play_log") { t in
                    t.add(column: "uuid",     .text)
                    t.add(column: "syncedAt", .double)
                }
                try db.execute(sql: """
                    CREATE UNIQUE INDEX IF NOT EXISTS idx_play_log_uuid
                    ON play_log(uuid) WHERE uuid IS NOT NULL
                """)
            }
            m.registerMigration("v3_cloudkit_registry") { db in
                try db.alter(table: "recap_registry") { t in
                    t.add(column: "ckRecordName", .text)
                }
            }
            m.registerMigration("v4_scrobble_queue") { db in
                try db.create(table: "scrobble_queue", ifNotExists: true) { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("songId",    .text).notNull()
                    t.column("serverId",  .text).notNull()
                    t.column("playedAt",  .double).notNull()
                    t.column("retries",   .integer).notNull().defaults(to: 0)
                }
            }
            try m.migrate(p)
            pool = p
        } catch {
            print("[PlayLogService] DB setup failed: \(error)")
        }
    }

    static var dbURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shelv_recap/recap.db")
    }

    private static var legacyDbURL: URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shelv_recap/recap.db")
    }

    nonisolated static func diskSizeBytes() -> Int {
        (try? dbURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    // MARK: - Play Log

    @discardableResult
    func log(songId: String, serverId: String, songDuration: Double) -> String? {
        guard let pool else { return nil }
        let uuid = UUID().uuidString.lowercased()
        let record = PlayLogRecord(
            songId: songId, serverId: serverId,
            playedAt: Date().timeIntervalSince1970, songDuration: songDuration,
            uuid: uuid, syncedAt: nil
        )
        safeWrite { db in try record.insert(db) }
        return uuid
    }

    func topSongs(serverId: String, from start: Date, to end: Date, limit: Int) -> [RecapSongCount] {
        guard let pool else { return [] }
        return (try? pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT songId, COUNT(*) AS cnt
                FROM play_log
                WHERE serverId = ?
                  AND playedAt >= ?
                  AND playedAt < ?
                GROUP BY songId
                ORDER BY cnt DESC
                LIMIT ?
                """, arguments: [serverId, start.timeIntervalSince1970, end.timeIntervalSince1970, limit])
            .map { RecapSongCount(songId: $0["songId"], count: $0["cnt"]) }
        }) ?? []
    }

    // MARK: - CloudKit Sync – Play Log

    func fetchUnsynced(limit: Int = 200) -> [PlayLogRecord] {
        guard let pool else { return [] }
        return (try? pool.read { db in
            try PlayLogRecord
                .filter(Column("uuid") != nil && Column("syncedAt") == nil)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    func markSynced(uuids: [String]) {
        guard let pool, !uuids.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        let placeholders = uuids.map { _ in "?" }.joined(separator: ",")
        var args: [DatabaseValueConvertible] = [now]
        args.append(contentsOf: uuids)
        safeWrite { db in
            try db.execute(
                sql: "UPDATE play_log SET syncedAt = ? WHERE uuid IN (\(placeholders))",
                arguments: StatementArguments(args)
            )
        }
    }

    func insertIfNotExists(uuid: String, songId: String, serverId: String, playedAt: Double, songDuration: Double) {
        
        safeWrite { db in
            if let existing = try PlayLogRecord.filter(Column("uuid") == uuid).fetchOne(db) {
                if existing.serverId != serverId {
                    try db.execute(sql: "UPDATE play_log SET serverId = ? WHERE uuid = ?",
                                   arguments: [serverId, uuid])
                }
            } else {
                let record = PlayLogRecord(
                    songId: songId, serverId: serverId,
                    playedAt: playedAt, songDuration: songDuration,
                    uuid: uuid, syncedAt: Date().timeIntervalSince1970
                )
                try record.insert(db)
            }
        }
    }

    func pendingUploadCount() -> Int {
        guard let pool else { return 0 }
        return (try? pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM play_log WHERE uuid IS NOT NULL AND syncedAt IS NULL")
        }) ?? 0
    }

    // MARK: - CloudKit Sync – Registry

    func updateRegistryCKRecordName(playlistId: String, ckRecordName: String) {
        
        safeWrite { db in
            try db.execute(
                sql: "UPDATE recap_registry SET ckRecordName = ? WHERE playlistId = ?",
                arguments: [ckRecordName, playlistId]
            )
        }
    }

    func registryEntry(serverId: String, periodType: String, periodStart: Double) -> RecapRegistryRecord? {
        guard let pool else { return nil }
        return try? pool.read { db in
            try RecapRegistryRecord
                .filter(Column("serverId") == serverId
                     && Column("periodType") == periodType
                     && Column("periodStart") == periodStart)
                .fetchOne(db)
        }
    }

    func registryEntry(byCKRecordName ckRecordName: String) -> RecapRegistryRecord? {
        guard let pool else { return nil }
        return try? pool.read { db in
            try RecapRegistryRecord
                .filter(Column("ckRecordName") == ckRecordName)
                .fetchOne(db)
        }
    }

    // MARK: - Scrobble Queue

    func addPendingScrobble(songId: String, serverId: String, playedAt: Double) {
        
        let record = ScrobbleQueueRecord(id: nil, songId: songId, serverId: serverId, playedAt: playedAt, retries: 0)
        safeWrite { db in try record.insert(db) }
    }

    func pendingScrobbles(limit: Int = 50) -> [ScrobbleQueueRecord] {
        guard let pool else { return [] }
        return (try? pool.read { db in
            try ScrobbleQueueRecord
                .order(Column("playedAt").asc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    func markScrobbleDone(id: Int64) {
        
        safeWrite { db in
            try db.execute(sql: "DELETE FROM scrobble_queue WHERE id = ?", arguments: [id])
        }
    }

    func incrementScrobbleRetry(id: Int64) {
        
        safeWrite { db in
            try db.execute(sql: "UPDATE scrobble_queue SET retries = retries + 1 WHERE id = ?", arguments: [id])
        }
    }

    func removeExhaustedScrobbles(maxRetries: Int = 5) {
        
        safeWrite { db in
            try db.execute(sql: "DELETE FROM scrobble_queue WHERE retries >= ?", arguments: [maxRetries])
        }
    }

    func removeScrobbles(serverId: String) {
        
        safeWrite { db in
            try db.execute(sql: "DELETE FROM scrobble_queue WHERE serverId = ?", arguments: [serverId])
        }
    }

    func pendingScrobbleCount() -> Int {
        guard let pool else { return 0 }
        return (try? pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scrobble_queue")
        }) ?? 0
    }

    func migrateServerId(from oldId: String, to newId: String) {
        guard let pool, oldId != newId else { return }
        safeWrite { db in
            try db.execute(
                sql: "UPDATE play_log SET serverId = ?, syncedAt = NULL WHERE serverId = ?",
                arguments: [newId, oldId]
            )
            try db.execute(sql: "UPDATE recap_registry SET serverId = ? WHERE serverId = ?", arguments: [newId, oldId])
            try db.execute(sql: "UPDATE scrobble_queue SET serverId = ? WHERE serverId = ?", arguments: [newId, oldId])
        }
    }

    // MARK: - Server Cleanup (CloudKit)

    func deleteCloudKitData(serverId: String) {
        
        safeWrite { db in
            try db.execute(
                sql: "UPDATE play_log SET uuid = NULL, syncedAt = NULL WHERE serverId = ?",
                arguments: [serverId]
            )
            try db.execute(
                sql: "UPDATE recap_registry SET ckRecordName = NULL WHERE serverId = ?",
                arguments: [serverId]
            )
            try db.execute(
                sql: "DELETE FROM scrobble_queue WHERE serverId = ?",
                arguments: [serverId]
            )
        }
    }

    // MARK: - Registry

    func registerPlaylist(_ record: RecapRegistryRecord) {
        
        safeWrite { db in try record.insert(db, onConflict: .replace) }
    }

    func deleteRegistryEntry(playlistId: String) {
        
        safeWrite { db in
            try db.execute(sql: "DELETE FROM recap_registry WHERE playlistId = ?", arguments: [playlistId])
        }
    }

    func deleteRegistryEntry(byCKRecordName ckRecordName: String) {
        
        safeWrite { db in
            try db.execute(sql: "DELETE FROM recap_registry WHERE ckRecordName = ?", arguments: [ckRecordName])
        }
    }

    func allRegistryEntries(serverId: String) -> [RecapRegistryRecord] {
        guard let pool else { return [] }
        return (try? pool.read { db in
            try RecapRegistryRecord
                .filter(Column("serverId") == serverId)
                .order(Column("periodStart").desc)
                .fetchAll(db)
        }) ?? []
    }

    func registryEntry(playlistId: String) -> RecapRegistryRecord? {
        guard let pool else { return nil }
        return try? pool.read { db in
            try RecapRegistryRecord.fetchOne(db, key: playlistId)
        }
    }

    func isRecapPlaylist(playlistId: String) -> Bool {
        registryEntry(playlistId: playlistId) != nil
    }

    // MARK: - Debug

    func recentLogs(serverId: String, limit: Int = 50) -> [PlayLogRecord] {
        guard let pool else { return [] }
        return (try? pool.read { db in
            try PlayLogRecord
                .filter(Column("serverId") == serverId)
                .order(Column("playedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    func allPlayLogs(serverId: String) -> [PlayLogRecord] {
        guard let pool else { return [] }
        return (try? pool.read { db in
            try PlayLogRecord
                .filter(Column("serverId") == serverId)
                .fetchAll(db)
        }) ?? []
    }

    func logCount(serverId: String) -> Int {
        guard let pool else { return 0 }
        return (try? pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM play_log WHERE serverId = ?",
                             arguments: [serverId])
        }) ?? 0
    }

    // MARK: - Export

    private static var importRollbackURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("shelv_recap_import_rollback.db")
    }

    func createImportRollback() throws {
        guard let pool else {
            throw NSError(domain: "PlayLogService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Database not initialized"])
        }
        let dest = Self.importRollbackURL
        for suffix in ["", "-wal", "-shm"] {
            let path = dest.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        let destination = try DatabaseQueue(path: dest.path)
        try pool.backup(to: destination)
    }

    func applyImportRollback() throws {
        let backup = Self.importRollbackURL
        guard FileManager.default.fileExists(atPath: backup.path) else {
            throw NSError(domain: "PlayLogService", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No rollback backup found"])
        }
        pool = nil
        let dest = Self.dbURL
        for suffix in ["", "-wal", "-shm"] {
            let path = dest.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: backup, to: dest)
        setup()
    }

    func cleanupImportRollback() {
        let backup = Self.importRollbackURL
        for suffix in ["", "-wal", "-shm"] {
            let path = backup.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    func makeExportBackup() throws -> URL {
        guard let pool else {
            throw NSError(domain: "PlayLogService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Database not initialized"])
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelv_recap_export.db")
        for suffix in ["", "-wal", "-shm"] {
            let path = dest.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        let destination = try DatabaseQueue(path: dest.path)
        try pool.backup(to: destination)
        return dest
    }

    // MARK: - Reset

    func resetLog(serverId: String) {
        
        safeWrite { db in
            try db.execute(sql: "DELETE FROM play_log WHERE serverId = ?", arguments: [serverId])
        }
    }

    func deletePlayLog(uuid: String) {
        
        safeWrite { db in
            try db.execute(sql: "DELETE FROM play_log WHERE uuid = ?", arguments: [uuid])
        }
    }

    func markAllUnsyncedForReUpload() {
        
        safeWrite { db in
            try db.execute(sql: "UPDATE play_log SET syncedAt = NULL WHERE uuid IS NOT NULL")
        }
    }

    func markServerUnsyncedForReUpload(serverId: String) {
        
        safeWrite { db in
            try db.execute(sql: "UPDATE play_log SET syncedAt = NULL WHERE serverId = ? AND uuid IS NOT NULL",
                           arguments: [serverId])
            try db.execute(sql: "UPDATE recap_registry SET ckRecordName = NULL WHERE serverId = ?",
                           arguments: [serverId])
        }
    }

    func rewriteAllServerIds(to newId: String) {
        guard let pool, !newId.isEmpty else { return }
        safeWrite { db in
            try db.execute(sql: "UPDATE play_log SET serverId = ?, syncedAt = NULL WHERE serverId != ?",
                           arguments: [newId, newId])
            try db.execute(sql: "UPDATE recap_registry SET serverId = ?, ckRecordName = NULL WHERE serverId != ?",
                           arguments: [newId, newId])
            try db.execute(sql: "UPDATE scrobble_queue SET serverId = ? WHERE serverId != ?",
                           arguments: [newId, newId])
        }
    }

    func resetRegistry(serverId: String) {
        
        safeWrite { db in
            try db.execute(sql: "DELETE FROM recap_registry WHERE serverId = ?", arguments: [serverId])
        }
    }
}
