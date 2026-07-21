import Combine
import SwiftUI

private struct LibraryDerivedState {
    var albumGroups: [(letter: String, items: [Album])] = []
    var albumGenreOptions: [AlbumGenreFilterOption] = []
    var artistGroups: [(letter: String, items: [Artist])] = []
    var albumCountByArtist: [String: Int] = [:]
}

private struct LibraryDerivedStateInput: Equatable {
    let isOffline: Bool
    let libraryAlbums: [Album]
    let libraryArtists: [Artist]
    let downloadedAlbums: [DownloadedAlbum]
    let downloadedArtists: [DownloadedArtist]
    let albumSort: AlbumSortOption
    let albumDirection: SortDirection
    let selectedAlbumGenre: String?
    let artistSort: ArtistSortOption
    let artistDirection: SortDirection
}

/// Serializes derived-library work so a cancelled rebuild never competes with its replacement.
private actor LibraryDerivedStateWorker {
    func rebuild(from input: LibraryDerivedStateInput) -> LibraryDerivedState? {
        guard !Task.isCancelled else { return nil }
        guard let sources = sources(from: input) else { return nil }
        let albumsSource = sources.albums
        let artistsSource = sources.artists
        let albumGenreOptions = AlbumGenreFilterOption.options(from: albumsSource)
        guard !Task.isCancelled else { return nil }
        let effectiveSelectedAlbumGenre = AlbumGenreFilterOption.selectedGenre(
            input.selectedAlbumGenre,
            in: albumGenreOptions
        )
        guard let filteredAlbums = filteredAlbums(
            albumsSource,
            selectedGenre: effectiveSelectedAlbumGenre
        ) else { return nil }

        guard !Task.isCancelled else { return nil }
        let albumCacheSort = LibraryRepository.albumCacheSort(for: input.albumSort.rawValue)
        let requestedAlbumDirection: LibraryDatabaseSortDirection = input.albumSort == .alphabetical
            ? .ascending
            : (input.albumDirection == .ascending ? .ascending : .descending)
        let sortedAlbums = LibraryRepository.locallySortedAlbums(
            filteredAlbums,
            sort: albumCacheSort.0,
            direction: requestedAlbumDirection
        )
        guard !Task.isCancelled else { return nil }

        let albumGroups: [(letter: String, items: [Album])]
        if input.albumSort == .alphabetical {
            albumGroups = LibraryGrouping.groupByFirstLetter(
                sortedAlbums,
                name: \.name,
                sortName: \.sortName
            )
            guard !Task.isCancelled else { return nil }
        } else {
            albumGroups = sortedAlbums.isEmpty ? [] : [(letter: "", items: sortedAlbums)]
        }

        guard let albumCountByArtist = albumCountsByArtist(
            in: albumsSource,
            artistCount: artistsSource.count
        ) else { return nil }

        let sortedArtists: [Artist]
        switch input.artistSort {
        case .alphabetical:
            guard !Task.isCancelled else { return nil }
            sortedArtists = LibraryRepository.locallySortedArtists(artistsSource)
            guard !Task.isCancelled else { return nil }
        case .frequent:
            guard let playCounts = playCountsByArtist(
                in: input.libraryAlbums,
                artistCount: artistsSource.count
            ) else { return nil }
            sortedArtists = artistsSource.sorted {
                (playCounts[$0.id] ?? 0) > (playCounts[$1.id] ?? 0)
            }
            guard !Task.isCancelled else { return nil }
        }

        let artistGroups: [(letter: String, items: [Artist])]
        if input.artistSort == .alphabetical {
            artistGroups = LibraryGrouping.groupByFirstLetter(
                sortedArtists,
                name: \.name,
                sortName: \.sortName
            )
            guard !Task.isCancelled else { return nil }
        } else {
            let items = input.artistDirection == .descending
                ? sortedArtists
                : Array(sortedArtists.reversed())
            artistGroups = items.isEmpty ? [] : [(letter: "", items: items)]
        }

        guard !Task.isCancelled else { return nil }
        return LibraryDerivedState(
            albumGroups: albumGroups,
            albumGenreOptions: albumGenreOptions,
            artistGroups: artistGroups,
            albumCountByArtist: albumCountByArtist
        )
    }

    private func sources(from input: LibraryDerivedStateInput) -> (albums: [Album], artists: [Artist])? {
        guard input.isOffline else {
            return Task.isCancelled ? nil : (input.libraryAlbums, input.libraryArtists)
        }

        var downloadedAlbumIds: Set<String> = []
        downloadedAlbumIds.reserveCapacity(input.downloadedAlbums.count)
        for (index, album) in input.downloadedAlbums.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { return nil }
            downloadedAlbumIds.insert(album.albumId)
        }

        let albums: [Album]
        if input.libraryAlbums.isEmpty {
            var converted: [Album] = []
            converted.reserveCapacity(input.downloadedAlbums.count)
            for (index, album) in input.downloadedAlbums.enumerated() {
                if index.isMultiple(of: 16), Task.isCancelled { return nil }
                converted.append(album.asAlbum())
            }
            albums = converted
        } else {
            var available: [Album] = []
            available.reserveCapacity(input.downloadedAlbums.count)
            var coveredIds: Set<String> = []
            coveredIds.reserveCapacity(input.downloadedAlbums.count)
            for (index, album) in input.libraryAlbums.enumerated() {
                if index.isMultiple(of: 64), Task.isCancelled { return nil }
                guard downloadedAlbumIds.contains(album.id) else { continue }
                available.append(album)
                coveredIds.insert(album.id)
            }
            for (index, album) in input.downloadedAlbums.enumerated() {
                if index.isMultiple(of: 16), Task.isCancelled { return nil }
                guard !coveredIds.contains(album.albumId) else { continue }
                available.append(album.asAlbum())
            }
            albums = available
        }

        var downloadedArtistNames: Set<String> = []
        downloadedArtistNames.reserveCapacity(input.downloadedArtists.count)
        for (index, artist) in input.downloadedArtists.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { return nil }
            downloadedArtistNames.insert(artist.name)
        }

        let artists: [Artist]
        if input.libraryArtists.isEmpty {
            var converted: [Artist] = []
            converted.reserveCapacity(input.downloadedArtists.count)
            for (index, artist) in input.downloadedArtists.enumerated() {
                if index.isMultiple(of: 64), Task.isCancelled { return nil }
                converted.append(artist.asArtist())
            }
            artists = converted
        } else {
            var available: [Artist] = []
            available.reserveCapacity(input.downloadedArtists.count)
            var coveredNames: Set<String> = []
            coveredNames.reserveCapacity(input.downloadedArtists.count)
            for (index, artist) in input.libraryArtists.enumerated() {
                if index.isMultiple(of: 64), Task.isCancelled { return nil }
                guard downloadedArtistNames.contains(artist.name) else { continue }
                available.append(artist)
                coveredNames.insert(artist.name)
            }
            for (index, artist) in input.downloadedArtists.enumerated() {
                if index.isMultiple(of: 64), Task.isCancelled { return nil }
                guard !coveredNames.contains(artist.name) else { continue }
                available.append(artist.asArtist())
            }
            artists = available
        }

        return Task.isCancelled ? nil : (albums, artists)
    }

    private func filteredAlbums(_ albums: [Album], selectedGenre: String?) -> [Album]? {
        guard let selectedGenre else { return Task.isCancelled ? nil : albums }
        var filtered: [Album] = []
        filtered.reserveCapacity(albums.count)
        for (index, album) in albums.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { return nil }
            if AlbumGenreFilterOption.matches(album, selectedGenre: selectedGenre) {
                filtered.append(album)
            }
        }
        return Task.isCancelled ? nil : filtered
    }

    private func albumCountsByArtist(in albums: [Album], artistCount: Int) -> [String: Int]? {
        var counts: [String: Int] = [:]
        counts.reserveCapacity(min(albums.count, artistCount))
        for (index, album) in albums.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { return nil }
            guard let artistId = album.artistId, !artistId.isEmpty else { continue }
            counts[artistId, default: 0] += 1
        }
        return Task.isCancelled ? nil : counts
    }

    private func playCountsByArtist(in albums: [Album], artistCount: Int) -> [String: Int]? {
        var counts: [String: Int] = [:]
        counts.reserveCapacity(artistCount)
        for (index, album) in albums.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { return nil }
            guard let artistId = album.artistId, !artistId.isEmpty else { continue }
            counts[artistId, default: 0] += album.playCount ?? 0
        }
        return Task.isCancelled ? nil : counts
    }
}

