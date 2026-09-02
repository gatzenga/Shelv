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
    var songTitle: String?     // nil = Metadaten noch nicht abgeglichen
    var artistName: String?    // Navidrome erlaubt Songs ohne Artist-Tag
    var albumName: String?     // Navidrome erlaubt Songs ohne Album-Tag

    static let databaseTableName = "play_log"
}

/// Distinct Song, wie er aktuell im Log steht — Grundlage für den Reconciliation-Task.
struct PlayLogSongEntry: Equatable {
    let songId: String
    let title: String?
    let artist: String?
    let album: String?
}

struct ScrobbleQueueRecord: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var songId: String
    var serverId: String
    var serverConfigId: String?
    var playedAt: Double       // Date.timeIntervalSince1970
    var retries: Int

    static let databaseTableName = "scrobble_queue"
}

// MARK: - Query Result

struct PlaySongCount {
    let songId: String
    let count: Int
}

enum PlayLogImportError: Error, Sendable {
    case restored(importMessage: String)
    case rollbackFailed(importMessage: String, rollbackMessage: String)
}

// MARK: - PlayLogService

actor PlayLogService {
    static let shared = PlayLogService()

    #if os(tvOS) && !SHELV_LOGIC_TESTS
    /// tvOS darf den Caches-Container unter Speicherdruck leeren. Für die kleine,
    /// zustellkritische Outbox ist UserDefaults deshalb die autoritative Quelle.
    private static let tvScrobbleBackupKey = "shelv_pending_scrobbles_v1"
    #endif

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
        guard pool == nil else { return }
        let url = Self.dbURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Umzug von einem früheren Ablageort. Die WAL- und SHM-Dateien müssen
            // mitkommen, sonst gehen die zuletzt geschriebenen Plays verloren.
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path),
               let legacy = Self.legacyDbURLs.first(where: { fm.fileExists(atPath: $0.path) }) {
                for suffix in ["", "-wal", "-shm"] {
                    let from = URL(fileURLWithPath: legacy.path + suffix)
                    let to = URL(fileURLWithPath: url.path + suffix)
                    guard fm.fileExists(atPath: from.path) else { continue }
                    try? fm.moveItem(at: from, to: to)
                }
                try? fm.removeItem(at: legacy.deletingLastPathComponent())
            }
            var config = Configuration()
            config.label = "shelv.db.playlog"
            config.qos = .userInitiated
            #if os(iOS)
            // Avoid closing idle readers from GRDB's main-thread lifecycle callback.
            config.persistentReadOnlyConnections = true
            #endif
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
                // Historisch: erweiterte eine Tabelle, die es nur in Installationen
                // von vor v8 gibt. Auf allen anderen ein No-op.
                guard try db.tableExists(RemovedFeatureCleanup.legacyDatabaseTable) else { return }
                let cols = try db.columns(in: RemovedFeatureCleanup.legacyDatabaseTable).map(\.name)
                guard !cols.contains("ckRecordName") else { return }
                try db.alter(table: RemovedFeatureCleanup.legacyDatabaseTable) { t in
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
                guard try db.tableExists(RemovedFeatureCleanup.legacyDatabaseTable) else { return }
                let cols = try db.columns(in: RemovedFeatureCleanup.legacyDatabaseTable).map(\.name)
                guard !cols.contains("isTest") else { return }
                try db.alter(table: RemovedFeatureCleanup.legacyDatabaseTable) { t in
                    t.add(column: "isTest", .boolean).notNull().defaults(to: false)
                }
            }
            m.registerMigration("v6_scrobble_server_config") { db in
                let cols = try db.columns(in: "scrobble_queue").map(\.name)
                guard !cols.contains("serverConfigId") else { return }
                try db.alter(table: "scrobble_queue") { t in
                    t.add(column: "serverConfigId", .text)
                }
                try db.create(
                    index: "idx_scrobble_queue_server_config",
                    on: "scrobble_queue",
                    columns: ["serverConfigId", "id"],
                    ifNotExists: true
                )
            }
            m.registerMigration("v7_play_log_metadata") { db in
                let cols = try db.columns(in: "play_log").map(\.name)
                let missing = ["songTitle", "artistName", "albumName"].filter { !cols.contains($0) }
                guard !missing.isEmpty else { return }
                try db.alter(table: "play_log") { t in
                    for column in missing {
                        t.add(column: column, .text)
                    }
                }
            }
            m.registerMigration("v8_drop_removed_registry") { db in
                try db.execute(sql: "DROP TABLE IF EXISTS \(RemovedFeatureCleanup.legacyDatabaseTable)")
            }
            try m.migrate(p)
            pool = p
            migrateTVScrobbleJournalIfNeeded()
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
            .appendingPathComponent("shelv_playlog/playlog.db")
        #else
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shelv_playlog/playlog.db")
        #endif
    }

    /// Frühere Ablageorte der Datenbank, neueste zuerst. `setup()` zieht die erste
    /// gefundene an den aktuellen Ort um, damit niemand seine Wiedergabe-Historie
    /// verliert.
    private static var legacyDbURLs: [URL] {
        let fm = FileManager.default
        var urls: [URL] = []
        #if !os(tvOS)
        urls.append(fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(RemovedFeatureCleanup.legacyDatabaseSubpath))
        #endif
        urls.append(fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(RemovedFeatureCleanup.legacyDatabaseSubpath))
        return urls
    }

    nonisolated static func diskSizeBytes() -> Int {
        (try? dbURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    // MARK: - Play Log

    #if SHELV_LOGIC_TESTS
    func insertLegacyPlayForTesting(
        songId: String, serverId: String, playedAt: Double, songDuration: Double,
        title: String? = nil, artist: String? = nil, album: String? = nil
    ) {
        safeWrite { db in
            try db.execute(
                sql: """
                    INSERT INTO play_log (songId, serverId, playedAt, songDuration, uuid, syncedAt, songTitle, artistName, albumName)
                    VALUES (?, ?, ?, ?, NULL, NULL, ?, ?, ?)
                    """,
                arguments: [songId, serverId, playedAt, songDuration, title, artist, album]
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
            uuid: uuid, syncedAt: nil,
            songTitle: nil, artistName: nil, albumName: nil
        )
        let wrote = safeWrite { db in try record.insert(db) }
        guard wrote else { return nil }
        return uuid
    }

    /// iOS/macOS schreiben lokalen Play und Server-Outbox in derselben
    /// GRDB-Transaktion. tvOS schreibt die zustellkritische Outbox zuerst in sein
    /// nicht purgeable Journal und danach den lokalen Play in die Cache-Datenbank.
    @discardableResult
    func recordPlayAndQueueScrobble(
        songId: String,
        serverId: String,
        serverConfigId: String,
        playedAt: Double,
        songDuration: Double,
        songTitle: String? = nil,
        artistName: String? = nil,
        albumName: String? = nil
    ) -> String? {
        #if !(os(tvOS) && !SHELV_LOGIC_TESTS)
        guard pool != nil else { return nil }
        #endif
        let uuid = UUID().uuidString.lowercased()
        let play = PlayLogRecord(
            songId: songId,
            serverId: serverId,
            playedAt: playedAt,
            songDuration: songDuration,
            uuid: uuid,
            syncedAt: nil,
            songTitle: songTitle,
            artistName: artistName,
            albumName: albumName
        )
        let pending = ScrobbleQueueRecord(
            id: nil,
            songId: songId,
            serverId: serverId,
            serverConfigId: serverConfigId,
            playedAt: playedAt,
            retries: 0
        )
        #if os(tvOS) && !SHELV_LOGIC_TESTS
        // Outbox-first: selbst wenn die purgeable Play-DB direkt danach ausfällt
        // oder entfernt wird, bleibt der Server-Scrobble dauerhaft vorgemerkt.
        var journal = loadTVScrobbleJournal()
        var durablePending = pending
        durablePending.id = nextTVScrobbleId(in: journal)
        journal.append(durablePending)
        guard saveTVScrobbleJournal(journal) else { return nil }
        _ = safeWrite { try play.insert($0) }
        return uuid
        #else
        let wrote = safeWrite {
            try play.insert($0)
            try pending.insert($0)
        }
        guard wrote else { return nil }
        syncTVScrobbleBackup()
        return uuid
        #endif
    }

    func topSongs(serverId: String, from start: Date, to end: Date, limit: Int) -> [PlaySongCount] {
        #if DEBUG && !SHELV_LOGIC_TESTS
        if SubsonicAPIService.shared.isDemoActive { return Array(DemoContent.playSongCounts().prefix(limit)) }
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
            .map { PlaySongCount(songId: $0["songId"], count: $0["cnt"]) }
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
    func insertIfNotExists(
        uuid: String, songId: String, serverId: String, playedAt: Double, songDuration: Double,
        songTitle: String? = nil, artistName: String? = nil, albumName: String? = nil
    ) -> Bool {
        guard pool != nil else { return false }
        var changed = false
        safeWrite { db in
            if let existing = try PlayLogRecord.filter(Column("uuid") == uuid).fetchOne(db) {
                // Ein anderes Gerät kann dieselbe Zeile später mit frisch nachgeholten
                // Metadaten re-uploaden (Database-Cleanup-Backfill) — die dürfen hier nicht
                // verworfen werden, nur weil die Zeile lokal schon existiert.
                var setClauses: [String] = []
                var args: [DatabaseValueConvertible] = []
                if existing.serverId != serverId {
                    setClauses.append("serverId = ?")
                    args.append(serverId)
                }
                // Eine andere Zeile kann per Reconciliation auf eine reparierte ID umgeschrieben
                // worden sein (repairSongId) — das muss auch hier ankommen, nicht nur die Metadaten.
                if existing.songId != songId {
                    setClauses.append("songId = ?")
                    args.append(songId)
                }
                // Ein nil vom Absender heißt "hat dazu (noch) nichts gesagt", nicht "ist leer" —
                // ein fehlender Wert darf nie bereits vorhandene lokale Metadaten löschen.
                if let songTitle, existing.songTitle != songTitle {
                    setClauses.append("songTitle = ?")
                    args.append(songTitle)
                }
                if let artistName, existing.artistName != artistName {
                    setClauses.append("artistName = ?")
                    args.append(artistName)
                }
                if let albumName, existing.albumName != albumName {
                    setClauses.append("albumName = ?")
                    args.append(albumName)
                }
                if !setClauses.isEmpty {
                    args.append(uuid)
                    try db.execute(
                        sql: "UPDATE play_log SET \(setClauses.joined(separator: ", ")) WHERE uuid = ?",
                        arguments: StatementArguments(args)
                    )
                    changed = db.changesCount > 0
                }
            } else {
                let record = PlayLogRecord(
                    songId: songId, serverId: serverId,
                    playedAt: playedAt, songDuration: songDuration,
                    uuid: uuid, syncedAt: Date().timeIntervalSince1970,
                    songTitle: songTitle, artistName: artistName, albumName: albumName
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

    // MARK: - Scrobble Queue

    @discardableResult
    func addPendingScrobble(
        songId: String,
        serverId: String,
        serverConfigId: String? = nil,
        playedAt: Double
    ) -> Bool {
        
        let record = ScrobbleQueueRecord(
            id: nil,
            songId: songId,
            serverId: serverId,
            serverConfigId: serverConfigId,
            playedAt: playedAt,
            retries: 0
        )
        #if os(tvOS) && !SHELV_LOGIC_TESTS
        var journal = loadTVScrobbleJournal()
        var durableRecord = record
        durableRecord.id = nextTVScrobbleId(in: journal)
        journal.append(durableRecord)
        return saveTVScrobbleJournal(journal)
        #else
        let wrote = safeWrite { db in try record.insert(db) }
        if wrote { syncTVScrobbleBackup() }
        return wrote
        #endif
    }

    func pendingScrobbles(limit: Int = 50) -> [ScrobbleQueueRecord] {
        #if os(tvOS) && !SHELV_LOGIC_TESTS
        return Array(
            loadTVScrobbleJournal()
                .sorted { $0.playedAt < $1.playedAt }
                .prefix(max(0, limit))
        )
        #else
        guard let pool else { return [] }
        return (try? pool.read { db in
            try ScrobbleQueueRecord
                .order(Column("playedAt").asc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
        #endif
    }

    func allPendingScrobbles() -> [ScrobbleQueueRecord] {
        #if os(tvOS) && !SHELV_LOGIC_TESTS
        return loadTVScrobbleJournal().sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        #else
        guard let pool else { return [] }
        return (try? pool.read { db in
            try ScrobbleQueueRecord
                .order(Column("id").asc)
                .fetchAll(db)
        }) ?? []
        #endif
    }

    @discardableResult
    func restorePendingScrobbles(_ records: [ScrobbleQueueRecord]) -> Bool {
        guard !records.isEmpty else { return true }
        #if os(tvOS) && !SHELV_LOGIC_TESTS
        var journal = loadTVScrobbleJournal()
        for record in records where !journal.contains(where: { sameScrobbleEvent($0, record) }) {
            var restored = record
            restored.id = nextTVScrobbleId(in: journal)
            journal.append(restored)
        }
        return saveTVScrobbleJournal(journal)
        #else
        let wrote = safeWrite { db in
            for record in records {
                var restored = record
                restored.id = nil
                try restored.insert(db)
            }
        }
        if wrote { syncTVScrobbleBackup() }
        return wrote
        #endif
    }

    func pendingScrobbles(afterId: Int64?, limit: Int = 50) -> [ScrobbleQueueRecord] {
        #if os(tvOS) && !SHELV_LOGIC_TESTS
        return Array(
            loadTVScrobbleJournal()
                .filter { ($0.id ?? 0) > (afterId ?? 0) }
                .sorted { ($0.id ?? 0) < ($1.id ?? 0) }
                .prefix(max(0, limit))
        )
        #else
        guard let pool else { return [] }
        return (try? pool.read { db in
            var request = ScrobbleQueueRecord
                .order(Column("id").asc)
                .limit(limit)
            if let afterId {
                request = request.filter(Column("id") > afterId)
            }
            return try request.fetchAll(db)
        }) ?? []
        #endif
    }

    func markScrobbleDone(id: Int64) {
        #if os(tvOS) && !SHELV_LOGIC_TESTS
        var journal = loadTVScrobbleJournal()
        journal.removeAll { $0.id == id }
        _ = saveTVScrobbleJournal(journal)
        #else
        safeWrite { db in
            try db.execute(sql: "DELETE FROM scrobble_queue WHERE id = ?", arguments: [id])
        }
        syncTVScrobbleBackup()
        #endif
    }

    func incrementScrobbleRetry(id: Int64) {
        #if os(tvOS) && !SHELV_LOGIC_TESTS
        var journal = loadTVScrobbleJournal()
        if let index = journal.firstIndex(where: { $0.id == id }) {
            journal[index].retries += 1
            _ = saveTVScrobbleJournal(journal)
        }
        #else
        safeWrite { db in
            try db.execute(sql: "UPDATE scrobble_queue SET retries = retries + 1 WHERE id = ?", arguments: [id])
        }
        syncTVScrobbleBackup()
        #endif
    }

    func removeScrobbles(serverId: String) {
        #if os(tvOS) && !SHELV_LOGIC_TESTS
        var journal = loadTVScrobbleJournal()
        journal.removeAll { $0.serverId == serverId }
        _ = saveTVScrobbleJournal(journal)
        #else
        safeWrite { db in
            try db.execute(sql: "DELETE FROM scrobble_queue WHERE serverId = ?", arguments: [serverId])
        }
        syncTVScrobbleBackup()
        #endif
    }

    func removeScrobbles(serverConfigId: String) {
        #if os(tvOS) && !SHELV_LOGIC_TESTS
        var journal = loadTVScrobbleJournal()
        journal.removeAll { $0.serverConfigId == serverConfigId }
        _ = saveTVScrobbleJournal(journal)
        #else
        safeWrite { db in
            try db.execute(
                sql: "DELETE FROM scrobble_queue WHERE serverConfigId = ?",
                arguments: [serverConfigId]
            )
        }
        syncTVScrobbleBackup()
        #endif
    }

    func removeAllScrobbles() {
        #if os(tvOS) && !SHELV_LOGIC_TESTS
        _ = saveTVScrobbleJournal([])
        #else
        safeWrite { db in
            try db.execute(sql: "DELETE FROM scrobble_queue")
        }
        syncTVScrobbleBackup()
        #endif
    }

    func pendingScrobbleCount() -> Int {
        #if os(tvOS) && !SHELV_LOGIC_TESTS
        return loadTVScrobbleJournal().count
        #else
        guard let pool else { return 0 }
        return (try? pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scrobble_queue")
        }) ?? 0
        #endif
    }

    func migrateServerId(from oldId: String, to newId: String) {
        guard pool != nil, oldId != newId else { return }
        safeWrite { db in
            try db.execute(
                sql: "UPDATE play_log SET serverId = ?, syncedAt = NULL WHERE serverId = ?",
                arguments: [newId, oldId]
            )
            #if !(os(tvOS) && !SHELV_LOGIC_TESTS)
            try db.execute(sql: "UPDATE scrobble_queue SET serverId = ? WHERE serverId = ?", arguments: [newId, oldId])
            #endif
        }
        #if os(tvOS) && !SHELV_LOGIC_TESTS
        var journal = loadTVScrobbleJournal()
        for index in journal.indices where journal[index].serverId == oldId {
            journal[index].serverId = newId
        }
        _ = saveTVScrobbleJournal(journal)
        #else
        syncTVScrobbleBackup()
        #endif
    }

    #if os(tvOS) && !SHELV_LOGIC_TESTS
    private func loadTVScrobbleJournal() -> [ScrobbleQueueRecord] {
        guard let data = UserDefaults.standard.data(forKey: Self.tvScrobbleBackupKey),
              let records = try? JSONDecoder().decode([ScrobbleQueueRecord].self, from: data)
        else { return [] }
        return records
    }

    @discardableResult
    private func saveTVScrobbleJournal(_ records: [ScrobbleQueueRecord]) -> Bool {
        if records.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.tvScrobbleBackupKey)
            return true
        }
        guard let data = try? JSONEncoder().encode(records) else { return false }
        UserDefaults.standard.set(data, forKey: Self.tvScrobbleBackupKey)
        return true
    }

    private func nextTVScrobbleId(in records: [ScrobbleQueueRecord]) -> Int64 {
        (records.compactMap(\.id).max() ?? 0) + 1
    }

    private func sameScrobbleEvent(_ lhs: ScrobbleQueueRecord, _ rhs: ScrobbleQueueRecord) -> Bool {
        lhs.songId == rhs.songId
            && lhs.serverId == rhs.serverId
            && lhs.serverConfigId == rhs.serverConfigId
            && lhs.playedAt == rhs.playedAt
    }

    /// Einmalige Migration der bisherigen SQLite+Mirror-Lösung. Danach ist nur
    /// noch das nicht purgeable UserDefaults-Journal für die Outbox zuständig.
    private func migrateTVScrobbleJournalIfNeeded() {
        guard let pool else { return }
        var journal = loadTVScrobbleJournal()
        var usedIds = Set<Int64>()
        for index in journal.indices {
            if let id = journal[index].id, usedIds.insert(id).inserted {
                continue
            }
            journal[index].id = nextTVScrobbleId(in: journal)
            if let id = journal[index].id { usedIds.insert(id) }
        }

        let legacyRows: [ScrobbleQueueRecord]
        do {
            legacyRows = try pool.read { db in
                try ScrobbleQueueRecord.order(Column("id").asc).fetchAll(db)
            }
        } catch {
            DBErrorLog.logPlayLog("tvOS scrobble migration read failed: \(error.localizedDescription)")
            return
        }
        for row in legacyRows where !journal.contains(where: { sameScrobbleEvent($0, row) }) {
            var migrated = row
            migrated.id = nextTVScrobbleId(in: journal)
            journal.append(migrated)
        }

        guard saveTVScrobbleJournal(journal) else { return }
        safeWrite { db in try db.execute(sql: "DELETE FROM scrobble_queue") }
    }

    private func syncTVScrobbleBackup() {}
    #else
    private func migrateTVScrobbleJournalIfNeeded() {}
    private func syncTVScrobbleBackup() {}
    #endif

    // MARK: - Server Cleanup (CloudKit)

    func deleteCloudKitData(serverId: String) {
        
        safeWrite { db in
            try db.execute(
                sql: "UPDATE play_log SET uuid = NULL, syncedAt = NULL WHERE serverId = ?",
                arguments: [serverId]
            )
        }
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

    /// Alle distinct Songs mit ihren aktuell gespeicherten Metadaten — Grundlage für den
    /// ID+Metadaten-Reconciliation-Task. `MAX` pickt den ersten nicht-NULL-Wert, falls
    /// einzelne Zeilen eines Songs (noch) unterschiedlich befüllt sind.
    func distinctSongEntries(serverId: String) -> [PlayLogSongEntry] {
        guard let pool else { return [] }
        return (try? pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT songId, MAX(songTitle) AS songTitle, MAX(artistName) AS artistName, MAX(albumName) AS albumName
                FROM play_log
                WHERE serverId = ?
                GROUP BY songId
                """, arguments: [serverId])
            .map {
                PlayLogSongEntry(
                    songId: $0["songId"],
                    title: $0["songTitle"],
                    artist: $0["artistName"],
                    album: $0["albumName"]
                )
            }
        }) ?? []
    }

    /// Aktualisiert die Metadaten aller Zeilen eines Songs — der Server hat unter dieser ID geantwortet.
    /// `syncedAt` wird nur zurückgesetzt, wenn sich die Metadaten wirklich ändern — sonst würde
    /// jeder Cleanup-Lauf jede unveränderte Zeile erneut zum iCloud-Upload vormerken.
    @discardableResult
    func updateMetadata(serverId: String, songId: String, title: String, artist: String?, album: String?) -> Bool {
        safeWrite { db in
            try db.execute(
                sql: """
                    UPDATE play_log
                    SET songTitle = ?, artistName = ?, albumName = ?,
                        syncedAt = CASE
                            WHEN uuid IS NOT NULL
                                AND (songTitle IS NOT ? OR artistName IS NOT ? OR albumName IS NOT ?)
                            THEN NULL
                            ELSE syncedAt
                        END
                    WHERE serverId = ? AND songId = ?
                    """,
                arguments: [title, artist, album, title, artist, album, serverId, songId]
            )
        }
    }

    /// Repariert eine tote ID: übernimmt die per Metadaten-Suche gefundene neue Song-ID
    /// (inkl. ihrer aktuellen Metadaten) für alle Zeilen, die noch die alte ID trugen.
    @discardableResult
    func repairSongId(
        serverId: String, oldSongId: String, newSongId: String,
        title: String, artist: String?, album: String?
    ) -> Bool {
        safeWrite { db in
            try db.execute(
                sql: """
                    UPDATE play_log SET songId = ?, songTitle = ?, artistName = ?, albumName = ?, syncedAt = NULL
                    WHERE serverId = ? AND songId = ?
                    """,
                arguments: [newSongId, title, artist, album, serverId, oldSongId]
            )
        }
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
            .appendingPathComponent("shelv_playlog_import_rollback.db")
    }

    /// Hält den PlayLog-Actor während Snapshot, Dateiaustausch und
    /// Outbox-Wiederherstellung exklusiv. Neue Plays warten dadurch bis nach dem
    /// Import und können weder in der alten DB verschwinden noch sie neu öffnen.
    func replaceDatabaseFromImport(sourceURL: URL, serverId: String) throws {
        let localPendingScrobbles = allPendingScrobbles()
        do {
            try createImportRollback()
        } catch {
            // Die Live-DB wurde noch nicht verändert und ist damit bereits der
            // vollständig erhaltene Ausgangszustand.
            throw PlayLogImportError.restored(importMessage: error.localizedDescription)
        }

        do {
            pool = nil
            let destination = Self.dbURL
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            for suffix in ["", "-wal", "-shm"] {
                let path = destination.path + suffix
                if FileManager.default.fileExists(atPath: path) {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            try discardImportedScrobbleQueueBeforeSetup()

            setup()
            guard pool != nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            rewriteAllServerIds(to: serverId)
            guard restorePendingScrobbles(localPendingScrobbles) else {
                throw CocoaError(.fileWriteUnknown)
            }
            cleanupImportRollback()
        } catch {
            let importMessage = error.localizedDescription
            do {
                try applyImportRollback()
                cleanupImportRollback()
            } catch {
                throw PlayLogImportError.rollbackFailed(
                    importMessage: importMessage,
                    rollbackMessage: error.localizedDescription
                )
            }
            throw PlayLogImportError.restored(importMessage: importMessage)
        }
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

    /// Entfernt nur die transportbezogene Queue aus einer gerade kopierten,
    /// noch geschlossenen Play-Datenbank. Sie gehört zum Quellgerät und darf
    /// weder migriert noch an eine lokale Serverkonfiguration umgeschrieben werden.
    func discardImportedScrobbleQueueBeforeSetup() throws {
        guard pool == nil else {
            throw NSError(
                domain: "PlayLogService",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Database must be closed before import sanitization"]
            )
        }
        let database = try DatabaseQueue(path: Self.dbURL.path)
        try database.write { db in
            if try db.tableExists("scrobble_queue") {
                try db.execute(sql: "DELETE FROM scrobble_queue")
            }
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
            .appendingPathComponent("shelv_playlog_export.db")
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
        }
    }

    func rewriteAllServerIds(to newId: String) {
        guard pool != nil, !newId.isEmpty else { return }
        safeWrite { db in
            try db.execute(sql: "UPDATE play_log SET serverId = ?, syncedAt = NULL WHERE serverId != ?",
                           arguments: [newId, newId])
            // Ein DB-Import darf keine transportbezogene Outbox des
            // Quellgeräts übernehmen. Deren Zielkonfiguration ist nicht Teil des
            // Backups und ein Rewrite könnte Plays an den falschen Server senden.
            try db.execute(sql: "DELETE FROM scrobble_queue")
        }
        syncTVScrobbleBackup()
    }

}
