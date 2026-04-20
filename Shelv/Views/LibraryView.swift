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
}

enum ArtistSortOption: String, CaseIterable {
    case alphabetical, frequent

    var label: String {
        switch self {
        case .alphabetical: return tr("Name", "Name")
        case .frequent:     return tr("Most Played", "Meist gespielt")
        }
    }
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
    @EnvironmentObject var libraryStore: LibraryStore
    private let player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("enablePlaylists") private var enablePlaylists = true

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
                && libraryStore.starredSongs.isEmpty
                && libraryStore.starredAlbums.isEmpty
                && libraryStore.starredArtists.isEmpty
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
        .navigationTitle(tr("Library", "Bibliothek"))
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
        if sortOption == .alphabetical {
            // Name immer A-Z (keine Richtung)
            albumGroups = groupByFirstLetter(libraryStore.albums, name: \.name)
        } else {
            // Server liefert non-alphabetische Sortierung bereits absteigend (natural).
            // Direction.desc → as-is; Direction.asc → umdrehen.
            let items = albumDirection == .descending
                ? libraryStore.albums
                : Array(libraryStore.albums.reversed())
            albumGroups = items.isEmpty ? [] : [(letter: "", items: items)]
        }

        // Artists
        let artistsBase = sortedArtists()
        if artistSortOption == .alphabetical {
            // Name immer A-Z
            artistGroups = groupByFirstLetter(artistsBase, name: \.name)
        } else {
            // sortedArtists liefert Most-Played bereits absteigend (natural).
            let items = artistDirection == .descending
                ? artistsBase
                : Array(artistsBase.reversed())
            artistGroups = items.isEmpty ? [] : [(letter: "", items: items)]
        }
    }

    private func sortedArtists() -> [Artist] {
        let base: [Artist]
        switch artistSortOption {
        case .alphabetical:
            base = libraryStore.artists
        case .frequent:
            let counts = Dictionary(
                grouping: libraryStore.albums,
                by: { $0.artistId ?? "" }
            ).mapValues { $0.compactMap { $0.playCount }.reduce(0, +) }
            base = libraryStore.artists.sorted {
                (counts[$0.id] ?? 0) > (counts[$1.id] ?? 0)
            }
        }
        return base
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
            async let reload: Void = {
                switch currentSegment {
                case .albums:    await libraryStore.loadAlbums(sortBy: currentSort)
                case .artists:   await libraryStore.loadArtists()
                case .favorites: await libraryStore.loadStarred()
                }
            }()
            async let sync: Void = CloudKitSyncService.shared.syncNow()
            _ = await (reload, sync)
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

    private func queueAlbum(_ album: Album) {
        Task {
            do {
                let songs = try await libraryStore.fetchAlbumSongs(album)
                guard !songs.isEmpty else { return }
                player.addToQueue(songs)
                currentToast = ShelveToast(message: tr("Added to Queue", "Zur Warteschlange hinzugefügt"))
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func playNextAlbum(_ album: Album) {
        Task {
            do {
                let songs = try await libraryStore.fetchAlbumSongs(album)
                guard !songs.isEmpty else { return }
                player.addPlayNext(songs)
                currentToast = ShelveToast(message: tr("Plays Next", "Wird als nächstes gespielt"))
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func playAlbum(_ album: Album) {
        Task {
            do {
                let songs = try await libraryStore.fetchAlbumSongs(album)
                guard !songs.isEmpty else { return }
                player.play(songs: songs, startIndex: 0)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func shuffleAlbum(_ album: Album) {
        Task {
            do {
                let songs = try await libraryStore.fetchAlbumSongs(album)
                guard !songs.isEmpty else { return }
                player.playShuffled(songs: songs)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func addAlbumToPlaylist(_ album: Album) {
        Task {
            do {
                let songs = try await libraryStore.fetchAlbumSongs(album)
                guard !songs.isEmpty else { return }
                NotificationCenter.default.post(name: .addSongsToPlaylist, object: songs.map(\.id))
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
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
                    scrollID.wrappedValue = "\(idPrefix)-\(letter)"
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
                                    Button { addAlbumToPlaylist(album) } label: { Image(systemName: "music.note.list") }
                                        .tint(.purple)
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
                            proxy.scrollTo("alb-\(letter)", anchor: .top)
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
                        proxy.scrollTo("art-\(letter)", anchor: .top)
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
            AlbumArtView(coverArtId: artist.coverArt, size: 300, isCircle: true)
                .aspectRatio(1, contentMode: .fit)
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
                        ForEach(libraryStore.starredAlbums) { album in
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
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
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
                                    currentToast = ShelveToast(message: tr("Added to Queue", "Zur Warteschlange hinzugefügt"))
                                } label: { Image(systemName: "text.badge.plus") }
                                .tint(accentColor)
                                Button {
                                    player.addPlayNext(song)
                                    currentToast = ShelveToast(message: tr("Plays Next", "Wird als nächstes gespielt"))
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
                Button { addAlbumToPlaylist(album) } label: {
                    Label(tr("Add to Playlist…", "Zur Playlist hinzufügen…"), systemImage: "music.note.list")
                }
            }
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
                        let songs = await libraryStore.fetchAllSongs(for: artist)
                        guard !songs.isEmpty else { return }
                        NotificationCenter.default.post(name: .addSongsToPlaylist, object: songs.map(\.id))
                    }
                } label: { Label(tr("Add to Playlist…", "Zur Playlist hinzufügen…"), systemImage: "music.note.list") }
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
                ForEach(AlbumSortOption.allCases, id: \.rawValue) { option in
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
                ForEach(ArtistSortOption.allCases, id: \.rawValue) { option in
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
