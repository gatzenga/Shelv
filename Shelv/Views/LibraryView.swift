import SwiftUI

struct LibraryView: View {
    @ObservedObject var libraryStore = LibraryStore.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @EnvironmentObject var serverStore: ServerStore
    private let player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    @AppStorage("enableInstantMix") private var enableInstantMix = true
    @AppStorage("enableDownloads") private var enableDownloads = false

    @State private var segment: LibrarySegment = .albums
    @State private var showAddToPlaylist = false
    @State private var playlistSongIds: [String] = []
    @AppStorage("albumSortOption") private var sortOptionRaw: String = AlbumSortOption.alphabetical.rawValue
    private var sortOption: AlbumSortOption { AlbumSortOption(rawValue: sortOptionRaw) ?? .alphabetical }
    @AppStorage("albumSortDirection") private var albumDirectionRaw: String = SortDirection.ascending.rawValue
    private var albumDirection: SortDirection { SortDirection(rawValue: albumDirectionRaw) ?? .ascending }
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
    @State private var artistGroups: [(letter: String, items: [Artist])] = []
    @State private var albumCountByArtist: [String: Int] = [:]
    @State private var refreshContinuation: CheckedContinuation<Void, Never>?
    @ObservedObject private var downloadStore = DownloadStore.shared
    @State private var albumToDeleteDownloads: Album?
    @State private var artistToDeleteDownloads: Artist?
    @State private var rebuildTask: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 14)]

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
            let isLoadingFavorites = libraryStore.isLoadingStarred
                && displayStarredSongs.isEmpty
                && displayStarredAlbums.isEmpty
                && displayStarredArtists.isEmpty
            if isLoadingFavorites {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                favoritesContent
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
        LibrarySegmentPicker(selection: $segment, enableFavorites: enableFavorites)
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        if segment == .albums || segment == .artists {
            ToolbarItem(placement: .topBarTrailing) {
                LibrarySortMenu(
                    segment: segment,
                    albumSortRaw: $sortOptionRaw,
                    albumDirectionRaw: $albumDirectionRaw,
                    artistSortRaw: $artistSortRaw,
                    artistDirectionRaw: $artistDirectionRaw,
                    isOffline: offlineMode.isOffline,
                    onAlbumSortChanged: { newValue in
                        Task { await libraryStore.loadAlbums(sortBy: newValue) }
                    }
                )
            }
        }
        if segment != .favorites {
            ToolbarItem(placement: .topBarTrailing) {
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
                if let cont = refreshContinuation {
                    refreshContinuation = nil
                    cont.resume()
                }
                if sortOption.requiresServer { sortOptionRaw = AlbumSortOption.alphabetical.rawValue }
                if artistSortOption.requiresServer { artistSortRaw = ArtistSortOption.alphabetical.rawValue }
            }
            rebuildGroups()
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadsLibraryChanged)) { _ in
            rebuildGroups()
        }
        .onChange(of: albumDirectionRaw) { _, _ in rebuildGroups() }
        .onChange(of: artistSortRaw) { _, _ in rebuildGroups() }
        .onChange(of: artistDirectionRaw) { _, _ in rebuildGroups() }
        .onChange(of: enableFavorites) { _, enabled in
            let isFavorites = segment == .favorites
            if !enabled && isFavorites { segment = .albums }
        }
    }

    private func rebuildGroups() {
        rebuildTask?.cancel()

        let albumsSource = displayAlbums
        let artistsSource = displayArtists
        let libraryAlbums = libraryStore.albums
        let sortOpt = sortOption
        let albumDir = albumDirection
        let artistSort = artistSortOption
        let artistDir = artistDirection

        rebuildTask = Task.detached(priority: .userInitiated) {
            // 1. Alben im Hintergrund gruppieren
            let calculatedAlbumGroups: [(letter: String, items: [Album])]
            if sortOpt == .alphabetical {
                calculatedAlbumGroups = LibraryGrouping.groupByFirstLetter(albumsSource, name: \.name)
            } else {
                let items = albumDir == .descending
                    ? albumsSource
                    : Array(albumsSource.reversed())
                calculatedAlbumGroups = items.isEmpty ? [] : [(letter: "", items: items)]
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
                sortedArtists = artistsSource
            case .frequent:
                let counts = Dictionary(
                    grouping: libraryAlbums,
                    by: { $0.artistId ?? "" }
                ).mapValues { $0.compactMap { $0.playCount }.reduce(0, +) }
                sortedArtists = artistsSource.sorted { (counts[$0.id] ?? 0) > (counts[$1.id] ?? 0) }
            }

            // 3. Künstler im Hintergrund gruppieren
            let calculatedArtistGroups: [(letter: String, items: [Artist])]
            if artistSort == .alphabetical {
                calculatedArtistGroups = LibraryGrouping.groupByFirstLetter(sortedArtists, name: \.name)
            } else {
                let items = artistDir == .descending
                    ? sortedArtists
                    : Array(sortedArtists.reversed())
                calculatedArtistGroups = items.isEmpty ? [] : [(letter: "", items: items)]
            }

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.albumGroups = calculatedAlbumGroups
                self.artistGroups = calculatedArtistGroups
                self.albumCountByArtist = calculatedAlbumCountByArtist
            }
        }
    }

    private var downloadedAlbumIds: Set<String> {
        Set(downloadStore.albums.map { $0.albumId })
    }
    private var downloadedArtistNames: Set<String> {
        Set(downloadStore.artists.map { $0.name })
    }

    private var downloadedArtistBadgeNames: Set<String> {
        var names = downloadedArtistNames
        for song in downloadStore.songs {
            names.formUnion(splitNavidromeArtist(song.artistName))
        }
        return names
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
    private var downloadedSongIds: Set<String> {
        Set(downloadStore.songs.map { $0.songId })
    }

    private var displayAlbums: [Album] {
        guard offlineMode.isOffline else { return libraryStore.albums }
        if libraryStore.albums.isEmpty { return downloadStore.albums.map { $0.asAlbum() } }
        let fromLibrary = libraryStore.albums.filter { downloadedAlbumIds.contains($0.id) }
        let coveredIds = Set(fromLibrary.map { $0.id })
        let extras = downloadStore.albums
            .filter { !coveredIds.contains($0.albumId) }
            .map { $0.asAlbum() }
        return fromLibrary + extras
    }

    private var displayArtists: [Artist] {
        guard offlineMode.isOffline else { return libraryStore.artists }
        if libraryStore.artists.isEmpty { return downloadStore.artists.map { $0.asArtist() } }
        let fromLibrary = libraryStore.artists.filter { downloadedArtistNames.contains($0.name) }
        let coveredNames = Set(fromLibrary.map { $0.name })
        let extras = downloadStore.artists
            .filter { !coveredNames.contains($0.name) }
            .map { $0.asArtist() }
        return fromLibrary + extras
    }

    private func sortedArtists() -> [Artist] {
        let source = displayArtists
        switch artistSortOption {
        case .alphabetical:
            return source
        case .frequent:
            let counts = Dictionary(
                grouping: libraryStore.albums,
                by: { $0.artistId ?? "" }
            ).mapValues { $0.compactMap { $0.playCount }.reduce(0, +) }
            return source.sorted { (counts[$0.id] ?? 0) > (counts[$1.id] ?? 0) }
        }
    }

    private var mainContent: some View {
        stackContent
        .refreshable {
            let currentSegment = segment
            let currentSort = sortOption.rawValue
            await withCheckedContinuation { cont in
                refreshContinuation = cont
                Task { @MainActor in
                    switch currentSegment {
                    case .albums:    await libraryStore.loadAlbums(sortBy: currentSort)
                    case .artists:   await libraryStore.loadArtists()
                    case .favorites: await libraryStore.loadStarred()
                    }
                    await CloudKitSyncService.shared.syncNow()
                    if let cont = refreshContinuation {
                        refreshContinuation = nil
                        cont.resume()
                    }
                }
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
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button { haptic(); queueAlbum(album) } label: { Image(systemName: "text.badge.plus") }
                                    .tint(accentColor)
                                Button { haptic(); playNextAlbum(album) } label: { Image(systemName: "text.insert") }
                                    .tint(.orange)
                                albumDownloadSwipeButton(album)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if !offlineMode.isOffline {
                                    if enableFavorites {
                                        Button {
                                            haptic(.medium); Task { await libraryStore.toggleStarAlbum(album) }
                                        } label: {
                                            Image(systemName: libraryStore.isAlbumStarred(album) ? "heart.slash" : "heart.fill")
                                        }
                                        .tint(.pink)
                                    }
                                    if enablePlaylists {
                                        Button { addAlbumToPlaylist(album) } label: { Image(systemName: "music.note.list") }
                                            .tint(accentColor)
                                    }
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
                            NavigationLink(destination: ArtistDetailView(artist: artist)) {
                                LibraryArtistGridCell(
                                    artist: artist,
                                    isDownloaded: downloadedArtistBadgeNames.contains(artist.name),
                                    accentColor: accentColor
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu { artistContextMenuItems(artist) }
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
                        Button { navigateToArtist = artist } label: {
                            LibraryArtistListRow(
                                artist: artist,
                                localAlbumCount: albumCountByArtist[artist.id] ?? artist.albumCount ?? 0,
                                isDownloaded: downloadedArtistBadgeNames.contains(artist.name),
                                accentColor: accentColor
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu { artistContextMenuItems(artist) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { haptic(); queueArtist(artist) } label: { Image(systemName: "text.badge.plus") }
                                .tint(accentColor)
                            Button { haptic(); playNextArtist(artist) } label: { Image(systemName: "text.insert") }
                                .tint(.orange)
                            artistDownloadSwipeButton(artist)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            if !offlineMode.isOffline {
                                if enableFavorites {
                                    Button {
                                        haptic(.medium); Task { await libraryStore.toggleStarArtist(artist) }
                                    } label: {
                                        Image(systemName: libraryStore.isArtistStarred(artist) ? "heart.slash" : "heart.fill")
                                    }
                                    .tint(.pink)
                                }
                                if enablePlaylists {
                                    Button {
                                        Task {
                                            let songs = await libraryStore.fetchAllSongs(for: artist)
                                            guard !songs.isEmpty else { return }
                                            NotificationCenter.default.post(name: .addSongsToPlaylist, object: songs.map(\.id))
                                        }
                                    } label: { Image(systemName: "music.note.list") }
                                    .tint(accentColor)
                                }
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

    private var displayStarredSongs: [Song] {
        guard offlineMode.isOffline else { return libraryStore.starredSongs }
        return libraryStore.starredSongs.filter { downloadedSongIds.contains($0.id) }
    }

    private var displayStarredAlbums: [Album] {
        guard offlineMode.isOffline else { return libraryStore.starredAlbums }
        return libraryStore.starredAlbums.filter { downloadedAlbumIds.contains($0.id) }
    }

    private var displayStarredArtists: [Artist] {
        guard offlineMode.isOffline else { return libraryStore.starredArtists }
        return libraryStore.starredArtists.filter { downloadedArtistNames.contains($0.name) }
    }

    @ViewBuilder
    private var favoritesContent: some View {
        let hasSongs   = !displayStarredSongs.isEmpty
        let hasAlbums  = !displayStarredAlbums.isEmpty
        let hasArtists = !displayStarredArtists.isEmpty

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
                        ForEach(displayStarredArtists) { artist in
                            NavigationLink(destination: ArtistDetailView(artist: artist)) {
                                LibraryFavoriteArtistRow(
                                    artist: artist,
                                    isDownloaded: downloadedArtistBadgeNames.contains(artist.name),
                                    accentColor: accentColor
                                )
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button { haptic(); queueArtist(artist) } label: { Image(systemName: "text.badge.plus") }
                                    .tint(accentColor)
                                Button { haptic(); playNextArtist(artist) } label: { Image(systemName: "text.insert") }
                                    .tint(.orange)
                                artistDownloadSwipeButton(artist)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if !offlineMode.isOffline {
                                    Button {
                                        haptic(.medium); Task { await libraryStore.toggleStarArtist(artist) }
                                    } label: { Image(systemName: "heart.slash") }
                                    .tint(.pink)
                                    if enablePlaylists {
                                        Button {
                                            Task {
                                                let songs = await libraryStore.fetchAllSongs(for: artist)
                                                guard !songs.isEmpty else { return }
                                                NotificationCenter.default.post(name: .addSongsToPlaylist, object: songs.map(\.id))
                                            }
                                        } label: { Image(systemName: "music.note.list") }
                                        .tint(accentColor)
                                    }
                                }
                            }
                        }
                    }
                }
                if hasAlbums {
                    Section(String(localized: "albums")) {
                        ForEach(displayStarredAlbums) { album in
                            NavigationLink(destination: AlbumDetailView(album: album)) {
                                LibraryFavoriteAlbumRow(album: album)
                            }
                            .contextMenu {
                                albumContextMenuItems(album)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button { haptic(); queueAlbum(album) } label: { Image(systemName: "text.badge.plus") }
                                    .tint(accentColor)
                                Button { haptic(); playNextAlbum(album) } label: { Image(systemName: "text.insert") }
                                    .tint(.orange)
                                albumDownloadSwipeButton(album)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if !offlineMode.isOffline {
                                    Button {
                                        haptic(.medium); Task { await libraryStore.toggleStarAlbum(album) }
                                    } label: { Image(systemName: "heart.slash") }
                                    .tint(.pink)
                                    if enablePlaylists {
                                        Button { addAlbumToPlaylist(album) } label: { Image(systemName: "music.note.list") }
                                            .tint(accentColor)
                                    }
                                }
                            }
                        }
                    }
                }
                if hasSongs {
                    Section(String(localized: "songs")) {
                        ForEach(displayStarredSongs) { song in
                            Button { player.playSong(song) } label: {
                                LibraryStarredSongRow(song: song)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    haptic(); player.addToQueue(song)
                                    currentToast = ShelveToast(message: String(localized: "added_to_queue"))
                                } label: { Image(systemName: "text.badge.plus") }
                                .tint(accentColor)
                                Button {
                                    haptic(); player.addPlayNext(song)
                                    currentToast = ShelveToast(message: String(localized: "plays_next"))
                                } label: { Image(systemName: "text.insert") }
                                .tint(.orange)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if !offlineMode.isOffline {
                                    Button {
                                        haptic(.medium); Task { await libraryStore.toggleStarSong(song) }
                                    } label: { Image(systemName: "heart.slash") }
                                    .tint(.pink)
                                    if enablePlaylists {
                                        Button {
                                            playlistSongIds = [song.id]
                                            showAddToPlaylist = true
                                        } label: { Image(systemName: "music.note.list") }
                                        .tint(accentColor)
                                    }
                                }
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
    private func albumContextMenuItems(_ album: Album) -> some View {
        Button { playAlbum(album) } label: {
            Label(String(localized: "play"), systemImage: "play.fill")
        }
        Button { shuffleAlbum(album) } label: {
            Label(String(localized: "shuffle"), systemImage: "shuffle")
        }
        if enableInstantMix && !offlineMode.isOffline {
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
        if !offlineMode.isOffline && (enableFavorites || enablePlaylists) {
            Divider()
            if enableFavorites {
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
            if enablePlaylists {
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

    @ViewBuilder
    private func albumDownloadSwipeButton(_ album: Album) -> some View {
        if enableDownloads {
            let status = DownloadStore.shared.albumDownloadStatus(albumId: album.id,
                                                                  totalSongs: album.songCount ?? 0)
            switch status {
            case .none, .partial:
                if !offlineMode.isOffline {
                    Button {
                        haptic(); DownloadStore.shared.enqueueAlbum(album)
                    } label: { Image(systemName: "arrow.down.circle") }
                    .tint(accentColor)
                }
            case .complete:
                Button {
                    haptic(); albumToDeleteDownloads = album
                } label: { Image(systemName: "arrow.down.circle") }
                .tint(.red)
            }
        }
    }

    @ViewBuilder
    private func artistDownloadSwipeButton(_ artist: Artist) -> some View {
        if enableDownloads {
            if downloadedArtistNames.contains(artist.name) {
                Button {
                    haptic(); artistToDeleteDownloads = artist
                } label: { Image(systemName: "arrow.down.circle") }
                .tint(.red)
            } else if !offlineMode.isOffline {
                Button {
                    haptic()
                    let sid = serverStore.activeServer?.stableId ?? ""
                    Task { await DownloadService.shared.enqueueArtist(artist: artist, serverId: sid) }
                } label: { Image(systemName: "arrow.down.circle") }
                .tint(accentColor)
            }
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

        if enableInstantMix && !offlineMode.isOffline {
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

        if !offlineMode.isOffline && (enableFavorites || enablePlaylists) {
            Divider()
            if enableFavorites {
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
            if enablePlaylists {
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
            if downloadedArtistNames.contains(artist.name) {
                Button(role: .destructive) {
                    artistToDeleteDownloads = artist
                } label: {
                    Label(String(localized: "delete_downloads_2"), systemImage: "arrow.down.circle")
                }
            }
        }
    }

}
