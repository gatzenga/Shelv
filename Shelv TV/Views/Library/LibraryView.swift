import SwiftUI

struct LibraryView: View {
    @ObservedObject var store = LibraryStore.shared
    @AppStorage("enableFavorites") private var enableFavorites = true

    @State private var segment = 0   // 0 = Albums, 1 = Artists, 2 = Favorites
    private let player = AudioPlayerService.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    Text(String(localized: "albums")).tag(0)
                    Text(String(localized: "artists")).tag(1)
                    if enableFavorites { Text(String(localized: "favorites")).tag(2) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 700)
                .padding(.top, 40)
                .padding(.bottom, 24)

                switch segment {
                case 0:
                    coverGrid(store.albums) { AlbumCard(album: $0) }
                case 1:
                    coverGrid(store.artists) { ArtistCard(artist: $0) }
                default:
                    favoritesList
                }
            }
            .task { await store.loadAlbums() }
            .task { await store.loadArtists() }
            .task(id: enableFavorites) { if enableFavorites { await store.loadStarred() } }
        }
    }

    // MARK: - Cover-Grid (Alben / Künstler) — gleicher Look wie Discover

    private func coverGrid<T: Identifiable, Card: View>(_ items: [T], @ViewBuilder card: @escaping (T) -> Card) -> some View {
        ScrollView {
            LazyVGrid(columns: coverGridColumns, alignment: .leading, spacing: 50) {
                ForEach(items) { card($0) }
            }
            .padding(.horizontal, 50)
            .padding(.top, 30)
            .padding(.bottom, 50)
        }
    }

    // MARK: - Favoriten — native List wie die Suche

    @ViewBuilder
    private var favoritesList: some View {
        List {
            if !store.favoriteSongs.isEmpty {
                Section {
                    ForEach(Array(store.favoriteSongs.enumerated()), id: \.element.id) { i, song in
                        SongRow(song: song, index: i) {
                            player.play(songs: store.favoriteSongs, startIndex: i)
                        }
                    }
                } header: {
                    HStack {
                        Text(String(localized: "songs"))
                        Spacer()
                        Button {
                            player.play(songs: store.favoriteSongs, startIndex: 0)
                        } label: { Label(String(localized: "play"), systemImage: "play.fill") }
                        .buttonStyle(.bordered)
                    }
                }
            }
            if !store.favoriteAlbums.isEmpty {
                Section(String(localized: "albums")) {
                    cardRow { ForEach(store.favoriteAlbums) { AlbumCard(album: $0) } }
                }
            }
            if !store.favoriteArtists.isEmpty {
                Section(String(localized: "artists")) {
                    cardRow { ForEach(store.favoriteArtists) { ArtistCard(artist: $0) } }
                }
            }
        }
    }

    private func cardRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 40) { content() }
                .padding(.vertical, 20)
        }
        .scrollClipDisabled()
        .listRowBackground(Color.clear)
    }
}
