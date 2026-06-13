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
}

enum SortDirection: String, CaseIterable {
    case ascending, descending
    var icon: String { self == .ascending ? "arrow.up" : "arrow.down" }
}

extension Notification.Name {
    /// Gepostet von Detail-Views beim Verschwinden → Library scrollt wieder nach oben.
    static let libraryScrollTop = Notification.Name("libraryScrollTop")
}

struct LibraryView: View {
    @ObservedObject var store = LibraryStore.shared
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("albumSortOption") private var albumSortRaw = "alphabeticalByName"
    @AppStorage("albumSortDirection") private var albumDirRaw = "ascending"
    @AppStorage("artistSortDirection") private var artistDirRaw = "ascending"
    @AppStorage("albumViewIsGrid") private var albumIsGrid = true
    @AppStorage("artistViewIsGrid") private var artistIsGrid = false

    @State private var segment = 0   // 0 = Albums, 1 = Artists, 2 = Favorites
    @State private var path = NavigationPath()
    private let player = AudioPlayerService.shared

    private var albumSort: AlbumSortOption { AlbumSortOption(rawValue: albumSortRaw) ?? .alphabetical }
    private var albumDir: SortDirection { SortDirection(rawValue: albumDirRaw) ?? .ascending }
    private var artistDir: SortDirection { SortDirection(rawValue: artistDirRaw) ?? .ascending }

    /// "year" wird client-seitig sortiert → der Server liefert dafür die alphabetische Liste.
    private var albumServerType: String { albumSort == .year ? "alphabeticalByName" : albumSort.rawValue }

    private var displayAlbums: [Album] {
        var result = store.albums
        if albumSort == .year { result.sort { ($0.year ?? 0) < ($1.year ?? 0) } }
        if albumDir == .descending { result.reverse() }
        return result
    }

    private var displayArtists: [Artist] {
        artistDir == .descending ? store.artists.reversed() : store.artists
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    Text(String(localized: "albums")).tag(0)
                    Text(String(localized: "artists")).tag(1)
                    if enableFavorites { Text(String(localized: "favorites")).tag(2) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 700)
                .padding(.top, 40)
                .padding(.bottom, 16)

                if segment == 0 { albumControls }
                else if segment == 1 { artistControls }

                switch segment {
                case 0:
                    if albumIsGrid { coverGrid(displayAlbums) { AlbumCard(album: $0) } }
                    else { albumList }
                case 1:
                    if artistIsGrid { coverGrid(displayArtists) { ArtistCard(artist: $0) } }
                    else { artistList }
                default:
                    favoritesList
                }
            }
            .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
            .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0) }
            .task(id: albumServerType) { await store.loadAlbums(sortBy: albumServerType) }
            .task { await store.loadArtists() }
            .task(id: enableFavorites) { if enableFavorites { await store.loadStarred() } }
        }
    }

    // MARK: - Sortier-/Ansicht-Steuerung

    private var albumControls: some View {
        HStack(spacing: 24) {
            Menu {
                ForEach(AlbumSortOption.allCases, id: \.rawValue) { opt in
                    Button { albumSortRaw = opt.rawValue } label: {
                        if albumSort == opt { Label(opt.label, systemImage: "checkmark") }
                        else { Text(opt.label) }
                    }
                }
            } label: {
                Label(albumSort.label, systemImage: "arrow.up.arrow.down")
            }
            Button { albumDirRaw = albumDir == .ascending ? "descending" : "ascending" } label: {
                Image(systemName: albumDir.icon)
            }
            Button { albumIsGrid.toggle() } label: {
                Image(systemName: albumIsGrid ? "list.bullet" : "square.grid.2x2")
            }
        }
        .buttonStyle(.bordered)
        .padding(.bottom, 16)
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
    }

    // MARK: - Cover-Grid (Alben / Künstler)

    private func coverGrid<T: Identifiable, Card: View>(_ items: [T], @ViewBuilder card: @escaping (T) -> Card) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear.frame(height: 1).id("top")
                LazyVGrid(columns: coverGridColumns, alignment: .leading, spacing: 50) {
                    ForEach(items) { card($0) }
                }
                .padding(.horizontal, 50)
                .padding(.top, 30)
                .padding(.bottom, 50)
            }
            .onAppear { proxy.scrollTo("top", anchor: .top) }
            // Beim Zurück aus einem Detail (tvOS stellt sonst den Fokus aufs gewählte Cover):
            // kurz verzögert nach oben, nachdem die Fokus-Wiederherstellung gelaufen ist.
            .onReceive(NotificationCenter.default.publisher(for: .libraryScrollTop)) { _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    withAnimation { proxy.scrollTo("top", anchor: .top) }
                }
            }
        }
    }

    // MARK: - Listen-Ansicht (Alben / Künstler)

    private var albumList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(displayAlbums) { album in
                    AlbumListRow(album: album) { path.append(album) }
                }
            }
            .padding(.vertical, 24)
        }
        .scrollIndicators(.hidden)
    }

    private var artistList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(displayArtists) { artist in
                    ArtistListRow(artist: artist,
                                  albumCount: store.albums.filter { $0.artistId == artist.id }.count) {
                        path.append(artist)
                    }
                }
            }
            .padding(.vertical, 24)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Favoriten — native List wie die Suche

    @ViewBuilder
    private var favoritesList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !store.favoriteSongs.isEmpty {
                    Text(String(localized: "songs")).font(.title3).bold().padding(.horizontal, 50)
                    LazyVStack(spacing: 4) {
                        ForEach(Array(store.favoriteSongs.enumerated()), id: \.element.id) { i, song in
                            DetailSongRow(song: song, number: i, showArtwork: true) {
                                player.play(songs: store.favoriteSongs, startIndex: i)
                            }
                        }
                    }
                }
                if !store.favoriteAlbums.isEmpty {
                    Text(String(localized: "albums")).font(.title3).bold().padding(.horizontal, 50)
                    cardRow { ForEach(store.favoriteAlbums) { AlbumCard(album: $0) } }
                }
                if !store.favoriteArtists.isEmpty {
                    Text(String(localized: "artists")).font(.title3).bold().padding(.horizontal, 50)
                    cardRow { ForEach(store.favoriteArtists) { ArtistCard(artist: $0) } }
                }
            }
            .padding(.vertical, 24)
        }
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
