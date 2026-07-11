import Foundation

protocol LibraryAPIClient: AnyObject {
    func getAlbumList(type: String, size: Int, offset: Int) async throws -> [Album]
    func getAllArtists() async throws -> [Artist]
}

/// Builds one deterministic library order across every Shelv platform.
///
/// OpenSubsonic's `sortName` is authoritative when the server supplies a
/// non-empty value. Otherwise a leading article is ignored for sorting and
/// section grouping while the original display name remains untouched.
nonisolated enum LibrarySortKey {
    private static let articlePrefixes: [String] = [
        // English
        "the ", "an ", "a ",
        // German
        "eine ", "ein ", "der ", "die ", "das ",
        // French
        "les ", "le ", "la ", "l\u{2019}", "l'", "une ", "un ",
        // Spanish
        "los ", "las ", "el ", "la ", "una ", "un ",
        // Italian
        "gli ", "uno ", "una ", "il ", "lo ", "la ", "le ", "i ", "un\u{2019}", "un'", "un ",
        // Portuguese
        "uma ", "um ", "os ", "as ", "o ", "a ",
    ]

    /// The normalized value used for comparison and persistence.
    static func normalized(displayName: String, explicitSortName: String? = nil) -> String {
        if let explicit = trimmedNonEmpty(explicitSortName) {
            return normalize(explicit)
        }
        return normalize(removingLeadingArticle(from: displayName))
    }

    /// The section title for the same key that controls alphabetical order.
    static func sectionLetter(displayName: String, explicitSortName: String? = nil) -> String {
        let key = normalized(displayName: displayName, explicitSortName: explicitSortName)
        guard let first = key.first, first.isLetter else { return "#" }
        return String(first).uppercased()
    }

    /// A display-preserving article fallback for ordering strings that do not
    /// have an OpenSubsonic sort-name field, such as a song's artist label.
    static func removingLeadingArticle(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        for prefix in articlePrefixes where lowered.hasPrefix(prefix) {
            let remainder = trimmed.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty {
                return remainder
            }
        }
        return trimmed
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
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

    static func locallySortedAlbums(_ albums: [Album], sortBy: String) -> [Album] {
        let sort = albumCacheSort(for: sortBy)
        return locallySortedAlbums(albums, sort: sort.0, direction: sort.1)
    }

    static func locallySortedAlbums(
        _ albums: [Album],
        sort: LibraryAlbumSort,
        direction: LibraryDatabaseSortDirection
    ) -> [Album] {
        albums.sorted { lhs, rhs in
            switch sort {
            case .name:
                let lhsKey = LibrarySortKey.normalized(
                    displayName: lhs.name,
                    explicitSortName: lhs.sortName
                )
                let rhsKey = LibrarySortKey.normalized(
                    displayName: rhs.name,
                    explicitSortName: rhs.sortName
                )
                if lhsKey != rhsKey {
                    return ordered(lhsKey, rhsKey, direction: direction)
                }
                return lhs.id < rhs.id
            case .artist:
                let lhsArtist = lhs.artist ?? ""
                let rhsArtist = rhs.artist ?? ""
                let lhsArtistKey = LibrarySortKey.normalized(displayName: lhsArtist)
                let rhsArtistKey = LibrarySortKey.normalized(displayName: rhsArtist)
                if lhsArtistKey != rhsArtistKey {
                    return ordered(lhsArtistKey, rhsArtistKey, direction: direction)
                }
                return compareAlbums(lhs, rhs)
            case .year:
                let lhsYear = lhs.year ?? 0
                let rhsYear = rhs.year ?? 0
                if lhsYear != rhsYear {
                    return ordered(lhsYear, rhsYear, direction: direction)
                }
                return compareAlbums(lhs, rhs)
            case .playCount:
                let lhsCount = lhs.playCount ?? 0
                let rhsCount = rhs.playCount ?? 0
                if lhsCount != rhsCount {
                    return ordered(lhsCount, rhsCount, direction: direction)
                }
                return compareAlbums(lhs, rhs)
            case .created:
                let lhsCreated = lhs.created?.timeIntervalSince1970 ?? 0
                let rhsCreated = rhs.created?.timeIntervalSince1970 ?? 0
                if lhsCreated != rhsCreated {
                    return ordered(lhsCreated, rhsCreated, direction: direction)
                }
                return compareAlbums(lhs, rhs)
            }
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

    private static func compareAlbums(_ lhs: Album, _ rhs: Album) -> Bool {
        let lhsKey = LibrarySortKey.normalized(
            displayName: lhs.name,
            explicitSortName: lhs.sortName
        )
        let rhsKey = LibrarySortKey.normalized(
            displayName: rhs.name,
            explicitSortName: rhs.sortName
        )
        if lhsKey != rhsKey { return lhsKey < rhsKey }
        return lhs.id < rhs.id
    }

    private static func ordered<T: Comparable>(
        _ lhs: T,
        _ rhs: T,
        direction: LibraryDatabaseSortDirection
    ) -> Bool {
        switch direction {
        case .ascending:
            return lhs < rhs
        case .descending:
            return lhs > rhs
        }
    }

}
