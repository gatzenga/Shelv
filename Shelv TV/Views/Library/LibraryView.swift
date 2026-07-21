import SwiftUI

enum AlbumSortOption: String, CaseIterable {
    case alphabetical = "alphabeticalByName"
    case frequent     = "frequent"
    case newest       = "newest"
    case year         = "year"

    var label: String {
        switch self {
        case .alphabetical: return String(localized: "name")
        case .frequent:     return String(localized: "most_played")
        case .newest:       return String(localized: "recently_added")
        case .year:         return String(localized: "year")
        }
    }

    nonisolated var allowsDirection: Bool { self != .alphabetical }
}

enum SortDirection: String, CaseIterable {
    case ascending, descending
    var icon: String { self == .ascending ? "arrow.up" : "arrow.down" }
}

struct LibraryView: View {
    @ObservedObject var store = LibraryStore.shared
    @AppStorage(PersonalizationPreferenceKey.showFavoritesInLibrary) private var showFavoritesInLibrary = true
    @AppStorage(PersonalizationPreferenceKey.showGenreFilter) private var showGenreFilter = true
    @AppStorage("albumSortOption") private var albumSortRaw = "alphabeticalByName"
    @AppStorage("albumSortDirection") private var albumDirRaw = "ascending"
    @AppStorage(PersonalizationPreferenceKey.albumGenreFilter) private var albumGenreFilterRaw = ""
    @AppStorage("artistSortDirection") private var artistDirRaw = "ascending"
    @AppStorage("albumViewIsGrid") private var albumIsGrid = true
    @AppStorage("artistViewIsGrid") private var artistIsGrid = false

    @State private var segment = 0   // 0 = Albums, 1 = Artists, 2 = Favorites
    @State private var path = NavigationPath()
    @State private var derivedAlbums: [Album] = []
    @State private var albumGenreOptions: [AlbumGenreFilterOption] = []
    @State private var derivedArtists: [Artist] = []
    @State private var derivedAlbumCountByArtist: [String: Int] = [:]
    @State private var derivedRebuildTask: Task<Void, Never>?
    @State private var showAlbumGenrePicker = false
    private let player = AudioPlayerService.shared

    private var albumSort: AlbumSortOption { AlbumSortOption(rawValue: albumSortRaw) ?? .alphabetical }
    private var albumDir: SortDirection { SortDirection(rawValue: albumDirRaw) ?? .ascending }
    private var artistDir: SortDirection { SortDirection(rawValue: artistDirRaw) ?? .ascending }

    /// "year" wird client-seitig sortiert → der Server liefert dafür die alphabetische Liste.
    private var albumServerType: String { albumSort == .year ? "alphabeticalByName" : albumSort.rawValue }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    Text(String(localized: "albums")).tag(0)
                    Text(String(localized: "artists")).tag(1)
                    if showFavoritesInLibrary { Text(String(localized: "favorites")).tag(2) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 700)
                .padding(.top, 40)
                .padding(.bottom, 16)
                .focusSection()

                if segment == 0 { albumControls }
                else if segment == 1 { artistControls }

