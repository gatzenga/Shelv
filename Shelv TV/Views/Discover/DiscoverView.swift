import SwiftUI

struct DiscoverView: View {
    @ObservedObject var library = LibraryStore.shared
    @ObservedObject var recap = RecapStore.shared
    private let api = SubsonicAPIService.shared
    private let player = AudioPlayerService.shared

    @State private var newest: [Album] = []
    @State private var recent: [Album] = []
    @State private var frequent: [Album] = []
    @State private var isShuffling = false

    private var recapPlaylists: [Playlist] {
        library.playlists.filter { recap.recapPlaylistIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 44) {
                    // Insights + Shuffle oben
                    HStack(spacing: 30) {
                        NavigationLink { InsightsView() } label: {
                            actionCard(String(localized: "insights"), "chart.bar.xaxis")
                        }
                        .buttonStyle(.card)

                        Button { Task { await shuffleAll() } } label: {
                            actionCard(String(localized: "mix_shuffle_all"), "shuffle")
                        }
                        .buttonStyle(.card)
                        .disabled(isShuffling)
                    }

                    if !recapPlaylists.isEmpty {
                        playlistRow(String(localized: "recaps"), recapPlaylists)
                    }
                    albumRow(String(localized: "recently_added"), newest)
                    albumRow(String(localized: "recently_played"), recent)
                    albumRow(String(localized: "frequently_played"), frequent)
                }
                .padding(50)
            }
            .navigationTitle(String(localized: "discover"))
            .task { await load() }
        }
    }

    private func load() async {
        await library.loadPlaylists()
        async let n = try? api.getAlbumList(type: "newest", size: 20)
        async let r = try? api.getAlbumList(type: "recent", size: 20)
        async let f = try? api.getAlbumList(type: "frequent", size: 20)
        newest = await n ?? []
        recent = await r ?? []
        frequent = await f ?? []
    }

    private func shuffleAll() async {
        isShuffling = true; defer { isShuffling = false }
        if let songs = try? await api.getRandomSongs(size: 500), !songs.isEmpty {
            player.playShuffled(songs: songs)
        }
    }

    // MARK: - Reihen

    @ViewBuilder
    private func albumRow(_ title: String, _ albums: [Album]) -> some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.title2).bold()
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 30) {
                        ForEach(albums) { AlbumCard(album: $0, size: 240) }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    @ViewBuilder
    private func playlistRow(_ title: String, _ playlists: [Playlist]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2).bold()
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 30) {
                    ForEach(playlists) { PlaylistCard(playlist: $0, size: 240) }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func actionCard(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 50))
            Text(title).font(.title3)
        }
        .frame(width: 320, height: 200)
        .background(Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 16))
    }
}
