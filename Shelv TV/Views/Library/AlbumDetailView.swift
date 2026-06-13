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
                    if let artistName = album.artist {
                        if let aid = album.artistId, !aid.isEmpty {
                            NavigationLink {
                                ArtistDetailView(artist: Artist(id: aid, name: artistName))
                            } label: {
                                Text(artistName).font(.body).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(artistName).font(.body).foregroundStyle(.secondary).lineLimit(1)
                        }
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

            // Rechte Spalte — Trackliste (bei ≥2 Discs nach Disc gruppiert)
            List {
                if hasMultipleDiscs {
                    ForEach(discNumbers, id: \.self) { disc in
                        Section("Disc \(disc)") {
                            ForEach(songs.filter { ($0.discNumber ?? 1) == disc }) { song in
                                songRow(song)
                            }
                        }
                    }
                } else {
                    ForEach(songs) { song in songRow(song) }
                }
            }
            .listStyle(.plain)
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 60)
        .padding(.top, 40)
        .toolbar(.hidden, for: .tabBar)
        .onDisappear { NotificationCenter.default.post(name: .libraryScrollTop, object: nil) }
        .task {
            songs = await LibraryStore.shared.albumSongs(album)
            albumStarred = album.starred != nil
        }
    }

    private var discNumbers: [Int] { Array(Set(songs.map { $0.discNumber ?? 1 })).sorted() }
    private var hasMultipleDiscs: Bool { discNumbers.count > 1 }

    private func songRow(_ song: Song) -> some View {
        let idx = songs.firstIndex { $0.id == song.id } ?? 0
        return SongRow(song: song, index: (song.track.map { $0 - 1 }) ?? idx, showArtwork: false) {
            player.play(songs: songs, startIndex: idx)
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 24, bottom: 6, trailing: 24))
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
