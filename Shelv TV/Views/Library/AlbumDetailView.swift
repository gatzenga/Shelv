import SwiftUI

/// Album-Seite im tvOS-Zweispalter: links Cover + Metadaten + Aktionen (vertikal zentriert),
/// rechts die scrollende Trackliste mit eigenem Fokus-Highlight.
struct AlbumDetailView: View {
    let album: Album
    @AppStorage("enableFavorites") private var enableFavorites = true
    private let api = SubsonicAPIService.shared
    private let player = AudioPlayerService.shared

    @State private var songs: [Song] = []
    @State private var albumStarred = false

    private var discNumbers: [Int] { Array(Set(songs.map { $0.discNumber ?? 1 })).sorted() }
    private var hasMultipleDiscs: Bool { discNumbers.count > 1 }

    var body: some View {
        HStack(alignment: .center, spacing: 60) {
            leftColumn.frame(width: 300)
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
    }

    // MARK: - Linke Spalte (vertikal zentriert, einzelne Aktionsbuttons)

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            CoverArtView(url: album.coverURL(600), size: 300, cornerRadius: 12)
            VStack(alignment: .leading, spacing: 6) {
                Text(album.name).font(.title3).bold().lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                artistLink
                if let year = album.year {
                    Text(String(year)).font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 12) {
                actionButton(String(localized: "play"), "play.fill") { player.play(songs: songs, startIndex: 0) }
                actionButton(String(localized: "shuffle"), "shuffle") { player.playShuffled(songs: songs) }
                HStack(spacing: 12) {
                    iconButton("text.line.first.and.arrowtriangle.forward") { player.addPlayNext(songs) }
                    iconButton("text.append") { player.addToQueue(songs) }
                    if enableFavorites {
                        iconButton(albumStarred ? "heart.fill" : "heart") { toggleAlbumStar() }
                    }
                }
            }
            .disabled(songs.isEmpty)
        }
    }

    private func actionButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private func iconButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var artistLink: some View {
        if let artistName = album.artist {
            AccentTextLink(text: artistName, font: .body) {
                ArtistDetailView(artist: resolvedLibraryArtist(name: artistName, id: album.artistId))
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
