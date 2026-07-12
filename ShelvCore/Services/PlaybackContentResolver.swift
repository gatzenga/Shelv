import Foundation

nonisolated enum ArtistAlbumSortKind: Equatable, Sendable {
    case alphabetical
    case frequent
    case newest
    case year
}

nonisolated enum ArtistAlbumSortDirection: String, Equatable, Sendable {
    case ascending
    case descending
}

/// The persisted artist-detail sorting preference shared by the visible view
/// and background playback intents. Raw-value aliases cover the iOS/tvOS and
/// macOS UI enums without making the intent service depend on either UI target.
nonisolated struct ArtistAlbumSortPreference: Equatable, Sendable {
    let kind: ArtistAlbumSortKind
    let direction: ArtistAlbumSortDirection

    init(sortRaw: String?, directionRaw: String?) {
        switch sortRaw {
        case "alphabeticalByName", "name":
            kind = .alphabetical
        case "frequent", "mostPlayed":
            kind = .frequent
        case "newest", "recentlyAdded":
            kind = .newest
        case "year":
            kind = .year
        default:
            // This is also the default used by every artist detail screen.
            kind = .newest
        }
        direction = ArtistAlbumSortDirection(rawValue: directionRaw ?? "") ?? .descending
    }
}

nonisolated enum ArtistAlbumPlaybackOrder {
    static let sortDefaultsKey = "artistDetailAlbumSort"
    static let directionDefaultsKey = "artistDetailAlbumDirection"

    @MainActor
    static func storedPreference(defaults: UserDefaults = .standard) -> ArtistAlbumSortPreference {
        ArtistAlbumSortPreference(
            sortRaw: defaults.string(forKey: sortDefaultsKey),
            directionRaw: defaults.string(forKey: directionDefaultsKey)
        )
    }

    /// Applies exactly the ordering used by the artist detail view on the
    /// current platform. The intent can rebuild it from persisted preferences
    /// even when no SwiftUI view exists in memory.
    static func sorted(
        _ albums: [Album],
        preference: ArtistAlbumSortPreference
    ) -> [Album] {
        switch preference.kind {
        case .alphabetical:
            let base = albums.sorted {
                let lhsKey = LibrarySortKey.normalized(
                    displayName: $0.name,
                    explicitSortName: $0.sortName
                )
                let rhsKey = LibrarySortKey.normalized(
                    displayName: $1.name,
                    explicitSortName: $1.sortName
                )
                if lhsKey != rhsKey { return lhsKey < rhsKey }
                return $0.id < $1.id
            }
            #if os(tvOS)
            return preference.direction == .ascending ? base : Array(base.reversed())
            #else
            return base
            #endif

        case .frequent:
            return ordered(albums, direction: preference.direction) {
                ($0.playCount ?? 0) < ($1.playCount ?? 0)
            }

        case .newest:
            return ordered(albums, direction: preference.direction) {
                ($0.created ?? .distantPast) < ($1.created ?? .distantPast)
            }

        case .year:
            return ordered(albums, direction: preference.direction) {
                ($0.year ?? 0) < ($1.year ?? 0)
            }
        }
    }

    private static func ordered(
        _ albums: [Album],
        direction: ArtistAlbumSortDirection,
        ascendingComparator: (Album, Album) -> Bool
    ) -> [Album] {
        let base = albums.sorted(by: ascendingComparator)
        return direction == .ascending ? base : Array(base.reversed())
    }

}

/// Resolves the same playable collections used by the app's detail views.
///
/// The resolver deliberately has no "top songs" dependency: playing an artist
/// means loading that artist's albums and then their tracks, just like tapping
/// Play or Shuffle in an artist view.
nonisolated struct PlaybackContentProvider: Sendable {
    let song: @Sendable (String) async throws -> Song
    let albumSongs: @Sendable (String) async throws -> [Song]
    let artistAlbums: @Sendable (String) async throws -> [Album]
    let playlistSongs: @Sendable (String) async throws -> [Song]
}

