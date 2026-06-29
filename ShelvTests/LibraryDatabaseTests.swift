import XCTest

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

    func testUnfinishedGenerationDoesNotReplaceVisibleLibrary() async throws {
        let database = try await makeDatabase()

        try await writeAlbums([album(id: "old", name: "Old")], to: database, serverKey: "server-a", generation: "g1")
        try await database.beginGeneration(entity: .albums, serverKey: "server-a")
        try await database.upsertAlbums([album(id: "new", name: "New")], serverKey: "server-a", stableId: nil, generation: "g2")

        let visibleDuringRefresh = try await database.albums(serverKey: "server-a").map(\.id)
        XCTAssertEqual(visibleDuringRefresh, ["old"])

        try await database.finishGeneration(entity: .albums, serverKey: "server-a", generation: "g2")
        let visibleAfterFinish = try await database.albums(serverKey: "server-a").map(\.id)
        XCTAssertEqual(visibleAfterFinish, ["new"])
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
}