@MainActor
private final class LibraryDerivedStateController: ObservableObject {
    static let shared = LibraryDerivedStateController()

    @Published private(set) var state = LibraryDerivedState()

    private let worker = LibraryDerivedStateWorker()
    private var rebuildTask: Task<Void, Never>?
    private var pendingInput: LibraryDerivedStateInput?
    private var completedInput: LibraryDerivedStateInput?
    private var generation: UInt64 = 0
    private var cancellables = Set<AnyCancellable>()
    private var isActive = false

    private init() {}

    func activate() {
        guard !isActive else { return }
        isActive = true

        LibraryStore.shared.$albums
            .dropFirst()
            .sink { [weak self] albums in
                self?.rebuildCurrent(libraryAlbums: albums)
            }
            .store(in: &cancellables)

        LibraryStore.shared.$artists
            .dropFirst()
            .sink { [weak self] artists in
                self?.rebuildCurrent(libraryArtists: artists)
            }
            .store(in: &cancellables)

        DownloadStore.shared.$albums
            .dropFirst()
            .sink { [weak self] albums in
                guard OfflineModeService.shared.isOffline else { return }
                self?.rebuildCurrent(
                    downloadedAlbums: albums,
                    coalescingBackgroundUpdates: true
                )
            }
            .store(in: &cancellables)

        DownloadStore.shared.$artists
            .dropFirst()
            .sink { [weak self] artists in
                guard OfflineModeService.shared.isOffline else { return }
                self?.rebuildCurrent(
                    downloadedArtists: artists,
                    coalescingBackgroundUpdates: true
                )
            }
            .store(in: &cancellables)

        OfflineModeService.shared.$isOffline
            .dropFirst()
            .sink { [weak self] isOffline in
                self?.rebuildCurrent(isOffline: isOffline)
            }
            .store(in: &cancellables)

        rebuildCurrent()
    }

    func rebuild(
        from input: LibraryDerivedStateInput,
        coalescingBackgroundUpdates: Bool = false
    ) {
        guard input != pendingInput, input != completedInput else { return }

        rebuildTask?.cancel()
        generation &+= 1
        let requestGeneration = generation
        pendingInput = input
        let worker = worker

        rebuildTask = Task.detached(priority: .utility) { [weak self] in
            if coalescingBackgroundUpdates {
                do {
                    try await Task.sleep(nanoseconds: 120_000_000)
                } catch {
                    await self?.finishCancelled(generation: requestGeneration)
                    return
                }
            }

            guard !Task.isCancelled,
                  let result = await worker.rebuild(from: input),
                  !Task.isCancelled
            else {
                await self?.finishCancelled(generation: requestGeneration)
                return
            }

            await self?.publish(
                result,
                for: input,
                generation: requestGeneration
            )
        }
    }

    private func rebuildCurrent(
        isOffline: Bool? = nil,
        libraryAlbums: [Album]? = nil,
        libraryArtists: [Artist]? = nil,
        downloadedAlbums: [DownloadedAlbum]? = nil,
        downloadedArtists: [DownloadedArtist]? = nil,
        coalescingBackgroundUpdates: Bool = false
    ) {
        let defaults = UserDefaults.standard
        let albumSort = AlbumSortOption(
            rawValue: defaults.string(forKey: "albumSortOption")
                ?? AlbumSortOption.alphabetical.rawValue
        ) ?? .alphabetical
        let albumDirection = SortDirection(
            rawValue: defaults.string(forKey: "albumSortDirection")
                ?? SortDirection.ascending.rawValue
        ) ?? .ascending
        let artistSort = ArtistSortOption(
            rawValue: defaults.string(forKey: "artistSortOption")
                ?? ArtistSortOption.alphabetical.rawValue
        ) ?? .alphabetical
        let artistDirection = SortDirection(
            rawValue: defaults.string(forKey: "artistSortDirection")
                ?? SortDirection.ascending.rawValue
        ) ?? .ascending

        rebuild(
            from: LibraryDerivedStateInput(
                isOffline: isOffline ?? OfflineModeService.shared.isOffline,
                libraryAlbums: libraryAlbums ?? LibraryStore.shared.albums,
                libraryArtists: libraryArtists ?? LibraryStore.shared.artists,
                downloadedAlbums: downloadedAlbums ?? DownloadStore.shared.albums,
                downloadedArtists: downloadedArtists ?? DownloadStore.shared.artists,
                albumSort: albumSort,
                albumDirection: albumDirection,
                selectedAlbumGenre: defaults.bool(forKey: PersonalizationPreferenceKey.showGenreFilter)
                    ? AlbumGenreFilterOption.normalizedGenre(
                        defaults.string(forKey: PersonalizationPreferenceKey.albumGenreFilter) ?? ""
                    )
                    : nil,
                artistSort: artistSort,
                artistDirection: artistDirection
            ),
            coalescingBackgroundUpdates: coalescingBackgroundUpdates
        )
    }

