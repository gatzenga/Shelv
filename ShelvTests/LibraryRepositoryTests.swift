import XCTest

final class LibraryRepositoryTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelvLibraryRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testRefreshAlbumsImportsAllPages() async throws {
        let database = try await makeDatabase()
        let api = FakeLibraryAPIClient(albumPages: [
            [album(id: "a1", name: "Alpha"), album(id: "a2", name: "Beta")],
            [album(id: "a3", name: "Gamma")],
        ])
        let repository = LibraryRepository(database: database, api: api, pageSize: 2)

        let result = try await repository.refreshAlbums(serverKey: "server-a", stableId: "stable-a")

        XCTAssertEqual(result.map(\.id), ["a1", "a2", "a3"])
        XCTAssertEqual(api.albumRequests.map(\.offset), [0, 2])
        let albumCount = try await database.albumCount(serverKey: "server-a")
        let cachedAlbumIds = try await database.albums(serverKey: "server-a").map(\.id)
        XCTAssertEqual(albumCount, 3)
        XCTAssertEqual(cachedAlbumIds, ["a1", "a2", "a3"])
    }

    func testRefreshAlbumsHandlesHundredThousandGeneratedAlbums() async throws {
        let database = try await makeDatabase()
        let api = GeneratedLibraryAPIClient(totalAlbums: 100_000)
        let repository = LibraryRepository(database: database, api: api, pageSize: 1_000)

        let result = try await repository.refreshAlbums(serverKey: "server-a", stableId: "stable-a")

        XCTAssertEqual(result.count, 100_000)
        XCTAssertEqual(api.albumRequests.count, 101)
        XCTAssertEqual(api.albumRequests.first?.offset, 0)
        XCTAssertEqual(api.albumRequests.last?.offset, 100_000)
        let albumCount = try await database.albumCount(serverKey: "server-a")
        let firstAlbumIds = try await database
            .albums(serverKey: "server-a", limit: 3)
            .map(\.id)
        XCTAssertEqual(albumCount, 100_000)
        XCTAssertEqual(firstAlbumIds, ["album-000000", "album-000001", "album-000002"])
    }

    func testRefreshAlbumsFailureKeepsPreviousGenerationVisible() async throws {
        let database = try await makeDatabase()
        try await seedAlbums([album(id: "old", name: "Old")], database: database, generation: "old-generation")
        let api = FakeLibraryAPIClient(
            albumPages: [[album(id: "new", name: "New")]],
            failureAfterAlbumRequestCount: 1
        )
        let repository = LibraryRepository(database: database, api: api, pageSize: 1)

        do {
            _ = try await repository.refreshAlbums(serverKey: "server-a", stableId: "stable-a")
            XCTFail("Expected refresh to throw")
        } catch {
            let cachedAlbumIds = try await database.albums(serverKey: "server-a").map(\.id)
            let state = try await database.syncState(serverKey: "server-a", entity: .albums)
            XCTAssertEqual(cachedAlbumIds, ["old"])
            XCTAssertEqual(state?.status, "failed")
            XCTAssertEqual(state?.syncGeneration, "old-generation")
        }
    }

    func testRetryAfterFailedAlbumRefreshReplacesGeneration() async throws {
        let database = try await makeDatabase()
        try await seedAlbums([album(id: "old", name: "Old")], database: database, generation: "old-generation")
        let failingAPI = FakeLibraryAPIClient(
            albumPages: [[album(id: "partial", name: "Partial")]],
            failureAfterAlbumRequestCount: 1
        )
        let failingRepository = LibraryRepository(database: database, api: failingAPI, pageSize: 1)
        _ = try? await failingRepository.refreshAlbums(serverKey: "server-a", stableId: "stable-a")

        let succeedingAPI = FakeLibraryAPIClient(albumPages: [
            [album(id: "new-1", name: "New 1")],
            [album(id: "new-2", name: "New 2")],
            [],
        ])
        let succeedingRepository = LibraryRepository(database: database, api: succeedingAPI, pageSize: 1)

        let result = try await succeedingRepository.refreshAlbums(serverKey: "server-a", stableId: "stable-a")

        XCTAssertEqual(result.map(\.id), ["new-1", "new-2"])
        let cachedAlbumIds = try await database.albums(serverKey: "server-a").map(\.id)
        XCTAssertEqual(cachedAlbumIds, ["new-1", "new-2"])
    }

    func testRefreshArtistsStoresSortedResult() async throws {
        let database = try await makeDatabase()
        let api = FakeLibraryAPIClient(artists: [
            Artist(id: "artist-b", name: "Beta"),
            Artist(id: "artist-a", name: "Alpha"),
        ])
        let repository = LibraryRepository(database: database, api: api)

        let result = try await repository.refreshArtists(serverKey: "server-a", stableId: nil)

        XCTAssertEqual(result.map(\.id), ["artist-a", "artist-b"])
        let cachedArtistIds = try await database.artists(serverKey: "server-a").map(\.id)
        XCTAssertEqual(cachedArtistIds, ["artist-a", "artist-b"])
    }

    private func makeDatabase() async throws -> LibraryDatabase {
        let database = LibraryDatabase(databaseURL: tempDir.appendingPathComponent("library.db"))
        try await database.setup()
        return database
    }

    private func seedAlbums(_ albums: [Album], database: LibraryDatabase, generation: String) async throws {
        try await database.beginGeneration(entity: .albums, serverKey: "server-a")
        try await database.upsertAlbums(albums, serverKey: "server-a", stableId: "stable-a", generation: generation)
        try await database.finishGeneration(entity: .albums, serverKey: "server-a", generation: generation)
    }
}

