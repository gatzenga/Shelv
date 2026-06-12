import SwiftUI

struct AlbumDetailView: View {
    let album: Album
    @AppStorage("enableFavorites") private var enableFavorites = true
    private let api = SubsonicAPIService.shared
    private let player = AudioPlayerService.shared

    @State private var songs: [Song] = []
    @State private var albumStarred = false

    var body: some View {
        List {
            // Kopf — reine Anzeige (Cover + Metadaten)
            Section {
                HStack(alignment: .top, spacing: 40) {
                    CoverArtView(url: album.coverURL(600), size: 320, cornerRadius: 12)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(album.name).font(.title).bold().lineLimit(2)
                        if let artist = album.artist {
                            Text(artist).font(.title3).foregroundStyle(.secondary)
                        }
                        if let year = album.year {
                            Text(String(year)).font(.callout).foregroundStyle(.secondary)
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
                    if enableFavorites {
                        Button { toggleAlbumStar() } label: {
                            Label(String(localized: "favorite"),
                                  systemImage: albumStarred ? "heart.fill" : "heart")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(songs.isEmpty)
                .listRowBackground(Color.clear)
            }

            // Songs — Tracknummer statt (redundantem) Cover, Context-Menü für Queue/Favorit
            Section {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, index: index, showArtwork: false) {
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
        .task {
            songs = await LibraryStore.shared.albumSongs(album)
            albumStarred = album.starred != nil
        }
    }

    private func toggleAlbumStar() {
        albumStarred.toggle()
        Task {
            if albumStarred { try? await api.star(albumId: album.id) }
            else { try? await api.unstar(albumId: album.id) }
        }
    }
}
