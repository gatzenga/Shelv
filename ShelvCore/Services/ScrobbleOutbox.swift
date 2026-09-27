import Foundation
import GRDB

struct ScrobbleQueueRecord: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var songId: String
    var serverId: String
    var serverConfigId: String?
    var playedAt: Double       // Date.timeIntervalSince1970
    var retries: Int

    static let databaseTableName = "scrobble_queue"
}

/// Durable outbox for plays that still have to reach Navidrome.
///
/// iOS and macOS keep it in a small SQLite file of its own. tvOS may purge its
/// Caches container under storage pressure, so there the queue lives in
/// UserDefaults instead, which is fine for a handful of pending rows.
///
/// Earlier versions kept this queue inside the play history database. `setup()`
/// carries any rows still waiting there into the outbox and then deletes the
/// old database for good.
actor ScrobbleOutbox {
    static let shared = ScrobbleOutbox()

    #if os(tvOS) && !SHELV_LOGIC_TESTS
    private static let tvJournalKey = "shelv_pending_scrobbles_v1"
    private var didSetup = false
    #else
    private var queue: DatabaseQueue?
    #endif

    #if SHELV_LOGIC_TESTS
    nonisolated(unsafe) static var testDatabaseURL: URL?
    nonisolated(unsafe) static var testLegacyDatabaseURL: URL?
    #endif

    private init() {}

    // MARK: - Setup

    func setup() {
        #if os(tvOS) && !SHELV_LOGIC_TESTS
        guard !didSetup else { return }
        didSetup = true
        var journal = loadJournal()
        for row in Self.drainLegacyDatabase() where !journal.contains(where: { Self.sameEvent($0, row) }) {
            var migrated = row
            migrated.id = Self.nextId(in: journal)
            journal.append(migrated)
        }
        _ = saveJournal(journal)
        #else
        guard queue == nil else { return }
        let url = Self.databaseURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var config = Configuration()
            config.label = "shelv.db.scrobbleoutbox"
            config.qos = .userInitiated
            let q = try DatabaseQueue(path: url.path, configuration: config)
            var migrator = DatabaseMigrator()
            migrator.registerMigration("v1_create") { db in
                try db.create(table: "scrobble_queue", ifNotExists: true) { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("songId", .text).notNull()
                    t.column("serverId", .text).notNull()
                    t.column("serverConfigId", .text)
                    t.column("playedAt", .double).notNull()
                    t.column("retries", .integer).notNull().defaults(to: 0)
                }
                try db.create(
                    index: "idx_scrobble_queue_server_config",
                    on: "scrobble_queue",
                    columns: ["serverConfigId", "id"],
                    ifNotExists: true
                )
            }
            try migrator.migrate(q)
            queue = q
            Self.applyDataProtection(at: url)
        } catch {
            DBErrorLog.logDatabase("Scrobble outbox setup failed: \(error.localizedDescription)")
            return
        }

        let legacyRows = Self.drainLegacyDatabase()
        if !legacyRows.isEmpty {
            safeWrite { db in
                for row in legacyRows {
                    var migrated = row
                    migrated.id = nil
                    try migrated.insert(db)
                }
            }
        }
        #endif
    }

    func shutdown() {
        #if os(tvOS) && !SHELV_LOGIC_TESTS
        didSetup = false
        #else
        queue = nil
        #endif
    }

    // MARK: - Queue

    @discardableResult
    func enqueue(
        songId: String,
        serverId: String,
        serverConfigId: String?,
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
        var journal = loadJournal()
        var durable = record
        durable.id = Self.nextId(in: journal)
        journal.append(durable)
        return saveJournal(journal)
        #else
        return safeWrite { db in try record.insert(db) }
        #endif
    }

    func pendingScrobbles(afterId: Int64?, limit: Int = 50) -> [ScrobbleQueueRecord] {
        #if os(tvOS) && !SHELV_LOGIC_TESTS
        return Array(
            loadJournal()
                .filter { ($0.id ?? 0) > (afterId ?? 0) }
                .sorted { ($0.id ?? 0) < ($1.id ?? 0) }
                .prefix(max(0, limit))
        )
        #else
        guard let queue else { return [] }
        return (try? queue.read { db in
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
        var journal = loadJournal()
        journal.removeAll { $0.id == id }
        _ = saveJournal(journal)
        #else
        safeWrite { db in
            try db.execute(sql: "DELETE FROM scrobble_queue WHERE id = ?", arguments: [id])
        }
        #endif
    }

    func incrementScrobbleRetry(id: Int64) {
        #if os(tvOS) && !SHELV_LOGIC_TESTS
        var journal = loadJournal()
        if let index = journal.firstIndex(where: { $0.id == id }) {
            journal[index].retries += 1
            _ = saveJournal(journal)
        }
        #else
        safeWrite { db in
            try db.execute(sql: "UPDATE scrobble_queue SET retries = retries + 1 WHERE id = ?", arguments: [id])
        }
        #endif
    }

    func removeScrobbles(serverConfigId: String) {
        #if os(tvOS) && !SHELV_LOGIC_TESTS
        var journal = loadJournal()
        journal.removeAll { $0.serverConfigId == serverConfigId }
        _ = saveJournal(journal)
        #else
        safeWrite { db in
            try db.execute(
                sql: "DELETE FROM scrobble_queue WHERE serverConfigId = ?",
                arguments: [serverConfigId]
            )
        }
        #endif
    }

    func removeAllScrobbles() {
        #if os(tvOS) && !SHELV_LOGIC_TESTS
        _ = saveJournal([])
        #else
        safeWrite { db in
            try db.execute(sql: "DELETE FROM scrobble_queue")
        }
        #endif
    }

    func pendingScrobbleCount() -> Int {
        #if os(tvOS) && !SHELV_LOGIC_TESTS
        return loadJournal().count
        #else
        guard let queue else { return 0 }
        return (try? queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scrobble_queue")
        }) ?? 0
        #endif
    }

    func migrateServerId(from oldId: String, to newId: String) {
        guard oldId != newId else { return }
        #if os(tvOS) && !SHELV_LOGIC_TESTS
        var journal = loadJournal()
        for index in journal.indices where journal[index].serverId == oldId {
            journal[index].serverId = newId
        }
        _ = saveJournal(journal)
        #else
        safeWrite { db in
            try db.execute(
                sql: "UPDATE scrobble_queue SET serverId = ? WHERE serverId = ?",
                arguments: [newId, oldId]
            )
        }
        #endif
    }

    // MARK: - Storage

    #if os(tvOS) && !SHELV_LOGIC_TESTS
    private func loadJournal() -> [ScrobbleQueueRecord] {
        guard let data = UserDefaults.standard.data(forKey: Self.tvJournalKey),
              let records = try? JSONDecoder().decode([ScrobbleQueueRecord].self, from: data)
        else { return [] }
        return records
    }

    @discardableResult
    private func saveJournal(_ records: [ScrobbleQueueRecord]) -> Bool {
        if records.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.tvJournalKey)
            return true
        }
        guard let data = try? JSONEncoder().encode(records) else { return false }
        UserDefaults.standard.set(data, forKey: Self.tvJournalKey)
        return true
    }

    private static func nextId(in records: [ScrobbleQueueRecord]) -> Int64 {
        (records.compactMap(\.id).max() ?? 0) + 1
    }

    private static func sameEvent(_ lhs: ScrobbleQueueRecord, _ rhs: ScrobbleQueueRecord) -> Bool {
        lhs.songId == rhs.songId
            && lhs.serverId == rhs.serverId
            && lhs.serverConfigId == rhs.serverConfigId
            && lhs.playedAt == rhs.playedAt
    }
    #else
    @discardableResult
    private func safeWrite(_ label: String = #function, _ block: (Database) throws -> Void) -> Bool {
        guard let queue else {
            DBErrorLog.logDatabase("Scrobble outbox \(label): not initialized")
            return false
        }
        do {
            try queue.write(block)
            return true
        } catch {
            DBErrorLog.logDatabase("Scrobble outbox \(label): \(error.localizedDescription)")
            return false
        }
    }

    static var databaseURL: URL {
        #if SHELV_LOGIC_TESTS
        if let testDatabaseURL { return testDatabaseURL }
        #endif
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shelv_scrobbles/outbox.db")
    }

    private static func applyDataProtection(at url: URL) {
        #if os(iOS)
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let path = url.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: path
            )
        }
        #endif
    }
    #endif

    // MARK: - Legacy play history database

    /// Every place the removed play history database may still sit, newest first.
    private static var legacyDatabaseURLs: [URL] {
        #if SHELV_LOGIC_TESTS
        if let testLegacyDatabaseURL { return [testLegacyDatabaseURL] }
        #endif
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        var urls: [URL] = []
        #if !os(tvOS)
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        urls.append(support.appendingPathComponent("shelv_playlog/playlog.db"))
        urls.append(support.appendingPathComponent(RemovedFeatureCleanup.legacyDatabaseSubpath))
        #endif
        urls.append(caches.appendingPathComponent("shelv_playlog/playlog.db"))
        urls.append(caches.appendingPathComponent(RemovedFeatureCleanup.legacyDatabaseSubpath))
        return urls
    }

    /// Reads the scrobbles that were still waiting in the old play history
    /// database, then deletes that database. A file that cannot be read is kept
    /// so the next launch can try again instead of losing its pending plays.
    private static func drainLegacyDatabase() -> [ScrobbleQueueRecord] {
        let fm = FileManager.default
        var rows: [ScrobbleQueueRecord] = []
        for url in legacyDatabaseURLs where fm.fileExists(atPath: url.path) {
            do {
                // Read-write on purpose: SQLite may have to fold a leftover
                // WAL file back in before the last queued rows become visible.
                let legacy = try DatabaseQueue(path: url.path)
                let found = try legacy.read { db -> [ScrobbleQueueRecord] in
                    guard try db.tableExists("scrobble_queue") else { return [] }
                    let hasConfigColumn = try db.columns(in: "scrobble_queue")
                        .contains { $0.name == "serverConfigId" }
                    let sql = hasConfigColumn
                        ? "SELECT id, songId, serverId, serverConfigId, playedAt, retries FROM scrobble_queue ORDER BY id"
                        : "SELECT id, songId, serverId, NULL AS serverConfigId, playedAt, retries FROM scrobble_queue ORDER BY id"
                    return try ScrobbleQueueRecord.fetchAll(db, sql: sql)
                }
                try legacy.close()
                rows.append(contentsOf: found)
            } catch {
                DBErrorLog.logDatabase("Legacy play history read failed: \(error.localizedDescription)")
                continue
            }
            for suffix in ["", "-wal", "-shm"] {
                try? fm.removeItem(atPath: url.path + suffix)
            }
            let folder = url.deletingLastPathComponent()
            if (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? fm.removeItem(at: folder)
            }
        }
        return rows
    }
}
