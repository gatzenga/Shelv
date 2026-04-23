import SwiftUI

struct AlbumContextMenuModifier: ViewModifier {
    let album: Album
    var showPreview: Bool = true

    @ObservedObject var libraryStore = LibraryStore.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    @AppStorage("enableDownloads") private var enableDownloads = false

    @State private var cachedSongs: [Song]?

    func body(content: Content) -> some View {
        if showPreview {
            content.contextMenu {
                menuItems
            } preview: {
                AlbumArtView(coverArtId: album.coverArt, size: 600, cornerRadius: 0)
                    .frame(width: 280, height: 280)
                    .task { let _ = await fetchSongs() }
            }
        } else {
            content.contextMenu { menuItems }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
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

        if !offlineMode.isOffline && (enableFavorites || enablePlaylists) {
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

        if enableDownloads {
            Divider()
            albumDownloadMenuItems
        }
    }

    @ViewBuilder
    private var albumDownloadMenuItems: some View {
        let status = DownloadStore.shared.albumDownloadStatus(
            albumId: album.id,
            totalSongs: album.songCount ?? 0
        )
        switch status {
        case .none:
            if !offlineMode.isOffline {
                Button {
                    DownloadStore.shared.enqueueAlbum(album)
                } label: {
                    Label(tr("Download Album", "Album herunterladen"),
                          systemImage: "arrow.down.circle")
                }
            }
        case .partial:
            if !offlineMode.isOffline {
                Button {
                    DownloadStore.shared.enqueueAlbum(album)
                } label: {
                    Label(tr("Download Remaining", "Rest herunterladen"),
                          systemImage: "arrow.down.circle")
                }
            }
            Button(role: .destructive) {
                DownloadStore.shared.deleteAlbum(album.id)
            } label: {
                Label { Text(tr("Delete Downloads", "Downloads löschen")) } icon: { DeleteDownloadIcon(tint: .red) }
            }
        case .complete:
            Button(role: .destructive) {
                DownloadStore.shared.deleteAlbum(album.id)
            } label: {
                Label { Text(tr("Delete Downloads", "Downloads löschen")) } icon: { DeleteDownloadIcon(tint: .red) }
            }
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

extension View {
    func albumContextMenu(_ album: Album, showPreview: Bool = true) -> some View {
        modifier(AlbumContextMenuModifier(album: album, showPreview: showPreview))
    }
}
