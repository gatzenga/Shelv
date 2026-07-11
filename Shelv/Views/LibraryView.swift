import SwiftUI

struct LibraryView: View {
    @ObservedObject var libraryStore = LibraryStore.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @EnvironmentObject var serverStore: ServerStore
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
    @State private var albumGroups: [(letter: String, items: [Album])] = []
    @State private var albumGenreOptions: [AlbumGenreFilterOption] = []
    @State private var artistGroups: [(letter: String, items: [Artist])] = []
    @State private var albumCountByArtist: [String: Int] = [:]
    @ObservedObject private var downloadStore = DownloadStore.shared
    @State private var albumToDeleteDownloads: Album?
    @State private var artistToDeleteDownloads: Artist?
    @State private var rebuildTask: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 14)]

    private struct DownloadedLibrarySnapshot: Sendable {
        let albumIds: Set<String>
        let artistNames: Set<String>
        let artistBadgeNames: Set<String>
        let songIds: Set<String>
    }

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
                    artists: starredArtists,
                    snapshot: snapshot
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
        .onReceive(libraryStore.$albums) { _ in Task { @MainActor in rebuildGroups() } }
        .onReceive(libraryStore.$artists) { _ in Task { @MainActor in rebuildGroups() } }
        .onReceive(downloadStore.$albums) { _ in Task { @MainActor in rebuildGroups() } }
        .onReceive(downloadStore.$artists) { _ in Task { @MainActor in rebuildGroups() } }
        .onChange(of: offlineMode.isOffline) { _, isOffline in
            if isOffline {
                if sortOption.requiresServer { sortOptionRaw = AlbumSortOption.alphabetical.rawValue }
                if artistSortOption.requiresServer { artistSortRaw = ArtistSortOption.alphabetical.rawValue }
            }
            rebuildGroups()
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadsLibraryChanged)) { _ in
            rebuildGroups()
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

    private func rebuildGroups() {
        rebuildTask?.cancel()

        let albumsSource: [Album]
        let artistsSource: [Artist]
        if offlineMode.isOffline {
            let snapshot = downloadedLibrarySnapshot
            albumsSource = displayAlbums(using: snapshot)
            artistsSource = displayArtists(using: snapshot)
        } else {
            albumsSource = libraryStore.albums
            artistsSource = libraryStore.artists
        }
        let libraryAlbums = libraryStore.albums
        let sortOpt = sortOption
        let albumDir = albumDirection
        let selectedAlbumGenre = showGenreFilter
            ? AlbumGenreFilterOption.normalizedGenre(albumGenreFilterRaw)
            : nil
        let artistSort = artistSortOption
        let artistDir = artistDirection

        rebuildTask = Task.detached(priority: .userInitiated) {
            let calculatedAlbumGenreOptions = AlbumGenreFilterOption.options(from: albumsSource)
            let effectiveSelectedAlbumGenre = AlbumGenreFilterOption.selectedGenre(
                selectedAlbumGenre,
                in: calculatedAlbumGenreOptions
            )
            let filteredAlbums: [Album]
            if let effectiveSelectedAlbumGenre {
                filteredAlbums = albumsSource.filter {
                    AlbumGenreFilterOption.matches($0, selectedGenre: effectiveSelectedAlbumGenre)
                }
            } else {
                filteredAlbums = albumsSource
            }

            // 1. Alben im Hintergrund gruppieren
            let albumCacheSort = LibraryRepository.albumCacheSort(for: sortOpt.rawValue)
            let requestedAlbumDirection: LibraryDatabaseSortDirection = sortOpt == .alphabetical
                ? .ascending
                : (albumDir == .ascending ? .ascending : .descending)
            let sortedAlbums = LibraryRepository.locallySortedAlbums(
                filteredAlbums,
                sort: albumCacheSort.0,
                direction: requestedAlbumDirection
            )
            let calculatedAlbumGroups: [(letter: String, items: [Album])]
            if sortOpt == .alphabetical {
                calculatedAlbumGroups = LibraryGrouping.groupByFirstLetter(
                    sortedAlbums,
                    name: \.name,
                    sortName: \.sortName
                )
            } else {
                calculatedAlbumGroups = sortedAlbums.isEmpty ? [] : [(letter: "", items: sortedAlbums)]
            }

            let calculatedAlbumCountByArtist: [String: Int] = {
                var counts: [String: Int] = [:]
                counts.reserveCapacity(min(albumsSource.count, artistsSource.count))
                for album in albumsSource {
                    guard let artistId = album.artistId, !artistId.isEmpty else { continue }
                    counts[artistId, default: 0] += 1
                }
                return counts
            }()

            // 2. Künstler im Hintergrund sortieren
            let sortedArtists: [Artist]
            switch artistSort {
            case .alphabetical:
                sortedArtists = LibraryRepository.locallySortedArtists(artistsSource)
            case .frequent:
                var counts: [String: Int] = [:]
                counts.reserveCapacity(artistsSource.count)
                for album in libraryAlbums {
                    guard let artistId = album.artistId, !artistId.isEmpty else { continue }
                    counts[artistId, default: 0] += album.playCount ?? 0
                }
                sortedArtists = artistsSource.sorted { (counts[$0.id] ?? 0) > (counts[$1.id] ?? 0) }
            }

            // 3. Künstler im Hintergrund gruppieren
            let calculatedArtistGroups: [(letter: String, items: [Artist])]
            if artistSort == .alphabetical {
                calculatedArtistGroups = LibraryGrouping.groupByFirstLetter(
                    sortedArtists,
                    name: \.name,
                    sortName: \.sortName
                )
            } else {
                let items = artistDir == .descending
                    ? sortedArtists
                    : Array(sortedArtists.reversed())
                calculatedArtistGroups = items.isEmpty ? [] : [(letter: "", items: items)]
            }

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.albumGroups = calculatedAlbumGroups
                self.albumGenreOptions = calculatedAlbumGenreOptions
                self.artistGroups = calculatedArtistGroups
                self.albumCountByArtist = calculatedAlbumCountByArtist
            }
        }
    }

    private var downloadedLibrarySnapshot: DownloadedLibrarySnapshot {
        let albumIds = Set(downloadStore.albums.map(\.albumId))
        let artistNames = Set(downloadStore.artists.map(\.name))
        let songIds = Set(downloadStore.songs.map(\.songId))
        var artistBadgeNames = artistNames
        for song in downloadStore.songs {
            artistBadgeNames.formUnion(splitNavidromeArtist(song.artistName))
        }
        return DownloadedLibrarySnapshot(
            albumIds: albumIds,
            artistNames: artistNames,
            artistBadgeNames: artistBadgeNames,
            songIds: songIds
        )
    }

    private func splitNavidromeArtist(_ name: String) -> [String] {
        let seps = [" feat. ", " feat ", " ft. ", " ft ", " / ", "; "]
        var parts = [name]
        for sep in seps {
            parts = parts.flatMap { part -> [String] in
                var result: [String] = []
                var s = part
                while let range = s.range(of: sep, options: .caseInsensitive) {
                    result.append(String(s[..<range.lowerBound]))
                    s = String(s[range.upperBound...])
                }
                result.append(s)
                return result
            }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
                if let match = downloadStore.artists.first(where: { $0.name == artist.name }) {
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
                                    AlbumCardView(album: album, showArtist: true)
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
                            Button { navigateToAlbum = album } label: {
                                LibraryAlbumListRow(album: album)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { albumContextMenuItems(album) }
                            .personalizedAlbumArtistSwipeActions(
                                isOffline: offlineMode.isOffline,
                                isFavorite: libraryStore.isAlbumStarred(album),
                                downloadState: albumDownloadState(album),
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
        let snapshot = downloadedLibrarySnapshot
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
            ForEach(artistGroups, id: \.letter) { group in
                Section {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(group.items) { artist in
                            NavigationLink(destination: ArtistDetailView(artist: artist)) {
                                LibraryArtistGridCell(
                                    artist: artist,
                                    isDownloaded: snapshot.artistBadgeNames.contains(artist.name),
                                    accentColor: accentColor
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu { artistContextMenuItems(artist, snapshot: snapshot) }
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
        let snapshot = downloadedLibrarySnapshot
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
                        Button { navigateToArtist = artist } label: {
                            LibraryArtistListRow(
                                artist: artist,
                                localAlbumCount: albumCountByArtist[artist.id] ?? artist.albumCount ?? 0,
                                isDownloaded: snapshot.artistBadgeNames.contains(artist.name),
                                accentColor: accentColor
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu { artistContextMenuItems(artist, snapshot: snapshot) }
                        .personalizedAlbumArtistSwipeActions(
                            isOffline: offlineMode.isOffline,
                            isFavorite: libraryStore.isArtistStarred(artist),
                            downloadState: artistDownloadState(artist, snapshot: snapshot),
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
        artists: [Artist],
        snapshot: DownloadedLibrarySnapshot
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
                if hasArtists {
                    Section(String(localized: "artists")) {
                        ForEach(artists) { artist in
                            NavigationLink(destination: ArtistDetailView(artist: artist)) {
                                LibraryFavoriteArtistRow(
                                    artist: artist,
                                    isDownloaded: snapshot.artistBadgeNames.contains(artist.name),
                                    accentColor: accentColor
                                )
                            }
                            .personalizedAlbumArtistSwipeActions(
                                isOffline: offlineMode.isOffline,
                                isFavorite: true,
                                downloadState: artistDownloadState(artist, snapshot: snapshot),
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
                if hasAlbums {
                    Section(String(localized: "albums")) {
                        ForEach(albums) { album in
                            NavigationLink(destination: AlbumDetailView(album: album)) {
                                LibraryFavoriteAlbumRow(album: album)
                            }
                            .contextMenu {
                                albumContextMenuItems(album)
                            }
                            .personalizedAlbumArtistSwipeActions(
                                isOffline: offlineMode.isOffline,
                                isFavorite: true,
                                downloadState: albumDownloadState(album),
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
                if hasSongs {
                    Section(String(localized: "songs")) {
                        ForEach(songs) { song in
                            Button { player.playSong(song) } label: {
                                LibraryStarredSongRow(song: song)
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
                        systemImage: libraryStore.isAlbumStarred(album) ? "heart.slash" : "heart"
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

    private func albumDownloadState(_ album: Album) -> PersonalizedDownloadSwipeState {
        guard enableDownloads else { return .hidden }
        let status = downloadStore.albumDownloadStatus(albumId: album.id, totalSongs: album.songCount ?? 0)
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

    private func artistDownloadState(_ artist: Artist, snapshot: DownloadedLibrarySnapshot) -> PersonalizedDownloadSwipeState {
        guard enableDownloads else { return .hidden }
        if snapshot.artistNames.contains(artist.name) {
            return .delete
        }
        return offlineMode.isOffline ? .hidden : .download
    }

    private func handleArtistDownloadSwipe(_ artist: Artist) {
        guard enableDownloads else { return }
        if downloadedLibrarySnapshot.artistNames.contains(artist.name) {
            haptic(); artistToDeleteDownloads = artist
        } else if !offlineMode.isOffline {
            haptic()
            let sid = serverStore.activeServer?.stableId ?? ""
            Task { await DownloadService.shared.enqueueArtist(artist: artist, serverId: sid) }
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
            Button(role: .destructive) { albumToDeleteDownloads = album } label: { Label(String(localized: "delete_downloads_2"), systemImage: "arrow.down.circle") }
        case .complete:
            Button(role: .destructive) { albumToDeleteDownloads = album } label: { Label(String(localized: "delete_downloads_2"), systemImage: "arrow.down.circle") }
        }
    }

    @ViewBuilder
    private func artistContextMenuItems(_ artist: Artist, snapshot: DownloadedLibrarySnapshot) -> some View {
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
                        systemImage: libraryStore.isArtistStarred(artist) ? "heart.slash" : "heart"
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
            if !offlineMode.isOffline {
                Button {
                    let sid = serverStore.activeServer?.stableId ?? ""
                    Task { await DownloadService.shared.enqueueArtist(artist: artist, serverId: sid) }
                } label: {
                    Label(String(localized: "download_artist"), systemImage: "arrow.down.circle")
                }
            }
            if snapshot.artistNames.contains(artist.name) {
                Button(role: .destructive) {
                    artistToDeleteDownloads = artist
                } label: {
                    Label(String(localized: "delete_downloads_2"), systemImage: "arrow.down.circle")
                }
            }
        }
    }

}
