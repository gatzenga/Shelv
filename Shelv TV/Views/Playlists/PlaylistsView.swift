import SwiftUI

struct PlaylistsView: View {
    @ObservedObject var store = LibraryStore.shared
    private let columns = [GridItem(.adaptive(minimum: 280), spacing: 40)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if store.playlists.isEmpty && store.isLoadingPlaylists {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                } else if store.playlists.isEmpty {
                    ContentUnavailableView(
                        String(localized: "no_playlists_2"),
                        systemImage: "music.note.list"
                    )
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVGrid(columns: columns, spacing: 40) {
                        ForEach(store.playlists) { playlist in
                            PlaylistCard(playlist: playlist)
                        }
                    }
                }
            }
            .padding(50)
            .navigationTitle(String(localized: "playlists"))
            .task { await store.loadPlaylists() }
        }
    }
}

struct PlaylistCard: View {
    let playlist: Playlist
    var size: CGFloat = 280

    var body: some View {
        NavigationLink {
            PlaylistDetailView(playlist: playlist)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                CoverArtView(url: playlist.coverURL(500), size: size, cornerRadius: 8)
                Text(playlist.name).lineLimit(1).font(.callout)
                if let count = playlist.songCount {
                    Text("\(count) \(String(localized: "songs"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: size)
        }
        .buttonStyle(.card)
    }
}

struct PlaylistDetailView: View {
    let playlist: Playlist
    private let player = AudioPlayerService.shared

    @State private var songs: [Song] = []

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 40) {
                CoverArtView(url: playlist.coverURL(600), size: 360, cornerRadius: 12)
                VStack(alignment: .leading, spacing: 16) {
                    Text(playlist.name).font(.title).bold().lineLimit(2)
                    if let count = playlist.songCount {
                        Text("\(count) \(String(localized: "songs"))")
                            .font(.title3).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 20) {
                        Button { player.play(songs: songs, startIndex: 0) } label: {
                            Label(String(localized: "play"), systemImage: "play.fill")
                        }
                        Button { player.playShuffled(songs: songs) } label: {
                            Label(String(localized: "shuffle"), systemImage: "shuffle")
                        }
                    }
                    .disabled(songs.isEmpty)
                    .padding(.top, 8)
                }
                Spacer()
            }
            .padding(.bottom, 30)

            LazyVStack(spacing: 0) {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, index: index) {
                        player.play(songs: songs, startIndex: index)
                    }
                    if index < songs.count - 1 { Divider() }
                }
            }
        }
        .padding(50)
        .task { songs = await LibraryStore.shared.playlistSongs(playlist) }
    }
}