                // Eigene Fokus-Sektion → von Picker/Steuerung springt „runter" zuverlässig
                // in die Liste, auch wenn kein Element direkt darunter sitzt (z. B. Favoriten).
                Group {
                    switch segment {
                    case 0:
                        if albumIsGrid {
                            coverGrid(derivedAlbums, indexLabel: albumIndexLabel) { AlbumCard(album: $0) }
                        }
                        else { albumList(derivedAlbums) }
                    case 1:
                        if artistIsGrid {
                            coverGrid(derivedArtists, indexLabel: artistIndexLabel) { ArtistCard(artist: $0) }
                        }
                        else { artistList(derivedArtists, counts: derivedAlbumCountByArtist) }
                    default:
                        favoritesList
                    }
                }
                .focusSection()
            }
            .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
            .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0) }
            .task(id: store.reloadID) { await store.loadAlbums(sortBy: albumServerType) }
            .task(id: store.reloadID) { await store.loadArtists() }
            .task(id: "\(store.reloadID)|\(showFavoritesInLibrary)") { if showFavoritesInLibrary { await store.loadStarred() } }
            .onAppear { rebuildDerivedLibraryState() }
            .onReceive(store.$albums) { _ in Task { @MainActor in rebuildDerivedLibraryState() } }
            .onReceive(store.$artists) { _ in Task { @MainActor in rebuildDerivedLibraryState() } }
            .onChange(of: albumSortRaw) { _, _ in rebuildDerivedLibraryState() }
            .onChange(of: albumDirRaw) { _, _ in rebuildDerivedLibraryState() }
            .onChange(of: albumGenreFilterRaw) { _, _ in rebuildDerivedLibraryState() }
            .onChange(of: showGenreFilter) { _, enabled in
                if !enabled { albumGenreFilterRaw = "" }
                rebuildDerivedLibraryState()
            }
            .onChange(of: artistDirRaw) { _, _ in rebuildDerivedLibraryState() }
            .onChange(of: showFavoritesInLibrary) { _, enabled in
                if !enabled && segment == 2 { segment = 0 }
            }
            .onDisappear {
                derivedRebuildTask?.cancel()
                derivedRebuildTask = nil
            }
        }
    }

    private func rebuildDerivedLibraryState() {
        derivedRebuildTask?.cancel()

        let albums = store.albums
        let artists = store.artists
        let sort = albumSort
        let albumDirection = albumDir
        let selectedAlbumGenre = showGenreFilter
            ? AlbumGenreFilterOption.normalizedGenre(albumGenreFilterRaw)
            : nil
        let artistDirection = artistDir

        derivedRebuildTask = Task.detached(priority: .userInitiated) {
            let nextGenreOptions = AlbumGenreFilterOption.options(from: albums)
            let effectiveSelectedAlbumGenre = AlbumGenreFilterOption.selectedGenre(
                selectedAlbumGenre,
                in: nextGenreOptions
            )
            let filteredAlbums: [Album]
            if let effectiveSelectedAlbumGenre {
                filteredAlbums = albums.filter {
                    AlbumGenreFilterOption.matches($0, selectedGenre: effectiveSelectedAlbumGenre)
                }
            } else {
                filteredAlbums = albums
            }

            let nextAlbums: [Album] = {
                let cacheSort = LibraryRepository.albumCacheSort(for: sort.rawValue)
                let requestedDirection: LibraryDatabaseSortDirection
                if sort.allowsDirection {
                    requestedDirection = albumDirection == .ascending ? .ascending : .descending
                } else {
                    requestedDirection = .ascending
                }
                return LibraryRepository.locallySortedAlbums(
                    filteredAlbums,
                    sort: cacheSort.0,
                    direction: requestedDirection
                )
            }()

            let nextArtists = LibraryRepository.locallySortedArtists(
                artists,
                direction: artistDirection == .ascending ? .ascending : .descending
            )

            let nextAlbumCountByArtist: [String: Int] = {
                var counts: [String: Int] = [:]
                counts.reserveCapacity(artists.count)
                for album in albums {
                    guard let artistId = album.artistId, !artistId.isEmpty else { continue }
                    counts[artistId, default: 0] += 1
                }
                return counts
            }()

            guard !Task.isCancelled else { return }
            await MainActor.run {
                derivedAlbums = nextAlbums
                albumGenreOptions = nextGenreOptions
                derivedArtists = nextArtists
                derivedAlbumCountByArtist = nextAlbumCountByArtist
            }
        }
    }

    // MARK: - Sortier-/Ansicht-Steuerung

    private var albumControls: some View {
        HStack(spacing: 24) {
            if showGenreFilter {
                albumGenreButton
            }
            Menu {
                ForEach(AlbumSortOption.allCases, id: \.rawValue) { opt in
                    Button { albumSortRaw = opt.rawValue } label: {
                        if albumSort == opt { Label(opt.label, systemImage: "checkmark") }
                        else { Text(opt.label) }
                    }
                }
            } label: {
                Label("\(String(localized: "sort")): \(albumSort.label)", systemImage: "arrow.up.arrow.down")
            }
            if albumSort.allowsDirection {
                Button { albumDirRaw = albumDir == .ascending ? "descending" : "ascending" } label: {
                    Image(systemName: albumDir.icon)
                }
            }
            Button { albumIsGrid.toggle() } label: {
                Image(systemName: albumIsGrid ? "list.bullet" : "square.grid.2x2")
            }
        }
        .buttonStyle(.bordered)
        .padding(.bottom, 16)
        .focusSection()
    }

    private var albumGenreButtonTitle: String {
        let selectedGenre = AlbumGenreFilterOption.selectedGenre(albumGenreFilterRaw, in: albumGenreOptions)
            ?? String(localized: "all_genres")
        return "\(String(localized: "genre")): \(selectedGenre)"
    }

    private var albumGenreButton: some View {
        Button {
            showAlbumGenrePicker = true
        } label: {
            Label(albumGenreButtonTitle, systemImage: "guitars")
        }
        .disabled(albumGenreOptions.isEmpty)
        .confirmationDialog(String(localized: "genre"), isPresented: $showAlbumGenrePicker, titleVisibility: .visible) {
            Button {
                albumGenreFilterRaw = ""
            } label: {
                if AlbumGenreFilterOption.selectedGenre(albumGenreFilterRaw, in: albumGenreOptions) == nil {
                    Label(String(localized: "all_genres"), systemImage: "checkmark")
                } else {
                    Text(String(localized: "all_genres"))
                }
            }

            ForEach(albumGenreOptions) { option in
                Button {
                    albumGenreFilterRaw = option.name
                } label: {
                    if AlbumGenreFilterOption.normalizedKey(albumGenreFilterRaw) == option.id {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }

            Button(String(localized: "cancel"), role: .cancel) {}
        }
    }

    private var artistControls: some View {
        HStack(spacing: 24) {
            Button { artistDirRaw = artistDir == .ascending ? "descending" : "ascending" } label: {
                Image(systemName: artistDir.icon)
            }
            Button { artistIsGrid.toggle() } label: {
                Image(systemName: artistIsGrid ? "list.bullet" : "square.grid.2x2")
            }
        }
        .buttonStyle(.bordered)
        .padding(.bottom, 16)
        .focusSection()
    }

    // MARK: - Cover-Grid (Alben / Künstler)

    private func coverGrid<T: Identifiable, Card: View>(
        _ items: [T],
        indexLabel: @escaping (T) -> String?,
        @ViewBuilder card: @escaping (T) -> Card
    ) -> some View {
        let groups = tvRowAlignedSectionIndexGroups(
            items,
            columnCount: coverGridColumns.count,
            indexLabel: indexLabel
        )

        return ScrollView {
            LazyVGrid(columns: coverGridColumns, alignment: .leading, spacing: 50) {
                ForEach(groups) { group in
                    tvIndexedSection(group.label) {
                        ForEach(group.items) { card($0) }
                    }
                }
            }
            .padding(.horizontal, 50)
            .padding(.top, 30)
            .padding(.bottom, 50)
        }
    }

    // MARK: - Listen-Ansicht (Alben / Künstler)

    private func albumList(_ albums: [Album]) -> some View {
        let groups = tvSectionIndexGroups(albums, indexLabel: albumIndexLabel)

        return ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(groups) { group in
                    tvIndexedSection(group.label) {
                        ForEach(group.items) { album in
                            AlbumListRow(album: album) { path.append(album) }
                        }
                    }
                }
            }
            .padding(.vertical, 24)
        }
        .scrollIndicators(.hidden)
    }

    private func albumIndexLabel(_ album: Album) -> String? {
        switch albumSort {
        case .alphabetical:
            return LibrarySortKey.sectionLetter(
                displayName: album.name,
                explicitSortName: album.sortName
            )
        case .frequent, .newest, .year:
            return nil
        }
    }

    private func artistIndexLabel(_ artist: Artist) -> String? {
        LibrarySortKey.sectionLetter(
            displayName: artist.name,
            explicitSortName: artist.sortName
        )
    }

    private func artistList(_ artists: [Artist], counts: [String: Int]) -> some View {
        let groups = tvSectionIndexGroups(artists, indexLabel: artistIndexLabel)

        return ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(groups) { group in
                    tvIndexedSection(group.label) {
                        ForEach(group.items) { artist in
                            ArtistListRow(artist: artist,
                                          albumCount: counts[artist.id] ?? artist.albumCount ?? 0) {
                                path.append(artist)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 24)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Favoriten

    @ViewBuilder
    private var favoritesList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !store.favoriteAlbums.isEmpty {
                    Text(String(localized: "albums")).font(.title3).bold().padding(.horizontal, 50)
                    cardRow {
                        ForEach(Array(store.favoriteAlbums.prefix(FavoritePresentation.previewLimit))) {
                            AlbumCard(album: $0)
                        }
                    }
                    .focusSection()
                    if store.favoriteAlbums.count > FavoritePresentation.previewLimit {
                        showAllFavoritesLink(count: store.favoriteAlbums.count) {
                            favoriteAlbumsPage
                        }
                    }
                }

                if !store.favoriteSongs.isEmpty {
                    Text(String(localized: "songs")).font(.title3).bold().padding(.horizontal, 50)
                    LazyVStack(spacing: 4) {
                        favoriteSongRows(Array(store.favoriteSongs.prefix(FavoritePresentation.previewLimit)))
                    }
                    .focusSection()
                    if store.favoriteSongs.count > FavoritePresentation.previewLimit {
                        showAllFavoritesLink(count: store.favoriteSongs.count) {
                            favoriteSongsPage
                        }
                    }
                }

                if !store.favoriteArtists.isEmpty {
                    Text(String(localized: "artists")).font(.title3).bold().padding(.horizontal, 50)
                    cardRow {
                        ForEach(Array(store.favoriteArtists.prefix(FavoritePresentation.previewLimit))) {
                            ArtistCard(artist: $0)
                        }
                    }
                    .focusSection()
                    if store.favoriteArtists.count > FavoritePresentation.previewLimit {
                        showAllFavoritesLink(count: store.favoriteArtists.count) {
                            favoriteArtistsPage
                        }
                    }
                }
            }
            .padding(.vertical, 24)
        }
    }

    @ViewBuilder
    private func favoriteSongRows(_ songs: [Song]) -> some View {
        ForEach(songs) { song in
            let index = store.favoriteSongs.firstIndex(where: { $0.id == song.id }) ?? 0
            DetailSongRow(song: song, number: index, showArtwork: true) {
                player.play(songs: store.favoriteSongs, startIndex: index)
            }
        }
    }

    private func showAllFavoritesLink<Destination: View>(
        count: Int,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        HStack {
            NavigationLink(destination: destination()) {
                Text(String(format: String(localized: "show_all_count_format"), count))
                    .font(.headline)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 50)
        .focusSection()
    }

    private var favoriteAlbumsPage: some View {
        ScrollView {
            LazyVGrid(columns: coverGridColumns, alignment: .leading, spacing: 50) {
                ForEach(store.favoriteAlbums) { album in
                    AlbumCard(album: album)
                }
            }
            .padding(.horizontal, 50)
            .padding(.vertical, 30)
        }
        .navigationTitle(String(localized: "favorite_albums"))
    }

    private var favoriteSongsPage: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                favoriteSongRows(store.favoriteSongs)
            }
            .padding(.vertical, 24)
        }
        .navigationTitle(String(localized: "favorite_songs"))
    }

    private var favoriteArtistsPage: some View {
        ScrollView {
            LazyVGrid(columns: coverGridColumns, alignment: .leading, spacing: 50) {
                ForEach(store.favoriteArtists) { artist in
                    ArtistCard(artist: artist)
                }
            }
            .padding(.horizontal, 50)
            .padding(.vertical, 30)
        }
        .navigationTitle(String(localized: "favorite_artists"))
    }

    private func cardRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 40) { content() }
                .padding(.horizontal, 50)
                .padding(.vertical, 20)
        }
        .scrollClipDisabled()
    }
}