nonisolated enum PlaybackContentResolver {
    enum ResolutionError: Error, Equatable, Sendable {
        case unsupportedKind(ShortcutPlayableKind)
    }

    static func songs(
        for kind: ShortcutPlayableKind,
        contentID: String,
        provider: PlaybackContentProvider
    ) async throws -> [Song] {
        switch kind {
        case .song:
            return [try await provider.song(contentID)]
        case .album:
            return try await provider.albumSongs(contentID)
        case .artist:
            let albums = try await provider.artistAlbums(contentID)
            return await artistSongs(from: albums) { albumID in
                (try? await provider.albumSongs(albumID)) ?? []
            }
        case .playlist:
            return try await provider.playlistSongs(contentID)
        case .radio:
            throw ResolutionError.unsupportedKind(.radio)
        }
    }

    /// Loads albums concurrently but preserves the order supplied by the view
    /// or server. An unavailable album is skipped, matching the existing app UI.
    static func artistSongs(
        from albums: [Album],
        loadAlbumSongs: @escaping @Sendable (String) async -> [Song]
    ) async -> [Song] {
        let indexedAlbums = Array(albums.enumerated())
        return await withTaskGroup(of: (Int, [Song]).self) { group in
            for (index, album) in indexedAlbums {
                group.addTask {
                    (index, await loadAlbumSongs(album.id))
                }
            }

            var songsByAlbum: [(Int, [Song])] = []
            songsByAlbum.reserveCapacity(indexedAlbums.count)
            for await result in group {
                songsByAlbum.append(result)
            }
            return songsByAlbum
                .sorted { $0.0 < $1.0 }
                .flatMap(\.1)
        }
    }
}

nonisolated struct DownloadedPlaybackSelection: Sendable {
    let songs: [Song]
    let order: ShortcutPlaybackOrder
}

/// Builds the three download queues shown by the app's offline mix buttons.
nonisolated enum DownloadedPlaybackQueueBuilder {
    static func selection(
        from records: [DownloadRecord],
        mode: ShortcutDownloadsMode
    ) -> DownloadedPlaybackSelection {
        selection(
            from: records.map { $0.toDownloadedSong() },
            mode: mode
        )
    }

    static func selection(
        from downloads: [DownloadedSong],
        mode: ShortcutDownloadsMode,
        shuffle: ([DownloadedSong]) -> [DownloadedSong] = { $0.shuffled() }
    ) -> DownloadedPlaybackSelection {
        switch mode {
        case .all:
            let songs = downloads
                .map { $0.asSong() }
                .sorted(by: librarySort)
            return DownloadedPlaybackSelection(
                songs: Array(songs.prefix(500)),
                order: .inOrder
            )
        case .shuffled:
            let songs = shuffle(downloads)
                .prefix(500)
                .map { $0.asSong() }
            return DownloadedPlaybackSelection(songs: songs, order: .shuffled)
        case .newest:
            let songs = downloads
                .sorted { $0.addedAt > $1.addedAt }
                .prefix(100)
                .map { $0.asSong() }
            return DownloadedPlaybackSelection(songs: songs, order: .shuffled)
        }
    }

    private static func librarySort(_ lhs: Song, _ rhs: Song) -> Bool {
        let artistOrder = LibrarySortKey.removingLeadingArticle(from: lhs.artist ?? "")
            .localizedStandardCompare(LibrarySortKey.removingLeadingArticle(from: rhs.artist ?? ""))
        if artistOrder != .orderedSame { return artistOrder == .orderedAscending }

        let albumOrder = (lhs.album ?? "").localizedStandardCompare(rhs.album ?? "")
        if albumOrder != .orderedSame { return albumOrder == .orderedAscending }

        let leftDisc = lhs.discNumber ?? 0
        let rightDisc = rhs.discNumber ?? 0
        if leftDisc != rightDisc { return leftDisc < rightDisc }
        return (lhs.track ?? 0) < (rhs.track ?? 0)
    }

}