    private func publish(
        _ result: LibraryDerivedState,
        for input: LibraryDerivedStateInput,
        generation requestGeneration: UInt64
    ) {
        guard generation == requestGeneration else { return }
        pendingInput = nil
        completedInput = input
        rebuildTask = nil
        state = result
    }

    private func finishCancelled(generation requestGeneration: UInt64) {
        guard generation == requestGeneration else { return }
        pendingInput = nil
        rebuildTask = nil
    }
}

@MainActor
enum LibraryDerivedStatePrewarmer {
    static func activate() {
        LibraryDerivedStateController.shared.activate()
    }
}

struct LibraryView: View {
    @ObservedObject var libraryStore = LibraryStore.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @ObservedObject private var derivedStateController = LibraryDerivedStateController.shared
    @EnvironmentObject var serverStore: ServerStore
    @Environment(\.personalizationSwipeConfiguration) private var personalization
    private let player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    @AppStorage(PersonalizationPreferenceKey.showFavoritesInLibrary) private var showFavoritesInLibrary = true
    @AppStorage(PersonalizationPreferenceKey.showFavoriteActions) private var showFavoriteActions = true
    @AppStorage(PersonalizationPreferenceKey.showPlaylistActions) private var showPlaylistActions = true
    @AppStorage(PersonalizationPreferenceKey.showInstantMixActions) private var showInstantMixActions = true
    @AppStorage(PersonalizationPreferenceKey.showGenreFilter) private var showGenreFilter = true
    @AppStorage("enableDownloads") private var enableDownloads = true

