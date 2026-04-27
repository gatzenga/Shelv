import SwiftUI

enum AlbumSortOption: String, CaseIterable {
    case alphabetical = "alphabeticalByName"
    case frequent     = "frequent"
    case newest       = "newest"
    case year         = "year"

    var label: String {
        switch self {
        case .alphabetical: return tr("Name", "Name")
        case .frequent:     return tr("Most Played", "Meist gespielt")
        case .newest:       return tr("Recently Added", "Kürzlich hinzugefügt")
        case .year:         return tr("Year", "Jahr")
        }
    }

    var requiresServer: Bool { self == .frequent || self == .newest }
}

enum ArtistSortOption: String, CaseIterable {
    case alphabetical, frequent

    var label: String {
        switch self {
        case .alphabetical: return tr("Name", "Name")
        case .frequent:     return tr("Most Played", "Meist gespielt")
        }
    }

    var requiresServer: Bool { self == .frequent }
}

enum SortDirection: String, CaseIterable {
    case ascending, descending

    var label: String {
        switch self {
        case .ascending:  return tr("Ascending", "Aufsteigend")
        case .descending: return tr("Descending", "Absteigend")
        }
    }
}

enum LibrarySegment: Int {
    case albums, artists, favorites
}

struct LibraryView: View {
    @ObservedObject var libraryStore = LibraryStore.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @EnvironmentObject var serverStore: ServerStore
    private let player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("enablePlaylists") private var enablePlaylists = true
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
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var currentToast: ShelveToast?
    @State private var albumGroups: [(letter: String, items: [Album])] = []
    @State private var artistGroups: [(letter: String, items: [Artist])] = []
    @State private var refreshContinuation: CheckedContinuation<Void, Never>?
    @ObservedObject private var downloadStore = DownloadStore.shared

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 14)]

    private static let sortArticles: [String] = [
        "the ", "an ", "a ",
        "der ", "die ", "das ", "dem ", "den ", "des ",
        "eine ", "einer ", "einem ", "einen ", "ein ",
        "les ", "le ", "la ", "l\u{2019}", "l'",
        "une ", "des ", "un ",
        "los ", "las ", "el ", "una ", "un ",
        "gli ", "uno ", "una ", "il ", "lo ", "un ",
        "umas ", "uma ", "uns ", "um ", "os ", "as ",
        "het ", "een ", "de ",
    ]

    private func sortKey(for name: String) -> String {
        let lower = name.lowercased()
        for article in Self.sortArticles {
            if lower.hasPrefix(article) {
                return String(name.dropFirst(article.count))
            }
        }
        return name
    }

    private func groupByFirstLetter<T>(_ items: [T], name: KeyPath<T, String>) -> [(letter: String, items: [T])] {
        var dict: [String: [T]] = [:]
        for item in items {
            let key = sortKey(for: item[keyPath: name])
            let raw = String(key.prefix(1))
            let base = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).uppercased()
            let letter = (base.first?.isLetter == true) ? String(base.prefix(1)) : "#"
            dict[letter, default: []].append(item)
        }
        let letters = dict.keys.sorted {
            if $0 == "#" { return true }
            if $1 == "#" { return false }
            return $0 < $1
        }
        return letters.map { ($0, dict[$0]!) }
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
                indexedScrollView(
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
                indexedScrollView(
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
        Picker("", selection: $segment) {
            Text(tr("Albums", "Alben")).tag(LibrarySegment.albums)
            Text(tr("Artists", "Künstler")).tag(LibrarySegment.artists)
            if enableFavorites {
                Text(tr("Favorites", "Favoriten")).tag(LibrarySegment.favorites)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        if segment == .albums || segment == .artists {
            ToolbarItem(placement: .topBarTrailing) { sortMenu }
        }
        if segment != .favorites {
            ToolbarItem(placement: .topBarTrailing) { viewToggleButton }
        }
    }

    private var stackBase: some View {
        VStack(spacing: 0) {
            segmentPicker
            segmentContent
        }
        .navigationTitle(offlineMode.isOffline ? tr("Downloads", "Downloads") : tr("Library", "Bibliothek"))
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
        .onChange(of: libraryStore.albums) { _, _ in rebuildGroups() }
        .onChange(of: libraryStore.artists) { _, _ in rebuildGroups() }
        .onChange(of: downloadStore.albums) { _, _ in rebuildGroups() }
        .onChange(of: downloadStore.artists) { _, _ in rebuildGroups() }
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
        // Albums
        let albumsSource = displayAlbums
        if sortOption == .alphabetical {
            albumGroups = groupByFirstLetter(albumsSource, name: \.name)
        } else {
            let items = albumDirection == .descending
                ? albumsSource
                : Array(albumsSource.reversed())
            albumGroups = items.isEmpty ? [] : [(letter: "", items: items)]
        }

        // Artists
        let artistsBase = sortedArtists()
        if artistSortOption == .alphabetical {
            artistGroups = groupByFirstLetter(artistsBase, name: \.name)
        } else {
            let items = artistDirection == .descending
                ? artistsBase
                : Array(artistsBase.reversed())
            artistGroups = items.isEmpty ? [] : [(letter: "", items: items)]
        }
    }

    private var downloadedAlbumIds: Set<String> {
        Set(downloadStore.albums.map { $0.albumId })
    }
    private var downloadedArtistNames: Set<String> {
        Set(downloadStore.artists.map { $0.name })
    }
    private var downloadedSongIds: Set<String> {
        Set(downloadStore.songs.map { $0.id })
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

    private func applyDirection<T>(
        _ groups: [(letter: String, items: [T])],
        direction: SortDirection
    ) -> [(letter: String, items: [T])] {
        switch direction {
        case .ascending:
            return groups
        case .descending:
            return groups.reversed().map { ($0.letter, Array($0.items.reversed())) }
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
                    let bannerTask = Task {
                        try? await Task.sleep(for: .seconds(3))
                        if !Task.isCancelled { offlineMode.notifyServerError() }
                    }
                    switch currentSegment {
                    case .albums:    await libraryStore.loadAlbums(sortBy: currentSort)
                    case .artists:   await libraryStore.loadArtists()
                    case .favorites: await libraryStore.loadStarred()
                    }
                    await CloudKitSyncService.shared.syncNow()
                    bannerTask.cancel()
                    if let cont = refreshContinuation {
                        refreshContinuation = nil
                        cont.resume()
                    }
                }
            }
        }
        .shelveToast($currentToast)
        .onChange(of: libraryStore.errorMessage) { _, msg in
            if let msg {
                errorMessage = msg
                showError = true
                libraryStore.errorMessage = nil
            }
        }
        .alert(tr("Error", "Fehler"), isPresented: $showError, presenting: errorMessage) { _ in
            Button(tr("OK", "OK"), role: .cancel) {}
        } message: { msg in
            Text(msg)
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
            currentToast = ShelveToast(message: tr("Added to Queue", "Zur Warteschlange hinzugefügt"))
        }
    }

    private func playNextAlbum(_ album: Album) {
        Task {
            let songs = await songsForAlbum(album)
            guard !songs.isEmpty else { return }
            player.addPlayNext(songs)
            currentToast = ShelveToast(message: tr("Plays Next", "Wird als nächstes gespielt"))
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
            currentToast = ShelveToast(message: tr("Added to Queue", "Zur Warteschlange hinzugefügt"))
        }
    }

    private func playNextArtist(_ artist: Artist) {
        Task {
            let songs = await libraryStore.fetchAllSongs(for: artist)
            guard !songs.isEmpty else { return }
            player.addPlayNext(songs)
            currentToast = ShelveToast(message: tr("Plays Next", "Wird als nächstes gespielt"))
        }
    }

    private func indexedScrollView<Content: View>(
        letters: [String],
        idPrefix: String,
        scrollID: Binding<String?>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            content()
                .padding(.trailing, letters.isEmpty ? 0 : 16)
        }
        .scrollPosition(id: scrollID)
        .scrollIndicators(.hidden)
        .overlay(alignment: .trailing) {
            if !letters.isEmpty {
                AlphabetIndexBar(letters: letters) { letter in
                    withAnimation(.none) {
                        scrollID.wrappedValue = "\(idPrefix)-\(letter)"
                    }
                }
                .frame(width: 14)
                .padding(.vertical, 16)
                .padding(.trailing, 2)
            }
        }
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
                            letterHeader(group.letter, id: "alb-\(group.letter)")
                        }
                    }
                }
                bottomSpacer
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
                                albumListRowContent(album)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { albumContextMenuItems(album) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button { queueAlbum(album) } label: { Image(systemName: "text.badge.plus") }
                                    .tint(accentColor)
                                Button { playNextAlbum(album) } label: { Image(systemName: "text.insert") }
                                    .tint(.orange)
                                albumDownloadSwipeButton(album)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if !offlineMode.isOffline {
                                    if enableFavorites {
                                        Button {
                                            Task { await libraryStore.toggleStarAlbum(album) }
                                        } label: {
                                            Image(systemName: libraryStore.isAlbumStarred(album) ? "heart.slash" : "heart.fill")
                                        }
                                        .tint(.pink)
                                    }
                                    if enablePlaylists {
                                        Button { addAlbumToPlaylist(album) } label: { Image(systemName: "music.note.list") }
                                            .tint(.purple)
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
                                artistGridCell(artist)
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
                        letterHeader(group.letter, id: "art-\(group.letter)")
                    }
                }
            }
            bottomSpacer
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
                            artistListRow(artist)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { artistContextMenuItems(artist) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { queueArtist(artist) } label: { Image(systemName: "text.badge.plus") }
                                .tint(accentColor)
                            Button { playNextArtist(artist) } label: { Image(systemName: "text.insert") }
                                .tint(.orange)
                            artistDownloadSwipeButton(artist)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            if !offlineMode.isOffline {
                                if enableFavorites {
                                    Button {
                                        Task { await libraryStore.toggleStarArtist(artist) }
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
                                    .tint(.purple)
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

    private func artistGridCell(_ artist: Artist) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                AlbumArtView(coverArtId: artist.coverArt, size: 300, isCircle: true)
                    .aspectRatio(1, contentMode: .fit)
                if downloadedArtistNames.contains(artist.name) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(accentColor, in: Circle())
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .padding(6)
                }
            }
            Text(artist.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }

    private func artistListRow(_ artist: Artist) -> some View {
        HStack(spacing: 12) {
            AlbumArtView(coverArtId: artist.coverArt, size: 150, isCircle: true)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                let localCount = displayAlbums.filter { $0.artistId == artist.id }.count
                if localCount > 0 {
                    Text("\(localCount) \(tr("Albums", "Alben"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if downloadedArtistNames.contains(artist.name) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(accentColor, in: Circle())
            }
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
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
                tr("No Favorites", "Keine Favoriten"),
                systemImage: "heart",
                description: Text(tr(
                    "Star songs, albums and artists to see them here.",
                    "Markiere Titel, Alben und Künstler als Favoriten, um sie hier zu sehen."
                ))
            )
        } else {
            List {
                if hasArtists {
                    Section(tr("Artists", "Künstler")) {
                        ForEach(displayStarredArtists) { artist in
                            NavigationLink(destination: ArtistDetailView(artist: artist)) {
                                favArtistRow(artist)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button { queueArtist(artist) } label: { Image(systemName: "text.badge.plus") }
                                    .tint(accentColor)
                                Button { playNextArtist(artist) } label: { Image(systemName: "text.insert") }
                                    .tint(.orange)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    Task { await libraryStore.toggleStarArtist(artist) }
                                } label: { Image(systemName: "heart.slash") }
                                .tint(.pink)
                            }
                        }
                    }
                }
                if hasAlbums {
                    Section(tr("Albums", "Alben")) {
                        ForEach(displayStarredAlbums) { album in
                            NavigationLink(destination: AlbumDetailView(album: album)) {
                                favAlbumRow(album)
                            }
                            .contextMenu {
                                albumContextMenuItems(album)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button { queueAlbum(album) } label: { Image(systemName: "text.badge.plus") }
                                    .tint(accentColor)
                                Button { playNextAlbum(album) } label: { Image(systemName: "text.insert") }
                                    .tint(.orange)
                                albumDownloadSwipeButton(album)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if !offlineMode.isOffline {
                                    Button {
                                        Task { await libraryStore.toggleStarAlbum(album) }
                                    } label: { Image(systemName: "heart.slash") }
                                    .tint(.pink)
                                    if enablePlaylists {
                                        Button { addAlbumToPlaylist(album) } label: { Image(systemName: "music.note.list") }
                                            .tint(.purple)
                                    }
                                }
                            }
                        }
                    }
                }
                if hasSongs {
                    Section(tr("Songs", "Titel")) {
                        ForEach(displayStarredSongs) { song in
                            Button { player.playSong(song) } label: {
                                starredSongRow(song)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    player.addToQueue(song)
                                    currentToast = ShelveToast(message: tr("Added to Queue", "Zur Warteschlange hinzugefügt"))
                                } label: { Image(systemName: "text.badge.plus") }
                                .tint(accentColor)
                                Button {
                                    player.addPlayNext(song)
                                    currentToast = ShelveToast(message: tr("Plays Next", "Wird als nächstes gespielt"))
                                } label: { Image(systemName: "text.insert") }
                                .tint(.orange)
                                if enableDownloads {
                                    if downloadedSongIds.contains(song.id) {
                                        Button(role: .destructive) {
                                            DownloadStore.shared.deleteSong(song.id)
                                        } label: { DeleteDownloadIcon() }
                                        .tint(.red)
                                    } else if !offlineMode.isOffline {
                                        Button {
                                            DownloadStore.shared.enqueueSongs([song])
                                        } label: { Image(systemName: "arrow.down.circle") }
                                        .tint(accentColor)
                                    }
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if !offlineMode.isOffline {
                                    Button {
                                        Task { await libraryStore.toggleStarSong(song) }
                                    } label: { Image(systemName: "heart.slash") }
                                    .tint(.pink)
                                    if enablePlaylists {
                                        Button {
                                            playlistSongIds = [song.id]
                                            showAddToPlaylist = true
                                        } label: { Image(systemName: "music.note.list") }
                                        .tint(.purple)
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
            Label(tr("Play", "Abspielen"), systemImage: "play.fill")
        }
        Button { shuffleAlbum(album) } label: {
            Label(tr("Shuffle", "Zufällig"), systemImage: "shuffle")
        }
        Divider()
        Button { playNextAlbum(album) } label: {
            Label(tr("Play Next", "Als nächstes"), systemImage: "text.insert")
        }
        Button { queueAlbum(album) } label: {
            Label(tr("Add to Queue", "Zur Warteschlange"), systemImage: "text.badge.plus")
        }
        if !offlineMode.isOffline && (enableFavorites || enablePlaylists) {
            Divider()
            if enableFavorites {
                Button {
                    Task { await libraryStore.toggleStarAlbum(album) }
                } label: {
                    Label(
                        libraryStore.isAlbumStarred(album)
                            ? tr("Unfavorite", "Aus Favoriten entfernen")
                            : tr("Favorite", "Zu Favoriten"),
                        systemImage: libraryStore.isAlbumStarred(album) ? "heart.slash" : "heart"
                    )
                }
            }
            if enablePlaylists {
                Button { addAlbumToPlaylist(album) } label: {
                    Label(tr("Add to Playlist…", "Zur Playlist hinzufügen…"), systemImage: "music.note.list")
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
                        DownloadStore.shared.enqueueAlbum(album)
                    } label: { Image(systemName: "arrow.down.circle") }
                    .tint(accentColor)
                }
            case .complete:
                Button(role: .destructive) {
                    DownloadStore.shared.deleteAlbum(album.id)
                } label: { DeleteDownloadIcon() }
                .tint(.red)
            }
        }
    }

    @ViewBuilder
    private func artistDownloadSwipeButton(_ artist: Artist) -> some View {
        if enableDownloads {
            if downloadedArtistNames.contains(artist.name) {
                Button(role: .destructive) {
                    if let match = downloadStore.artists.first(where: { $0.name == artist.name }) {
                        DownloadStore.shared.deleteArtist(match.artistId)
                    }
                } label: { DeleteDownloadIcon() }
                .tint(.red)
            } else if !offlineMode.isOffline {
                Button {
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
                    Label(tr("Download Album", "Album herunterladen"), systemImage: "arrow.down.circle")
                }
            }
        case .partial:
            if !offlineMode.isOffline {
                Button { DownloadStore.shared.enqueueAlbum(album) } label: {
                    Label(tr("Download Remaining", "Rest herunterladen"), systemImage: "arrow.down.circle")
                }
            }
            Button(role: .destructive) { DownloadStore.shared.deleteAlbum(album.id) } label: { Label { Text(tr("Delete Downloads", "Downloads löschen")) } icon: { DeleteDownloadIcon(tint: .red) } }
        case .complete:
            Button(role: .destructive) { DownloadStore.shared.deleteAlbum(album.id) } label: { Label { Text(tr("Delete Downloads", "Downloads löschen")) } icon: { DeleteDownloadIcon(tint: .red) } }
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
        } label: { Label(tr("Play", "Abspielen"), systemImage: "play.fill") }

        Button {
            Task {
                let songs = await libraryStore.fetchAllSongs(for: artist)
                guard !songs.isEmpty else { return }
                player.playShuffled(songs: songs)
            }
        } label: { Label(tr("Shuffle", "Zufällig"), systemImage: "shuffle") }

        Divider()

        Button { playNextArtist(artist) } label: {
            Label(tr("Play Next", "Als nächstes"), systemImage: "text.insert")
        }
        Button { queueArtist(artist) } label: {
            Label(tr("Add to Queue", "Zur Warteschlange"), systemImage: "text.badge.plus")
        }

        if !offlineMode.isOffline && (enableFavorites || enablePlaylists) {
            Divider()
            if enableFavorites {
                Button {
                    Task { await libraryStore.toggleStarArtist(artist) }
                } label: {
                    Label(
                        libraryStore.isArtistStarred(artist)
                            ? tr("Unfavorite", "Aus Favoriten entfernen")
                            : tr("Favorite", "Zu Favoriten"),
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
                } label: { Label(tr("Add to Playlist…", "Zur Playlist hinzufügen…"), systemImage: "music.note.list") }
            }
        }
        if enableDownloads {
            Divider()
            if !offlineMode.isOffline {
                Button {
                    let sid = serverStore.activeServer?.stableId ?? ""
                    Task { await DownloadService.shared.enqueueArtist(artist: artist, serverId: sid) }
                } label: {
                    Label(tr("Download Artist", "Künstler herunterladen"), systemImage: "arrow.down.circle")
                }
            }
            if downloadedArtistNames.contains(artist.name) {
                Button(role: .destructive) {
                    if let match = downloadStore.artists.first(where: { $0.name == artist.name }) {
                        DownloadStore.shared.deleteArtist(match.artistId)
                    }
                } label: {
                    Label { Text(tr("Delete Downloads", "Downloads löschen")) } icon: { DeleteDownloadIcon(tint: .red) }
                }
            }
        }
    }

    private func albumListRowContent(_ album: Album) -> some View {
        HStack(spacing: 12) {
            AlbumArtView(coverArtId: album.coverArt, size: 150, cornerRadius: 8)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font(.body).lineLimit(1).foregroundStyle(.primary)
                HStack(spacing: 6) {
                    if let artist = album.artist {
                        Text(artist).font(.caption).foregroundStyle(.secondary)
                    }
                    if let year = album.year {
                        Text("·").font(.caption).foregroundStyle(.tertiary)
                        Text(String(year)).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            AlbumDownloadBadge(albumId: album.id)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func favArtistRow(_ artist: Artist) -> some View {
        HStack(spacing: 12) {
            AlbumArtView(coverArtId: artist.coverArt, size: 150, isCircle: true)
                .frame(width: 44, height: 44)
            Text(artist.name).font(.body).lineLimit(1)
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func favAlbumRow(_ album: Album) -> some View {
        HStack(spacing: 12) {
            AlbumArtView(coverArtId: album.coverArt, size: 150, cornerRadius: 8)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name).font(.body).lineLimit(1)
                if let artist = album.artist {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func starredSongRow(_ song: Song) -> some View {
        HStack(spacing: 12) {
            AlbumArtView(coverArtId: song.coverArt, size: 150, cornerRadius: 8)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.body).lineLimit(1).foregroundStyle(.primary)
                if let artist = song.artist {
                    Text(artist).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(song.durationFormatted)
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var viewToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if segment == .albums { albumIsGrid.toggle() }
                else { artistIsGrid.toggle() }
            }
        } label: {
            Image(systemName: (segment == .albums ? albumIsGrid : artistIsGrid)
                  ? "list.bullet"
                  : "square.grid.2x2")
        }
    }

    @ViewBuilder
    private var sortMenu: some View {
        switch segment {
        case .albums:
            albumSortMenu
        case .artists:
            artistSortMenu
        case .favorites:
            EmptyView()
        }
    }

    private var albumSortMenu: some View {
        Menu {
            Picker(selection: Binding(
                get: { sortOptionRaw },
                set: { newValue in
                    sortOptionRaw = newValue
                    Task { await libraryStore.loadAlbums(sortBy: newValue) }
                }
            )) {
                ForEach(AlbumSortOption.allCases.filter { !offlineMode.isOffline || !$0.requiresServer }, id: \.rawValue) { option in
                    Text(option.label).tag(option.rawValue)
                }
            } label: {
                Label(tr("Sort", "Sortieren"), systemImage: "arrow.up.arrow.down")
            }

            if sortOption != .alphabetical {
                Picker(selection: $albumDirectionRaw) {
                    ForEach(SortDirection.allCases, id: \.rawValue) { dir in
                        Text(dir.label).tag(dir.rawValue)
                    }
                } label: {
                    Label(tr("Direction", "Richtung"), systemImage: "arrow.up.and.down")
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }

    private var artistSortMenu: some View {
        Menu {
            Picker(selection: $artistSortRaw) {
                ForEach(ArtistSortOption.allCases.filter { !offlineMode.isOffline || !$0.requiresServer }, id: \.rawValue) { option in
                    Text(option.label).tag(option.rawValue)
                }
            } label: {
                Label(tr("Sort", "Sortieren"), systemImage: "arrow.up.arrow.down")
            }

            if artistSortOption != .alphabetical {
                Picker(selection: $artistDirectionRaw) {
                    ForEach(SortDirection.allCases, id: \.rawValue) { dir in
                        Text(dir.label).tag(dir.rawValue)
                    }
                } label: {
                    Label(tr("Direction", "Richtung"), systemImage: "arrow.up.and.down")
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }

    private func letterHeader(_ letter: String, id: String) -> some View {
        Text(letter)
            .font(.title2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                LinearGradient(
                    stops: [
                        .init(color: Color(UIColor.systemBackground),              location: 0.0),
                        .init(color: Color(UIColor.systemBackground),              location: 0.65),
                        .init(color: Color(UIColor.systemBackground).opacity(0),   location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .id(id)
    }

    private var bottomSpacer: some View {
        PlayerBottomSpacer()
    }
}
