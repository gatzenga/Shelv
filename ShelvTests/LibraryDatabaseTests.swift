import XCTest
import GRDB

final class LibraryDatabaseTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelvLibraryDatabaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testSetupCreatesTablesAndIndexes() async throws {
        let database = try await makeDatabase()

        let names = try await database.schemaObjectNames()

        XCTAssertTrue(names.contains("library_albums"))
        XCTAssertTrue(names.contains("library_artists"))
        XCTAssertTrue(names.contains("library_sync_state"))
        XCTAssertTrue(names.contains("idx_library_albums_sortName"))
        XCTAssertTrue(names.contains("idx_library_artists_sortName"))
    }

    func testUpsertAndFetchAlbumsPreservesFields() async throws {
        let database = try await makeDatabase()
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let starred = Date(timeIntervalSince1970: 1_710_000_000)
        let album = Album(
            id: "album-1",
            name: "Alpha",
            sortName: "Alpha, The",
            artist: "Artist A",
            artistId: "artist-1",
            coverArt: "cover-1",
            songCount: 12,
            duration: 3600,
            year: 2024,
            genre: "Rock",
            playCount: 9,
            starred: starred,
            created: created
        )

        try await writeAlbums([album], to: database, serverKey: "server-a", generation: "g1")

        let fetched = try await database.albums(serverKey: "server-a")
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].id, album.id)
        XCTAssertEqual(fetched[0].name, album.name)
        XCTAssertEqual(fetched[0].sortName, album.sortName)
        XCTAssertEqual(fetched[0].artist, album.artist)
        XCTAssertEqual(fetched[0].artistId, album.artistId)
        XCTAssertEqual(fetched[0].coverArt, album.coverArt)
        XCTAssertEqual(fetched[0].songCount, album.songCount)
        XCTAssertEqual(fetched[0].duration, album.duration)
        XCTAssertEqual(fetched[0].year, album.year)
        XCTAssertEqual(fetched[0].genre, album.genre)
        XCTAssertEqual(fetched[0].playCount, album.playCount)
        XCTAssertEqual(fetched[0].created?.timeIntervalSince1970 ?? 0, created.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(fetched[0].starred?.timeIntervalSince1970 ?? 0, starred.timeIntervalSince1970, accuracy: 0.001)
    }

    func testUpsertReplacesAlbumInNextGeneration() async throws {
        let database = try await makeDatabase()

        try await writeAlbums([album(id: "a1", name: "Old", year: 2020)], to: database, serverKey: "server-a", generation: "g1")
        try await writeAlbums([album(id: "a1", name: "New", year: 2025)], to: database, serverKey: "server-a", generation: "g2")

        let fetched = try await database.albums(serverKey: "server-a")
        XCTAssertEqual(fetched.map(\.name), ["New"])
        let albumCount = try await database.albumCount(serverKey: "server-a")
        XCTAssertEqual(albumCount, 1)
    }

    func testAlbumSortingUsesDatabaseOrder() async throws {
        let database = try await makeDatabase()
        let albums = [
            album(id: "a1", name: "Beta", artist: "Zed", year: 2020, playCount: 4, created: 100),
            album(id: "a2", name: "Alpha", artist: "Mid", year: 2024, playCount: 10, created: 300),
            album(id: "a3", name: "Gamma", artist: "Ann", year: 2019, playCount: 1, created: 200),
        ]

        try await writeAlbums(albums, to: database, serverKey: "server-a", generation: "g1")

        let byName = try await database.albums(serverKey: "server-a", sort: .name).map(\.id)
        let byYear = try await database.albums(serverKey: "server-a", sort: .year, direction: .descending).map(\.id)
        let byPlayCount = try await database.albums(serverKey: "server-a", sort: .playCount, direction: .descending).map(\.id)
        let byCreated = try await database.albums(serverKey: "server-a", sort: .created, direction: .descending).map(\.id)
        let byArtist = try await database.albums(serverKey: "server-a", sort: .artist).map(\.id)
        XCTAssertEqual(byName, ["a2", "a1", "a3"])
        XCTAssertEqual(byYear, ["a2", "a1", "a3"])
        XCTAssertEqual(byPlayCount, ["a2", "a1", "a3"])
        XCTAssertEqual(byCreated, ["a2", "a3", "a1"])
        XCTAssertEqual(byArtist, ["a3", "a2", "a1"])
    }

    func testDatabaseSortingUsesMetadataTagBeforeArticleFallback() async throws {
        let database = try await makeDatabase()
        let albums = [
            Album(id: "tagged", name: "The Police", sortName: "The Police"),
            Album(id: "queen", name: "Queen"),
            Album(id: "untagged", name: "The Police"),
        ]
        let artists = [
            Artist(id: "tagged", name: "The Police", sortName: "The Police"),
            Artist(id: "queen", name: "Queen"),
            Artist(id: "untagged", name: "The Police"),
        ]

        try await writeAlbums(albums, to: database, serverKey: "server-a", generation: "g1")
        try await writeArtists(artists, to: database, serverKey: "server-a", generation: "g1")

        let sortedAlbums = try await database.albums(serverKey: "server-a")
        let sortedArtists = try await database.artists(serverKey: "server-a")
        XCTAssertEqual(sortedAlbums.map(\.id), ["untagged", "queen", "tagged"])
        XCTAssertEqual(sortedArtists.map(\.id), ["untagged", "queen", "tagged"])
        XCTAssertEqual(sortedAlbums.last?.sortName, "The Police")
        XCTAssertEqual(sortedArtists.last?.sortName, "The Police")
    }

    func testAlbumPaginationAppliesAfterStableSort() async throws {
        let database = try await makeDatabase()
        let albums = [
            album(id: "a1", name: "Alpha"),
            album(id: "a2", name: "Beta"),
            album(id: "a3", name: "Gamma"),
            album(id: "a4", name: "Delta"),
        ]

        try await writeAlbums(albums, to: database, serverKey: "server-a", generation: "g1")

        let page = try await database
            .albums(serverKey: "server-a", sort: .name, limit: 2, offset: 1)
            .map(\.id)
        XCTAssertEqual(page, ["a2", "a4"])
    }

    func testArtistSortingByAlbumCountUsesDatabaseOrder() async throws {
        let database = try await makeDatabase()
        let artists = [
            Artist(id: "artist-low", name: "Low", albumCount: 1),
            Artist(id: "artist-none", name: "None", albumCount: nil),
            Artist(id: "artist-high", name: "High", albumCount: 4),
        ]

        try await writeArtists(artists, to: database, serverKey: "server-a", generation: "g1")

        let descending = try await database
            .artists(serverKey: "server-a", sort: .albumCount, direction: .descending)
            .map(\.id)
        let ascending = try await database
            .artists(serverKey: "server-a", sort: .albumCount, direction: .ascending)
            .map(\.id)
        XCTAssertEqual(descending, ["artist-high", "artist-low", "artist-none"])
        XCTAssertEqual(ascending, ["artist-none", "artist-low", "artist-high"])
    }

    func testUnfinishedGenerationDoesNotReplaceVisibleLibrary() async throws {
        let database = try await makeDatabase()

        try await writeAlbums([album(id: "shared", name: "Old")], to: database, serverKey: "server-a", generation: "g1")
        try await database.beginGeneration(entity: .albums, serverKey: "server-a")
        try await database.upsertAlbums([album(id: "shared", name: "New")], serverKey: "server-a", stableId: nil, generation: "g2")

        let visibleDuringRefresh = try await database.albums(serverKey: "server-a").map(\.name)
        XCTAssertEqual(visibleDuringRefresh, ["Old"])

        try await database.finishGeneration(entity: .albums, serverKey: "server-a", generation: "g2")
        let visibleAfterFinish = try await database.albums(serverKey: "server-a").map(\.name)
        XCTAssertEqual(visibleAfterFinish, ["New"])
    }

    func testFailedAlbumGenerationKeepsPreviousRecordWhenIDsOverlap() async throws {
        let database = try await makeDatabase()

        try await writeAlbums([album(id: "shared", name: "Old")], to: database, serverKey: "server-a", generation: "g1")
        try await database.beginGeneration(entity: .albums, serverKey: "server-a")
        try await database.upsertAlbums([album(id: "shared", name: "New")], serverKey: "server-a", stableId: nil, generation: "g2")
        try await database.recordFailure(entity: .albums, serverKey: "server-a", error: TestLibraryError.refreshFailed)

        let visibleAfterFailure = try await database.albums(serverKey: "server-a").map(\.name)
        let state = try await database.syncState(serverKey: "server-a", entity: .albums)
        XCTAssertEqual(visibleAfterFailure, ["Old"])
        XCTAssertEqual(state?.status, "failed")
        XCTAssertEqual(state?.syncGeneration, "g1")
    }

    func testFailedArtistGenerationKeepsPreviousRecordWhenIDsOverlap() async throws {
        let database = try await makeDatabase()

        try await writeArtists([artist(id: "shared", name: "Old Artist")], to: database, serverKey: "server-a", generation: "g1")
        try await database.beginGeneration(entity: .artists, serverKey: "server-a")
        try await database.upsertArtists([artist(id: "shared", name: "New Artist")], serverKey: "server-a", stableId: nil, generation: "g2")
        try await database.recordFailure(entity: .artists, serverKey: "server-a", error: TestLibraryError.refreshFailed)

        let visibleAfterFailure = try await database.artists(serverKey: "server-a").map(\.name)
        let state = try await database.syncState(serverKey: "server-a", entity: .artists)
        XCTAssertEqual(visibleAfterFailure, ["Old Artist"])
        XCTAssertEqual(state?.status, "failed")
        XCTAssertEqual(state?.syncGeneration, "g1")
    }

    func testSuccessfulEmptyGenerationClearsVisibleLibrary() async throws {
        let database = try await makeDatabase()

        try await writeAlbums([album(id: "old", name: "Old")], to: database, serverKey: "server-a", generation: "g1")
        try await database.beginGeneration(entity: .albums, serverKey: "server-a")
        try await database.finishGeneration(entity: .albums, serverKey: "server-a", generation: "empty")

        let fetched = try await database.albums(serverKey: "server-a")
        let state = try await database.syncState(serverKey: "server-a", entity: .albums)
        XCTAssertTrue(fetched.isEmpty)
        XCTAssertEqual(state?.status, "completed")
        XCTAssertEqual(state?.syncGeneration, "empty")
        XCTAssertEqual(state?.rowCount, 0)
    }

    func testSameAlbumIDCanExistOnDifferentServers() async throws {
        let database = try await makeDatabase()

        try await writeAlbums([album(id: "shared", name: "Server A")], to: database, serverKey: "server-a", generation: "g1")
        try await writeAlbums([album(id: "shared", name: "Server B")], to: database, serverKey: "server-b", generation: "g1")

        let serverAAlbums = try await database.albums(serverKey: "server-a").map(\.name)
        let serverBAlbums = try await database.albums(serverKey: "server-b").map(\.name)
        XCTAssertEqual(serverAAlbums, ["Server A"])
        XCTAssertEqual(serverBAlbums, ["Server B"])
    }

    func testMigratesLegacyPrimaryKeySchemaToGenerationSafeKeys() async throws {
        let databaseURL = tempDir.appendingPathComponent("legacy-library.db")
        try createLegacyV1Database(at: databaseURL)
        let database = LibraryDatabase(databaseURL: databaseURL)

        try await database.setup()
        let migratedAlbumNames = try await database.albums(serverKey: "server-a").map(\.name)
        let migratedArtistNames = try await database.artists(serverKey: "server-a").map(\.name)
        XCTAssertEqual(migratedAlbumNames, ["Old Album"])
        XCTAssertEqual(migratedArtistNames, ["Old Artist"])

        try await database.beginGeneration(entity: .albums, serverKey: "server-a")
        try await database.upsertAlbums([album(id: "shared", name: "New Album")], serverKey: "server-a", stableId: "stable-a", generation: "g2")
        try await database.beginGeneration(entity: .artists, serverKey: "server-a")
        try await database.upsertArtists([artist(id: "shared", name: "New Artist")], serverKey: "server-a", stableId: "stable-a", generation: "g2")

        let visibleAlbumNamesDuringRefresh = try await database.albums(serverKey: "server-a").map(\.name)
        let visibleArtistNamesDuringRefresh = try await database.artists(serverKey: "server-a").map(\.name)
        XCTAssertEqual(visibleAlbumNamesDuringRefresh, ["Old Album"])
        XCTAssertEqual(visibleArtistNamesDuringRefresh, ["Old Artist"])

        try await database.recordFailure(entity: .albums, serverKey: "server-a", error: TestLibraryError.refreshFailed)
        try await database.recordFailure(entity: .artists, serverKey: "server-a", error: TestLibraryError.refreshFailed)
        let visibleAlbumNamesAfterFailure = try await database.albums(serverKey: "server-a").map(\.name)
        let visibleArtistNamesAfterFailure = try await database.artists(serverKey: "server-a").map(\.name)
        let albumStateAfterFailure = try await database.syncState(serverKey: "server-a", entity: .albums)
        let artistStateAfterFailure = try await database.syncState(serverKey: "server-a", entity: .artists)
        XCTAssertEqual(visibleAlbumNamesAfterFailure, ["Old Album"])
        XCTAssertEqual(visibleArtistNamesAfterFailure, ["Old Artist"])
        XCTAssertEqual(albumStateAfterFailure?.syncGeneration, "g1")
        XCTAssertEqual(artistStateAfterFailure?.syncGeneration, "g1")
    }

    func testClearOnlyDeletesSelectedServer() async throws {
        let database = try await makeDatabase()

        try await writeAlbums([album(id: "a1", name: "A")], to: database, serverKey: "server-a", generation: "g1")
        try await writeAlbums([album(id: "b1", name: "B")], to: database, serverKey: "server-b", generation: "g1")

        try await database.clear(serverKey: "server-a")

        let serverAAlbums = try await database.albums(serverKey: "server-a")
        let serverBAlbums = try await database.albums(serverKey: "server-b").map(\.id)
        XCTAssertTrue(serverAAlbums.isEmpty)
        XCTAssertEqual(serverBAlbums, ["b1"])
    }

    func testArtistsSearchAndCounts() async throws {
        let database = try await makeDatabase()
        let artists = [
            Artist(id: "artist-1", name: "The Comets", albumCount: 2, coverArt: "cover-a"),
            Artist(id: "artist-2", name: "Moon Unit", albumCount: 1, coverArt: nil),
        ]
        let albums = [
            album(id: "a1", name: "Comet One", artist: "The Comets", artistId: "artist-1"),
            album(id: "a2", name: "Comet Two", artist: "The Comets", artistId: "artist-1"),
            album(id: "a3", name: "Moonrise", artist: "Moon Unit", artistId: "artist-2"),
        ]

        try await writeArtists(artists, to: database, serverKey: "server-a", generation: "g1")
        try await writeAlbums(albums, to: database, serverKey: "server-a", generation: "g1")

        let artistCount = try await database.artistCount(serverKey: "server-a")
        let artistSearch = try await database.searchArtists(serverKey: "server-a", query: "moon").map(\.id)
        let albumSearch = try await database.searchAlbums(serverKey: "server-a", query: "comet").map(\.id)
        let counts = try await database.albumCountByArtist(serverKey: "server-a")
        XCTAssertEqual(artistCount, 2)
        XCTAssertEqual(artistSearch, ["artist-2"])
        XCTAssertEqual(albumSearch, ["a1", "a2"])
        XCTAssertEqual(counts, ["artist-1": 2, "artist-2": 1])
    }

    private func makeDatabase() async throws -> LibraryDatabase {
        let database = LibraryDatabase(databaseURL: tempDir.appendingPathComponent("library.db"))
        try await database.setup()
        return database
    }

    private func createLegacyV1Database(at url: URL) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_create_library_cache") { db in
            try Self.createLegacyLibraryAlbumsTable(db)
            try Self.createLegacyLibraryArtistsTable(db)
            try Self.createLegacyLibrarySyncStateTable(db)
            try Self.insertLegacyVisibleAlbum(db)
            try Self.insertLegacyVisibleArtist(db)
        }
        try migrator.migrate(DatabaseQueue(path: url.path))
    }

    nonisolated private static func createLegacyLibraryAlbumsTable(_ db: Database) throws {
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
            t.primaryKey(["serverKey", "id"])
        }
        try db.create(index: "idx_library_albums_sortName", on: "library_albums", columns: ["serverKey", "sortName"])
        try db.create(index: "idx_library_albums_artistId", on: "library_albums", columns: ["serverKey", "artistId"])
        try db.create(index: "idx_library_albums_year", on: "library_albums", columns: ["serverKey", "year"])
        try db.create(index: "idx_library_albums_playCount", on: "library_albums", columns: ["serverKey", "playCount"])
        try db.create(index: "idx_library_albums_created", on: "library_albums", columns: ["serverKey", "created"])
        try db.create(index: "idx_library_albums_artist_sortName", on: "library_albums", columns: ["serverKey", "artist", "sortName"])
    }

    nonisolated private static func createLegacyLibraryArtistsTable(_ db: Database) throws {
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
            t.primaryKey(["serverKey", "id"])
        }
        try db.create(index: "idx_library_artists_sortName", on: "library_artists", columns: ["serverKey", "sortName"])
        try db.create(index: "idx_library_artists_albumCount", on: "library_artists", columns: ["serverKey", "albumCount"])
    }

    nonisolated private static func createLegacyLibrarySyncStateTable(_ db: Database) throws {
        try db.create(table: "library_sync_state") { t in
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

    nonisolated private static func insertLegacyVisibleAlbum(_ db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO library_albums (
                serverKey, stableId, id, name, sortName, artist, artistId, coverArt,
                songCount, duration, year, genre, playCount, starred, created, syncGeneration, updatedAt
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                "server-a", "stable-a", "shared", "Old Album", "old album", "Old Artist", "shared",
                "cover-a", 1, 60, 2020, "Rock", 7, 1_700_000_000.0, 1_700_000_001.0, "g1", 1_700_000_002.0,
            ]
        )
        try db.execute(
            sql: """
            INSERT INTO library_sync_state
                (serverKey, entity, status, startedAt, completedAt, syncGeneration, rowCount, lastError)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: ["server-a", "albums", "completed", 1.0, 2.0, "g1", 1, nil]
        )
    }

    nonisolated private static func insertLegacyVisibleArtist(_ db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO library_artists (
                serverKey, stableId, id, name, sortName, albumCount, coverArt, starred, syncGeneration, updatedAt
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                "server-a", "stable-a", "shared", "Old Artist", "old artist", 1, "cover-a",
                1_700_000_000.0, "g1", 1_700_000_002.0,
            ]
        )
        try db.execute(
            sql: """
            INSERT INTO library_sync_state
                (serverKey, entity, status, startedAt, completedAt, syncGeneration, rowCount, lastError)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: ["server-a", "artists", "completed", 1.0, 2.0, "g1", 1, nil]
        )
    }

    private func writeAlbums(
        _ albums: [Album],
        to database: LibraryDatabase,
        serverKey: String,
        generation: String
    ) async throws {
        try await database.beginGeneration(entity: .albums, serverKey: serverKey)
        try await database.upsertAlbums(albums, serverKey: serverKey, stableId: "stable-\(serverKey)", generation: generation)
        try await database.finishGeneration(entity: .albums, serverKey: serverKey, generation: generation)
    }

    private func writeArtists(
        _ artists: [Artist],
        to database: LibraryDatabase,
        serverKey: String,
        generation: String
    ) async throws {
        try await database.beginGeneration(entity: .artists, serverKey: serverKey)
        try await database.upsertArtists(artists, serverKey: serverKey, stableId: "stable-\(serverKey)", generation: generation)
        try await database.finishGeneration(entity: .artists, serverKey: serverKey, generation: generation)
    }

    private func album(
        id: String,
        name: String,
        artist: String? = nil,
        artistId: String? = nil,
        year: Int? = nil,
        playCount: Int? = nil,
        created: TimeInterval? = nil
    ) -> Album {
        Album(
            id: id,
            name: name,
            artist: artist,
            artistId: artistId,
            year: year,
            playCount: playCount,
            created: created.map(Date.init(timeIntervalSince1970:))
        )
    }

    private func artist(id: String, name: String) -> Artist {
        Artist(id: id, name: name)
    }
}

private enum TestLibraryError: Error {
    case refreshFailed
}
