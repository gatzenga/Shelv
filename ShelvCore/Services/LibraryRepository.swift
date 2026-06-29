import Foundation

protocol LibraryAPIClient: AnyObject {
    func getAlbumList(type: String, size: Int, offset: Int) async throws -> [Album]
    func getAllArtists() async throws -> [Artist]
}

#if !SHELV_LOGIC_TESTS
extension SubsonicAPIService: LibraryAPIClient {}
#endif

nonisolated final class LibraryRepository {
    #if !SHELV_LOGIC_TESTS
    static let shared = LibraryRepository(database: .shared, api: SubsonicAPIService.shared)
    #endif

    private let database: LibraryDatabase
    private let api: LibraryAPIClient
    private let pageSize: Int

    init(database: LibraryDatabase, api: LibraryAPIClient, pageSize: Int = 500) {
        self.database = database
        self.api = api
        self.pageSize = pageSize
    }

    func cachedAlbums(
        serverKey: String,
        sort: LibraryAlbumSort = .name,
        direction: LibraryDatabaseSortDirection = .ascending,
        limit: Int? = nil,
        offset: Int = 0
    ) async -> [Album] {
        do {
            try await database.setup()
            return try await database.albums(
                serverKey: serverKey,
                sort: sort,
                direction: direction,
                limit: limit,
                offset: offset
            )
        } catch {
            return []
        }
    }

    func cachedArtists(
        serverKey: String,
        sort: LibraryArtistSort = .name,
        direction: LibraryDatabaseSortDirection = .ascending,
        limit: Int? = nil,
        offset: Int = 0
    ) async -> [Artist] {
        do {
            try await database.setup()
            return try await database.artists(
                serverKey: serverKey,
                sort: sort,
                direction: direction,
                limit: limit,
                offset: offset
            )
        } catch {
            return []
        }
    }

    func storeAlbums(_ albums: [Album], serverKey: String, stableId: String?) async {
        let generation = UUID().uuidString
        do {
            try await database.setup()
            try await database.beginGeneration(entity: .albums, serverKey: serverKey)
            try await database.upsertAlbums(albums, serverKey: serverKey, stableId: stableId, generation: generation)
            try await database.finishGeneration(entity: .albums, serverKey: serverKey, generation: generation)
        } catch {
            try? await database.recordFailure(entity: .albums, serverKey: serverKey, error: error)
        }
    }

    func storeArtists(_ artists: [Artist], serverKey: String, stableId: String?) async {
        let generation = UUID().uuidString
        do {
            try await database.setup()
            try await database.beginGeneration(entity: .artists, serverKey: serverKey)
            try await database.upsertArtists(artists, serverKey: serverKey, stableId: stableId, generation: generation)
            try await database.finishGeneration(entity: .artists, serverKey: serverKey, generation: generation)
        } catch {
            try? await database.recordFailure(entity: .artists, serverKey: serverKey, error: error)
        }
    }

    func refreshAlbums(serverKey: String, stableId: String?, sortBy: String = "alphabeticalByName") async throws -> [Album] {
        let generation = UUID().uuidString
        do {
            try await database.setup()
            try await database.beginGeneration(entity: .albums, serverKey: serverKey)

            var offset = 0
            let apiSortBy = Self.apiSort(for: sortBy)

            while true {
                try Task.checkCancellation()
                let page = try await api.getAlbumList(type: apiSortBy, size: pageSize, offset: offset)
                if !page.isEmpty {
                    try await database.upsertAlbums(page, serverKey: serverKey, stableId: stableId, generation: generation)
                }
                if page.count < pageSize { break }
                offset += pageSize
            }

            try await database.finishGeneration(entity: .albums, serverKey: serverKey, generation: generation)
            let cacheSort = Self.albumCacheSort(for: sortBy)
            return try await database.albums(
                serverKey: serverKey,
                sort: cacheSort.0,
                direction: cacheSort.1
            )
        } catch {
            try? await database.recordFailure(entity: .albums, serverKey: serverKey, error: error)
            throw error
        }
    }

    func refreshArtists(serverKey: String, stableId: String?) async throws -> [Artist] {
        let generation = UUID().uuidString
        do {
            try await database.setup()
            try await database.beginGeneration(entity: .artists, serverKey: serverKey)
            try Task.checkCancellation()
            let artists = try await api.getAllArtists()
            try await database.upsertArtists(artists, serverKey: serverKey, stableId: stableId, generation: generation)
            try await database.finishGeneration(entity: .artists, serverKey: serverKey, generation: generation)
            return try await database.artists(serverKey: serverKey, sort: .name)
        } catch {
            try? await database.recordFailure(entity: .artists, serverKey: serverKey, error: error)
            throw error
        }
    }

    static func albumCacheSort(for sortBy: String) -> (LibraryAlbumSort, LibraryDatabaseSortDirection) {
        switch sortBy {
        case "year":
            return (.year, .descending)
        case "frequent", "mostPlayed":
            return (.playCount, .descending)
        case "newest", "recentlyAdded":
            return (.created, .descending)
        default:
            return (.name, .ascending)
        }
    }

    private static func apiSort(for sortBy: String) -> String {
        switch sortBy {
        case "year", "frequent", "mostPlayed":
            return "alphabeticalByName"
        case "recentlyAdded":
            return "newest"
        default:
            return sortBy
        }
    }
}