private final class FakeLibraryAPIClient: LibraryAPIClient {
    private let albumPages: [[Album]]
    private let artists: [Artist]
    private let failureAfterAlbumRequestCount: Int?
    private(set) var albumRequests: [(type: String, size: Int, offset: Int)] = []

    init(
        albumPages: [[Album]] = [],
        artists: [Artist] = [],
        failureAfterAlbumRequestCount: Int? = nil
    ) {
        self.albumPages = albumPages
        self.artists = artists
        self.failureAfterAlbumRequestCount = failureAfterAlbumRequestCount
    }

    func getAlbumList(type: String, size: Int, offset: Int) async throws -> [Album] {
        albumRequests.append((type: type, size: size, offset: offset))
        if let failureAfterAlbumRequestCount, albumRequests.count > failureAfterAlbumRequestCount {
            throw FakeLibraryAPIError.requestFailed
        }
        let pageIndex = offset / size
        guard pageIndex < albumPages.count else { return [] }
        return albumPages[pageIndex]
    }

    func getAllArtists() async throws -> [Artist] {
        artists
    }
}

private enum FakeLibraryAPIError: Error {
    case requestFailed
}

private final class GeneratedLibraryAPIClient: LibraryAPIClient {
    private let totalAlbums: Int
    private(set) var albumRequests: [(type: String, size: Int, offset: Int)] = []

    init(totalAlbums: Int) {
        self.totalAlbums = totalAlbums
    }

    func getAlbumList(type: String, size: Int, offset: Int) async throws -> [Album] {
        albumRequests.append((type: type, size: size, offset: offset))
        guard offset < totalAlbums else { return [] }

        let end = min(offset + size, totalAlbums)
        return (offset..<end).map { index in
            let padded = String(format: "%06d", index)
            return Album(
                id: "album-\(padded)",
                name: "Album \(padded)",
                artist: "Artist \(index / 10)",
                artistId: "artist-\(index / 10)",
                playCount: index % 100
            )
        }
    }

    func getAllArtists() async throws -> [Artist] {
        []
    }
}

private func album(id: String, name: String) -> Album {
    Album(id: id, name: name)
}
