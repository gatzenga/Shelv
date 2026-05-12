import SwiftUI

struct AlbumContextMenuModifier: ViewModifier {
    let album: Album
    var showPreview: Bool = true

    @ObservedObject var libraryStore = LibraryStore.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    @AppStorage("enableDownloads") private var enableDownloads = false
    @AppStorage("themeColor") private var themeColorName = "violet"

    @State private var cachedSongs: [Song]?
    @State private var pendingPlaylistIds: PendingPlaylistIds?
    @State private var showDeleteAlbumDownloadConfirm = false

    func body(content: Content) -> some View {
        if showPreview {
            content.contextMenu {
                menuItems
            } preview: {
                AlbumArtView(coverArtId: album.coverArt, size: 600, cornerRadius: 0)
                    .frame(width: 280, height: 280)
                    .task { let _ = await fetchSongs() }
            }
            .sheet(item: $pendingPlaylistIds) { item in
                AddToPlaylistSheet(songIds: item.ids)
                    .environmentObject(libraryStore)
                    .tint(AppTheme.color(for: themeColorName))
            }
            .alert(String(localized: "delete_downloads"), isPresented: $showDeleteAlbumDownloadConfirm) {
                Button(String(localized: "delete"), role: .destructive) {
                    DownloadStore.shared.deleteAlbum(album.id)
                }
                Button(String(localized: "cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "the_downloads_will_be_removed_from_this_device"))
            }
        } else {
            content.contextMenu { menuItems }
            .sheet(item: $pendingPlaylistIds) { item in
                AddToPlaylistSheet(songIds: item.ids)
                    .environmentObject(libraryStore)
                    .tint(AppTheme.color(for: themeColorName))
            }
            .alert(String(localized: "delete_downloads"), isPresented: $showDeleteAlbumDownloadConfirm) {
                Button(String(localized: "delete"), role: .destructive) {
                    DownloadStore.shared.deleteAlbum(album.id)
                }
                Button(String(localized: "cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "the_downloads_will_be_removed_from_this_device"))
            }
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
            Label(String(localized: "play"), systemImage: "play.fill")
        }

        Button {
            Task {
                guard let songs = await fetchSongs(), !songs.isEmpty else { return }
                AudioPlayerService.shared.playShuffled(songs: songs)
            }
        } label: {
            Label(String(localized: "shuffle"), systemImage: "shuffle")
        }

        Divider()

        Button {
            Task {
                guard let songs = await fetchSongs(), !songs.isEmpty else { return }
                AudioPlayerService.shared.addPlayNext(songs)
            }
        } label: {
            Label(String(localized: "play_next"), systemImage: "text.insert")
        }

        Button {
            Task {
                guard let songs = await fetchSongs(), !songs.isEmpty else { return }
                AudioPlayerService.shared.addToQueue(songs)
            }
        } label: {
            Label(String(localized: "add_to_queue"), systemImage: "text.badge.plus")
        }

        if !offlineMode.isOffline && (enableFavorites || enablePlaylists) {
            Divider()
            if enableFavorites {
                Button {
                    Task { await libraryStore.toggleStarAlbum(album) }
                } label: {
                    Label(
                        libraryStore.isAlbumStarred(album)
                            ? String(localized: "unfavorite")
                            : String(localized: "favorite"),
                        systemImage: libraryStore.isAlbumStarred(album) ? "heart.slash" : "heart"
                    )
                }
            }
            if enablePlaylists {
                Button {
                    if let cached = cachedSongs, !cached.isEmpty {
                        pendingPlaylistIds = PendingPlaylistIds(ids: cached.map(\.id))
                    } else {
                        Task {
                            guard let songs = await fetchSongs(), !songs.isEmpty else { return }
                            pendingPlaylistIds = PendingPlaylistIds(ids: songs.map(\.id))
                        }
                    }
                } label: {
                    Label(String(localized: "add_to_playlist"), systemImage: "music.note.list")
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
                    Label(String(localized: "download_album"),
                          systemImage: "arrow.down.circle")
                }
            }
        case .partial:
            if !offlineMode.isOffline {
                Button {
                    DownloadStore.shared.enqueueAlbum(album)
                } label: {
                    Label(String(localized: "download_remaining"),
                          systemImage: "arrow.down.circle")
                }
            }
            Button(role: .destructive) {
                showDeleteAlbumDownloadConfirm = true
            } label: {
                Label(String(localized: "delete_downloads_2"), systemImage: "arrow.down.circle")
            }
        case .complete:
            Button(role: .destructive) {
                showDeleteAlbumDownloadConfirm = true
            } label: {
                Label(String(localized: "delete_downloads_2"), systemImage: "arrow.down.circle")
            }
        }
    }

    private func fetchSongs() async -> [Song]? {
        if offlineMode.isOffline {
            return DownloadStore.shared.albums.first { $0.albumId == album.id }?.songs.map { $0.asSong() }
        }
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

private struct PendingPlaylistIds: Identifiable {
    let id = UUID()
    let ids: [String]
}
