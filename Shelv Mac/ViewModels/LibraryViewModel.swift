import SwiftUI
import Combine

@MainActor
class LibraryViewModel: ObservableObject {
    static let shared = LibraryViewModel()

    @Published var albums: [Album] = [] {
        didSet {
            scheduleSortedAlbumsRebuild()
            scheduleSortedArtistsRebuild()
        }
    }
    @Published var artists: [Artist] = [] {
        didSet { scheduleSortedArtistsRebuild() }
    }
    @Published var sortOption: LibrarySortOption = .name {
        didSet { scheduleSortedAlbumsRebuild() }
    }
    @Published var albumSortDirection: SortDirection = .ascending {
        didSet { scheduleSortedAlbumsRebuild() }
    }
    @Published var artistSortOption: ArtistSortOption = .name {
        didSet { scheduleSortedArtistsRebuild() }
    }
    @Published var artistSortDirection: SortDirection = .ascending {
        didSet { scheduleSortedArtistsRebuild() }
    }
    @Published private(set) var sortedAlbums: [Album] = []
    @Published private(set) var sortedArtists: [Artist] = []
    @Published var isLoadingAlbums: Bool = false
    @Published var isLoadingArtists: Bool = false
    @Published var errorMessage: String?

    private var sortedAlbumsTask: Task<Void, Never>?
    private var sortedArtistsTask: Task<Void, Never>?

