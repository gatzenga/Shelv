import SwiftUI

struct AlbumCardView: View {
    let album: Album
    var fixedSize: CGFloat? = nil
    var showArtist: Bool = true
    var showYear: Bool = false

    @EnvironmentObject var libraryStore: LibraryStore
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("enablePlaylists") private var enablePlaylists = true

    @State private var cachedSongs: [Song]?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let s = fixedSize {
                AlbumArtView(coverArtId: album.coverArt, size: 300, cornerRadius: 12)
                    .frame(width: s, height: s)
            } else {
                AlbumArtView(coverArtId: album.coverArt, size: 300, cornerRadius: 12)
                    .aspectRatio(1, contentMode: .fit)
            }
            Text(album.name)
                .font(.caption).bold()
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)
            if showArtist, let artist = album.artist {
                Text(artist)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            if showYear, let year = album.year {
                Text(String(year))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: fixedSize)
        .contextMenu {
            Button {
                Task {
                    guard let songs = await fetchSongs(), !songs.isEmpty else { return }
                    AudioPlayerService.shared.play(songs: songs, startIndex: 0)
                }
            } label: {
                Label(tr("Play", "Abspielen"), systemImage: "play.fill")
            }

            Button {
                Task {
                    guard let songs = await fetchSongs(), !songs.isEmpty else { return }
                    AudioPlayerService.shared.playShuffled(songs: songs)
                }
            } label: {
                Label(tr("Shuffle", "Zufällig"), systemImage: "shuffle")
            }

            Divider()

            Button {
                Task {
                    guard let songs = await fetchSongs(), !songs.isEmpty else { return }
                    AudioPlayerService.shared.addPlayNext(songs)
                }
            } label: {
                Label(tr("Play Next", "Als nächstes"), systemImage: "text.insert")
            }

            Button {
                Task {
                    guard let songs = await fetchSongs(), !songs.isEmpty else { return }
                    AudioPlayerService.shared.addToQueue(songs)
                }
            } label: {
                Label(tr("Add to Queue", "Zur Warteschlange"), systemImage: "text.badge.plus")
            }

            if enableFavorites || enablePlaylists {
                Divider()
                if enableFavorites {
                    Button {
                        Task { await libraryStore.toggleStarAlbum(album) }
                    } label: {
                        Label(
                            libraryStore.isAlbumStarred(album)
                                ? tr("Unfavorite", "Aus Favoriten entfernen")
                                : tr("Favorite", "Zu Favoriten"),
                            systemImage: libraryStore.isAlbumStarred(album) ? "heart.slash" : "heart"
                        )
                    }
                }
                if enablePlaylists {
                    Button {
                        Task {
                            guard let songs = await fetchSongs(), !songs.isEmpty else { return }
                            NotificationCenter.default.post(name: .addSongsToPlaylist, object: songs.map(\.id))
                        }
                    } label: {
                        Label(tr("Add to Playlist…", "Zur Playlist hinzufügen…"), systemImage: "music.note.list")
                    }
                }
            }
        } preview: {
            AlbumArtView(coverArtId: album.coverArt, size: 600, cornerRadius: 0)
                .frame(width: 280, height: 280)
                .task { let _ = await fetchSongs() }
        }
    }

    private func fetchSongs() async -> [Song]? {
        if let cachedSongs { return cachedSongs }
        guard let detail = try? await SubsonicAPIService.shared.getAlbum(id: album.id) else { return nil }
        let songs = detail.song ?? []
        await MainActor.run { cachedSongs = songs }
        return songs
    }
}
