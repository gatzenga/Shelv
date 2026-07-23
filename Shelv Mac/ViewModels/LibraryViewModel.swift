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
        didSet {
            if !isUpdatingAlbumSortSelection { scheduleSortedAlbumsRebuild() }
        }
    }
    @Published var albumSortDirection: SortDirection = .ascending {
        didSet {
            if !isUpdatingAlbumSortSelection { scheduleSortedAlbumsRebuild() }
        }
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
    private var sortedAlbumsGeneration = 0
    private var sortedArtistsGeneration = 0
    private var isUpdatingAlbumSortSelection = false

    func selectAlbumSortOption(_ option: LibrarySortOption) {
        guard sortOption != option || albumSortDirection != option.naturalDirection else { return }

        isUpdatingAlbumSortSelection = true
        sortOption = option
        albumSortDirection = option.naturalDirection
        isUpdatingAlbumSortSelection = false
        scheduleSortedAlbumsRebuild()
    }

    private func scheduleSortedAlbumsRebuild() {
        sortedAlbumsTask?.cancel()
        sortedAlbumsGeneration &+= 1
        let generation = sortedAlbumsGeneration
        let source = albums
        let option = sortOption
        let direction = albumSortDirection

        sortedAlbumsTask = Task.detached(priority: .userInitiated) {
            let sorted = Self.sortedAlbums(source, option: option, direction: direction)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.sortedAlbumsGeneration == generation else { return }
                self.sortedAlbums = sorted
            }
        }
    }

    private func scheduleSortedArtistsRebuild() {
        sortedArtistsTask?.cancel()
        sortedArtistsGeneration &+= 1
        let generation = sortedArtistsGeneration
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
                guard self.sortedArtistsGeneration == generation else { return }
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
        let requestedDirection: LibraryDatabaseSortDirection = option == .name || option == .artist
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
            natural = LibraryRepository.locallySortedArtists(artists)
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
                return compareArtists(lhs, rhs)
            }
        }
        return natural
    }

    nonisolated private static func compareArtists(_ lhs: Artist, _ rhs: Artist) -> Bool {
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
    private var albumLoadGeneration = 0
    private var artistLoadGeneration = 0
    private var starredLoadGeneration = 0
    private var playlistLoadGeneration = 0
    private var isRefreshingAlbums = false
    private var isRefreshingArtists = false
    private var isRefreshingStarred = false
    private var isRefreshingPlaylists = false
    private var refreshingAlbumIdentity: ServerIdentity?
    private var refreshingArtistIdentity: ServerIdentity?
    private var refreshingStarredIdentity: ServerIdentity?
    private var refreshingPlaylistIdentity: ServerIdentity?
    private var albumRefreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var artistRefreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var starredRefreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var playlistRefreshWaiters: [CheckedContinuation<Void, Never>] = []

    private struct ServerIdentity: Equatable {
        let serverKey: String
        let stableId: String?
        let baseURL: String
        let username: String
    }

    private var loadedStarredCacheIdentity: ServerIdentity?
    private var loadedStarredCacheSelectionKey: String?
    private var serverWideStarredSongIDs: Set<String>?
    private var serverWideStarredAlbumIDs: Set<String>?
    private var serverWideStarredArtistIDs: Set<String>?

    private var activeServerIdentity: ServerIdentity? {
        guard let server = AppState.shared.serverStore.activeServer else { return nil }
        return ServerIdentity(
            serverKey: server.id.uuidString,
            stableId: server.stableId.isEmpty ? nil : server.stableId,
            baseURL: server.activeBaseURL,
            username: server.username
        )
    }

    /// Publishes the last confirmed favorite state before library rows become visible.
    /// The subsequent server refresh reconciles removals and additions.
    func loadCachedStarred() async {
        let librarySelection = MusicLibraryStore.shared.snapshot
        let isOffline = OfflineModeService.shared.isOffline
        let selectionKey = isOffline
            ? librarySelection.allSelectionKey
            : librarySelection.selectionKey
        let allowsLegacyFallback = isOffline || !librarySelection.appliesFilter
        guard let identity = activeServerIdentity,
              loadedStarredCacheIdentity != identity
                || loadedStarredCacheSelectionKey != selectionKey
        else { return }

        let cacheKey = identity.stableId ?? identity.serverKey
        let cached: Starred2Result? = await Task.detached(priority: .userInitiated) {
            LibraryViewModel.loadStarredCache(
                serverId: cacheKey,
                selectionKey: selectionKey
            ) ?? (allowsLegacyFallback
                ? LibraryViewModel.loadStarredCache(serverId: cacheKey)
                : nil)
        }.value

        let currentSelection = MusicLibraryStore.shared.snapshot
        let currentSelectionKey = OfflineModeService.shared.isOffline
            ? currentSelection.allSelectionKey
            : currentSelection.selectionKey
        guard !Task.isCancelled,
              activeServerIdentity == identity,
              currentSelectionKey == selectionKey,
              loadedStarredCacheIdentity != identity
                || loadedStarredCacheSelectionKey != selectionKey
        else { return }
        if let cached {
            let songs = FavoritePresentation.songs(cached.song ?? [])
            let albums = FavoritePresentation.albums(cached.album ?? [])
            let artists = FavoritePresentation.artists(cached.artist ?? [])
            if starredSongs != songs { starredSongs = songs }
            if starredAlbums != albums { starredAlbums = albums }
            if starredArtists != artists { starredArtists = artists }
            if isOffline || !librarySelection.appliesFilter {
                applyServerWideStarred(cached)
            }
        }
        loadedStarredCacheIdentity = identity
        loadedStarredCacheSelectionKey = selectionKey
    }

    private func persistStarredCache(for identity: ServerIdentity) {
        guard activeServerIdentity == identity else { return }
        let cacheKey = identity.stableId ?? identity.serverKey
        let selectionKey = MusicLibraryStore.shared.snapshot.selectionKey
        let songs = starredSongs
        let albums = starredAlbums
        let artists = starredArtists
        Task.detached(priority: .utility) {
            LibraryViewModel.saveStarredCache(
                songs: songs,
                albums: albums,
                artists: artists,
                serverId: cacheKey,
                selectionKey: selectionKey
            )
        }
    }

    private func applyServerWideStarred(_ result: StarredResult) {
        serverWideStarredSongIDs = Set((result.song ?? []).map(\.id))
        serverWideStarredAlbumIDs = Set((result.album ?? []).map(\.id))
        serverWideStarredArtistIDs = Set((result.artist ?? []).map(\.id))
    }

    private func updateServerWideSong(id: String, isStarred: Bool) {
        var ids = serverWideStarredSongIDs ?? Set(starredSongs.map(\.id))
        if isStarred { ids.insert(id) } else { ids.remove(id) }
        serverWideStarredSongIDs = ids
    }

    private func updateServerWideAlbum(id: String, isStarred: Bool) {
        var ids = serverWideStarredAlbumIDs ?? Set(starredAlbums.map(\.id))
        if isStarred { ids.insert(id) } else { ids.remove(id) }
        serverWideStarredAlbumIDs = ids
    }

    private func updateServerWideArtist(id: String, isStarred: Bool) {
        var ids = serverWideStarredArtistIDs ?? Set(starredArtists.map(\.id))
        if isStarred { ids.insert(id) } else { ids.remove(id) }
        serverWideStarredArtistIDs = ids
    }

    private func isCurrentAlbumLoad(_ generation: Int, identity: ServerIdentity) -> Bool {
        !Task.isCancelled
            && albumLoadGeneration == generation
            && activeServerIdentity == identity
    }

    private func isCurrentArtistLoad(_ generation: Int, identity: ServerIdentity) -> Bool {
        !Task.isCancelled
            && artistLoadGeneration == generation
            && activeServerIdentity == identity
    }

    private func isCurrentStarredLoad(_ generation: Int, identity: ServerIdentity) -> Bool {
        !Task.isCancelled
            && starredLoadGeneration == generation
            && activeServerIdentity == identity
    }

    private func isCurrentPlaylistLoad(_ generation: Int, identity: ServerIdentity) -> Bool {
        !Task.isCancelled
            && playlistLoadGeneration == generation
            && activeServerIdentity == identity
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
        albumLoadGeneration &+= 1
        artistLoadGeneration &+= 1
        starredLoadGeneration &+= 1
        playlistLoadGeneration &+= 1
        isRefreshingAlbums = false
        isRefreshingArtists = false
        isRefreshingStarred = false
        isRefreshingPlaylists = false
        refreshingAlbumIdentity = nil
        refreshingArtistIdentity = nil
        refreshingStarredIdentity = nil
        refreshingPlaylistIdentity = nil
        loadedStarredCacheIdentity = nil
        loadedStarredCacheSelectionKey = nil
        serverWideStarredSongIDs = nil
        serverWideStarredAlbumIDs = nil
        serverWideStarredArtistIDs = nil
        let waiters = albumRefreshWaiters
            + artistRefreshWaiters
            + starredRefreshWaiters
            + playlistRefreshWaiters
        albumRefreshWaiters.removeAll()
        artistRefreshWaiters.removeAll()
        starredRefreshWaiters.removeAll()
        playlistRefreshWaiters.removeAll()
        waiters.forEach { $0.resume() }
        isLoadingAlbums = false
        isLoadingArtists = false
        isLoadingStarred = false
        isLoadingPlaylists = false
        albums = []
        artists = []
        starredSongs = []
        starredAlbums = []
        starredArtists = []
        playlists = []
        lastPlaylistsLoadDate = nil
        errorMessage = nil
    }

    /// Clears only online content controlled by the active Navidrome library
    /// filter. Playlists, recaps, play history, and downloads stay server-wide.
    func resetForMusicLibrarySelection() {
        albumLoadGeneration &+= 1
        artistLoadGeneration &+= 1
        starredLoadGeneration &+= 1
        isRefreshingAlbums = false
        isRefreshingArtists = false
        isRefreshingStarred = false
        refreshingAlbumIdentity = nil
        refreshingArtistIdentity = nil
        refreshingStarredIdentity = nil
        loadedStarredCacheIdentity = nil
        loadedStarredCacheSelectionKey = nil
        let waiters = albumRefreshWaiters + artistRefreshWaiters + starredRefreshWaiters
        albumRefreshWaiters.removeAll()
        artistRefreshWaiters.removeAll()
        starredRefreshWaiters.removeAll()
        waiters.forEach { $0.resume() }
        isLoadingAlbums = false
        isLoadingArtists = false
        isLoadingStarred = false
        albums = []
        artists = []
        starredSongs = []
        starredAlbums = []
        starredArtists = []
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

        let librarySelection = await MusicLibraryStore.shared.prepareActiveServer()
        await loadCachedStarred()
        guard !Task.isCancelled else { return }

        let requestedIdentity = activeServerIdentity
        if isRefreshingAlbums,
           refreshingAlbumIdentity == requestedIdentity {
            await withCheckedContinuation { continuation in
                albumRefreshWaiters.append(continuation)
            }
            return
        }
        isRefreshingAlbums = true
        refreshingAlbumIdentity = requestedIdentity
        albumLoadGeneration &+= 1
        let generation = albumLoadGeneration
        defer {
            if albumLoadGeneration == generation {
                isRefreshingAlbums = false
                refreshingAlbumIdentity = nil
                isLoadingAlbums = false
                let waiters = albumRefreshWaiters
                albumRefreshWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }

        guard let identity = requestedIdentity,
              activeServerIdentity == identity
        else { return }
        isLoadingAlbums = albums.isEmpty
        errorMessage = nil

        if albums.isEmpty {
            let cacheSort = Self.albumCacheSort(for: sortOption)
            let cached = await libraryRepository.cachedAlbums(
                serverKey: identity.serverKey,
                libraryIDs: librarySelection.visibleCacheFolderIDs,
                sort: cacheSort.0,
                direction: cacheSort.1
            )
            guard isCurrentAlbumLoad(generation, identity: identity) else { return }
            if !cached.isEmpty {
                albums = cached
            } else if let sid = identity.stableId,
                      !librarySelection.appliesFilter {
                let legacyCached: [Album]? = await Task.detached(priority: .userInitiated) {
                    LibraryViewModel.loadLibraryCache([Album].self, name: "albums", serverId: sid)
                }.value
                guard isCurrentAlbumLoad(generation, identity: identity) else { return }
                if let legacyCached, !legacyCached.isEmpty {
                    albums = legacyCached
                    await libraryRepository.storeAlbums(
                        legacyCached,
                        serverKey: identity.serverKey,
                        stableId: identity.stableId
                    )
                    guard isCurrentAlbumLoad(generation, identity: identity) else { return }
                }
            }
        }

        if let serverId = identity.stableId, !albums.isEmpty {
            let allCachedAlbums = await libraryRepository.cachedAlbums(
                serverKey: identity.serverKey,
                libraryIDs: librarySelection.allCacheFolderIDs
            )
            guard isCurrentAlbumLoad(generation, identity: identity) else { return }
            await DownloadService.shared.adoptCachedAlbumDownloads(
                allCachedAlbums.isEmpty ? albums : allCachedAlbums,
                serverId: serverId
            )
            guard isCurrentAlbumLoad(generation, identity: identity) else { return }
        }

        guard !OfflineModeService.shared.isOffline else { return }

        do {
            let all = try await libraryRepository.refreshAlbums(
                serverKey: identity.serverKey,
                stableId: identity.stableId,
                libraryIDs: librarySelection.allCacheFolderIDs,
                visibleLibraryIDs: librarySelection.visibleCacheFolderIDs,
                sortBy: Self.subsonicSortKey(for: sortOption)
            )
            guard isCurrentAlbumLoad(generation, identity: identity) else { return }
            albums = all
            if let serverId = identity.stableId {
                let allRefreshedAlbums = await libraryRepository.cachedAlbums(
                    serverKey: identity.serverKey,
                    libraryIDs: librarySelection.allCacheFolderIDs
                )
                guard isCurrentAlbumLoad(generation, identity: identity) else { return }
                let observedAlbums = allRefreshedAlbums.isEmpty
                    ? all
                    : allRefreshedAlbums
                Task {
                    await DownloadService.shared.observeAlbumSummaries(
                        observedAlbums,
                        serverId: serverId,
                        schedulesStaleRefresh: true
                    )
                }
            }
        } catch {
            if isCurrentAlbumLoad(generation, identity: identity),
               !(error is CancellationError) {
                errorMessage = OfflineModeService.shared.inlineErrorMessage(for: error)
            }
        }
    }

    // MARK: - Artists

    func loadArtists() async {
        #if DEBUG
        if let count = DemoContent.largeLibraryFixtureAlbumCount {
            await applyLargeLibraryFixtureArtists(albumCount: count)
            return
        }
        #endif

        let librarySelection = await MusicLibraryStore.shared.prepareActiveServer()
        await loadCachedStarred()
        guard !Task.isCancelled else { return }

        let requestedIdentity = activeServerIdentity
        if isRefreshingArtists,
           refreshingArtistIdentity == requestedIdentity {
            await withCheckedContinuation { continuation in
                artistRefreshWaiters.append(continuation)
            }
            return
        }
        isRefreshingArtists = true
        refreshingArtistIdentity = requestedIdentity
        artistLoadGeneration &+= 1
        let generation = artistLoadGeneration
        defer {
            if artistLoadGeneration == generation {
                isRefreshingArtists = false
                refreshingArtistIdentity = nil
                isLoadingArtists = false
                let waiters = artistRefreshWaiters
                artistRefreshWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }

        guard let identity = requestedIdentity,
              activeServerIdentity == identity
        else { return }
        isLoadingArtists = artists.isEmpty
        errorMessage = nil

        if artists.isEmpty {
            let cached = await libraryRepository.cachedArtists(
                serverKey: identity.serverKey,
                libraryIDs: librarySelection.visibleCacheFolderIDs
            )
            guard isCurrentArtistLoad(generation, identity: identity) else { return }
            if !cached.isEmpty {
                artists = cached
            } else if let sid = identity.stableId,
                      !librarySelection.appliesFilter {
                let legacyCached: [Artist]? = await Task.detached(priority: .userInitiated) {
                    LibraryViewModel.loadLibraryCache([Artist].self, name: "artists", serverId: sid)
                }.value
                guard isCurrentArtistLoad(generation, identity: identity) else { return }
                if let legacyCached, !legacyCached.isEmpty {
                    artists = legacyCached
                    await libraryRepository.storeArtists(
                        legacyCached,
                        serverKey: identity.serverKey,
                        stableId: identity.stableId
                    )
                    guard isCurrentArtistLoad(generation, identity: identity) else { return }
                }
            }
        }

        guard !OfflineModeService.shared.isOffline else { return }

        do {
            let result = try await libraryRepository.refreshArtists(
                serverKey: identity.serverKey,
                stableId: identity.stableId,
                libraryIDs: librarySelection.allCacheFolderIDs,
                visibleLibraryIDs: librarySelection.visibleCacheFolderIDs
            )
            guard isCurrentArtistLoad(generation, identity: identity) else { return }
            artists = result
            let map = Dictionary(result.compactMap { artist -> (String, String)? in
                guard let cover = artist.coverArt else { return nil }
                return (artist.name, cover)
            }, uniquingKeysWith: { first, _ in first })
            NotificationCenter.default.post(name: .libraryArtistsLoaded, object: map)
        } catch {
            if isCurrentArtistLoad(generation, identity: identity),
               !(error is CancellationError) {
                errorMessage = OfflineModeService.shared.inlineErrorMessage(for: error)
            }
        }
    }

    nonisolated private static func subsonicSortKey(for option: LibrarySortOption) -> String {
        switch option {
        case .name:
            return "alphabeticalByName"
        case .artist:
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
        case .artist:
            return (.artist, .ascending)
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
        _ = await MusicLibraryStore.shared.prepareActiveServer()
        await loadCachedStarred()
        guard !Task.isCancelled else { return }

        let requestedIdentity = activeServerIdentity
        if isRefreshingStarred,
           refreshingStarredIdentity == requestedIdentity {
            await withCheckedContinuation { continuation in
                starredRefreshWaiters.append(continuation)
            }
            return
        }
        isRefreshingStarred = true
        refreshingStarredIdentity = requestedIdentity
        starredLoadGeneration &+= 1
        let generation = starredLoadGeneration
        defer {
            if starredLoadGeneration == generation {
                isRefreshingStarred = false
                refreshingStarredIdentity = nil
                isLoadingStarred = false
                let waiters = starredRefreshWaiters
                starredRefreshWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }

        guard let identity = requestedIdentity,
              activeServerIdentity == identity
        else { return }

        guard !OfflineModeService.shared.isOffline else { return }
        let requestedSelection = MusicLibraryStore.shared.snapshot
        let requestedSelectionKey = requestedSelection.selectionKey
        isLoadingStarred = starredSongs.isEmpty && starredAlbums.isEmpty && starredArtists.isEmpty

        do {
            let result = try await api.getStarred()
            guard isCurrentStarredLoad(generation, identity: identity),
                  !OfflineModeService.shared.isOffline,
                  MusicLibraryStore.shared.snapshot.selectionKey == requestedSelectionKey
            else { return }
            let songs = FavoritePresentation.songs(result.song ?? [])
            let albums = FavoritePresentation.albums(result.album ?? [])
            let artists = FavoritePresentation.artists(result.artist ?? [])
            starredSongs = songs
            starredAlbums = albums
            starredArtists = artists
            persistStarredCache(for: identity)

            let serverWideResult: StarredResult?
            if requestedSelection.appliesFilter {
                serverWideResult = try? await api.getStarred(libraryFilter: .all)
                guard isCurrentStarredLoad(generation, identity: identity),
                      !OfflineModeService.shared.isOffline,
                      MusicLibraryStore.shared.snapshot.selectionKey == requestedSelectionKey
                else { return }
                if let serverWideResult {
                    LibraryViewModel.saveStarredCache(
                        songs: FavoritePresentation.songs(serverWideResult.song ?? []),
                        albums: FavoritePresentation.albums(serverWideResult.album ?? []),
                        artists: FavoritePresentation.artists(serverWideResult.artist ?? []),
                        serverId: identity.stableId ?? identity.serverKey,
                        selectionKey: requestedSelection.allSelectionKey
                    )
                }
            } else {
                serverWideResult = result
            }

            if let serverWideResult {
                applyServerWideStarred(serverWideResult)
            }
            if let sid = identity.stableId,
               let serverWideResult {
                let starredIds = Set((serverWideResult.song ?? []).map(\.id))
                await DownloadDatabase.shared.syncFavorites(serverId: sid, starredSongIds: starredIds)
                guard isCurrentStarredLoad(generation, identity: identity) else { return }
                NotificationCenter.default.post(name: .downloadsLibraryChanged, object: nil)
            }
        } catch {
            if isCurrentStarredLoad(generation, identity: identity),
               !(error is CancellationError) {
                errorMessage = OfflineModeService.shared.inlineErrorMessage(for: error)
            }
        }
    }

    func isSongStarred(_ song: Song) -> Bool {
        serverWideStarredSongIDs?.contains(song.id)
            ?? (song.starred != nil || starredSongs.contains { $0.id == song.id })
    }

    func isAlbumStarred(_ album: Album) -> Bool {
        serverWideStarredAlbumIDs?.contains(album.id)
            ?? (album.starred != nil || starredAlbums.contains { $0.id == album.id })
    }

    func isArtistStarred(_ artist: Artist) -> Bool {
        serverWideStarredArtistIDs?.contains(artist.id)
            ?? (artist.starred != nil || starredArtists.contains { $0.id == artist.id })
    }

    func toggleStarSong(_ song: Song) async {
        let identity = activeServerIdentity
        let wasStarred = isSongStarred(song)
        // Optimistic update
        if wasStarred {
            starredSongs.removeAll { $0.id == song.id }
        } else {
            var favorite = song
            favorite.starred = Date()
            starredSongs.insert(favorite, at: 0)
        }
        updateServerWideSong(id: song.id, isStarred: !wasStarred)
        do {
            if wasStarred {
                try await api.unstar(songId: song.id)
            } else {
                try await api.star(songId: song.id)
            }
            guard activeServerIdentity == identity else { return }
            if MusicLibraryStore.shared.snapshot.appliesFilter {
                await loadStarred()
            } else if let identity {
                persistStarredCache(for: identity)
            }
        } catch {
            guard activeServerIdentity == identity else { return }
            // Rollback
            if wasStarred {
                starredSongs.append(song)
                starredSongs = FavoritePresentation.songs(starredSongs)
            } else {
                starredSongs.removeAll { $0.id == song.id }
            }
            updateServerWideSong(id: song.id, isStarred: wasStarred)
            if let identity { persistStarredCache(for: identity) }
            errorMessage = OfflineModeService.shared.inlineErrorMessage(for: error, userInitiated: true)
        }
    }

    func toggleStarAlbum(_ album: Album) async {
        let identity = activeServerIdentity
        let wasStarred = isAlbumStarred(album)
        if wasStarred {
            starredAlbums.removeAll { $0.id == album.id }
        } else {
            var favorite = album
            favorite.starred = Date()
            starredAlbums.insert(favorite, at: 0)
        }
        updateServerWideAlbum(id: album.id, isStarred: !wasStarred)
        do {
            if wasStarred {
                try await api.unstar(albumId: album.id)
            } else {
                try await api.star(albumId: album.id)
            }
            guard activeServerIdentity == identity else { return }
            if MusicLibraryStore.shared.snapshot.appliesFilter {
                await loadStarred()
            } else if let identity {
                persistStarredCache(for: identity)
            }
        } catch {
            guard activeServerIdentity == identity else { return }
            if wasStarred {
                starredAlbums.append(album)
                starredAlbums = FavoritePresentation.albums(starredAlbums)
            } else {
                starredAlbums.removeAll { $0.id == album.id }
            }
            updateServerWideAlbum(id: album.id, isStarred: wasStarred)
            if let identity { persistStarredCache(for: identity) }
            errorMessage = OfflineModeService.shared.inlineErrorMessage(for: error, userInitiated: true)
        }
    }

    func toggleStarArtist(_ artist: Artist) async {
        let identity = activeServerIdentity
        let wasStarred = isArtistStarred(artist)
        if wasStarred {
            starredArtists.removeAll { $0.id == artist.id }
        } else {
            var favorite = artist
            favorite.starred = Date()
            starredArtists.insert(favorite, at: 0)
        }
        updateServerWideArtist(id: artist.id, isStarred: !wasStarred)
        do {
            if wasStarred {
                try await api.unstar(artistId: artist.id)
            } else {
                try await api.star(artistId: artist.id)
            }
            guard activeServerIdentity == identity else { return }
            if MusicLibraryStore.shared.snapshot.appliesFilter {
                await loadStarred()
            } else if let identity {
                persistStarredCache(for: identity)
            }
        } catch {
            guard activeServerIdentity == identity else { return }
            if wasStarred {
                starredArtists.append(artist)
                starredArtists = FavoritePresentation.artists(starredArtists)
            } else {
                starredArtists.removeAll { $0.id == artist.id }
            }
            updateServerWideArtist(id: artist.id, isStarred: wasStarred)
            if let identity { persistStarredCache(for: identity) }
            errorMessage = OfflineModeService.shared.inlineErrorMessage(for: error, userInitiated: true)
        }
    }

    // MARK: - Playlists

    func loadPlaylists(force: Bool = false) async {
        let requestedIdentity = activeServerIdentity
        if isRefreshingPlaylists,
           refreshingPlaylistIdentity == requestedIdentity {
            await withCheckedContinuation { continuation in
                playlistRefreshWaiters.append(continuation)
            }
            return
        }
        if !force,
           let lastPlaylistsLoadDate,
           Date().timeIntervalSince(lastPlaylistsLoadDate) < playlistsRefreshInterval {
            return
        }

        isRefreshingPlaylists = true
        refreshingPlaylistIdentity = requestedIdentity
        playlistLoadGeneration &+= 1
        let generation = playlistLoadGeneration
        defer {
            if playlistLoadGeneration == generation {
                isRefreshingPlaylists = false
                refreshingPlaylistIdentity = nil
                isLoadingPlaylists = false
                let waiters = playlistRefreshWaiters
                playlistRefreshWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }

        guard let identity = requestedIdentity,
              activeServerIdentity == identity
        else { return }

        if playlists.isEmpty, let serverId = identity.stableId {
            let cached = loadPlaylistsCache(serverId: serverId)
            guard isCurrentPlaylistLoad(generation, identity: identity) else { return }
            playlists = cached
        }
        guard !OfflineModeService.shared.isOffline else { return }
        isLoadingPlaylists = true
        lastPlaylistsLoadDate = Date()

        do {
            let result = try await api.getPlaylists()
            guard isCurrentPlaylistLoad(generation, identity: identity) else { return }
            playlists = result
            if let serverId = identity.stableId {
                savePlaylistsCache(result, serverId: serverId)
            }
        } catch {
            if isCurrentPlaylistLoad(generation, identity: identity),
               !(error is CancellationError) {
                errorMessage = OfflineModeService.shared.inlineErrorMessage(for: error)
            }
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
            errorMessage = OfflineModeService.shared.inlineErrorMessage(for: error)
            return nil
        }
    }

    nonisolated private static var libraryCacheDir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shelv_library_cache")
    }

    nonisolated private static func loadLibraryCache<T: Decodable>(_ type: T.Type, name: String, serverId: String) -> T? {
        let url = libraryCacheDir.appendingPathComponent("\(name.pathSafeComponent)_\(serverId.pathSafeComponent).json")
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

    nonisolated private static func saveStarredCache(
        songs: [Song],
        albums: [Album],
        artists: [Artist],
        serverId: String,
        selectionKey: String? = nil
    ) {
        let dir = starredCacheDir
        let safeServerId = starredCacheIdentifier(
            serverId: serverId,
            selectionKey: selectionKey
        )
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(songs).write(
            to: dir.appendingPathComponent("starred_songs_\(safeServerId).json"),
            options: .atomic
        )
        try? JSONEncoder().encode(albums).write(
            to: dir.appendingPathComponent("starred_albums_\(safeServerId).json"),
            options: .atomic
        )
        try? JSONEncoder().encode(artists).write(
            to: dir.appendingPathComponent("starred_artists_\(safeServerId).json"),
            options: .atomic
        )
    }

    nonisolated private static func loadStarredCache(
        serverId: String,
        selectionKey: String? = nil
    ) -> Starred2Result? {
        let dir = starredCacheDir
        let dec = JSONDecoder()
        let safeServerId = starredCacheIdentifier(
            serverId: serverId,
            selectionKey: selectionKey
        )
        let songs   = (try? Data(contentsOf: dir.appendingPathComponent("starred_songs_\(safeServerId).json")))
            .flatMap { try? dec.decode([Song].self, from: $0) }
        let albums  = (try? Data(contentsOf: dir.appendingPathComponent("starred_albums_\(safeServerId).json")))
            .flatMap { try? dec.decode([Album].self, from: $0) }
        let artists = (try? Data(contentsOf: dir.appendingPathComponent("starred_artists_\(safeServerId).json")))
            .flatMap { try? dec.decode([Artist].self, from: $0) }
        guard songs != nil || albums != nil || artists != nil else { return nil }
        return Starred2Result(artist: artists, album: albums, song: songs)
    }

    nonisolated private static func starredCacheIdentifier(
        serverId: String,
        selectionKey: String?
    ) -> String {
        let identifier = selectionKey.map { "\(serverId)_\($0)" } ?? serverId
        return identifier.pathSafeComponent
    }

    private func savePlaylistsCache(_ playlists: [Playlist], serverId: String) {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        let url = Self.playlistCacheDir.appendingPathComponent("playlist_list_\(serverId.pathSafeComponent).json")
        try? FileManager.default.createDirectory(at: Self.playlistCacheDir, withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    private func loadPlaylistsCache(serverId: String) -> [Playlist] {
        let url = Self.playlistCacheDir.appendingPathComponent("playlist_list_\(serverId.pathSafeComponent).json")
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
            errorMessage = OfflineModeService.shared.inlineErrorMessage(for: error, userInitiated: true)
        }
    }

    func deletePlaylist(_ playlist: Playlist) async {
        do {
            try await api.deletePlaylist(id: playlist.id)
            playlists.removeAll { $0.id == playlist.id }
            if let entry = await PlayLogService.shared.registryEntry(playlistId: playlist.id) {
                CloudKitSyncService.debugLog("[LibraryDelete] playlistId=\(playlist.id) was recap, deleting marker=\(entry.ckRecordName ?? "nil")")
                if let ckName = entry.ckRecordName {
                    await CloudKitSyncService.shared.queueRecapMarkerDeletion(ckRecordName: ckName)
                }
                await PlayLogService.shared.deleteRegistryEntry(playlistId: playlist.id)
                NotificationCenter.default.post(name: .recapRegistryUpdated, object: nil)
            }
        } catch {
            errorMessage = OfflineModeService.shared.inlineErrorMessage(for: error, userInitiated: true)
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
            errorMessage = OfflineModeService.shared.inlineErrorMessage(for: error, userInitiated: true)
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
            errorMessage = OfflineModeService.shared.inlineErrorMessage(for: error, userInitiated: true)
            return false
        }
    }

    @discardableResult
    func removeSongsFromPlaylist(_ playlist: Playlist, indices: [Int]) async -> Bool {
        do {
            try await api.updatePlaylist(id: playlist.id, songIndicesToRemove: indices)
            if let idx = playlists.firstIndex(where: { $0.id == playlist.id }) {
                let p = playlists[idx]
                playlists[idx] = Playlist(id: p.id, name: p.name, comment: p.comment,
                                          songCount: max(0, (p.songCount ?? 0) - indices.count),
                                          duration: p.duration, coverArt: p.coverArt)
            }
            return true
        } catch {
            errorMessage = OfflineModeService.shared.inlineErrorMessage(for: error, userInitiated: true)
            return false
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
            errorMessage = OfflineModeService.shared.inlineErrorMessage(for: error, userInitiated: true)
        }
    }
}
