import Foundation
import GRDB

enum LibraryEntity: String {
    case albums
    case artists
}

enum LibraryDatabaseSortDirection {
    case ascending
    case descending
}

enum LibraryAlbumSort {
    case name
    case artist
    case year
    case playCount
    case created
}

enum LibraryArtistSort {
    case name
    case albumCount
}

struct LibrarySyncState: Equatable {
    let serverKey: String
    let entity: LibraryEntity
    let status: String
    let startedAt: Double?
    let completedAt: Double?
    let syncGeneration: String?
    let pendingGeneration: String?
    let rowCount: Int?
    let lastError: String?
}

private struct LibraryAlbumRecord: Codable, FetchableRecord, PersistableRecord {
    var serverKey: String
    var stableId: String?
    var id: String
    var name: String
    /// Normalized effective key used by SQLite ordering.
    var sortName: String
    /// Raw OpenSubsonic sort name for model round-tripping and matching section grouping.
    var metadataSortName: String?
    var artist: String?
    var artistId: String?
    var coverArt: String?
    var songCount: Int?
    var duration: Int?
    var year: Int?
    var genre: String?
    var playCount: Int?
    var starred: Double?
    var created: Double?
    var syncGeneration: String
    var updatedAt: Double

    static let databaseTableName = "library_albums"

    init(album: Album, serverKey: String, stableId: String?, generation: String, updatedAt: Double) {
        self.serverKey = serverKey
        self.stableId = stableId
        self.id = album.id
        self.name = album.name
        self.sortName = LibrarySortKey.normalized(
            displayName: album.name,
            explicitSortName: album.sortName
        )
        self.metadataSortName = album.sortName
        self.artist = album.artist
        self.artistId = album.artistId
        self.coverArt = album.coverArt
        self.songCount = album.songCount
        self.duration = album.duration
        self.year = album.year
        self.genre = album.genre
        self.playCount = album.playCount
        self.starred = album.starred?.timeIntervalSince1970
        self.created = album.created?.timeIntervalSince1970
        self.syncGeneration = generation
        self.updatedAt = updatedAt
    }

    func toAlbum() -> Album {
        Album(
            id: id,
            name: name,
            sortName: metadataSortName,
            artist: artist,
            artistId: artistId,
            coverArt: coverArt,
            songCount: songCount,
            duration: duration,
            year: year,
            genre: genre,
            playCount: playCount,
            starred: starred.map(Date.init(timeIntervalSince1970:)),
            created: created.map(Date.init(timeIntervalSince1970:))
        )
    }
}

private struct LibraryArtistRecord: Codable, FetchableRecord, PersistableRecord {
    var serverKey: String
    var stableId: String?
    var id: String
    var name: String
    /// Normalized effective key used by SQLite ordering.
    var sortName: String
    /// Raw OpenSubsonic sort name for model round-tripping and matching section grouping.
    var metadataSortName: String?
    var albumCount: Int?
    var coverArt: String?
    var starred: Double?
    var syncGeneration: String
    var updatedAt: Double

    static let databaseTableName = "library_artists"

    init(artist: Artist, serverKey: String, stableId: String?, generation: String, updatedAt: Double) {
        self.serverKey = serverKey
        self.stableId = stableId
        self.id = artist.id
        self.name = artist.name
        self.sortName = LibrarySortKey.normalized(
            displayName: artist.name,
            explicitSortName: artist.sortName
        )
        self.metadataSortName = artist.sortName
        self.albumCount = artist.albumCount
        self.coverArt = artist.coverArt
        self.starred = artist.starred?.timeIntervalSince1970
        self.syncGeneration = generation
        self.updatedAt = updatedAt
    }

    func toArtist() -> Artist {
        Artist(
            id: id,
            name: name,
            sortName: metadataSortName,
            albumCount: albumCount,
            coverArt: coverArt,
            starred: starred.map(Date.init(timeIntervalSince1970:))
        )
    }
}

