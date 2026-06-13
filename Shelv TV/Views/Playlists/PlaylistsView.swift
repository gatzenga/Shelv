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
            .playlistContextMenu(playlist)

            Text(playlist.name).lineLimit(1).font(.callout)
            if let count = playlist.songCount {
                Text("\(count) \(String(localized: "songs"))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: size)
    }
}

/// Playlist-Seite im selben Zweispalter wie das Album: links Cover + Aktionen
/// (immer sichtbar), rechts die scrollende Songliste (mit Covern, gemischte Alben).
struct PlaylistDetailView: View {
    let playlist: Playlist
    private let player = AudioPlayerService.shared

    @State private var songs: [Song] = []

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            // Linke Spalte — fix
            VStack(alignment: .leading, spacing: 24) {
                CoverArtView(url: playlist.coverURL(600), size: 380, cornerRadius: 12)
                VStack(alignment: .leading, spacing: 6) {
                    Text(playlist.name).font(.title2).bold().lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let count = playlist.songCount {
                        Text("\(count) \(String(localized: "songs"))")
                            .font(.body).foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 14) {
                    actionButton(String(localized: "play"), "play.fill") {
                        player.play(songs: songs, startIndex: 0)
                    }
                    actionButton(String(localized: "shuffle"), "shuffle") {
                        player.playShuffled(songs: songs)
                    }
                    actionButton(String(localized: "play_next"), "text.line.first.and.arrowtriangle.forward") {
                        player.addPlayNext(songs)
                    }
                    actionButton(String(localized: "add_to_queue"), "text.append") {
                        player.addToQueue(songs)
                    }
                }
                .disabled(songs.isEmpty)

                Spacer()
            }
            .frame(width: 380)

            // Rechte Spalte — Songliste
            List {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, index: index) {
                        player.play(songs: songs, startIndex: index)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 24, bottom: 6, trailing: 24))
                }
            }
            .listStyle(.plain)
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 60)
        .padding(.top, 40)
        .task { songs = await LibraryStore.shared.playlistSongs(playlist) }
    }

    private func actionButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}
