import SwiftUI

struct AlbumContextMenuModifier: ViewModifier {
    let album: Album
    @ObservedObject var libraryStore = LibraryViewModel.shared
    @ObservedObject private var downloadStore = DownloadStore.shared
    @ObservedObject private var offlineMode = OfflineModeService.shared
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    @AppStorage("enableInstantMix") private var enableInstantMix = true
    @AppStorage("enableDownloads") private var enableDownloads = false
    @State private var showDeleteConfirm = false

    func body(content: Content) -> some View {
        content.contextMenu {
            Button(String(localized: "play")) {
                withAlbumSongs(errorMsg: String(localized: "playback_failed")) { songs in
                    AudioPlayerService.shared.play(songs: songs)
                }
            }
            Button(String(localized: "shuffle")) {
                withAlbumSongs(errorMsg: String(localized: "playback_failed")) { songs in
                    AudioPlayerService.shared.playShuffled(songs: songs)
                }
            }
            if enableInstantMix && !offlineMode.isOffline {
                Button(String(localized: "instant_mix")) {
                    playInstantMix()
                }
            }
            Divider()
            Button(String(localized: "play_next")) {
                withAlbumSongs(errorMsg: String(localized: "action_failed")) { songs in
                    AudioPlayerService.shared.addPlayNext(songs)
                    NotificationCenter.default.post(name: .showToast, object: String(localized: "added_to_play_next"))
                }
            }
            Button(String(localized: "add_to_queue")) {
                withAlbumSongs(errorMsg: String(localized: "action_failed")) { songs in
                    AudioPlayerService.shared.addToQueue(songs)
                    NotificationCenter.default.post(name: .showToast, object: String(localized: "added_to_queue"))
                }
            }
            if enableFavorites || enablePlaylists {
                Divider()
                if enableFavorites {
                    Button(libraryStore.isAlbumStarred(album)
                           ? String(localized: "remove_from_favorites")
                           : String(localized: "add_to_favorites")) {
                        Task { await libraryStore.toggleStarAlbum(album) }
                    }
                }
                if enablePlaylists {
                    Button(String(localized: "add_to_playlist")) {
                        withAlbumSongs(errorMsg: String(localized: "action_failed")) { songs in
                            guard !songs.isEmpty else { return }
                            NotificationCenter.default.post(name: .addSongsToPlaylist, object: songs.map(\.id))
                        }
                    }
                }
            }
            if enableDownloads {
                Divider()
                let status = downloadStore.albumDownloadStatus(albumId: album.id, totalSongs: album.songCount ?? 0)
                switch status {
                case .none:
                    if !offlineMode.isOffline {
                        Button(String(localized: "download_album")) {
                            DownloadStore.shared.enqueueAlbum(album)
                        }
                    }
                case .partial:
                    if !offlineMode.isOffline {
                        Button(String(localized: "download_remaining")) {
                            DownloadStore.shared.enqueueAlbum(album)
                        }
                    }
                    Button(role: .destructive) { showDeleteConfirm = true } label: { Label { Text(String(localized: "delete_downloads")) } icon: { DeleteDownloadIcon(tint: .red) } }
                case .complete:
                    Button(role: .destructive) { showDeleteConfirm = true } label: { Label { Text(String(localized: "delete_downloads")) } icon: { DeleteDownloadIcon(tint: .red) } }
                }
            }
        }
        .alert(String(localized: "delete_downloads_2"), isPresented: $showDeleteConfirm) {
            Button(String(localized: "delete"), role: .destructive) {
                DownloadStore.shared.deleteAlbum(album.id)
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "the_downloads_will_be_removed_from_this_device"))
        }
    }

    private func playInstantMix() {
        InstantMixService.playAlbumMix(for: album)
    }

    private func withAlbumSongs(errorMsg: String, _ action: @MainActor @escaping ([Song]) -> Void) {
        Task {
            if offlineMode.isOffline {
                let songs = DownloadStore.shared.albums
                    .first { $0.albumId == album.id }?
                    .songs.map { $0.asSong() } ?? []
                await MainActor.run { action(songs) }
                return
            }
            do {
                let detail = try await SubsonicAPIService.shared.getAlbum(id: album.id)
                await MainActor.run { action(detail.song ?? []) }
            } catch {
                NotificationCenter.default.post(name: .showToast, object: errorMsg)
            }
        }
    }
}

extension View {
    func albumContextMenu(_ album: Album) -> some View {
        modifier(AlbumContextMenuModifier(album: album))
    }
}
