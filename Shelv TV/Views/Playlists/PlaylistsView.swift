import SwiftUI

struct PlaylistsView: View {
    @ObservedObject var store = LibraryStore.shared
    @ObservedObject var recap = RecapStore.shared
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 40), count: 6)

    /// Recap-Playlists raus — die haben ihren eigenen Tab.
    private var playlists: [Playlist] {
        store.playlists.filter { !recap.recapPlaylistIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if playlists.isEmpty && store.isLoadingPlaylists {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                    } else if playlists.isEmpty {
                        ContentUnavailableView(
                            String(localized: "no_playlists_2"),
                            systemImage: "music.note.list"
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        LazyVGrid(columns: columns, spacing: 40) {
                            ForEach(playlists) { playlist in
                                PlaylistCard(playlist: playlist)
                            }
                        }
                    }
                }
                // Lift-Puffer im Scrollbereich, sonst clippt der .card-Lift.
                .padding(50)
            }
            .scrollClipDisabled()
            .task { await store.loadPlaylists() }
        }
    }
}

struct PlaylistCard: View {
    let playlist: Playlist
    var size: CGFloat = 270

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink {
                PlaylistDetailView(playlist: playlist)
            } label: {
                CoverArtView(url: playlist.coverURL(500), size: size, cornerRadius: 8)
                    .scaleEffect(focused ? 1.05 : 1.0)
                    .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 18, y: 10)
                    .animation(.easeOut(duration: 0.18), value: focused)
            }
            .buttonStyle(.borderless)
            .focused($focused)

            Text(playlist.name).lineLimit(1).font(.callout)
            if let count = playlist.songCount {
                Text("\(count) \(String(localized: "songs"))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: size)
    }
}

struct PlaylistDetailView: View {
    let playlist: Playlist
    private let player = AudioPlayerService.shared

    @State private var songs: [Song] = []

    var body: some View {
        List {
            Section {
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
                .padding(.vertical, 20)
                .listRowBackground(Color.clear)
            }

            Section {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, index: index) {
                        player.play(songs: songs, startIndex: index)
                    }
                }
            }
        }
        .task { songs = await LibraryStore.shared.playlistSongs(playlist) }
    }
}
