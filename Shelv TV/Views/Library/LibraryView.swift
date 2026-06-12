import SwiftUI

struct LibraryView: View {
    @ObservedObject var store = LibraryStore.shared
    @AppStorage("enableFavorites") private var enableFavorites = true

    @State private var segment = 0   // 0 = Albums, 1 = Artists, 2 = Favorites
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 40), count: 6)
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
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)   // verdeckt die durchscrollenden Karten
                .zIndex(1)

                ScrollView {
                    Group {
                        switch segment {
                        case 0:
                            grid(store.albums) { AlbumCard(album: $0) }
                        case 1:
                            grid(store.artists) { ArtistCard(artist: $0) }
                        default:
                            favorites
                        }
                    }
                    .padding(.horizontal, 50)
                    .padding(.top, 36)    // Abstand zur Tab-Leiste, damit der Fokus-Zoom nicht anstößt
                    .padding(.bottom, 40)
                }
                .scrollClipDisabled()
            }
            .task { await store.loadAlbums() }
            .task { await store.loadArtists() }
            .task(id: enableFavorites) { if enableFavorites { await store.loadStarred() } }
        }
    }

    private func grid<T: Identifiable, Card: View>(_ items: [T], @ViewBuilder card: @escaping (T) -> Card) -> some View {
        LazyVGrid(columns: columns, spacing: 40) {
            ForEach(items) { card($0) }
        }
    }

    @ViewBuilder
    private var favorites: some View {
        VStack(alignment: .leading, spacing: 40) {
            if !store.favoriteSongs.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(String(localized: "songs")).font(.title2).bold()
                        Spacer()
                        Button {
                            player.play(songs: store.favoriteSongs, startIndex: 0)
                        } label: { Label(String(localized: "play"), systemImage: "play.fill") }
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(Array(store.favoriteSongs.enumerated()), id: \.element.id) { i, song in
                            SongRow(song: song, index: i) {
                                player.play(songs: store.favoriteSongs, startIndex: i)
                            }
                            if i < store.favoriteSongs.count - 1 { Divider() }
                        }
                    }
                }
            }
            if !store.favoriteAlbums.isEmpty {
                Text(String(localized: "albums")).font(.title2).bold()
                grid(store.favoriteAlbums) { AlbumCard(album: $0) }
            }
            if !store.favoriteArtists.isEmpty {
                Text(String(localized: "artists")).font(.title2).bold()
                grid(store.favoriteArtists) { ArtistCard(artist: $0) }
            }
        }
    }
}
