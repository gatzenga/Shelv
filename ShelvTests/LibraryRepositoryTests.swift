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

    func testRefreshAlbumsSortsYearLocallyWithoutRequestingUnsupportedAPISort() async throws {
        let database = try await makeDatabase()
        let api = FakeLibraryAPIClient(albumPages: [[
            album(id: "old", name: "Old", year: 1999),
            album(id: "new", name: "New", year: 2025),
            album(id: "middle", name: "Middle", year: 2010),
        ]])
        let repository = LibraryRepository(database: database, api: api)

        let result = try await repository.refreshAlbums(
            serverKey: "server-a",
            stableId: "stable-a",
            sortBy: "year"
        )

        XCTAssertEqual(api.albumRequests.map(\.type), ["alphabeticalByName"])
        XCTAssertEqual(result.map(\.id), ["new", "middle", "old"])
        let cachedAlbumIds = try await database
            .albums(serverKey: "server-a", sort: .year, direction: .descending)
            .map(\.id)
        XCTAssertEqual(cachedAlbumIds, ["new", "middle", "old"])
    }

    func testRefreshAlbumsRecentlyAddedRequestsNewestAndSortsCreatedDescending() async throws {
        let database = try await makeDatabase()
        let api = FakeLibraryAPIClient(albumPages: [[
            album(id: "older", name: "Older", created: 100),
            album(id: "newer", name: "Newer", created: 300),
            album(id: "middle", name: "Middle", created: 200),
        ]])
        let repository = LibraryRepository(database: database, api: api)

        let result = try await repository.refreshAlbums(
            serverKey: "server-a",
            stableId: "stable-a",
            sortBy: "recentlyAdded"
        )

        XCTAssertEqual(api.albumRequests.map(\.type), ["newest"])
        XCTAssertEqual(result.map(\.id), ["newer", "middle", "older"])
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
        try await seedAlbums([album(id: "shared", name: "Old")], database: database, generation: "old-generation")
        let api = FakeLibraryAPIClient(
            albumPages: [[album(id: "shared", name: "New")]],
            failureAfterAlbumRequestCount: 1
        )
        let repository = LibraryRepository(database: database, api: api, pageSize: 1)

        do {
            _ = try await repository.refreshAlbums(serverKey: "server-a", stableId: "stable-a")
            XCTFail("Expected refresh to throw")
        } catch {
            let cachedAlbumNames = try await database.albums(serverKey: "server-a").map(\.name)
            let state = try await database.syncState(serverKey: "server-a", entity: .albums)
            XCTAssertEqual(cachedAlbumNames, ["Old"])
            XCTAssertEqual(state?.status, "failed")
            XCTAssertEqual(state?.syncGeneration, "old-generation")
        }
    }

    func testRefreshArtistsFailureKeepsPreviousGenerationVisible() async throws {
        let database = try await makeDatabase()
        try await seedArtists([Artist(id: "shared", name: "Old Artist")], database: database, generation: "old-generation")
        let api = FakeLibraryAPIClient(
            artists: [Artist(id: "shared", name: "New Artist")],
            failArtists: true
        )
        let repository = LibraryRepository(database: database, api: api)

        do {
            _ = try await repository.refreshArtists(serverKey: "server-a", stableId: "stable-a")
            XCTFail("Expected refresh to throw")
        } catch {
            let cachedArtistNames = try await database.artists(serverKey: "server-a").map(\.name)
            let state = try await database.syncState(serverKey: "server-a", entity: .artists)
            XCTAssertEqual(cachedArtistNames, ["Old Artist"])
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

    func testStableIdentityBackfillCancelsOldRefreshAndRetryPublishesNewIdentity() async throws {
        let database = try await makeDatabase()
        let api = MutableContextLibraryAPIClient(
            stableId: nil,
            albums: [album(id: "stale", name: "Stale")]
        )
        api.onNextAlbumRequest = {
            api.updateIdentity(serverKey: "server-a", stableId: "stable-a")
        }
        let repository = LibraryRepository(database: database, api: api)

        do {
            _ = try await repository.refreshAlbums(serverKey: "server-a", stableId: nil)
            XCTFail("Expected the pre-backfill refresh to be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let albumsAfterCancellation = try await database.albums(serverKey: "server-a")
        let stateAfterCancellation = try await database.syncState(serverKey: "server-a", entity: .albums)
        XCTAssertTrue(albumsAfterCancellation.isEmpty)
        XCTAssertEqual(stateAfterCancellation?.status, "failed")
        XCTAssertNil(stateAfterCancellation?.syncGeneration)
        XCTAssertNil(stateAfterCancellation?.pendingGeneration)

        api.albums = [album(id: "fresh", name: "Fresh")]
        let refreshed = try await repository.refreshAlbums(
            serverKey: "server-a",
            stableId: "stable-a"
        )

        XCTAssertEqual(refreshed.map(\.id), ["fresh"])
    }

    func testCredentialEpochRejectsABAResponseBeforePersistence() async throws {
        let database = try await makeDatabase()
        let api = MutableContextLibraryAPIClient(
            stableId: "stable-a",
            albums: [album(id: "foreign", name: "Foreign")]
        )
        api.onNextAlbumRequest = {
            api.performABASwitch()
        }
        let repository = LibraryRepository(database: database, api: api)

        do {
            _ = try await repository.refreshAlbums(serverKey: "server-a", stableId: "stable-a")
            XCTFail("Expected the A-to-B-to-A response to be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let albumsAfterCancellation = try await database.albums(serverKey: "server-a")
        let state = try await database.syncState(serverKey: "server-a", entity: .albums)
        XCTAssertTrue(albumsAfterCancellation.isEmpty)
        XCTAssertEqual(state?.status, "failed")
        XCTAssertNil(state?.syncGeneration)
        XCTAssertNil(state?.pendingGeneration)
    }

    func testLibrarySortKeyIgnoresArticlesInSupportedLanguages() {
        let examples: [(name: String, expected: String)] = [
            ("The Police", "police"),
            ("Eine kleine Geschichte", "kleine geschichte"),
            ("L’Amour Toujours", "amour toujours"),
            ("Los Lobos", "lobos"),
            ("Gli Anni", "anni"),
            ("Os Mutantes", "mutantes"),
        ]

        for example in examples {
            XCTAssertEqual(
                LibrarySortKey.normalized(displayName: example.name),
                example.expected,
                example.name
            )
        }
    }

    func testExplicitSortNameAlwaysWinsOverArticleFallback() {
        XCTAssertEqual(
            LibrarySortKey.normalized(
                displayName: "The Police",
                explicitSortName: "The Police"
            ),
            "the police"
        )
        XCTAssertEqual(
            LibrarySortKey.sectionLetter(
                displayName: "The Police",
                explicitSortName: "The Police"
            ),
            "T"
        )
        XCTAssertEqual(
            LibrarySortKey.sectionLetter(displayName: "The Police"),
            "P"
        )
    }

    func testBlankSortNameFallsBackAndArticlesMustBeWholeWords() {
        XCTAssertEqual(
            LibrarySortKey.normalized(displayName: "The Cranberries", explicitSortName: "  "),
            "cranberries"
        )
        XCTAssertEqual(
            LibrarySortKey.normalized(displayName: "Theatre of Tragedy"),
            "theatre of tragedy"
        )
        XCTAssertEqual(LibrarySortKey.normalized(displayName: "The"), "the")
    }

    func testLocalAlbumSortingUsesTagBeforeArticleFallback() {
        let albums = [
            Album(id: "tagged", name: "The Police", sortName: "The Police"),
            Album(id: "queen", name: "Queen"),
            Album(id: "untagged", name: "The Police"),
        ]

        let sorted = LibraryRepository.locallySortedAlbums(
            albums,
            sort: .name,
            direction: .ascending
        )

        XCTAssertEqual(sorted.map(\.id), ["untagged", "queen", "tagged"])
    }

    func testLocalArtistSortingUsesTagBeforeArticleFallback() {
        let artists = [
            Artist(id: "tagged", name: "The Police", sortName: "The Police"),
            Artist(id: "queen", name: "Queen"),
            Artist(id: "untagged", name: "The Police"),
        ]

        let sorted = LibraryRepository.locallySortedArtists(artists)

        XCTAssertEqual(sorted.map(\.id), ["untagged", "queen", "tagged"])
    }

    func testAlbumAndArtistDecodeOpenSubsonicSortName() throws {
        let album = try JSONDecoder().decode(
            Album.self,
            from: Data(#"{"id":"album-1","name":"The Wall","sortName":"Wall, The"}"#.utf8)
        )
        let artist = try JSONDecoder().decode(
            Artist.self,
            from: Data(#"{"id":"artist-1","name":"The Police","sortName":"Police, The"}"#.utf8)
        )

        XCTAssertEqual(album.sortName, "Wall, The")
        XCTAssertEqual(artist.sortName, "Police, The")
    }

    private func makeDatabase() async throws -> LibraryDatabase {
        let database = LibraryDatabase(databaseURL: tempDir.appendingPathComponent("library.db"))
        try await database.setup()
        return database
    }

    private func seedAlbums(_ albums: [Album], database: LibraryDatabase, generation: String) async throws {
        try await database.beginGeneration(entity: .albums, serverKey: "server-a", generation: generation)
        try await database.upsertAlbums(albums, serverKey: "server-a", stableId: "stable-a", generation: generation)
        try await database.finishGeneration(entity: .albums, serverKey: "server-a", generation: generation)
    }

    private func seedArtists(_ artists: [Artist], database: LibraryDatabase, generation: String) async throws {
        try await database.beginGeneration(entity: .artists, serverKey: "server-a", generation: generation)
        try await database.upsertArtists(artists, serverKey: "server-a", stableId: "stable-a", generation: generation)
        try await database.finishGeneration(entity: .artists, serverKey: "server-a", generation: generation)
    }
}

private final class FakeLibraryAPIClient: LibraryAPIClient {
    private let albumPages: [[Album]]
    private let artists: [Artist]
    private let failureAfterAlbumRequestCount: Int?
    private let failArtists: Bool
    private(set) var albumRequests: [(type: String, size: Int, offset: Int)] = []

    init(
        albumPages: [[Album]] = [],
        artists: [Artist] = [],
        failureAfterAlbumRequestCount: Int? = nil,
        failArtists: Bool = false
    ) {
        self.albumPages = albumPages
        self.artists = artists
        self.failureAfterAlbumRequestCount = failureAfterAlbumRequestCount
        self.failArtists = failArtists
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
        if failArtists {
            throw FakeLibraryAPIError.requestFailed
        }
        return artists
    }
}

private enum FakeLibraryAPIError: Error {
    case requestFailed
}

private final class MutableContextLibraryAPIClient: LibraryAPIClient {
    private(set) var serverKey = "server-a"
    private(set) var stableId: String?
    private(set) var credentialGeneration: UInt64 = 1
    var albums: [Album]
    var onNextAlbumRequest: (() -> Void)?

    init(stableId: String?, albums: [Album]) {
        self.stableId = stableId
        self.albums = albums
    }

    func captureLibraryRequestContext(
        serverKey: String,
        stableId: String?
    ) -> LibraryAPIRequestContext? {
        guard self.serverKey == serverKey, self.stableId == stableId else { return nil }
        return LibraryAPIRequestContext(
            serverKey: serverKey,
            stableId: stableId,
            credentialGeneration: credentialGeneration
        )
    }

    func isLibraryRequestContextCurrent(_ context: LibraryAPIRequestContext) -> Bool {
        serverKey == context.serverKey
            && stableId == context.stableId
            && credentialGeneration == context.credentialGeneration
    }

    func getAlbumList(type: String, size: Int, offset: Int) async throws -> [Album] {
        if let onNextAlbumRequest {
            self.onNextAlbumRequest = nil
            onNextAlbumRequest()
        }
        return offset == 0 ? albums : []
    }

    func getAllArtists() async throws -> [Artist] {
        []
    }

    func updateIdentity(serverKey: String, stableId: String?) {
        self.serverKey = serverKey
        self.stableId = stableId
        credentialGeneration &+= 1
    }

    func performABASwitch() {
        serverKey = "server-b"
        credentialGeneration &+= 1
        serverKey = "server-a"
        credentialGeneration &+= 1
    }
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

private func album(
    id: String,
    name: String,
    sortName: String? = nil,
    year: Int? = nil,
    created: TimeInterval? = nil
) -> Album {
    Album(
        id: id,
        name: name,
        sortName: sortName,
        year: year,
        created: created.map(Date.init(timeIntervalSince1970:))
    )
}
