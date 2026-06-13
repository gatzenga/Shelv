import SwiftUI

/// Album-Seite im tvOS-Zweispalter (wie Apple Music): links Cover + Metadaten +
/// Aktionen (bleiben immer sichtbar), rechts die scrollende Trackliste.
struct AlbumDetailView: View {
    let album: Album
    @AppStorage("enableFavorites") private var enableFavorites = true
    private let api = SubsonicAPIService.shared
    private let player = AudioPlayerService.shared

    @State private var songs: [Song] = []
    @State private var albumStarred = false

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            // Linke Spalte — fix
            VStack(alignment: .leading, spacing: 24) {
                CoverArtView(url: album.coverURL(600), size: 380, cornerRadius: 12)
                VStack(alignment: .leading, spacing: 6) {
                    Text(album.name).font(.title2).bold().lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let artist = album.artist {
                        Text(artist).font(.body).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let year = album.year {
                        Text(String(year)).font(.callout).foregroundStyle(.secondary)
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
                    if enableFavorites {
                        actionButton(String(localized: "favorite"), albumStarred ? "heart.fill" : "heart") {
                            toggleAlbumStar()
                        }
                    }
                }
                .disabled(songs.isEmpty)

                Spacer()
            }
            .frame(width: 380)

            // Rechte Spalte — Trackliste
            List {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, index: index, showArtwork: false) {
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
        .task {
            songs = await LibraryStore.shared.albumSongs(album)
            albumStarred = album.starred != nil
        }
    }

    private func actionButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private func toggleAlbumStar() {
        albumStarred.toggle()
        Task {
            if albumStarred { try? await api.star(albumId: album.id) }
            else { try? await api.unstar(albumId: album.id) }
        }
    }
}
