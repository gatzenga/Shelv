import SwiftUI

struct ArtistContextMenuModifier: ViewModifier {
    let artist: Artist
    @ObservedObject var libraryStore = LibraryViewModel.shared
    @ObservedObject var downloadStore = DownloadStore.shared
    @EnvironmentObject var appState: AppState
    @ObservedObject private var offlineMode = OfflineModeService.shared
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    @AppStorage("enableDownloads") private var enableDownloads = false
    @State private var showDeleteConfirm = false

    func body(content: Content) -> some View {
        content.contextMenu {
            Button(String(localized: "play")) {
                Task {
                    do {
                        let songs = try await fetchSongs()
                        guard !songs.isEmpty else { return }
                        await MainActor.run { AudioPlayerService.shared.play(songs: songs) }
                    } catch {
                        NotificationCenter.default.post(name: .showToast, object: String(localized: "playback_failed"))
                    }
                }
            }
            Button(String(localized: "shuffle")) {
                Task {
                    do {
                        let songs = try await fetchSongs()
                        guard !songs.isEmpty else { return }
                        await MainActor.run { AudioPlayerService.shared.playShuffled(songs: songs) }
                    } catch {
                        NotificationCenter.default.post(name: .showToast, object: String(localized: "playback_failed"))
                    }
                }
            }
            Divider()
            Button(String(localized: "play_next")) {
                Task {
                    do {
                        let songs = try await fetchSongs()
                        guard !songs.isEmpty else { return }
                        await MainActor.run {
                            AudioPlayerService.shared.addPlayNext(songs)
                            NotificationCenter.default.post(name: .showToast, object: String(localized: "added_to_play_next"))
                        }
                    } catch {
                        NotificationCenter.default.post(name: .showToast, object: String(localized: "action_failed"))
                    }
                }
            }
            Button(String(localized: "add_to_queue")) {
                Task {
                    do {
                        let songs = try await fetchSongs()
                        guard !songs.isEmpty else { return }
                        await MainActor.run {
                            AudioPlayerService.shared.addToUserQueue(songs)
                            NotificationCenter.default.post(name: .showToast, object: String(localized: "added_to_queue"))
                        }
                    } catch {
                        NotificationCenter.default.post(name: .showToast, object: String(localized: "action_failed"))
                    }
                }
            }
            if enableFavorites || enablePlaylists {
                Divider()
                if enableFavorites {
                    Button(libraryStore.isArtistStarred(artist)
                           ? String(localized: "remove_from_favorites")
                           : String(localized: "add_to_favorites")) {
                        Task { await libraryStore.toggleStarArtist(artist) }
                    }
                }
                if enablePlaylists {
                    Button(String(localized: "add_to_playlist")) {
                        Task {
                            do {
                                let songs = try await fetchSongs()
                                guard !songs.isEmpty else { return }
                                let ids = songs.map(\.id)
                                await MainActor.run {
                                    NotificationCenter.default.post(name: .addSongsToPlaylist, object: ids)
                                }
                            } catch {
                                NotificationCenter.default.post(name: .showToast, object: String(localized: "action_failed"))
                            }
                        }
                    }
                }
            }
            if enableDownloads {
                Divider()
                if !offlineMode.isOffline {
                    Button(String(localized: "download_artist")) {
                        let stable = appState.serverStore.activeServer?.stableId ?? ""
                        Task { await DownloadService.shared.enqueueArtist(artist: artist, serverId: stable) }
                        NotificationCenter.default.post(name: .showToast, object: String(localized: "download_started"))
                    }
                }
                if downloadStore.artists.contains(where: { $0.name == artist.name }) {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label { Text(String(localized: "delete_downloads")) } icon: { DeleteDownloadIcon(tint: .red) }
                    }
                }
            }
        }
        .alert(String(localized: "delete_downloads_2"), isPresented: $showDeleteConfirm) {
            Button(String(localized: "delete"), role: .destructive) {
                if let match = downloadStore.artists.first(where: { $0.name == artist.name }) {
                    downloadStore.deleteArtist(match.artistId)
                }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "the_downloads_will_be_removed_from_this_device"))
        }
    }

    private func fetchSongs() async throws -> [Song] {
        if offlineMode.isOffline {
            return DownloadStore.shared.artists
                .first { $0.name == artist.name }?
                .albums.flatMap { $0.songs.map { $0.asSong() } } ?? []
        }
        let detail = try await SubsonicAPIService.shared.getArtist(id: artist.id)
        return try await withThrowingTaskGroup(of: [Song].self) { group -> [Song] in
            for album in detail.album ?? [] {
                group.addTask { try await SubsonicAPIService.shared.getAlbum(id: album.id).song ?? [] }
            }
            var result: [Song] = []
            for try await albumSongs in group { result.append(contentsOf: albumSongs) }
            return result
        }
    }
}

extension View {
    func artistContextMenu(_ artist: Artist) -> some View {
        modifier(ArtistContextMenuModifier(artist: artist))
    }
}
