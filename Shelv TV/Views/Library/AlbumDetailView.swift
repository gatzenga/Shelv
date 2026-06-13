import SwiftUI

/// Album-Seite im tvOS-Zweispalter: links Cover + Metadaten + Aktionen (vertikal zentriert),
/// rechts die scrollende Trackliste mit eigenem Fokus-Highlight.
struct AlbumDetailView: View {
    let album: Album
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    private let api = SubsonicAPIService.shared
    private let player = AudioPlayerService.shared

    @State private var songs: [Song] = []
    @State private var albumStarred = false
    @State private var showAddToPlaylist = false

    private var discNumbers: [Int] { Array(Set(songs.map { $0.discNumber ?? 1 })).sorted() }
    private var hasMultipleDiscs: Bool { discNumbers.count > 1 }

    var body: some View {
        HStack(alignment: .center, spacing: 60) {
            leftColumn.frame(width: 360)
            trackList.frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 60)
        .toolbar(.hidden, for: .tabBar)
        .onDisappear { NotificationCenter.default.post(name: .libraryScrollTop, object: nil) }
        .task {
            songs = await LibraryStore.shared.albumSongs(album)
            albumStarred = album.starred != nil
        }
        .sheet(isPresented: $showAddToPlaylist) { AddToPlaylistView(songIds: songs.map(\.id)) }
    }

    // MARK: - Linke Spalte (vertikal zentriert)

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            CoverArtView(url: album.coverURL(600), size: 300, cornerRadius: 12)
            VStack(alignment: .leading, spacing: 6) {
                Text(album.name).font(.title3).bold().lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                artistLink
                if let year = album.year {
                    Text(String(year)).font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 14) {
                Button { player.play(songs: songs, startIndex: 0) } label: {
                    Label(String(localized: "play"), systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                Button { player.playShuffled(songs: songs) } label: {
                    Image(systemName: "shuffle")
                }
                Menu {
                    Button { player.addPlayNext(songs) } label: {
                        Label(String(localized: "play_next"), systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    Button { player.addToQueue(songs) } label: {
                        Label(String(localized: "add_to_queue"), systemImage: "text.append")
                    }
                    if enablePlaylists {
                        Button { showAddToPlaylist = true } label: {
                            Label(String(localized: "add_to_playlist"), systemImage: "text.badge.plus")
                        }
                    }
                    if enableFavorites {
                        Button { toggleAlbumStar() } label: {
                            Label(albumStarred ? String(localized: "unfavorite") : String(localized: "favorite"),
                                  systemImage: albumStarred ? "heart.fill" : "heart")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
            .buttonStyle(.bordered)
            .disabled(songs.isEmpty)
        }
    }

    @ViewBuilder
    private var artistLink: some View {
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
    }

    // MARK: - Rechte Spalte (Trackliste)

    private var trackList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                if hasMultipleDiscs {
                    ForEach(discNumbers, id: \.self) { disc in
                        HStack {
                            Text("Disc \(disc)").font(.headline).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                        ForEach(songs.filter { ($0.discNumber ?? 1) == disc }) { detailRow($0) }
                    }
                } else {
                    ForEach(songs) { detailRow($0) }
                }
            }
            .padding(.vertical, 30)
        }
        .scrollIndicators(.hidden)
    }

    private func detailRow(_ song: Song) -> some View {
        let idx = songs.firstIndex { $0.id == song.id } ?? 0
        return DetailSongRow(song: song, number: (song.track.map { $0 - 1 }) ?? idx) {
            player.play(songs: songs, startIndex: idx)
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