    private func scheduleSortedAlbumsRebuild() {
        sortedAlbumsTask?.cancel()
        let source = albums
        let option = sortOption
        let direction = albumSortDirection

        sortedAlbumsTask = Task.detached(priority: .userInitiated) {
            let sorted = Self.sortedAlbums(source, option: option, direction: direction)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.sortedAlbums = sorted
            }
        }
    }

    private func scheduleSortedArtistsRebuild() {
        sortedArtistsTask?.cancel()
        let source = artists
        let albumSource = albums
        let option = artistSortOption
        let direction = artistSortDirection

        sortedArtistsTask = Task.detached(priority: .userInitiated) {
            let sorted = Self.sortedArtists(
                source,
                albums: albumSource,
                option: option,
                direction: direction
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.sortedArtists = sorted
            }
        }
    }

    nonisolated private static func sortedAlbums(
        _ albums: [Album],
        option: LibrarySortOption,
        direction: SortDirection
    ) -> [Album] {
        let cacheSort = albumCacheSort(for: option)
        let requestedDirection: LibraryDatabaseSortDirection = option == .name
            ? .ascending
            : (direction == .ascending ? .ascending : .descending)
        return LibraryRepository.locallySortedAlbums(
            albums,
            sort: cacheSort.0,
            direction: requestedDirection
        )
    }

    nonisolated private static func sortedArtists(
        _ artists: [Artist],
        albums: [Album],
        option: ArtistSortOption,
        direction: SortDirection
    ) -> [Artist] {
        let natural: [Artist]
        switch option {
        case .name:
            natural = artists.sorted { lhs, rhs in
                compareStrings(lhs.name, rhs.name, lhs.id, rhs.id)
            }
        case .mostPlayed:
            var counts: [String: Int] = [:]
            counts.reserveCapacity(artists.count)
            for album in albums {
                guard let artistId = album.artistId, !artistId.isEmpty else { continue }
                counts[artistId, default: 0] += album.playCount ?? 0
            }
            natural = artists.sorted { lhs, rhs in
                let lhsCount = counts[lhs.id] ?? 0
                let rhsCount = counts[rhs.id] ?? 0
                if lhsCount != rhsCount {
                    return direction == .descending
                        ? lhsCount > rhsCount
                        : lhsCount < rhsCount
                }
                return compareStrings(lhs.name, rhs.name, lhs.id, rhs.id)
            }
        }
        return natural
    }

    nonisolated private static func compareStrings(_ lhs: String, _ rhs: String, _ lhsId: String, _ rhsId: String) -> Bool {
        let lhsKey = normalizedSortKey(lhs)
        let rhsKey = normalizedSortKey(rhs)
        if lhsKey != rhsKey { return lhsKey < rhsKey }
        return lhsId < rhsId
    }

    nonisolated private static func normalizedSortKey(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    // MARK: - Favorites
    @Published var starredSongs: [Song] = []
    @Published var starredAlbums: [Album] = []
    @Published var starredArtists: [Artist] = []
    @Published var isLoadingStarred: Bool = false

    // MARK: - Playlists
    @Published var playlists: [Playlist] = []
    @Published var isLoadingPlaylists: Bool = false

    private let api = SubsonicAPIService.shared
    private let libraryRepository = LibraryRepository.shared
    private var lastPlaylistsLoadDate: Date?
    private let playlistsRefreshInterval: TimeInterval = 60

    private var activeServerKeys: (serverKey: String, stableId: String?)? {
        guard let server = AppState.shared.serverStore.activeServer else { return nil }
        let stableId = server.stableId.isEmpty ? nil : server.stableId
        return (server.id.uuidString, stableId)
    }

    #if DEBUG
    private func applyLargeLibraryFixtureAlbums(count: Int) async {
        guard !isLoadingAlbums else { return }
        isLoadingAlbums = albums.isEmpty
        errorMessage = nil

        if albums.count == count, albums.first?.id.hasPrefix("fixture-album-") == true {
            scheduleSortedAlbumsRebuild()
        } else {
            albums = await Task.detached(priority: .userInitiated) {
                DemoContent.largeLibraryAlbums(count: count)
            }.value
        }

        isLoadingAlbums = false
    }

    private func applyLargeLibraryFixtureArtists(albumCount: Int) async {
        guard !isLoadingArtists else { return }
        isLoadingArtists = artists.isEmpty
        errorMessage = nil

        if artists.first?.id.hasPrefix("fixture-artist-") == true {
            scheduleSortedArtistsRebuild()
        } else {
            artists = await Task.detached(priority: .userInitiated) {
                DemoContent.largeLibraryArtists(albumCount: albumCount)
            }.value
        }

        isLoadingArtists = false
    }
    #endif

    // MARK: - Reset (bei Serverwechsel)

    func reset() {
        albums = []
        artists = []
        starredSongs = []
        starredAlbums = []
        starredArtists = []
        playlists = []
        lastPlaylistsLoadDate = nil
        errorMessage = nil
    }

    // MARK: - Albums

    func loadAlbums() async {
        #if DEBUG
        if let count = DemoContent.largeLibraryFixtureAlbumCount {
            await applyLargeLibraryFixtureAlbums(count: count)
            return
        }
        #endif

        guard !isLoadingAlbums else { return }

        if albums.isEmpty, let keys = activeServerKeys {
            let cacheSort = Self.albumCacheSort(for: sortOption)
            let cached = await libraryRepository.cachedAlbums(
                serverKey: keys.serverKey,
                sort: cacheSort.0,
                direction: cacheSort.1
            )
            if !cached.isEmpty {
                albums = cached
            } else if let sid = keys.stableId {
                let legacyCached: [Album]? = await Task.detached(priority: .userInitiated) {
                    LibraryViewModel.loadLibraryCache([Album].self, name: "albums", serverId: sid)
                }.value
                if let legacyCached, !legacyCached.isEmpty {
                    albums = legacyCached
                    await libraryRepository.storeAlbums(legacyCached, serverKey: keys.serverKey, stableId: keys.stableId)
                }
            }
        }

        guard !OfflineModeService.shared.isOffline else { isLoadingAlbums = false; return }

        isLoadingAlbums = albums.isEmpty
        errorMessage = nil
        do {
            guard let keys = activeServerKeys else {
                isLoadingAlbums = false
                return
            }
            let all = try await libraryRepository.refreshAlbums(
                serverKey: keys.serverKey,
                stableId: keys.stableId,
                sortBy: Self.subsonicSortKey(for: sortOption)
            )
            albums = all
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingAlbums = false
    }

    // MARK: - Artists

    func loadArtists() async {
        #if DEBUG
        if let count = DemoContent.largeLibraryFixtureAlbumCount {
            await applyLargeLibraryFixtureArtists(albumCount: count)
            return
        }
        #endif

        guard !isLoadingArtists else { return }

        if artists.isEmpty, let keys = activeServerKeys {
            let cached = await libraryRepository.cachedArtists(serverKey: keys.serverKey)
            if !cached.isEmpty {
                artists = cached
            } else if let sid = keys.stableId {
                let legacyCached: [Artist]? = await Task.detached(priority: .userInitiated) {
                    LibraryViewModel.loadLibraryCache([Artist].self, name: "artists", serverId: sid)
                }.value
                if let legacyCached, !legacyCached.isEmpty {
                    artists = legacyCached
                    await libraryRepository.storeArtists(legacyCached, serverKey: keys.serverKey, stableId: keys.stableId)
                }
            }
        }

        guard !OfflineModeService.shared.isOffline else { isLoadingArtists = false; return }

        isLoadingArtists = artists.isEmpty
        errorMessage = nil
        do {
            guard let keys = activeServerKeys else {
                isLoadingArtists = false
                return
            }
            artists = try await libraryRepository.refreshArtists(serverKey: keys.serverKey, stableId: keys.stableId)
            let map = Dictionary(artists.compactMap { artist -> (String, String)? in
                guard let cover = artist.coverArt else { return nil }
                return (artist.name, cover)
            }, uniquingKeysWith: { first, _ in first })
            NotificationCenter.default.post(name: .libraryArtistsLoaded, object: map)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingArtists = false
    }

    nonisolated private static func subsonicSortKey(for option: LibrarySortOption) -> String {
        switch option {
        case .name:
            return "alphabeticalByName"
        case .year:
            return "year"
        case .mostPlayed:
            return "frequent"
        case .recentlyAdded:
            return "newest"
        }
    }

    nonisolated private static func albumCacheSort(for option: LibrarySortOption) -> (LibraryAlbumSort, LibraryDatabaseSortDirection) {
        switch option {
        case .name:
            return (.name, .ascending)
        case .year:
            return (.year, .descending)
        case .mostPlayed:
            return (.playCount, .descending)
        case .recentlyAdded:
            return (.created, .descending)
        }
    }

    // MARK: - Starred / Favorites

    func loadStarred() async {
        if let serverId = AppState.shared.serverStore.activeServer?.stableId, !serverId.isEmpty {
            let sid = serverId
            let cached: Starred2Result? = await Task.detached(priority: .userInitiated) {
                LibraryViewModel.loadStarredCache(serverId: sid)
            }.value
            if let cached {
                starredSongs = cached.song ?? []
                starredAlbums = cached.album ?? []
                starredArtists = cached.artist ?? []
            }
        }

        guard !OfflineModeService.shared.isOffline else { isLoadingStarred = false; return }
        isLoadingStarred = starredSongs.isEmpty && starredAlbums.isEmpty && starredArtists.isEmpty

        do {
            let result = try await api.getStarred()
            starredSongs = result.song ?? []
            starredAlbums = result.album ?? []
            starredArtists = result.artist ?? []
            if let serverId = AppState.shared.serverStore.activeServer?.stableId, !serverId.isEmpty {
                let sid = serverId
                let songs = starredSongs; let albums = starredAlbums; let artists = starredArtists
                Task.detached(priority: .utility) {
                    LibraryViewModel.saveStarredCache(songs: songs, albums: albums, artists: artists, serverId: sid)
                }
                let starredIds = Set(starredSongs.map(\.id))
                await DownloadDatabase.shared.syncFavorites(serverId: sid, starredSongIds: starredIds)
                NotificationCenter.default.post(name: .downloadsLibraryChanged, object: nil)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingStarred = false
    }

    func isSongStarred(_ song: Song) -> Bool {
        starredSongs.contains { $0.id == song.id }
    }

    func isAlbumStarred(_ album: Album) -> Bool {
        starredAlbums.contains { $0.id == album.id }
    }

    func isArtistStarred(_ artist: Artist) -> Bool {
        starredArtists.contains { $0.id == artist.id }
    }

    func toggleStarSong(_ song: Song) async {
        let wasStarred = isSongStarred(song)
        // Optimistic update
        if wasStarred {
            starredSongs.removeAll { $0.id == song.id }
        } else {
            starredSongs.append(song)
        }
        do {
            if wasStarred {
                try await api.unstar(songId: song.id)
            } else {
                try await api.star(songId: song.id)
            }
        } catch {
            // Rollback
            if wasStarred {
                starredSongs.append(song)
            } else {
                starredSongs.removeAll { $0.id == song.id }
            }
            errorMessage = error.localizedDescription
        }
    }

    func toggleStarAlbum(_ album: Album) async {
        let wasStarred = isAlbumStarred(album)
        if wasStarred {
            starredAlbums.removeAll { $0.id == album.id }
        } else {
            starredAlbums.append(album)
        }
        do {
            if wasStarred {
                try await api.unstar(albumId: album.id)
            } else {
                try await api.star(albumId: album.id)
            }
        } catch {
            if wasStarred {
                starredAlbums.append(album)
            } else {
                starredAlbums.removeAll { $0.id == album.id }
            }
            errorMessage = error.localizedDescription
        }
    }

    func toggleStarArtist(_ artist: Artist) async {
        let wasStarred = isArtistStarred(artist)
        if wasStarred {
            starredArtists.removeAll { $0.id == artist.id }
        } else {
            starredArtists.append(artist)
        }
        do {
            if wasStarred {
                try await api.unstar(artistId: artist.id)
            } else {
                try await api.star(artistId: artist.id)
            }
        } catch {
            if wasStarred {
                starredArtists.append(artist)
            } else {
                starredArtists.removeAll { $0.id == artist.id }
            }
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Playlists

    func loadPlaylists(force: Bool = false) async {
        guard !isLoadingPlaylists else { return }
        if !force,
           let lastPlaylistsLoadDate,
           Date().timeIntervalSince(lastPlaylistsLoadDate) < playlistsRefreshInterval {
            return
        }

        if playlists.isEmpty, let serverId = AppState.shared.serverStore.activeServer?.stableId {
            playlists = loadPlaylistsCache(serverId: serverId)
        }
        guard !OfflineModeService.shared.isOffline else { isLoadingPlaylists = false; return }
        isLoadingPlaylists = true
        lastPlaylistsLoadDate = Date()
        defer { isLoadingPlaylists = false }

        do {
            playlists = try await api.getPlaylists()
            if let serverId = AppState.shared.serverStore.activeServer?.stableId {
                savePlaylistsCache(playlists, serverId: serverId)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadPlaylistDetail(id: String) async -> PlaylistDetail? {
        if OfflineModeService.shared.isOffline {
            return loadPlaylistDetailCache(id: id)
        }
        do {
            let detail = PlaylistDetail(try await api.getPlaylist(id: id))
            savePlaylistDetailCache(detail)
            let freshCount = detail.songs?.count ?? detail.songCount
            if let idx = playlists.firstIndex(where: { $0.id == id }) {
                let p = playlists[idx]
                playlists[idx] = Playlist(id: p.id, name: p.name, comment: p.comment,
                                          songCount: freshCount, duration: detail.duration, coverArt: p.coverArt)
            }
            return detail
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    nonisolated private static var libraryCacheDir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shelv_library_cache")
    }

    nonisolated private static func loadLibraryCache<T: Decodable>(_ type: T.Type, name: String, serverId: String) -> T? {
        let url = libraryCacheDir.appendingPathComponent("\(name)_\(serverId).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static var playlistCacheDir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shelv_playlist_cache")
    }

    nonisolated private static var starredCacheDir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shelv_starred_cache")
    }

    nonisolated private static func saveStarredCache(songs: [Song], albums: [Album], artists: [Artist], serverId: String) {
        let dir = starredCacheDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(songs).write(to: dir.appendingPathComponent("starred_songs_\(serverId).json"))
        try? JSONEncoder().encode(albums).write(to: dir.appendingPathComponent("starred_albums_\(serverId).json"))
        try? JSONEncoder().encode(artists).write(to: dir.appendingPathComponent("starred_artists_\(serverId).json"))
    }

    nonisolated private static func loadStarredCache(serverId: String) -> Starred2Result? {
        let dir = starredCacheDir
        let dec = JSONDecoder()
        let songs   = (try? Data(contentsOf: dir.appendingPathComponent("starred_songs_\(serverId).json")))
            .flatMap { try? dec.decode([Song].self, from: $0) }
        let albums  = (try? Data(contentsOf: dir.appendingPathComponent("starred_albums_\(serverId).json")))
            .flatMap { try? dec.decode([Album].self, from: $0) }
        let artists = (try? Data(contentsOf: dir.appendingPathComponent("starred_artists_\(serverId).json")))
            .flatMap { try? dec.decode([Artist].self, from: $0) }
        guard songs != nil || albums != nil || artists != nil else { return nil }
        return Starred2Result(artist: artists, album: albums, song: songs)
    }

    private func savePlaylistsCache(_ playlists: [Playlist], serverId: String) {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        let url = Self.playlistCacheDir.appendingPathComponent("playlist_list_\(serverId).json")
        try? FileManager.default.createDirectory(at: Self.playlistCacheDir, withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    private func loadPlaylistsCache(serverId: String) -> [Playlist] {
        let url = Self.playlistCacheDir.appendingPathComponent("playlist_list_\(serverId).json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Playlist].self, from: data)) ?? []
    }

    private func savePlaylistDetailCache(_ detail: PlaylistDetail) {
        let dir = Self.playlistCacheDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("playlist_\(detail.id.pathSafeComponent).json")
        try? JSONEncoder().encode(detail).write(to: url)
    }

    private func loadPlaylistDetailCache(id: String) -> PlaylistDetail? {
        let url = Self.playlistCacheDir.appendingPathComponent("playlist_\(id.pathSafeComponent).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PlaylistDetail.self, from: data)
    }

    func createPlaylist(name: String) async {
        do {
            let created = try await api.createPlaylist(name: name)
            playlists.append(created)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deletePlaylist(_ playlist: Playlist) async {
        do {
            try await api.deletePlaylist(id: playlist.id)
            playlists.removeAll { $0.id == playlist.id }
            if let entry = await PlayLogService.shared.registryEntry(playlistId: playlist.id) {
                CloudKitSyncService.debugLog("[LibraryDelete] playlistId=\(playlist.id) was recap, deleting marker=\(entry.ckRecordName ?? "nil")")
                if let ckName = entry.ckRecordName {
                    await CloudKitSyncService.shared.deleteRecapMarker(ckRecordName: ckName)
                }
                await PlayLogService.shared.deleteRegistryEntry(playlistId: playlist.id)
                NotificationCenter.default.post(name: .recapRegistryUpdated, object: nil)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renamePlaylist(_ playlist: Playlist, newName: String) async {
        do {
            try await api.updatePlaylist(id: playlist.id, name: newName)
            if let idx = playlists.firstIndex(where: { $0.id == playlist.id }) {
                playlists[idx] = Playlist(id: playlist.id, name: newName, comment: playlist.comment,
                                          songCount: playlist.songCount, duration: playlist.duration,
                                          coverArt: playlist.coverArt)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func addSongsToPlaylist(_ playlist: Playlist, songIds: [String]) async -> Bool {
        do {
            try await api.updatePlaylist(id: playlist.id, songIdsToAdd: songIds)
            if let refreshed = try? await api.getPlaylists() {
                playlists = refreshed
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func removeSongsFromPlaylist(_ playlist: Playlist, indices: [Int]) async {
        do {
            try await api.updatePlaylist(id: playlist.id, songIndicesToRemove: indices)
            if let idx = playlists.firstIndex(where: { $0.id == playlist.id }) {
                let p = playlists[idx]
                playlists[idx] = Playlist(id: p.id, name: p.name, comment: p.comment,
                                          songCount: max(0, (p.songCount ?? 0) - indices.count),
                                          duration: p.duration, coverArt: p.coverArt)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func syncPlaylistOrder(_ playlist: Playlist, songs: [Song]) async {
        // Remove all songs and re-add in desired order
        let count = songs.count
        guard count > 0 else { return }
        let removeIndices = Array(0..<count)
        do {
            try await api.updatePlaylist(id: playlist.id, songIndicesToRemove: removeIndices)
            try await api.updatePlaylist(id: playlist.id, songIdsToAdd: songs.map(\.id))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