struct TVSectionIndexGroup<Item>: Identifiable {
    let id: Int
    let label: String
    var items: [Item]
}

func tvSectionIndexGroups<Item>(
    _ items: [Item],
    chunkSize: Int = 20,
    indexLabel: (Item) -> String?
) -> [TVSectionIndexGroup<Item>] {
    guard !items.isEmpty else { return [] }

    var groups: [TVSectionIndexGroup<Item>] = []

    for item in items {
        if let label = indexLabel(item) {
            if groups.last?.label == label {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append(TVSectionIndexGroup(id: groups.count, label: label, items: [item]))
            }
        } else if (groups.last?.items.count ?? chunkSize) >= chunkSize {
            groups.append(TVSectionIndexGroup(id: groups.count, label: "•", items: [item]))
        } else {
            groups[groups.count - 1].items.append(item)
        }
    }

    return groups
}

func tvRowAlignedSectionIndexGroups<Item>(
    _ items: [Item],
    columnCount: Int,
    rowsPerChunk: Int = 4,
    indexLabel: (Item) -> String?
) -> [TVSectionIndexGroup<Item>] {
    guard !items.isEmpty, columnCount > 0 else { return [] }

    let labels = items.map(indexLabel)
    let hasIndexLabels = labels.contains { $0 != nil }
    let chunkSize = columnCount * max(rowsPerChunk, 1)
    var boundaries: [(offset: Int, label: String)] = [(0, labels[0] ?? "•")]

    if hasIndexLabels {
        for offset in labels.indices.dropFirst() where labels[offset] != labels[offset - 1] {
            let rowStart = offset - (offset % columnCount)
            let label = labels[offset] ?? "•"

            if boundaries[boundaries.count - 1].offset == rowStart {
                boundaries[boundaries.count - 1].label = label
            } else {
                boundaries.append((rowStart, label))
            }
        }
    } else {
        for offset in stride(from: chunkSize, to: items.count, by: chunkSize) {
            boundaries.append((offset, "•"))
        }
    }

    return boundaries.indices.map { index in
        let start = boundaries[index].offset
        let end = index + 1 < boundaries.count ? boundaries[index + 1].offset : items.count
        return TVSectionIndexGroup(
            id: index,
            label: boundaries[index].label,
            items: Array(items[start..<end])
        )
    }
}

@ViewBuilder
func tvIndexedSection<Content: View>(
    _ label: String,
    @ViewBuilder content: () -> Content
) -> some View {
    if #available(tvOS 26.0, *) {
        Section { content() }
            .sectionIndexLabel(label)
    } else {
        Section { content() }
    }
}