actor LibraryDatabase {
    static let shared = LibraryDatabase()

    private let databaseURL: URL
    private var databaseQueue: DatabaseQueue?

    init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL ?? Self.defaultDBURL
    }

    static var defaultDBURL: URL {
        #if os(tvOS)
        return FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shelv_library_cache/library.db")
        #else
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shelv_library_cache/library.db")
        #endif
    }

    func setup() throws {
        guard databaseQueue == nil else { return }
        let dir = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.applyStorageAttributes(at: databaseURL)
        databaseQueue = try openAndMigrate(at: databaseURL)
        Self.applyStorageAttributes(at: databaseURL)
    }

    func beginGeneration(entity: LibraryEntity, serverKey: String, generation: String) throws {
        try ensureDatabase().write { db in
            let now = Date().timeIntervalSince1970
            try db.execute(
                sql: """
                INSERT INTO library_sync_state
                    (serverKey, entity, status, startedAt, pendingGeneration)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(serverKey, entity) DO UPDATE SET
                    status = excluded.status,
                    startedAt = excluded.startedAt,
                    pendingGeneration = excluded.pendingGeneration,
                    lastError = NULL
                """,
                arguments: [serverKey, entity.rawValue, "syncing", now, generation]
            )
        }
    }

    func upsertAlbums(_ albums: [Album], serverKey: String, stableId: String?, generation: String) throws {
        guard !albums.isEmpty else { return }
        try ensureDatabase().write { db in
            let now = Date().timeIntervalSince1970
            for album in albums {
                let record = LibraryAlbumRecord(
                    album: album,
                    serverKey: serverKey,
                    stableId: stableId,
                    generation: generation,
                    updatedAt: now
                )
                try record.insert(db, onConflict: .replace)
            }
        }
    }

    func upsertArtists(_ artists: [Artist], serverKey: String, stableId: String?, generation: String) throws {
        guard !artists.isEmpty else { return }
        try ensureDatabase().write { db in
            let now = Date().timeIntervalSince1970
            for artist in artists {
                let record = LibraryArtistRecord(
                    artist: artist,
                    serverKey: serverKey,
                    stableId: stableId,
                    generation: generation,
                    updatedAt: now
                )
                try record.insert(db, onConflict: .replace)
            }
        }
    }

    /// Atomically promotes only the generation that still owns the current
    /// refresh slot. A superseded generation may clean up its own rows, but it
    /// can never delete or replace a newer snapshot.
    @discardableResult
    func finishGeneration(
        entity: LibraryEntity,
        serverKey: String,
        generation: String
    ) throws -> Bool {
        try ensureDatabase().write { db -> Bool in
            let table = Self.tableName(for: entity)
            let pendingGeneration = try String.fetchOne(
                db,
                sql: """
                SELECT pendingGeneration FROM library_sync_state
                WHERE serverKey = ? AND entity = ?
                """,
                arguments: [serverKey, entity.rawValue]
            )
            guard pendingGeneration == generation else {
                let visibleGeneration = try visibleGeneration(
                    db: db,
                    serverKey: serverKey,
                    entity: entity
                )
                if visibleGeneration != generation {
                    try db.execute(
                        sql: "DELETE FROM \(table) WHERE serverKey = ? AND syncGeneration = ?",
                        arguments: [serverKey, generation]
                    )
                }
                return false
            }

            let rowCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(table) WHERE serverKey = ? AND syncGeneration = ?",
                arguments: [serverKey, generation]
            ) ?? 0

            try db.execute(
                sql: "DELETE FROM \(table) WHERE serverKey = ? AND syncGeneration != ?",
                arguments: [serverKey, generation]
            )

            let now = Date().timeIntervalSince1970
            try db.execute(
                sql: """
                UPDATE library_sync_state
                SET status = ?,
                    completedAt = ?,
                    syncGeneration = ?,
                    pendingGeneration = NULL,
                    rowCount = ?,
                    lastError = NULL
                WHERE serverKey = ? AND entity = ? AND pendingGeneration = ?
                """,
                arguments: [
                    "completed", now, generation, rowCount,
                    serverKey, entity.rawValue, generation,
                ]
            )
            return true
        }
    }

    /// Records a failure only when `generation` still owns the refresh slot.
    /// Stale failures are cleanup-only and cannot overwrite newer state.
    @discardableResult
    func recordFailure(
        entity: LibraryEntity,
        serverKey: String,
        generation: String,
        error: Error
    ) throws -> Bool {
        try ensureDatabase().write { db -> Bool in
            let message = error.localizedDescription
            let table = Self.tableName(for: entity)
            let visibleGeneration = try visibleGeneration(
                db: db,
                serverKey: serverKey,
                entity: entity
            )
            if visibleGeneration != generation {
                try db.execute(
                    sql: "DELETE FROM \(table) WHERE serverKey = ? AND syncGeneration = ?",
                    arguments: [serverKey, generation]
                )
            }

            let pendingGeneration = try String.fetchOne(
                db,
                sql: """
                SELECT pendingGeneration FROM library_sync_state
                WHERE serverKey = ? AND entity = ?
                """,
                arguments: [serverKey, entity.rawValue]
            )
            guard pendingGeneration == generation else { return false }

            try db.execute(
                sql: """
                UPDATE library_sync_state
                SET status = ?, pendingGeneration = NULL, lastError = ?
                WHERE serverKey = ? AND entity = ? AND pendingGeneration = ?
                """,
                arguments: ["failed", message, serverKey, entity.rawValue, generation]
            )
            return true
        }
    }

    func albums(
        serverKey: String,
        sort: LibraryAlbumSort = .name,
        direction: LibraryDatabaseSortDirection = .ascending,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [Album] {
        try ensureDatabase().read { db in
            guard let generation = try visibleGeneration(db: db, serverKey: serverKey, entity: .albums) else {
                return []
            }
            var sql = """
                SELECT * FROM library_albums
                WHERE serverKey = ? AND syncGeneration = ?
                ORDER BY \(Self.albumOrderClause(sort: sort, direction: direction))
                """
            var args: [DatabaseValueConvertible] = [serverKey, generation]
            appendLimit(limit, offset: offset, to: &sql, args: &args)
            return try LibraryAlbumRecord
                .fetchAll(db, sql: sql, arguments: StatementArguments(args))
                .map { $0.toAlbum() }
        }
    }

    func artists(
        serverKey: String,
        sort: LibraryArtistSort = .name,
        direction: LibraryDatabaseSortDirection = .ascending,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [Artist] {
        try ensureDatabase().read { db in
            guard let generation = try visibleGeneration(db: db, serverKey: serverKey, entity: .artists) else {
                return []
            }
            var sql = """
                SELECT * FROM library_artists
                WHERE serverKey = ? AND syncGeneration = ?
                ORDER BY \(Self.artistOrderClause(sort: sort, direction: direction))
                """
            var args: [DatabaseValueConvertible] = [serverKey, generation]
            appendLimit(limit, offset: offset, to: &sql, args: &args)
            return try LibraryArtistRecord
                .fetchAll(db, sql: sql, arguments: StatementArguments(args))
                .map { $0.toArtist() }
        }
    }

    func searchAlbums(serverKey: String, query: String, limit: Int = 50, offset: Int = 0) throws -> [Album] {
        try ensureDatabase().read { db in
            guard let generation = try visibleGeneration(db: db, serverKey: serverKey, entity: .albums) else {
                return []
            }
            let q = "%\(query.lowercased())%"
            return try LibraryAlbumRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM library_albums
                WHERE serverKey = ?
                  AND syncGeneration = ?
                  AND (LOWER(name) LIKE ? OR LOWER(COALESCE(artist, '')) LIKE ?)
                ORDER BY sortName ASC, id ASC
                LIMIT ? OFFSET ?
                """,
                arguments: [serverKey, generation, q, q, limit, offset]
            ).map { $0.toAlbum() }
        }
    }

    func searchArtists(serverKey: String, query: String, limit: Int = 50, offset: Int = 0) throws -> [Artist] {
        try ensureDatabase().read { db in
            guard let generation = try visibleGeneration(db: db, serverKey: serverKey, entity: .artists) else {
                return []
            }
            let q = "%\(query.lowercased())%"
            return try LibraryArtistRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM library_artists
                WHERE serverKey = ?
                  AND syncGeneration = ?
                  AND LOWER(name) LIKE ?
                ORDER BY sortName ASC, id ASC
                LIMIT ? OFFSET ?
                """,
                arguments: [serverKey, generation, q, limit, offset]
            ).map { $0.toArtist() }
        }
    }

    func albumCount(serverKey: String) throws -> Int {
        try count(serverKey: serverKey, entity: .albums)
    }

    func artistCount(serverKey: String) throws -> Int {
        try count(serverKey: serverKey, entity: .artists)
    }

    func albumCountByArtist(serverKey: String) throws -> [String: Int] {
        try ensureDatabase().read { db in
            guard let generation = try visibleGeneration(db: db, serverKey: serverKey, entity: .albums) else {
                return [:]
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT artistId, COUNT(*) AS count
                FROM library_albums
                WHERE serverKey = ?
                  AND syncGeneration = ?
                  AND artistId IS NOT NULL
                  AND artistId != ''
                GROUP BY artistId
                """,
                arguments: [serverKey, generation]
            )
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                (row["artistId"] as String, row["count"] as Int)
            })
        }
    }

    func clear(serverKey: String) throws {
        try ensureDatabase().write { db in
            try db.execute(sql: "DELETE FROM library_albums WHERE serverKey = ?", arguments: [serverKey])
            try db.execute(sql: "DELETE FROM library_artists WHERE serverKey = ?", arguments: [serverKey])
            try db.execute(sql: "DELETE FROM library_sync_state WHERE serverKey = ?", arguments: [serverKey])
        }
    }

    func clearAll() throws {
        try ensureDatabase().write { db in
            try db.execute(sql: "DELETE FROM library_albums")
            try db.execute(sql: "DELETE FROM library_artists")
            try db.execute(sql: "DELETE FROM library_sync_state")
        }
    }

    func removeAllFiles() throws {
        databaseQueue = nil
        for suffix in ["", "-wal", "-shm"] {
            let path = databaseURL.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
        }
    }

    func syncState(serverKey: String, entity: LibraryEntity) throws -> LibrarySyncState? {
        try ensureDatabase().read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM library_sync_state
                WHERE serverKey = ? AND entity = ?
                """,
                arguments: [serverKey, entity.rawValue]
            ) else {
                return nil
            }
            return LibrarySyncState(
                serverKey: row["serverKey"],
                entity: entity,
                status: row["status"],
                startedAt: row["startedAt"],
                completedAt: row["completedAt"],
                syncGeneration: row["syncGeneration"],
                pendingGeneration: row["pendingGeneration"],
                rowCount: row["rowCount"],
                lastError: row["lastError"]
            )
        }
    }

    func schemaObjectNames() throws -> Set<String> {
        try ensureDatabase().read { db in
            let names = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type IN ('table', 'index')"
            )
            return Set(names)
        }
    }

    private func ensureDatabase() throws -> DatabaseQueue {
        if let databaseQueue { return databaseQueue }
        try setup()
        return databaseQueue!
    }

    private func openAndMigrate(at url: URL) throws -> DatabaseQueue {
        var config = Configuration()
        config.label = "shelv.db.library"
        config.qos = .userInitiated
        let databaseQueue = try DatabaseQueue(path: url.path, configuration: config)

        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_create_library_cache") { db in
            try db.create(table: "library_albums", ifNotExists: true) { t in
                t.column("serverKey", .text).notNull()
                t.column("stableId", .text)
                t.column("id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("sortName", .text).notNull()
                t.column("artist", .text)
                t.column("artistId", .text)
                t.column("coverArt", .text)
                t.column("songCount", .integer)
                t.column("duration", .integer)
                t.column("year", .integer)
                t.column("genre", .text)
                t.column("playCount", .integer)
                t.column("starred", .double)
                t.column("created", .double)
                t.column("syncGeneration", .text).notNull()
                t.column("updatedAt", .double).notNull()
                t.primaryKey(["serverKey", "syncGeneration", "id"])
            }
            try Self.createLibraryAlbumIndexes(db)

            try db.create(table: "library_artists", ifNotExists: true) { t in
                t.column("serverKey", .text).notNull()
                t.column("stableId", .text)
                t.column("id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("sortName", .text).notNull()
                t.column("albumCount", .integer)
                t.column("coverArt", .text)
                t.column("starred", .double)
                t.column("syncGeneration", .text).notNull()
                t.column("updatedAt", .double).notNull()
                t.primaryKey(["serverKey", "syncGeneration", "id"])
            }
            try Self.createLibraryArtistIndexes(db)

            try db.create(table: "library_sync_state", ifNotExists: true) { t in
                t.column("serverKey", .text).notNull()
                t.column("entity", .text).notNull()
                t.column("status", .text).notNull()
                t.column("startedAt", .double)
                t.column("completedAt", .double)
                t.column("syncGeneration", .text)
                t.column("rowCount", .integer)
                t.column("lastError", .text)
                t.primaryKey(["serverKey", "entity"])
            }
        }
        migrator.registerMigration("v2_generation_primary_keys") { db in
            try Self.rekeyLibraryTableIfNeeded(
                db,
                table: "library_albums",
                temporaryTable: "library_albums_v1",
                dropIndexes: Self.dropLibraryAlbumIndexes,
                createTable: Self.createLibraryAlbumsTable,
                createIndexes: Self.createLibraryAlbumIndexes
            )
            try Self.rekeyLibraryTableIfNeeded(
                db,
                table: "library_artists",
                temporaryTable: "library_artists_v1",
                dropIndexes: Self.dropLibraryArtistIndexes,
                createTable: Self.createLibraryArtistsTable,
                createIndexes: Self.createLibraryArtistIndexes
            )
        }
        migrator.registerMigration("v3_library_sort_metadata") { db in
            try db.alter(table: "library_albums") { table in
                table.add(column: "metadataSortName", .text)
            }
            try db.alter(table: "library_artists") { table in
                table.add(column: "metadataSortName", .text)
            }

            // Existing cache rows predate article-aware ordering. Rebuild only
            // their derived keys; metadata correctly remains nil until refresh.
            try Self.rebuildLegacySortKeys(db, table: "library_albums")
            try Self.rebuildLegacySortKeys(db, table: "library_artists")
        }
        migrator.registerMigration("v4_library_generation_ownership") { db in
            try db.alter(table: "library_sync_state") { table in
                table.add(column: "pendingGeneration", .text)
            }
        }
        try migrator.migrate(databaseQueue)
        return databaseQueue
    }

    private static func rebuildLegacySortKeys(_ db: Database, table: String) throws {
        let cursor = try Row.fetchCursor(
            db,
            sql: "SELECT serverKey, syncGeneration, id, name, sortName FROM \(table)"
        )
        var updates: [(key: String, serverKey: String, generation: String, id: String)] = []
        while let row = try cursor.next() {
            let name: String = row["name"]
            let oldKey: String = row["sortName"]
            let newKey = LibrarySortKey.normalized(displayName: name)
            guard newKey != oldKey else { continue }
            updates.append((
                key: newKey,
                serverKey: row["serverKey"],
                generation: row["syncGeneration"],
                id: row["id"]
            ))
        }

        for update in updates {
            try db.execute(
                sql: """
                UPDATE \(table) SET sortName = ?
                WHERE serverKey = ? AND syncGeneration = ? AND id = ?
                """,
                arguments: [update.key, update.serverKey, update.generation, update.id]
            )
        }
    }

    private static func createLibraryAlbumsTable(_ db: Database) throws {
        try db.create(table: "library_albums") { t in
            t.column("serverKey", .text).notNull()
            t.column("stableId", .text)
            t.column("id", .text).notNull()
            t.column("name", .text).notNull()
            t.column("sortName", .text).notNull()
            t.column("artist", .text)
            t.column("artistId", .text)
            t.column("coverArt", .text)
            t.column("songCount", .integer)
            t.column("duration", .integer)
            t.column("year", .integer)
            t.column("genre", .text)
            t.column("playCount", .integer)
            t.column("starred", .double)
            t.column("created", .double)
            t.column("syncGeneration", .text).notNull()
            t.column("updatedAt", .double).notNull()
            t.primaryKey(["serverKey", "syncGeneration", "id"])
        }
    }

    private static func createLibraryArtistsTable(_ db: Database) throws {
        try db.create(table: "library_artists") { t in
            t.column("serverKey", .text).notNull()
            t.column("stableId", .text)
            t.column("id", .text).notNull()
            t.column("name", .text).notNull()
            t.column("sortName", .text).notNull()
            t.column("albumCount", .integer)
            t.column("coverArt", .text)
            t.column("starred", .double)
            t.column("syncGeneration", .text).notNull()
            t.column("updatedAt", .double).notNull()
            t.primaryKey(["serverKey", "syncGeneration", "id"])
        }
    }

    private static func createLibraryAlbumIndexes(_ db: Database) throws {
        try db.create(index: "idx_library_albums_sortName", on: "library_albums", columns: ["serverKey", "syncGeneration", "sortName"], ifNotExists: true)
        try db.create(index: "idx_library_albums_artistId", on: "library_albums", columns: ["serverKey", "syncGeneration", "artistId"], ifNotExists: true)
        try db.create(index: "idx_library_albums_year", on: "library_albums", columns: ["serverKey", "syncGeneration", "year"], ifNotExists: true)
        try db.create(index: "idx_library_albums_playCount", on: "library_albums", columns: ["serverKey", "syncGeneration", "playCount"], ifNotExists: true)
        try db.create(index: "idx_library_albums_created", on: "library_albums", columns: ["serverKey", "syncGeneration", "created"], ifNotExists: true)
        try db.create(index: "idx_library_albums_artist_sortName", on: "library_albums", columns: ["serverKey", "syncGeneration", "artist", "sortName"], ifNotExists: true)
    }

    private static func createLibraryArtistIndexes(_ db: Database) throws {
        try db.create(index: "idx_library_artists_sortName", on: "library_artists", columns: ["serverKey", "syncGeneration", "sortName"], ifNotExists: true)
        try db.create(index: "idx_library_artists_albumCount", on: "library_artists", columns: ["serverKey", "syncGeneration", "albumCount"], ifNotExists: true)
    }

    private static func dropLibraryAlbumIndexes(_ db: Database) throws {
        for name in [
            "idx_library_albums_sortName",
            "idx_library_albums_artistId",
            "idx_library_albums_year",
            "idx_library_albums_playCount",
            "idx_library_albums_created",
            "idx_library_albums_artist_sortName",
        ] {
            try db.execute(sql: "DROP INDEX IF EXISTS \(name)")
        }
    }

    private static func dropLibraryArtistIndexes(_ db: Database) throws {
        for name in [
            "idx_library_artists_sortName",
            "idx_library_artists_albumCount",
        ] {
            try db.execute(sql: "DROP INDEX IF EXISTS \(name)")
        }
    }

    private static func rekeyLibraryTableIfNeeded(
        _ db: Database,
        table: String,
        temporaryTable: String,
        dropIndexes: (Database) throws -> Void,
        createTable: (Database) throws -> Void,
        createIndexes: (Database) throws -> Void
    ) throws {
        let primaryKey = try primaryKeyColumns(db: db, table: table)
        guard primaryKey != ["serverKey", "syncGeneration", "id"] else {
            try createIndexes(db)
            return
        }

        try dropIndexes(db)
        try db.execute(sql: "DROP TABLE IF EXISTS \(temporaryTable)")
        try db.execute(sql: "ALTER TABLE \(table) RENAME TO \(temporaryTable)")
        try createTable(db)
        try db.execute(
            sql: """
            INSERT INTO \(table)
            SELECT * FROM \(temporaryTable)
            """
        )
        try db.execute(sql: "DROP TABLE \(temporaryTable)")
        try createIndexes(db)
    }

    private static func primaryKeyColumns(db: Database, table: String) throws -> [String] {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return rows.compactMap { row -> (Int, String)? in
            let sequence: Int = row["pk"]
            guard sequence > 0 else { return nil }
            return (sequence, row["name"])
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }

    private func visibleGeneration(db: Database, serverKey: String, entity: LibraryEntity) throws -> String? {
        try String.fetchOne(
            db,
            sql: """
            SELECT syncGeneration FROM library_sync_state
            WHERE serverKey = ? AND entity = ? AND syncGeneration IS NOT NULL
            """,
            arguments: [serverKey, entity.rawValue]
        )
    }

    private func count(serverKey: String, entity: LibraryEntity) throws -> Int {
        try ensureDatabase().read { db in
            guard let generation = try visibleGeneration(db: db, serverKey: serverKey, entity: entity) else {
                return 0
            }
            return try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(Self.tableName(for: entity)) WHERE serverKey = ? AND syncGeneration = ?",
                arguments: [serverKey, generation]
            ) ?? 0
        }
    }

    private static func tableName(for entity: LibraryEntity) -> String {
        switch entity {
        case .albums: return "library_albums"
        case .artists: return "library_artists"
        }
    }

    private static func albumOrderClause(sort: LibraryAlbumSort, direction: LibraryDatabaseSortDirection) -> String {
        let suffix: String
        switch direction {
        case .ascending:
            suffix = "ASC"
        case .descending:
            suffix = "DESC"
        }
        switch sort {
        case .name:
            return "sortName \(suffix), id ASC"
        case .artist:
            return "COALESCE(artist, '') \(suffix), sortName ASC, id ASC"
        case .year:
            return "COALESCE(year, 0) \(suffix), sortName ASC, id ASC"
        case .playCount:
            return "COALESCE(playCount, 0) \(suffix), sortName ASC, id ASC"
        case .created:
            return "COALESCE(created, 0) \(suffix), sortName ASC, id ASC"
        }
    }

    private static func artistOrderClause(sort: LibraryArtistSort, direction: LibraryDatabaseSortDirection) -> String {
        let suffix: String
        switch direction {
        case .ascending:
            suffix = "ASC"
        case .descending:
            suffix = "DESC"
        }
        switch sort {
        case .name:
            return "sortName \(suffix), id ASC"
        case .albumCount:
            return "COALESCE(albumCount, 0) \(suffix), sortName ASC, id ASC"
        }
    }

    private func appendLimit(
        _ limit: Int?,
        offset: Int,
        to sql: inout String,
        args: inout [DatabaseValueConvertible]
    ) {
        if let limit {
            sql += " LIMIT ? OFFSET ?"
            args.append(limit)
            args.append(offset)
        }
    }

    private static func applyStorageAttributes(at url: URL) {
        var dirURL = url.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dirURL.setResourceValues(values)

        #if os(iOS) || os(tvOS)
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
}
