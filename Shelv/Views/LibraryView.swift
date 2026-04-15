import SwiftUI

enum AlbumSortOption: String, CaseIterable {
    case alphabetical = "alphabeticalByName"
    case frequent     = "frequent"
    case newest       = "newest"
    case year         = "year"

    var label: String {
        switch self {
        case .alphabetical: return tr("Name (A–Z)", "Name (A–Z)")
        case .frequent:     return tr("Most Played", "Meist gespielt")
        case .newest:       return tr("Recently Added", "Kürzlich hinzugefügt")
        case .year:         return tr("Year (newest)", "Jahr (neueste zuerst)")
        }
    }
}

enum LibrarySegment: Int {
    case albums, artists, favorites
}

struct LibraryView: View {
    @EnvironmentObject var libraryStore: LibraryStore
    @EnvironmentObject var player: AudioPlayerService
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    @AppStorage("enableFavorites") private var enableFavorites = false
    @AppStorage("enablePlaylists") private var enablePlaylists = false

    @State private var segment: LibrarySegment = .albums
    @State private var showAddToPlaylist = false
    @State private var playlistSongIds: [String] = []
    @State private var sortOption: AlbumSortOption = .alphabetical
    @AppStorage("albumViewIsGrid") private var albumIsGrid = true
    @AppStorage("artistViewIsGrid") private var artistIsGrid = false
    @State private var albumScrollID: String?
    @State private var artistScrollID: String?
    @State private var navigateToAlbum: Album?
    @State private var navigateToArtist: Artist?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 14)]

    private var albumGroups: [(letter: String, items: [Album])] {
        groupByFirstLetter(libraryStore.albums, name: \.name)
    }

    private var artistGroups: [(letter: String, items: [Artist])] {
        groupByFirstLetter(libraryStore.artists, name: \.name)
    }

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

    // Lädt alle Songs eines Künstlers parallel via withTaskGroup
    private func fetchArtistSongs(_ artist: Artist) async -> [Song] {
        guard let artistDetail = try? await SubsonicAPIService.shared.getArtist(id: artist.id),
              let albums = artistDetail.album, !albums.isEmpty else { return [] }
        return await withTaskGroup(of: [Song].self) { group in
            for album in albums {
                group.addTask {
                    guard let detail = try? await SubsonicAPIService.shared.getAlbum(id: album.id),
                          let songs = detail.song else { return [] }
                    return songs
                }
            }
            var all: [Song] = []
            for await albumSongs in group { all.append(contentsOf: albumSongs) }
            return all
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if enableFavorites {
                    Picker("", selection: $segment) {
                        Text(tr("Albums", "Alben")).tag(LibrarySegment.albums)
                        Text(tr("Artists", "Künstler")).tag(LibrarySegment.artists)
                        Text(tr("Favorites", "Favoriten")).tag(LibrarySegment.favorites)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                } else {
                    Picker("", selection: $segment) {
                        Text(tr("Albums", "Alben")).tag(LibrarySegment.albums)
                        Text(tr("Artists", "Künstler")).tag(LibrarySegment.artists)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }

                switch segment {
                case .albums:
                    if libraryStore.isLoadingAlbums && libraryStore.albums.isEmpty {
                        Spacer(); ProgressView(); Spacer()
                    } else if albumIsGrid {
                        indexedScrollView(
                            letters: albumGroups.map(\.letter),
                            idPrefix: "alb",
                            scrollID: $albumScrollID
                        ) { albumContent }
                    } else {
                        albumContent
                    }
                case .artists:
                    if libraryStore.isLoadingArtists && libraryStore.artists.isEmpty {
                        Spacer(); ProgressView(); Spacer()
                    } else if artistIsGrid {
                        indexedScrollView(
                            letters: artistGroups.map(\.letter),
                            idPrefix: "art",
                            scrollID: $artistScrollID
                        ) { artistGridContent }
                    } else {
                        artistListContent
                    }
                case .favorites:
                    if libraryStore.isLoadingStarred && libraryStore.starredSongs.isEmpty && libraryStore.starredAlbums.isEmpty && libraryStore.starredArtists.isEmpty {
                        Spacer(); ProgressView(); Spacer()
                    } else {
                        favoritesContent
                    }
                }
            }
            .navigationTitle(tr("Library", "Bibliothek"))
            .toolbar {
                if segment == .albums {
                    ToolbarItem(placement: .topBarTrailing) {
                        sortMenu
                    }
                }
                if segment != .favorites {
                    ToolbarItem(placement: .topBarTrailing) {
                        viewToggleButton
                    }
                }
            }
            .task {
                switch segment {
                case .albums:
                    if libraryStore.albums.isEmpty { await libraryStore.loadAlbums() }
                case .artists:
                    if libraryStore.artists.isEmpty { await libraryStore.loadArtists() }
                case .favorites:
                    await libraryStore.loadStarred()
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
            .onChange(of: enableFavorites) { _, enabled in
                if !enabled && segment == .favorites {
                    segment = .albums
                }
            }
            .refreshable {
                switch segment {
                case .albums:   await libraryStore.loadAlbums(sortBy: sortOption.rawValue)
                case .artists:  await libraryStore.loadArtists()
                case .favorites: await libraryStore.loadStarred()
                }
            }
            .sheet(isPresented: $showAddToPlaylist) {
                AddToPlaylistSheet(songIds: playlistSongIds)
                    .environmentObject(libraryStore)
                    .tint(accentColor)
            }
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
                    scrollID.wrappedValue = "\(idPrefix)-\(letter)"
                }
                .frame(width: 14)
                .padding(.vertical, 16)
                .padding(.trailing, 2)
            }
        }
    }

    // MARK: - Album Content

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
                        .padding(.bottom, 14)
                    } header: {
                        letterHeader(group.letter, id: "alb-\(group.letter)")
                    }
                }
                bottomSpacer
            }
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(albumGroups, id: \.letter) { group in
                        Text(group.letter)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .id("alb-\(group.letter)")
                            .listRowInsets(EdgeInsets(top: 20, leading: 16, bottom: 4, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        ForEach(group.items) { album in
                            Button { navigateToAlbum = album } label: {
                                albumListRowContent(album)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { albumContextMenuItems(album) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    Task {
                                        guard let detail = try? await SubsonicAPIService.shared.getAlbum(id: album.id),
                                              let songs = detail.song, !songs.isEmpty else { return }
                                        await MainActor.run { player.addToQueue(songs) }
                                    }
                                } label: { Image(systemName: "text.badge.plus") }
                                .tint(accentColor)
                                Button {
                                    Task {
                                        guard let detail = try? await SubsonicAPIService.shared.getAlbum(id: album.id),
                                              let songs = detail.song, !songs.isEmpty else { return }
                                        await MainActor.run { player.addPlayNext(songs) }
                                    }
                                } label: { Image(systemName: "text.insert") }
                                .tint(.orange)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if enableFavorites {
                                    Button {
                                        Task { await libraryStore.toggleStarAlbum(album) }
                                    } label: {
                                        Image(systemName: libraryStore.isAlbumStarred(album) ? "heart.slash" : "heart.fill")
                                    }
                                    .tint(.pink)
                                }
                                if enablePlaylists {
                                    Button {
                                        Task {
                                            guard let detail = try? await SubsonicAPIService.shared.getAlbum(id: album.id),
                                                  let songs = detail.song, !songs.isEmpty else { return }
                                            let ids = songs.map(\.id)
                                            await MainActor.run {
                                                NotificationCenter.default.post(name: .addSongsToPlaylist, object: ids)
                                            }
                                        }
                                    } label: { Image(systemName: "music.note.list") }
                                    .tint(.purple)
                                }
                            }
                        }
                    }
                    Color.clear
                        .frame(height: player.currentSong != nil ? 90 : 16)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollIndicators(.hidden)
                .contentMargins(.trailing, 20, for: .scrollContent)
                .overlay(alignment: .trailing) {
                    AlphabetIndexBar(letters: albumGroups.map(\.letter)) { letter in
                        proxy.scrollTo("alb-\(letter)", anchor: .top)
                    }
                    .frame(width: 14)
                    .padding(.vertical, 16)
                    .padding(.trailing, 2)
                }
                .navigationDestination(item: $navigateToAlbum) { album in
                    AlbumDetailView(album: album)
                }
            }
        }
    }

    // MARK: - Artist Content

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
                    .padding(.bottom, 14)
                } header: {
                    letterHeader(group.letter, id: "art-\(group.letter)")
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
                    Text(group.letter)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .id("art-\(group.letter)")
                        .listRowInsets(EdgeInsets(top: 20, leading: 16, bottom: 4, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    ForEach(group.items) { artist in
                        Button { navigateToArtist = artist } label: {
                            artistListRow(artist)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { artistContextMenuItems(artist) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                Task {
                                    let songs = await fetchArtistSongs(artist)
                                    guard !songs.isEmpty else { return }
                                    await MainActor.run { player.addToQueue(songs) }
                                }
                            } label: { Image(systemName: "text.badge.plus") }
                            .tint(accentColor)
                            Button {
                                Task {
                                    let songs = await fetchArtistSongs(artist)
                                    guard !songs.isEmpty else { return }
                                    await MainActor.run { player.addPlayNext(songs) }
                                }
                            } label: { Image(systemName: "text.insert") }
                            .tint(.orange)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
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
                                        let songs = await fetchArtistSongs(artist)
                                        guard !songs.isEmpty else { return }
                                        let ids = songs.map(\.id)
                                        await MainActor.run {
                                            NotificationCenter.default.post(name: .addSongsToPlaylist, object: ids)
                                        }
                                    }
                                } label: { Image(systemName: "music.note.list") }
                                .tint(.purple)
                            }
                        }
                    }
                }
                Color.clear
                    .frame(height: player.currentSong != nil ? 90 : 16)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollIndicators(.hidden)
            .contentMargins(.trailing, 20, for: .scrollContent)
            .overlay(alignment: .trailing) {
                AlphabetIndexBar(letters: artistGroups.map(\.letter)) { letter in
                    proxy.scrollTo("art-\(letter)", anchor: .top)
                }
                .frame(width: 14)
                .padding(.vertical, 16)
                .padding(.trailing, 2)
            }
            .navigationDestination(item: $navigateToArtist) { artist in
                ArtistDetailView(artist: artist)
            }
        }
    }

    private func artistGridCell(_ artist: Artist) -> some View {
        VStack(spacing: 8) {
            AlbumArtView(coverArtId: artist.coverArt, size: 300, cornerRadius: 999)
                .aspectRatio(1, contentMode: .fit)
            Text(artist.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }

    private func artistListRow(_ artist: Artist) -> some View {
        HStack(spacing: 12) {
            AlbumArtView(coverArtId: artist.coverArt, size: 150, cornerRadius: 999)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if let count = artist.albumCount {
                    Text("\(count) \(tr("Albums", "Alben"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .padding(.vertical, 9)
    }

    // MARK: - Favorites Content

    @ViewBuilder
    private var favoritesContent: some View {
        let hasSongs   = !libraryStore.starredSongs.isEmpty
        let hasAlbums  = !libraryStore.starredAlbums.isEmpty
        let hasArtists = !libraryStore.starredArtists.isEmpty

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
                        ForEach(libraryStore.starredArtists) { artist in
                            NavigationLink(destination: ArtistDetailView(artist: artist)) {
                                favArtistRow(artist)
                            }
                        }
                    }
                }
                if hasAlbums {
                    Section(tr("Albums", "Alben")) {
                        ForEach(libraryStore.starredAlbums) { album in
                            NavigationLink(destination: AlbumDetailView(album: album)) {
                                favAlbumRow(album)
                            }
                            .contextMenu {
                                albumContextMenuItems(album)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    Task {
                                        guard let detail = try? await SubsonicAPIService.shared.getAlbum(id: album.id),
                                              let songs = detail.song, !songs.isEmpty else { return }
                                        await MainActor.run { player.addToQueue(songs) }
                                    }
                                } label: { Image(systemName: "text.badge.plus") }
                                .tint(accentColor)
                                Button {
                                    Task {
                                        guard let detail = try? await SubsonicAPIService.shared.getAlbum(id: album.id),
                                              let songs = detail.song, !songs.isEmpty else { return }
                                        await MainActor.run { player.addPlayNext(songs) }
                                    }
                                } label: { Image(systemName: "text.insert") }
                                .tint(.orange)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    Task { await libraryStore.toggleStarAlbum(album) }
                                } label: { Image(systemName: "heart.slash") }
                                .tint(.pink)
                                if enablePlaylists {
                                    Button {
                                        Task {
                                            guard let detail = try? await SubsonicAPIService.shared.getAlbum(id: album.id),
                                                  let songs = detail.song, !songs.isEmpty else { return }
                                            let ids = songs.map(\.id)
                                            await MainActor.run {
                                                NotificationCenter.default.post(name: .addSongsToPlaylist, object: ids)
                                            }
                                        }
                                    } label: { Image(systemName: "music.note.list") }
                                    .tint(.purple)
                                }
                            }
                        }
                    }
                }
                if hasSongs {
                    Section(tr("Songs", "Titel")) {
                        ForEach(libraryStore.starredSongs) { song in
                            Button { player.playSong(song) } label: {
                                starredSongRow(song)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    player.addToQueue(song)
                                } label: { Image(systemName: "text.badge.plus") }
                                .tint(accentColor)
                                Button {
                                    player.addPlayNext(song)
                                } label: { Image(systemName: "text.insert") }
                                .tint(.orange)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
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
                Color.clear
                    .frame(height: player.currentSong != nil ? 90 : 16)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Context Menus

    @ViewBuilder
    private func albumContextMenuItems(_ album: Album) -> some View {
        Button {
            Task {
                guard let detail = try? await SubsonicAPIService.shared.getAlbum(id: album.id),
                      let songs = detail.song, !songs.isEmpty else { return }
                await MainActor.run { player.play(songs: songs, startIndex: 0) }
            }
        } label: { Label(tr("Play", "Abspielen"), systemImage: "play.fill") }

        Button {
            Task {
                guard let detail = try? await SubsonicAPIService.shared.getAlbum(id: album.id),
                      let songs = detail.song, !songs.isEmpty else { return }
                await MainActor.run { player.playShuffled(songs: songs) }
            }
        } label: { Label(tr("Shuffle", "Zufällig"), systemImage: "shuffle") }

        Divider()

        Button {
            Task {
                guard let detail = try? await SubsonicAPIService.shared.getAlbum(id: album.id),
                      let songs = detail.song, !songs.isEmpty else { return }
                await MainActor.run { player.addPlayNext(songs) }
            }
        } label: { Label(tr("Play Next", "Als nächstes"), systemImage: "text.insert") }

        Button {
            Task {
                guard let detail = try? await SubsonicAPIService.shared.getAlbum(id: album.id),
                      let songs = detail.song, !songs.isEmpty else { return }
                await MainActor.run { player.addToQueue(songs) }
            }
        } label: { Label(tr("Add to Queue", "Zur Warteschlange"), systemImage: "text.badge.plus") }

        if enableFavorites || enablePlaylists {
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
                Button {
                    Task {
                        guard let detail = try? await SubsonicAPIService.shared.getAlbum(id: album.id),
                              let songs = detail.song, !songs.isEmpty else { return }
                        let ids = songs.map(\.id)
                        await MainActor.run {
                            NotificationCenter.default.post(name: .addSongsToPlaylist, object: ids)
                        }
                    }
                } label: { Label(tr("Add to Playlist…", "Zur Playlist hinzufügen…"), systemImage: "music.note.list") }
            }
        }
    }

    @ViewBuilder
    private func artistContextMenuItems(_ artist: Artist) -> some View {
        Button {
            Task {
                let songs = await fetchArtistSongs(artist)
                guard !songs.isEmpty else { return }
                await MainActor.run { player.play(songs: songs, startIndex: 0) }
            }
        } label: { Label(tr("Play", "Abspielen"), systemImage: "play.fill") }

        Button {
            Task {
                let songs = await fetchArtistSongs(artist)
                guard !songs.isEmpty else { return }
                await MainActor.run { player.playShuffled(songs: songs) }
            }
        } label: { Label(tr("Shuffle", "Zufällig"), systemImage: "shuffle") }

        Divider()

        Button {
            Task {
                let songs = await fetchArtistSongs(artist)
                guard !songs.isEmpty else { return }
                await MainActor.run { player.addPlayNext(songs) }
            }
        } label: { Label(tr("Play Next", "Als nächstes"), systemImage: "text.insert") }

        Button {
            Task {
                let songs = await fetchArtistSongs(artist)
                guard !songs.isEmpty else { return }
                await MainActor.run { player.addToQueue(songs) }
            }
        } label: { Label(tr("Add to Queue", "Zur Warteschlange"), systemImage: "text.badge.plus") }

        if enableFavorites || enablePlaylists {
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
                        let songs = await fetchArtistSongs(artist)
                        guard !songs.isEmpty else { return }
                        let ids = songs.map(\.id)
                        await MainActor.run {
                            NotificationCenter.default.post(name: .addSongsToPlaylist, object: ids)
                        }
                    }
                } label: { Label(tr("Add to Playlist…", "Zur Playlist hinzufügen…"), systemImage: "music.note.list") }
            }
        }
    }

    // MARK: - Row Helpers

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
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func favArtistRow(_ artist: Artist) -> some View {
        HStack(spacing: 12) {
            AlbumArtView(coverArtId: artist.coverArt, size: 150, cornerRadius: 999)
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

    // MARK: - Toolbar Items

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

    private var sortMenu: some View {
        Menu {
            ForEach(AlbumSortOption.allCases, id: \.rawValue) { option in
                Button {
                    sortOption = option
                    Task { await libraryStore.loadAlbums(sortBy: option.rawValue) }
                } label: {
                    Label(option.label, systemImage: sortOption == option ? "checkmark" : "")
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }

    // MARK: - Shared Helpers

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
        Color.clear.frame(height: player.currentSong != nil ? 90 : 16)
    }
}
