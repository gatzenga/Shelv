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
    let rowCount: Int?
    let lastError: String?
}

private struct LibraryAlbumRecord: Codable, FetchableRecord, PersistableRecord {
    var serverKey: String
    var stableId: String?
    var id: String
    var name: String
    var sortName: String
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
        self.sortName = Self.makeSortName(album.name)
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

    private static func makeSortName(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

private struct LibraryArtistRecord: Codable, FetchableRecord, PersistableRecord {
    var serverKey: String
    var stableId: String?
    var id: String
    var name: String
    var sortName: String
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
        self.sortName = Self.makeSortName(artist.name)
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
            albumCount: albumCount,
            coverArt: coverArt,
            starred: starred.map(Date.init(timeIntervalSince1970:))
        )
    }

    private static func makeSortName(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

actor LibraryDatabase {
    static let shared = LibraryDatabase()

    private let databaseURL: URL
    private var pool: DatabasePool?

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
        guard pool == nil else { return }
        let dir = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.applyStorageAttributes(at: databaseURL)
        pool = try openAndMigrate(at: databaseURL)
        Self.applyStorageAttributes(at: databaseURL)
    }

    func beginGeneration(entity: LibraryEntity, serverKey: String) throws {
        try ensurePool().write { db in
            let now = Date().timeIntervalSince1970
            let exists = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM library_sync_state WHERE serverKey = ? AND entity = ?",
                arguments: [serverKey, entity.rawValue]
            ) ?? 0

            if exists > 0 {
                try db.execute(
                    sql: """
                    UPDATE library_sync_state
                    SET status = ?, startedAt = ?, lastError = NULL
                    WHERE serverKey = ? AND entity = ?
                    """,
                    arguments: ["syncing", now, serverKey, entity.rawValue]
                )
            } else {
                try db.execute(
                    sql: """
                    INSERT INTO library_sync_state (serverKey, entity, status, startedAt)
                    VALUES (?, ?, ?, ?)
                    """,
                    arguments: [serverKey, entity.rawValue, "syncing", now]
                )
            }
        }
    }

    func upsertAlbums(_ albums: [Album], serverKey: String, stableId: String?, generation: String) throws {
        guard !albums.isEmpty else { return }
        try ensurePool().write { db in
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
        try ensurePool().write { db in
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

    func finishGeneration(entity: LibraryEntity, serverKey: String, generation: String) throws {
        try ensurePool().write { db in
            let table = Self.tableName(for: entity)
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
                INSERT INTO library_sync_state
                    (serverKey, entity, status, completedAt, syncGeneration, rowCount, lastError)
                VALUES (?, ?, ?, ?, ?, ?, NULL)
                ON CONFLICT(serverKey, entity) DO UPDATE SET
                    status = excluded.status,
                    completedAt = excluded.completedAt,
                    syncGeneration = excluded.syncGeneration,
                    rowCount = excluded.rowCount,
                    lastError = NULL
                """,
                arguments: [serverKey, entity.rawValue, "completed", now, generation, rowCount]
            )
        }
    }

    func recordFailure(entity: LibraryEntity, serverKey: String, error: Error) throws {
        try ensurePool().write { db in
            let message = error.localizedDescription
            let exists = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM library_sync_state WHERE serverKey = ? AND entity = ?",
                arguments: [serverKey, entity.rawValue]
            ) ?? 0

            if exists > 0 {
                try db.execute(
                    sql: """
                    UPDATE library_sync_state
                    SET status = ?, lastError = ?
                    WHERE serverKey = ? AND entity = ?
                    """,
                    arguments: ["failed", message, serverKey, entity.rawValue]
                )
            } else {
                try db.execute(
                    sql: """
                    INSERT INTO library_sync_state (serverKey, entity, status, lastError)
                    VALUES (?, ?, ?, ?)
                    """,
                    arguments: [serverKey, entity.rawValue, "failed", message]
                )
            }
        }
    }

    func albums(
        serverKey: String,
        sort: LibraryAlbumSort = .name,
        direction: LibraryDatabaseSortDirection = .ascending,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [Album] {
        try ensurePool().read { db in
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
        try ensurePool().read { db in
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
        try ensurePool().read { db in
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
        try ensurePool().read { db in
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
        try ensurePool().read { db in
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
        try ensurePool().write { db in
            try db.execute(sql: "DELETE FROM library_albums WHERE serverKey = ?", arguments: [serverKey])
            try db.execute(sql: "DELETE FROM library_artists WHERE serverKey = ?", arguments: [serverKey])
            try db.execute(sql: "DELETE FROM library_sync_state WHERE serverKey = ?", arguments: [serverKey])
        }
    }

    func clearAll() throws {
        try ensurePool().write { db in
            try db.execute(sql: "DELETE FROM library_albums")
            try db.execute(sql: "DELETE FROM library_artists")
            try db.execute(sql: "DELETE FROM library_sync_state")
        }
    }

    func removeAllFiles() throws {
        pool = nil
        for suffix in ["", "-wal", "-shm"] {
            let path = databaseURL.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
        }
    }

    func syncState(serverKey: String, entity: LibraryEntity) throws -> LibrarySyncState? {
        try ensurePool().read { db in
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
                rowCount: row["rowCount"],
                lastError: row["lastError"]
            )
        }
    }

    func schemaObjectNames() throws -> Set<String> {
        try ensurePool().read { db in
            let names = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type IN ('table', 'index')"
            )
            return Set(names)
        }
    }

    private func ensurePool() throws -> DatabasePool {
        if let pool { return pool }
        try setup()
        return pool!
    }

    private func openAndMigrate(at url: URL) throws -> DatabasePool {
        var config = Configuration()
        config.targetQueue = DispatchQueue(label: "shelv.db.library", qos: .userInitiated)
        let pool = try DatabasePool(path: url.path, configuration: config)

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
                t.primaryKey(["serverKey", "id"])
            }
            try db.create(index: "idx_library_albums_sortName", on: "library_albums", columns: ["serverKey", "sortName"], ifNotExists: true)
            try db.create(index: "idx_library_albums_artistId", on: "library_albums", columns: ["serverKey", "artistId"], ifNotExists: true)
            try db.create(index: "idx_library_albums_year", on: "library_albums", columns: ["serverKey", "year"], ifNotExists: true)
            try db.create(index: "idx_library_albums_playCount", on: "library_albums", columns: ["serverKey", "playCount"], ifNotExists: true)
            try db.create(index: "idx_library_albums_created", on: "library_albums", columns: ["serverKey", "created"], ifNotExists: true)
            try db.create(index: "idx_library_albums_artist_sortName", on: "library_albums", columns: ["serverKey", "artist", "sortName"], ifNotExists: true)

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
                t.primaryKey(["serverKey", "id"])
            }
            try db.create(index: "idx_library_artists_sortName", on: "library_artists", columns: ["serverKey", "sortName"], ifNotExists: true)
            try db.create(index: "idx_library_artists_albumCount", on: "library_artists", columns: ["serverKey", "albumCount"], ifNotExists: true)

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
        try migrator.migrate(pool)
        return pool
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
        try ensurePool().read { db in
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