    @State private var segment: LibrarySegment = .albums
    @State private var showAddToPlaylist = false
    @State private var playlistSongIds: [String] = []
    @AppStorage("albumSortOption") private var sortOptionRaw: String = AlbumSortOption.alphabetical.rawValue
    private var sortOption: AlbumSortOption { AlbumSortOption(rawValue: sortOptionRaw) ?? .alphabetical }
    @AppStorage("albumSortDirection") private var albumDirectionRaw: String = SortDirection.ascending.rawValue
    private var albumDirection: SortDirection { SortDirection(rawValue: albumDirectionRaw) ?? .ascending }
    @AppStorage(PersonalizationPreferenceKey.albumGenreFilter) private var albumGenreFilterRaw = ""
    @AppStorage("artistSortOption") private var artistSortRaw: String = ArtistSortOption.alphabetical.rawValue
    private var artistSortOption: ArtistSortOption { ArtistSortOption(rawValue: artistSortRaw) ?? .alphabetical }
    @AppStorage("artistSortDirection") private var artistDirectionRaw: String = SortDirection.ascending.rawValue
    private var artistDirection: SortDirection { SortDirection(rawValue: artistDirectionRaw) ?? .ascending }
    @AppStorage("albumViewIsGrid") private var albumIsGrid = true
    @AppStorage("artistViewIsGrid") private var artistIsGrid = false
    @State private var albumScrollID: String?
    @State private var artistScrollID: String?
    @State private var navigateToAlbum: Album?
    @State private var navigateToArtist: Artist?
    @State private var currentToast: ShelveToast?
    @ObservedObject private var downloadStore = DownloadStore.shared
    @State private var albumToDeleteDownloads: Album?
    @State private var artistToDeleteDownloads: Artist?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 14)]

    private struct DownloadedLibrarySnapshot: Sendable {
        let albumIds: Set<String>
        let artistNames: Set<String>
        let artistBadgeNames: Set<String>
        let songIds: Set<String>
    }

    private var derivedState: LibraryDerivedState { derivedStateController.state }
    private var albumGroups: [(letter: String, items: [Album])] { derivedState.albumGroups }
    private var albumGenreOptions: [AlbumGenreFilterOption] { derivedState.albumGenreOptions }
    private var artistGroups: [(letter: String, items: [Artist])] { derivedState.artistGroups }
    private var albumCountByArtist: [String: Int] { derivedState.albumCountByArtist }

    @ViewBuilder
    private var segmentContent: some View {
        switch segment {
        case .albums:
            if libraryStore.isLoadingAlbums && libraryStore.albums.isEmpty {
                Spacer()
                ProgressView()
                Spacer()
            } else if albumIsGrid {
                IndexedScrollView(
                    letters: albumGroups.map(\.letter).filter { !$0.isEmpty },
                    idPrefix: "alb",
                    scrollID: $albumScrollID
                ) { albumContent }
            } else {
                albumContent
            }
        case .artists:
            if libraryStore.isLoadingArtists && libraryStore.artists.isEmpty {
                Spacer()
                ProgressView()
                Spacer()
            } else if artistIsGrid {
                IndexedScrollView(
                    letters: artistGroups.map(\.letter).filter { !$0.isEmpty },
                    idPrefix: "art",
                    scrollID: $artistScrollID
                ) { artistGridContent }
            } else {
                artistListContent
            }
        case .favorites:
            let snapshot = downloadedLibrarySnapshot
            let starredSongs = displayStarredSongs(using: snapshot)
            let starredAlbums = displayStarredAlbums(using: snapshot)
            let starredArtists = displayStarredArtists(using: snapshot)
            let isLoadingFavorites = libraryStore.isLoadingStarred
                && starredSongs.isEmpty
                && starredAlbums.isEmpty
                && starredArtists.isEmpty
            if isLoadingFavorites {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                favoritesContent(
                    songs: starredSongs,
                    albums: starredAlbums,
                    artists: starredArtists
                )
            }
        }
    }

    var body: some View {
        NavigationStack {
            mainContent
        }
    }

    @ViewBuilder
    private var segmentPicker: some View {
        LibrarySegmentPicker(selection: $segment, enableFavorites: showFavoritesInLibrary)
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        if segment != .favorites {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if segment == .albums && showGenreFilter {
                    LibraryGenreFilterMenu(
                        selectedGenre: $albumGenreFilterRaw,
                        options: albumGenreOptions,
                        accentColor: accentColor
                    )
                }

                LibrarySortMenu(
                    segment: segment,
                    albumSortRaw: $sortOptionRaw,
                    albumDirectionRaw: $albumDirectionRaw,
                    artistSortRaw: $artistSortRaw,
                    artistDirectionRaw: $artistDirectionRaw,
                    isOffline: offlineMode.isOffline,
                    accentColor: accentColor,
                    onAlbumSortChanged: { newValue in
                        Task { await libraryStore.applyAlbumSort(sortBy: newValue) }
                    }
                )

                LibraryViewToggleButton(
                    segment: segment,
                    albumIsGrid: $albumIsGrid,
                    artistIsGrid: $artistIsGrid
                )
            }
        }
    }

    private var stackBase: some View {
        VStack(spacing: 0) {
            segmentPicker
            segmentContent
        }
        .navigationTitle(offlineMode.isOffline ? String(localized: "downloads") : String(localized: "library"))
        .toolbar { libraryToolbar }
        .task(id: libraryStore.reloadID) {
            switch segment {
            case .albums:    await libraryStore.loadAlbums(sortBy: sortOption.rawValue)
            case .artists:   await libraryStore.loadArtists()
            case .favorites: await libraryStore.loadStarred()
            }
        }
        .onChange(of: segment) { _, newSegment in
            Task {
                switch newSegment {
                case .albums:
                    if libraryStore.albums.isEmpty { await libraryStore.loadAlbums() }
                case .artists:
                    if libraryStore.artists.isEmpty { await libraryStore.loadArtists() }
                case .favorites:
                    await libraryStore.loadStarred()
                }
            }
        }
    }

    private var stackContent: some View {
        stackBase
        .onAppear { rebuildGroups() }
        .onChange(of: offlineMode.isOffline) { _, isOffline in
            if isOffline {
                if sortOption.requiresServer { sortOptionRaw = AlbumSortOption.alphabetical.rawValue }
                if artistSortOption.requiresServer { artistSortRaw = ArtistSortOption.alphabetical.rawValue }
            }
            rebuildGroups()
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadsLibraryChanged)) { _ in
            guard offlineMode.isOffline else { return }
            rebuildGroups(coalescingBackgroundUpdates: true)
        }
        .onChange(of: albumDirectionRaw) { _, _ in rebuildGroups() }
        .onChange(of: albumGenreFilterRaw) { _, _ in rebuildGroups() }
        .onChange(of: showGenreFilter) { _, enabled in
            if !enabled { albumGenreFilterRaw = "" }
            rebuildGroups()
        }
        .onChange(of: artistSortRaw) { _, _ in rebuildGroups() }
        .onChange(of: artistDirectionRaw) { _, _ in rebuildGroups() }
        .onChange(of: showFavoritesInLibrary) { _, enabled in
            let isFavorites = segment == .favorites
            if !enabled && isFavorites { segment = .albums }
        }
    }

    private func rebuildGroups(coalescingBackgroundUpdates: Bool = false) {
        let input = LibraryDerivedStateInput(
            isOffline: offlineMode.isOffline,
            libraryAlbums: libraryStore.albums,
            libraryArtists: libraryStore.artists,
            downloadedAlbums: downloadStore.albums,
            downloadedArtists: downloadStore.artists,
            albumSort: sortOption,
            albumDirection: albumDirection,
            selectedAlbumGenre: showGenreFilter
                ? AlbumGenreFilterOption.normalizedGenre(albumGenreFilterRaw)
                : nil,
            artistSort: artistSortOption,
            artistDirection: artistDirection
        )
        derivedStateController.rebuild(
            from: input,
            coalescingBackgroundUpdates: coalescingBackgroundUpdates
        )
    }

    private var downloadedLibrarySnapshot: DownloadedLibrarySnapshot {
        let uiState = DownloadUIStateHub.shared.currentSnapshot
        return DownloadedLibrarySnapshot(
            albumIds: uiState.albumIDs,
            artistNames: uiState.artistNames,
            artistBadgeNames: uiState.artistBadgeNames,
            songIds: uiState.songIDs
        )
    }

    private func displayAlbums(using snapshot: DownloadedLibrarySnapshot) -> [Album] {
        guard offlineMode.isOffline else { return libraryStore.albums }
        if libraryStore.albums.isEmpty { return downloadStore.albums.map { $0.asAlbum() } }
        let fromLibrary = libraryStore.albums.filter { snapshot.albumIds.contains($0.id) }
        let coveredIds = Set(fromLibrary.map { $0.id })
        let extras = downloadStore.albums
            .filter { !coveredIds.contains($0.albumId) }
            .map { $0.asAlbum() }
        return fromLibrary + extras
    }

    private func displayArtists(using snapshot: DownloadedLibrarySnapshot) -> [Artist] {
        guard offlineMode.isOffline else { return libraryStore.artists }
        if libraryStore.artists.isEmpty { return downloadStore.artists.map { $0.asArtist() } }
        let fromLibrary = libraryStore.artists.filter { snapshot.artistNames.contains($0.name) }
        let coveredNames = Set(fromLibrary.map { $0.name })
        let extras = downloadStore.artists
            .filter { !coveredNames.contains($0.name) }
            .map { $0.asArtist() }
        return fromLibrary + extras
    }

    private var mainContent: some View {
        stackContent
        .refreshable {
            if await offlineMode.beginUserInitiatedServerRefresh() { return }
            defer { offlineMode.finishUserInitiatedServerRefresh() }
            let currentSegment = segment
            let currentSort = sortOption.rawValue
            Task { await CloudKitSyncService.shared.syncNow() }
            switch currentSegment {
            case .albums:    await libraryStore.loadAlbums(sortBy: currentSort)
            case .artists:   await libraryStore.loadArtists()
            case .favorites: await libraryStore.loadStarred()
            }
        }
        .shelveToast($currentToast)
        .alert(
            String(localized: "delete_downloads"),
            isPresented: Binding(get: { albumToDeleteDownloads != nil }, set: { if !$0 { albumToDeleteDownloads = nil } }),
            presenting: albumToDeleteDownloads
        ) { album in
            Button(String(localized: "delete"), role: .destructive) {
                DownloadStore.shared.deleteAlbum(album.id)
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: { _ in
            Text(String(localized: "the_downloads_will_be_removed_from_this_device"))
        }
        .alert(
            String(localized: "delete_downloads"),
            isPresented: Binding(get: { artistToDeleteDownloads != nil }, set: { if !$0 { artistToDeleteDownloads = nil } }),
            presenting: artistToDeleteDownloads
        ) { artist in
            Button(String(localized: "delete"), role: .destructive) {
                if let match = downloadStore.artists.first(where: {
                    $0.artistId == artist.id || $0.name == artist.name
                }) {
                    DownloadStore.shared.deleteArtist(match.artistId)
                }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: { _ in
            Text(String(localized: "the_downloads_will_be_removed_from_this_device"))
        }
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistSheet(songIds: playlistSongIds)
                .environmentObject(libraryStore)
                .tint(accentColor)
        }
    }

    private func songsForAlbum(_ album: Album) async -> [Song] {
        if offlineMode.isOffline {
            return downloadStore.albums.first { $0.albumId == album.id }?.songs.map { $0.asSong() } ?? []
        }
        return (try? await libraryStore.fetchAlbumSongs(album)) ?? []
    }

    private func queueAlbum(_ album: Album) {
        Task {
            let songs = await songsForAlbum(album)
            guard !songs.isEmpty else { return }
            player.addToQueue(songs)
            currentToast = ShelveToast(message: String(localized: "added_to_queue"))
        }
    }

    private func playNextAlbum(_ album: Album) {
        Task {
            let songs = await songsForAlbum(album)
            guard !songs.isEmpty else { return }
            player.addPlayNext(songs)
            currentToast = ShelveToast(message: String(localized: "plays_next"))
        }
    }

    private func playAlbum(_ album: Album) {
        Task {
            let songs = await songsForAlbum(album)
            guard !songs.isEmpty else { return }
            player.play(songs: songs, startIndex: 0)
        }
    }

    private func shuffleAlbum(_ album: Album) {
        Task {
            let songs = await songsForAlbum(album)
            guard !songs.isEmpty else { return }
            player.playShuffled(songs: songs)
        }
    }

    private func playInstantMix(album: Album) {
        InstantMixService.playAlbumMix(for: album, player: player)
    }

    private func addAlbumToPlaylist(_ album: Album) {
        Task {
            let songs = await songsForAlbum(album)
            guard !songs.isEmpty else { return }
            NotificationCenter.default.post(name: .addSongsToPlaylist, object: songs.map(\.id))
        }
    }

    private func queueArtist(_ artist: Artist) {
        Task {
            let songs = await libraryStore.fetchAllSongs(for: artist)
            guard !songs.isEmpty else { return }
            player.addToQueue(songs)
            currentToast = ShelveToast(message: String(localized: "added_to_queue"))
        }
    }

    private func playNextArtist(_ artist: Artist) {
        Task {
            let songs = await libraryStore.fetchAllSongs(for: artist)
            guard !songs.isEmpty else { return }
            player.addPlayNext(songs)
            currentToast = ShelveToast(message: String(localized: "plays_next"))
        }
    }

    private func addArtistToPlaylist(_ artist: Artist) {
        Task {
            let songs = await libraryStore.fetchAllSongs(for: artist)
            guard !songs.isEmpty else { return }
            NotificationCenter.default.post(name: .addSongsToPlaylist, object: songs.map(\.id))
        }
    }

    private func playInstantMix(artist: Artist) {
        InstantMixService.playArtistMix(for: artist, player: player)
    }

    @ViewBuilder
    private var albumContent: some View {
        if albumIsGrid {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(albumGroups, id: \.letter) { group in
                    Section {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(group.items) { album in
                                NavigationLink(destination: AlbumDetailView(album: album)) {
                                    AlbumCardView(
                                        album: album,
                                        personalization: personalization,
                                        showArtist: true
                                    )
                                        .equatable()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, group.letter.isEmpty ? 12 : 0)
                        .padding(.bottom, 14)
                    } header: {
                        if !group.letter.isEmpty {
                            LibraryLetterHeader(letter: group.letter, id: "alb-\(group.letter)")
                        }
                    }
                }
                PlayerBottomSpacer()
            }
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(albumGroups, id: \.letter) { group in
                        if !group.letter.isEmpty {
                            Text(group.letter)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.secondary)
                                .id("alb-\(group.letter)")
                                .listRowInsets(EdgeInsets(top: 20, leading: 16, bottom: 4, trailing: 0))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                        ForEach(group.items) { album in
                            AlbumDownloadStatusReader(
                                albumID: album.id,
                                totalSongs: album.songCount ?? 0,
                                tracksIntermediateProgress: false
                            ) { downloadStatus in
                                Button { navigateToAlbum = album } label: {
                                    LibraryAlbumListRow(album: album)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { albumContextMenuItems(album) }
                                .personalizedAlbumArtistSwipeActions(
                                    isOffline: offlineMode.isOffline,
                                    isFavorite: libraryStore.isAlbumStarred(album),
                                    downloadState: albumDownloadState(downloadStatus),
                                    accentColor: accentColor,
                                    onFavorite: {
                                        haptic(.medium); Task { await libraryStore.toggleStarAlbum(album) }
                                    },
                                    onAddToPlaylist: {
                                        addAlbumToPlaylist(album)
                                    },
                                    onDownload: {
                                        handleAlbumDownloadSwipe(album)
                                    },
                                    onPlayNext: {
                                        haptic(); playNextAlbum(album)
                                    },
                                    onAddToQueue: {
                                        haptic(); queueAlbum(album)
                                    }
                                )
                            }
                        }
                    }
                    PlayerBottomSpacer()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollIndicators(.hidden)
                .contentMargins(.trailing, 20, for: .scrollContent)
                .overlay(alignment: .trailing) {
                    let letters = albumGroups.map(\.letter).filter { !$0.isEmpty }
                    if !letters.isEmpty {
                        AlphabetIndexBar(letters: letters) { letter in
                            withAnimation(.none) {
                                proxy.scrollTo("alb-\(letter)", anchor: .top)
                            }
                        }
                        .frame(width: 14)
                        .padding(.vertical, 16)
                        .padding(.trailing, 2)
                    }
                }
                .navigationDestination(item: $navigateToAlbum) { album in
                    AlbumDetailView(album: album)
                }
            }
        }
    }

    @ViewBuilder
    private var artistGridContent: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
            ForEach(artistGroups, id: \.letter) { group in
                Section {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(group.items) { artist in
                            ArtistDownloadAvailabilityReader(artistName: artist.name) { availability in
                                NavigationLink(destination: ArtistDetailView(artist: artist)) {
                                    LibraryArtistGridCell(
                                        artist: artist,
                                        isDownloaded: availability.isBadgeDownloaded,
                                        accentColor: accentColor
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    artistContextMenuItems(artist)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, group.letter.isEmpty ? 12 : 0)
                    .padding(.bottom, 14)
                } header: {
                    if !group.letter.isEmpty {
                        LibraryLetterHeader(letter: group.letter, id: "art-\(group.letter)")
                    }
                }
            }
            PlayerBottomSpacer()
        }
    }

    @ViewBuilder
    private var artistListContent: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(artistGroups, id: \.letter) { group in
                    if !group.letter.isEmpty {
                        Text(group.letter)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .id("art-\(group.letter)")
                            .listRowInsets(EdgeInsets(top: 20, leading: 16, bottom: 4, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(group.items) { artist in
                        ArtistDownloadAvailabilityReader(artistName: artist.name) { availability in
                            Button { navigateToArtist = artist } label: {
                                LibraryArtistListRow(
                                    artist: artist,
                                    localAlbumCount: albumCountByArtist[artist.id] ?? artist.albumCount ?? 0,
                                    isDownloaded: availability.isBadgeDownloaded,
                                    accentColor: accentColor
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                artistContextMenuItems(artist)
                            }
                            .personalizedAlbumArtistSwipeActions(
                                isOffline: offlineMode.isOffline,
                                isFavorite: libraryStore.isArtistStarred(artist),
                                downloadState: artistDownloadState(for: artist),
                                accentColor: accentColor,
                                onFavorite: {
                                    haptic(.medium); Task { await libraryStore.toggleStarArtist(artist) }
                                },
                                onAddToPlaylist: {
                                    addArtistToPlaylist(artist)
                                },
                                onDownload: {
                                    handleArtistDownloadSwipe(artist)
                                },
                                onPlayNext: {
                                    haptic(); playNextArtist(artist)
                                },
                                onAddToQueue: {
                                    haptic(); queueArtist(artist)
                                }
                            )
                        }
                    }
                }
                PlayerBottomSpacer()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollIndicators(.hidden)
            .contentMargins(.trailing, 20, for: .scrollContent)
            .overlay(alignment: .trailing) {
                let letters = artistGroups.map(\.letter).filter { !$0.isEmpty }
                if !letters.isEmpty {
                    AlphabetIndexBar(letters: letters) { letter in
                        withAnimation(.none) {
                            proxy.scrollTo("art-\(letter)", anchor: .top)
                        }
                    }
                    .frame(width: 14)
                    .padding(.vertical, 16)
                    .padding(.trailing, 2)
                }
            }
            .navigationDestination(item: $navigateToArtist) { artist in
                ArtistDetailView(artist: artist)
            }
        }
    }

    private func displayStarredSongs(using snapshot: DownloadedLibrarySnapshot) -> [Song] {
        guard offlineMode.isOffline else { return libraryStore.starredSongs }
        return libraryStore.starredSongs.filter { snapshot.songIds.contains($0.id) }
    }

    private func displayStarredAlbums(using snapshot: DownloadedLibrarySnapshot) -> [Album] {
        guard offlineMode.isOffline else { return libraryStore.starredAlbums }
        return libraryStore.starredAlbums.filter { snapshot.albumIds.contains($0.id) }
    }

    private func displayStarredArtists(using snapshot: DownloadedLibrarySnapshot) -> [Artist] {
        guard offlineMode.isOffline else { return libraryStore.starredArtists }
        return libraryStore.starredArtists.filter { snapshot.artistNames.contains($0.name) }
    }

    @ViewBuilder
    private func favoritesContent(
        songs: [Song],
        albums: [Album],
        artists: [Artist]
    ) -> some View {
        let hasSongs = !songs.isEmpty
        let hasAlbums = !albums.isEmpty
        let hasArtists = !artists.isEmpty

        if !hasSongs && !hasAlbums && !hasArtists {
            ContentUnavailableView(
                String(localized: "no_favorites"),
                systemImage: "heart",
                description: Text(String(localized: "star_songs_albums_and_artists_to_see_them_here"))
            )
        } else {
            List {
                if hasAlbums {
                    Section(String(localized: "albums")) {
                        favoriteAlbumRows(Array(albums.prefix(FavoritePresentation.previewLimit)))
                        if albums.count > FavoritePresentation.previewLimit {
                            showAllFavoritesLink(count: albums.count) {
                                favoriteAlbumsPage
                            }
                        }
                    }
                }
                if hasSongs {
                    Section(String(localized: "songs")) {
                        favoriteSongRows(Array(songs.prefix(FavoritePresentation.previewLimit)))
                        if songs.count > FavoritePresentation.previewLimit {
                            showAllFavoritesLink(count: songs.count) {
                                favoriteSongsPage
                            }
                        }
                    }
                }
                if hasArtists {
                    Section(String(localized: "artists")) {
                        favoriteArtistRows(Array(artists.prefix(FavoritePresentation.previewLimit)))
                        if artists.count > FavoritePresentation.previewLimit {
                            showAllFavoritesLink(count: artists.count) {
                                favoriteArtistsPage
                            }
                        }
                    }
                }
                PlayerBottomSpacer()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func favoriteAlbumRows(_ albums: [Album]) -> some View {
        ForEach(albums) { album in
            AlbumDownloadStatusReader(
                albumID: album.id,
                totalSongs: album.songCount ?? 0,
                tracksIntermediateProgress: false
            ) { downloadStatus in
                NavigationLink(destination: AlbumDetailView(album: album)) {
                    LibraryFavoriteAlbumRow(album: album, showsFavoriteBadge: false)
                }
                .contextMenu {
                    albumContextMenuItems(album)
                }
                .personalizedAlbumArtistSwipeActions(
                    isOffline: offlineMode.isOffline,
                    isFavorite: true,
                    downloadState: albumDownloadState(downloadStatus),
                    accentColor: accentColor,
                    onFavorite: {
                        haptic(.medium); Task { await libraryStore.toggleStarAlbum(album) }
                    },
                    onAddToPlaylist: {
                        addAlbumToPlaylist(album)
                    },
                    onDownload: {
                        handleAlbumDownloadSwipe(album)
                    },
                    onPlayNext: {
                        haptic(); playNextAlbum(album)
                    },
                    onAddToQueue: {
                        haptic(); queueAlbum(album)
                    }
                )
            }
        }
    }

    @ViewBuilder
    private func favoriteSongRows(_ songs: [Song]) -> some View {
        ForEach(songs) { song in
            Button { player.playSong(song) } label: {
                LibraryStarredSongRow(song: song, showsFavoriteBadge: false)
            }
            .buttonStyle(.plain)
            .personalizedSongSwipeActions(
                song: song,
                isOffline: offlineMode.isOffline,
                isFavorite: true,
                accentColor: accentColor,
                onPlay: {
                    player.playSong(song)
                },
                onFavorite: {
                    haptic(.medium)
                    Task { await libraryStore.toggleStarSong(song) }
                },
                onAddToPlaylist: {
                    playlistSongIds = [song.id]
                    showAddToPlaylist = true
                },
                onPlayNext: {
                    haptic()
                    player.addPlayNext(song)
                    currentToast = ShelveToast(message: String(localized: "plays_next"))
                },
                onAddToQueue: {
                    haptic()
                    player.addToQueue(song)
                    currentToast = ShelveToast(message: String(localized: "added_to_queue"))
                }
            )
        }
    }

    @ViewBuilder
    private func favoriteArtistRows(_ artists: [Artist]) -> some View {
        ForEach(artists) { artist in
            ArtistDownloadAvailabilityReader(artistName: artist.name) { availability in
                NavigationLink(destination: ArtistDetailView(artist: artist)) {
                    LibraryFavoriteArtistRow(
                        artist: artist,
                        isDownloaded: availability.isBadgeDownloaded,
                        accentColor: accentColor,
                        showsFavoriteBadge: false
                    )
                }
                .contextMenu {
                    artistContextMenuItems(artist)
                }
                .personalizedAlbumArtistSwipeActions(
                    isOffline: offlineMode.isOffline,
                    isFavorite: true,
                    downloadState: artistDownloadState(for: artist),
                    accentColor: accentColor,
                    onFavorite: {
                        haptic(.medium); Task { await libraryStore.toggleStarArtist(artist) }
                    },
                    onAddToPlaylist: {
                        addArtistToPlaylist(artist)
                    },
                    onDownload: {
                        handleArtistDownloadSwipe(artist)
                    },
                    onPlayNext: {
                        haptic(); playNextArtist(artist)
                    },
                    onAddToQueue: {
                        haptic(); queueArtist(artist)
                    }
                )
            }
        }
    }

    private func showAllFavoritesLink<Destination: View>(
        count: Int,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination()) {
            Text(String(format: String(localized: "show_all_count_format"), count))
                .foregroundStyle(accentColor)
        }
        .listRowSeparator(.hidden)
    }

    private var favoriteAlbumsPage: some View {
        List {
            favoriteAlbumRows(displayStarredAlbums(using: downloadedLibrarySnapshot))
            PlayerBottomSpacer()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .navigationTitle(String(localized: "favorite_albums"))
    }

    private var favoriteSongsPage: some View {
        List {
            favoriteSongRows(displayStarredSongs(using: downloadedLibrarySnapshot))
            PlayerBottomSpacer()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .navigationTitle(String(localized: "favorite_songs"))
    }

    private var favoriteArtistsPage: some View {
        List {
            favoriteArtistRows(displayStarredArtists(using: downloadedLibrarySnapshot))
            PlayerBottomSpacer()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .navigationTitle(String(localized: "favorite_artists"))
    }

    @ViewBuilder
    private func albumContextMenuItems(_ album: Album) -> some View {
        Button { playAlbum(album) } label: {
            Label(String(localized: "play"), systemImage: "play.fill")
        }
        Button { shuffleAlbum(album) } label: {
            Label(String(localized: "shuffle"), systemImage: "shuffle")
        }
        if showInstantMixActions && !offlineMode.isOffline {
            Button { playInstantMix(album: album) } label: {
                Label(String(localized: "instant_mix"), systemImage: "sparkles")
            }
        }
        Divider()
        Button { playNextAlbum(album) } label: {
            Label(String(localized: "play_next"), systemImage: "text.insert")
        }
        Button { queueAlbum(album) } label: {
            Label(String(localized: "add_to_queue"), systemImage: "text.badge.plus")
        }
        if !offlineMode.isOffline && (showFavoriteActions || showPlaylistActions) {
            Divider()
            if showFavoriteActions {
                Button {
                    Task { await libraryStore.toggleStarAlbum(album) }
                } label: {
                    Label(
                        libraryStore.isAlbumStarred(album)
                            ? String(localized: "unfavorite")
                            : String(localized: "favorite"),
                        systemImage: libraryStore.isAlbumStarred(album) ? "heart.slash.fill" : "heart"
                    )
                }
            }
            if showPlaylistActions {
                Button { addAlbumToPlaylist(album) } label: {
                    Label(String(localized: "add_to_playlist"), systemImage: "music.note.list")
                }
            }
        }
        if enableDownloads {
            Divider()
            albumDownloadMenuItems(album)
        }
    }

    private func albumDownloadState(_ status: AlbumDownloadStatus) -> PersonalizedDownloadSwipeState {
        guard enableDownloads else { return .hidden }
        switch status {
        case .none, .partial:
            return offlineMode.isOffline ? .hidden : .download
        case .complete:
            return .delete
        }
    }

    private func handleAlbumDownloadSwipe(_ album: Album) {
        guard enableDownloads else { return }
        let status = downloadStore.albumDownloadStatus(albumId: album.id, totalSongs: album.songCount ?? 0)
        switch status {
        case .none, .partial:
            guard !offlineMode.isOffline else { return }
            haptic(); downloadStore.enqueueAlbum(album)
        case .complete:
            haptic(); albumToDeleteDownloads = album
        }
    }

    private func artistDownloadState(for artist: Artist) -> PersonalizedDownloadSwipeState {
        guard enableDownloads else { return .hidden }
        switch downloadStore.artistDownloadStatus(
            artist: artist,
            catalogAlbums: libraryStore.albums
        ) {
        case .none, .partial:
            return offlineMode.isOffline ? .hidden : .download
        case .complete:
            return .delete
        }
    }

    private func handleArtistDownloadSwipe(_ artist: Artist) {
        guard enableDownloads else { return }
        switch downloadStore.artistDownloadStatus(
            artist: artist,
            catalogAlbums: libraryStore.albums
        ) {
        case .none, .partial:
            guard !offlineMode.isOffline else { return }
            haptic()
            let sid = serverStore.activeServer?.stableId ?? ""
            Task { await DownloadService.shared.enqueueArtist(artist: artist, serverId: sid) }
        case .complete:
            haptic(); artistToDeleteDownloads = artist
        }
    }

    @ViewBuilder
    private func albumDownloadMenuItems(_ album: Album) -> some View {
        let status = DownloadStore.shared.albumDownloadStatus(albumId: album.id, totalSongs: album.songCount ?? 0)
        switch status {
        case .none:
            if !offlineMode.isOffline {
                Button { DownloadStore.shared.enqueueAlbum(album) } label: {
                    Label(String(localized: "download_album"), systemImage: "arrow.down.circle")
                }
            }
        case .partial:
            if !offlineMode.isOffline {
                Button { DownloadStore.shared.enqueueAlbum(album) } label: {
                    Label(String(localized: "download_remaining"), systemImage: "arrow.down.circle")
                }
            }
            Button(
                String(localized: "delete_downloads_2"),
                systemImage: DownloadActionSymbols.delete,
                role: .destructive
            ) {
                albumToDeleteDownloads = album
            }
            .tint(.red)
        case .complete:
            Button(
                String(localized: "delete_downloads_2"),
                systemImage: DownloadActionSymbols.delete,
                role: .destructive
            ) {
                albumToDeleteDownloads = album
            }
            .tint(.red)
        }
    }

    @ViewBuilder
    private func artistContextMenuItems(_ artist: Artist) -> some View {
        Button {
            Task {
                let songs = await libraryStore.fetchAllSongs(for: artist)
                guard !songs.isEmpty else { return }
                player.play(songs: songs, startIndex: 0)
            }
        } label: { Label(String(localized: "play"), systemImage: "play.fill") }

        Button {
            Task {
                let songs = await libraryStore.fetchAllSongs(for: artist)
                guard !songs.isEmpty else { return }
                player.playShuffled(songs: songs)
            }
        } label: { Label(String(localized: "shuffle"), systemImage: "shuffle") }

        if showInstantMixActions && !offlineMode.isOffline {
            Button { playInstantMix(artist: artist) } label: {
                Label(String(localized: "instant_mix"), systemImage: "sparkles")
            }
        }

        Divider()

        Button { playNextArtist(artist) } label: {
            Label(String(localized: "play_next"), systemImage: "text.insert")
        }
        Button { queueArtist(artist) } label: {
            Label(String(localized: "add_to_queue"), systemImage: "text.badge.plus")
        }

        if !offlineMode.isOffline && (showFavoriteActions || showPlaylistActions) {
            Divider()
            if showFavoriteActions {
                Button {
                    Task { await libraryStore.toggleStarArtist(artist) }
                } label: {
                    Label(
                        libraryStore.isArtistStarred(artist)
                            ? String(localized: "unfavorite")
                            : String(localized: "favorite"),
                        systemImage: libraryStore.isArtistStarred(artist) ? "heart.slash.fill" : "heart"
                    )
                }
            }
            if showPlaylistActions {
                Button {
                    Task {
                        let songs = await libraryStore.fetchAllSongs(for: artist)
                        guard !songs.isEmpty else { return }
                        NotificationCenter.default.post(name: .addSongsToPlaylist, object: songs.map(\.id))
                    }
                } label: { Label(String(localized: "add_to_playlist"), systemImage: "music.note.list") }
            }
        }
        if enableDownloads {
            Divider()
            let downloadStatus = downloadStore.artistDownloadStatus(
                artist: artist,
                catalogAlbums: libraryStore.albums
            )
            switch downloadStatus {
            case .none:
                if !offlineMode.isOffline {
                    Button {
                        let sid = serverStore.activeServer?.stableId ?? ""
                        Task { await DownloadService.shared.enqueueArtist(artist: artist, serverId: sid) }
                    } label: {
                        Label(String(localized: "download_artist"), systemImage: "arrow.down.circle")
                    }
                }
            case .partial:
                if !offlineMode.isOffline {
                    Button {
                        let sid = serverStore.activeServer?.stableId ?? ""
                        Task { await DownloadService.shared.enqueueArtist(artist: artist, serverId: sid) }
                    } label: {
                        Label(String(localized: "download_remaining"), systemImage: "arrow.down.circle")
                    }
                }
                Button(
                    String(localized: "delete_downloads_2"),
                    systemImage: DownloadActionSymbols.delete,
                    role: .destructive
                ) {
                    artistToDeleteDownloads = artist
                }
                .tint(.red)
            case .complete:
                Button(
                    String(localized: "delete_downloads_2"),
                    systemImage: DownloadActionSymbols.delete,
                    role: .destructive
                ) {
                    artistToDeleteDownloads = artist
                }
                .tint(.red)
            }
        }
    }

}
