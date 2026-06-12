import SwiftUI

struct PlaylistsView: View {
    @ObservedObject var store = LibraryStore.shared
    @ObservedObject var recap = RecapStore.shared

    /// Recap-Playlists raus — die haben ihren eigenen Tab.
    private var playlists: [Playlist] {
        store.playlists.filter { !recap.recapPlaylistIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if playlists.isEmpty && store.isLoadingPlaylists {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                } else if playlists.isEmpty {
                    ContentUnavailableView(
                        String(localized: "no_playlists_2"),
                        systemImage: "music.note.list"
                    )
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVGrid(columns: coverGridColumns, alignment: .leading, spacing: 50) {
                        ForEach(playlists) { playlist in
                            PlaylistCard(playlist: playlist)
                        }
                    }
                    .padding(.horizontal, 50)
                    .padding(.top, 30)
                    .padding(.bottom, 50)
                }
            }
            .task { await store.loadPlaylists() }
        }
    }
}

struct PlaylistCard: View {
    let playlist: Playlist
    var size: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            NavigationLink {
                PlaylistDetailView(playlist: playlist)
            } label: {
                CoverArtView(url: playlist.coverURL(500), size: size, cornerRadius: 8)
            }
            .buttonStyle(.card)

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
    @AppStorage("enableFavorites") private var enableFavorites = true
    private let api = SubsonicAPIService.shared
    private let player = AudioPlayerService.shared

    @State private var songs: [Song] = []

    var body: some View {
        List {
            // Kopf — reine Anzeige
            Section {
                HStack(alignment: .top, spacing: 40) {
                    CoverArtView(url: playlist.coverURL(600), size: 320, cornerRadius: 12)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(playlist.name).font(.title).bold().lineLimit(2)
                        if let count = playlist.songCount {
                            Text("\(count) \(String(localized: "songs"))")
                                .font(.title3).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 16)
                .listRowBackground(Color.clear)
            }

            // Aktionen — einzeln fokussierbar
            Section {
                HStack(spacing: 24) {
                    Button { player.play(songs: songs, startIndex: 0) } label: {
                        Label(String(localized: "play"), systemImage: "play.fill")
                    }
                    Button { player.playShuffled(songs: songs) } label: {
                        Label(String(localized: "shuffle"), systemImage: "shuffle")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(songs.isEmpty)
                .listRowBackground(Color.clear)
            }

            // Songs — mit Cover (gemischte Alben), Context-Menü für Queue/Favorit
            Section {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, index: index) {
                        player.play(songs: songs, startIndex: index)
                    }
                    .contextMenu {
                        Button { player.addPlayNext(song) } label: {
                            Label(String(localized: "play_next"), systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        Button { player.addToQueue(song) } label: {
                            Label(String(localized: "add_to_queue"), systemImage: "text.append")
                        }
                        if enableFavorites {
                            Button { Task { try? await api.star(songId: song.id) } } label: {
                                Label(String(localized: "favorite"), systemImage: "heart")
                            }
                        }
                    }
                }
            }
        }
        .task { songs = await LibraryStore.shared.playlistSongs(playlist) }
    }
}
