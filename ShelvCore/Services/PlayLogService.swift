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
    var isTest: Bool = false

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

    #if SHELV_LOGIC_TESTS
    nonisolated(unsafe) static var testDatabaseURL: URL?
    #endif

    private var pool: DatabasePool?
    private init() {}

    // MARK: - Setup

    func shutdown() {
        pool = nil
    }

    @discardableResult
    private func safeWrite(_ label: String = #function, _ block: (Database) throws -> Void) -> Bool {
        guard let pool else {
            DBErrorLog.logPlayLog("\(label): pool not initialized")
            return false
        }
        do {
            try pool.write(block)
            return true
        } catch {
            DBErrorLog.logPlayLog("\(label): \(error.localizedDescription)")
            return false
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
            var config = Configuration()
            config.targetQueue = DispatchQueue(label: "shelv.db.playlog", qos: .userInitiated)
            let p = try DatabasePool(path: url.path, configuration: config)
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
                let cols = try db.columns(in: "play_log").map(\.name)
                if !cols.contains("uuid") || !cols.contains("syncedAt") {
                    try db.alter(table: "play_log") { t in
                        if !cols.contains("uuid") {
                            t.add(column: "uuid", .text)
                        }
                        if !cols.contains("syncedAt") {
                            t.add(column: "syncedAt", .double)
                        }
                    }
                }
                try db.execute(sql: """
                    CREATE UNIQUE INDEX IF NOT EXISTS idx_play_log_uuid
                    ON play_log(uuid) WHERE uuid IS NOT NULL
                """)
            }
            m.registerMigration("v3_cloudkit_registry") { db in
                let cols = try db.columns(in: "recap_registry").map(\.name)
                guard !cols.contains("ckRecordName") else { return }
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
            m.registerMigration("v5_registry_is_test") { db in
                let cols = try db.columns(in: "recap_registry").map(\.name)
                guard !cols.contains("isTest") else { return }
                try db.alter(table: "recap_registry") { t in
                    t.add(column: "isTest", .boolean).notNull().defaults(to: false)
                }
            }
            try m.migrate(p)
            pool = p
            Self.applyDataProtection(at: url)
        } catch {
            DBErrorLog.logPlayLog("DB setup failed: \(error.localizedDescription)")
        }
    }

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
        #endif
    }

    static var dbURL: URL {
        #if SHELV_LOGIC_TESTS
        if let testDatabaseURL {
            return testDatabaseURL
        }
        #endif
        #if os(tvOS)
        // tvOS hat keinen beschreibbaren Application-Support-Ordner — nur Caches ist
        // persistent beschreibbar. Application Support liefert „You don't have permission".
        return FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shelv_recap/recap.db")
        #else
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shelv_recap/recap.db")
        #endif
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

    #if SHELV_LOGIC_TESTS
    func insertLegacyPlayForTesting(songId: String, serverId: String, playedAt: Double, songDuration: Double) {
        safeWrite { db in
            try db.execute(
                sql: """
                    INSERT INTO play_log (songId, serverId, playedAt, songDuration, uuid, syncedAt)
                    VALUES (?, ?, ?, ?, NULL, NULL)
                    """,
                arguments: [songId, serverId, playedAt, songDuration]
            )
        }
    }
    #endif

    @discardableResult
    func log(songId: String, serverId: String, songDuration: Double) -> String? {
        guard pool != nil else { return nil }
        let uuid = UUID().uuidString.lowercased()
        let record = PlayLogRecord(
            songId: songId, serverId: serverId,
            playedAt: Date().timeIntervalSince1970, songDuration: songDuration,
            uuid: uuid, syncedAt: nil
        )
        let wrote = safeWrite { db in try record.insert(db) }
        guard wrote else { return nil }
        return uuid
    }

    func topSongs(serverId: String, from start: Date, to end: Date, limit: Int) -> [RecapSongCount] {
        #if DEBUG && !SHELV_LOGIC_TESTS
        if SubsonicAPIService.shared.isDemoActive { return Array(DemoContent.recapSongCounts().prefix(limit)) }
        #endif
        guard let pool else { return [] }
        return (try? pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT songId, COUNT(*) AS cnt
                FROM play_log
                WHERE serverId = ?
                  AND playedAt >= ?
                  AND playedAt < ?
                GROUP BY songId
                ORDER BY cnt DESC, MAX(playedAt) DESC, songId ASC
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

    @discardableResult
    func assignMissingCloudIdentifiers(serverId: String? = nil) -> Int {
        guard pool != nil else { return 0 }
        var assigned = 0
        safeWrite { db in
            let ids: [Int64]
            if let serverId {
                ids = try Int64.fetchAll(
                    db,
                    sql: "SELECT id FROM play_log WHERE serverId = ? AND uuid IS NULL",
                    arguments: [serverId]
                )
            } else {
                ids = try Int64.fetchAll(db, sql: "SELECT id FROM play_log WHERE uuid IS NULL")
            }

            for id in ids {
                try db.execute(
                    sql: "UPDATE play_log SET uuid = ?, syncedAt = NULL WHERE id = ?",
                    arguments: [UUID().uuidString.lowercased(), id]
                )
            }
            assigned = ids.count
        }
        return assigned
    }

    func markSynced(uuids: [String]) {
        guard pool != nil, !uuids.isEmpty else { return }
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

    @discardableResult
    func insertIfNotExists(uuid: String, songId: String, serverId: String, playedAt: Double, songDuration: Double) -> Bool {
        guard pool != nil else { return false }
        var changed = false
        safeWrite { db in
            if let existing = try PlayLogRecord.filter(Column("uuid") == uuid).fetchOne(db) {
                if existing.serverId != serverId {
                    try db.execute(sql: "UPDATE play_log SET serverId = ? WHERE uuid = ?",
                                   arguments: [serverId, uuid])
                    changed = db.changesCount > 0
                }
            } else {
                let record = PlayLogRecord(
                    songId: songId, serverId: serverId,
                    playedAt: playedAt, songDuration: songDuration,
                    uuid: uuid, syncedAt: Date().timeIntervalSince1970
                )
                try record.insert(db)
                changed = true
            }
        }
        return changed
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

    func registryEntry(serverId: String, periodType: String, periodStart: Double, isTest: Bool? = nil) -> RecapRegistryRecord? {
        guard let pool else { return nil }
        return try? pool.read { db in
            var filter = Column("serverId") == serverId
                && Column("periodType") == periodType
                && Column("periodStart") == periodStart
            if let isTest {
                filter = filter && Column("isTest") == isTest
            }
            return try RecapRegistryRecord
                .filter(filter)
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
        guard pool != nil, oldId != newId else { return }
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

    func deleteRegistryEntries(playlistIds: [String]) {
        guard pool != nil, !playlistIds.isEmpty else { return }
        safeWrite { db in
            for start in stride(from: 0, to: playlistIds.count, by: 500) {
                let chunk = Array(playlistIds[start..<min(start + 500, playlistIds.count)])
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM recap_registry WHERE playlistId IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
            }
        }
    }

    func markRecapMarkersUnsyncedForReUpload(serverId: String) {
        guard pool != nil else { return }
        safeWrite { db in
            try db.execute(
                sql: "UPDATE recap_registry SET ckRecordName = NULL WHERE serverId = ?",
                arguments: [serverId]
            )
        }
    }

    @discardableResult
    func keepOnlyRegistryEntryForSamePeriod(_ record: RecapRegistryRecord) -> [String] {
        guard pool != nil else { return [] }
        var removed: [String] = []
        safeWrite { db in
            removed = try String.fetchAll(db, sql: """
                SELECT playlistId FROM recap_registry
                WHERE serverId = ?
                  AND periodType = ?
                  AND periodStart = ?
                  AND isTest = ?
                  AND playlistId != ?
                """, arguments: [
                    record.serverId,
                    record.periodType,
                    record.periodStart,
                    record.isTest,
                    record.playlistId
                ])

            if !removed.isEmpty {
                let placeholders = removed.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM recap_registry WHERE playlistId IN (\(placeholders))",
                    arguments: StatementArguments(removed)
                )
            }

            try record.insert(db, onConflict: .replace)
        }
        return removed
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

    func recentUniqueSongIds(serverId: String, limit: Int = 50) -> [String] {
        guard let pool else { return [] }
        return (try? pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT songId FROM play_log
                WHERE serverId = ?
                GROUP BY songId
                ORDER BY MAX(playedAt) DESC
                LIMIT ?
                """, arguments: [serverId, limit])
        }) ?? []
    }

    // MARK: - Database Cleanup (tote IDs)

    /// Alle verschiedenen Song-IDs im Log eines Servers (faltet Plays auf distinct Songs zusammen).
    func distinctSongIds(serverId: String) -> [String] {
        guard let pool else { return [] }
        return (try? pool.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT songId FROM play_log WHERE serverId = ?",
                                arguments: [serverId])
        }) ?? []
    }

    /// Anzahl verschiedener Songs im Log — günstig (COUNT), für die Mix-Schwellenprüfung.
    func distinctSongCount(serverId: String) -> Int {
        guard let pool else { return 0 }
        return (try? pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT songId) FROM play_log WHERE serverId = ?",
                             arguments: [serverId])
        }) ?? 0
    }

    /// Play-UUIDs (= CloudKit-RecordNames) für die gegebenen Songs — für die iCloud-Löschung.
    func uuids(forSongIds songIds: [String], serverId: String) -> [String] {
        guard let pool, !songIds.isEmpty else { return [] }
        var result: [String] = []
        try? pool.read { db in
            for start in stride(from: 0, to: songIds.count, by: 500) {
                let chunk = Array(songIds[start..<min(start + 500, songIds.count)])
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                var args: [DatabaseValueConvertible] = [serverId]
                args.append(contentsOf: chunk)
                let part = try String.fetchAll(db, sql: """
                    SELECT uuid FROM play_log
                    WHERE serverId = ? AND uuid IS NOT NULL AND songId IN (\(placeholders))
                    """, arguments: StatementArguments(args))
                result.append(contentsOf: part)
            }
        }
        return result
    }

    /// Löscht alle Plays der gegebenen Songs lokal. Gibt die Anzahl entfernter Zeilen zurück.
    @discardableResult
    func deletePlays(forSongIds songIds: [String], serverId: String) -> Int {
        guard pool != nil, !songIds.isEmpty else { return 0 }
        var removed = 0
        safeWrite { db in
            for start in stride(from: 0, to: songIds.count, by: 500) {
                let chunk = Array(songIds[start..<min(start + 500, songIds.count)])
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                var args: [DatabaseValueConvertible] = [serverId]
                args.append(contentsOf: chunk)
                try db.execute(sql: "DELETE FROM play_log WHERE serverId = ? AND songId IN (\(placeholders))",
                               arguments: StatementArguments(args))
                removed += db.changesCount
            }
        }
        return removed
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

    func playCount(serverId: String, from start: Date, to end: Date) -> Int {
        guard let pool else { return 0 }
        return (try? pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM play_log
                WHERE serverId = ? AND playedAt >= ? AND playedAt < ?
                """, arguments: [serverId, start.timeIntervalSince1970, end.timeIntervalSince1970])
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
        let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            throw NSError(domain: "PlayLogService", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Rollback backup was created but is empty"])
        }
    }

    func applyImportRollback() throws {
        let backup = Self.importRollbackURL
        guard FileManager.default.fileExists(atPath: backup.path) else {
            throw NSError(domain: "PlayLogService", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No rollback backup found"])
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: backup.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            throw NSError(domain: "PlayLogService", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Rollback backup is empty — refusing to replace live database"])
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
        guard pool != nil else {
            throw NSError(domain: "PlayLogService", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Database failed to open after rollback — backup preserved at \(backup.path)"])
        }
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
            try db.execute(sql: "UPDATE recap_registry SET ckRecordName = NULL")
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
        guard pool != nil, !newId.isEmpty else { return }
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
