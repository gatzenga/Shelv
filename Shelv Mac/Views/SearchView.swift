import SwiftUI

struct SearchView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var libraryStore = LibraryViewModel.shared
    @StateObject private var vm = SearchViewModel()
    @FocusState private var isSearchFocused: Bool
    @AppStorage(PersonalizationPreferenceKey.showFavoriteActions) private var showFavoriteActions = true
    @AppStorage(PersonalizationPreferenceKey.showPlaylistActions) private var showPlaylistActions = true
    @State private var lyricsResults: [LyricsSearchResult] = []
    @State private var lyricsTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(String(localized: "search_artists_albums_tracks"), text: $vm.query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onSubmit { Task { await vm.search() } }
                if !vm.query.isEmpty {
                    Button { vm.query = ""; vm.clearResults() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(16)

            Divider()

            if vm.isLoading {
                ProgressView(String(localized: "searching"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.isEmpty && lyricsResults.isEmpty && !vm.query.isEmpty {
                ContentUnavailableView.search(text: vm.query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.isEmpty && lyricsResults.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(String(localized: "enter_a_search_term"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if !vm.artists.isEmpty {
                            SearchSection(title: String(localized: "artists")) {
                                ForEach(vm.artists) { artist in
                                    NavigationLink(value: artist) {
                                        SearchArtistRow(artist: artist)
                                    }
                                    .buttonStyle(.plain)
                                    .artistContextMenu(artist)
                                }
                            }
                        }
                        if !vm.albums.isEmpty {
                            SearchSection(title: String(localized: "albums")) {
                                ForEach(vm.albums) { album in
                                    NavigationLink(value: album) {
                                        SearchAlbumRow(album: album)
                                    }
                                    .buttonStyle(.plain)
                                    .albumContextMenu(album)
                                    .environmentObject(libraryStore)
                                }
                            }
                        }
                        if !vm.songs.isEmpty {
                            SearchSection(title: String(localized: "tracks")) {
                                ForEach(vm.songs) { song in
                                    SearchSongRow(
                                        song: song,
                                        showFavorite: showFavoriteActions,
                                        showPlaylist: showPlaylistActions,
                                        isStarred: libraryStore.isSongStarred(song)
                                    ) {
                                        let idx = vm.songs.firstIndex(where: { $0.id == song.id }) ?? 0
                                        appState.player.play(songs: vm.songs, startIndex: idx)
                                    } onPlayNext: {
                                        appState.player.addPlayNext(song)
                                        NotificationCenter.default.post(name: .showToast, object: String(localized: "added_to_play_next"))
                                    } onAddToQueue: {
                                        appState.player.addToQueue(song)
                                        NotificationCenter.default.post(name: .showToast, object: String(localized: "added_to_queue"))
                                    } onFavorite: {
                                        Task { await libraryStore.toggleStarSong(song) }
                                    } onAddToPlaylist: {
                                        NotificationCenter.default.post(name: .addSongsToPlaylist, object: [song.id])
                                    }
                                }
                            }
                        }
                        if !lyricsResults.isEmpty {
                            SearchSection(title: String(localized: "lyrics")) {
                                ForEach(lyricsResults) { item in
                                    LyricsSearchRow(
                                        item: item,
                                        query: vm.query,
                                        showFavorite: showFavoriteActions,
                                        showPlaylist: showPlaylistActions,
                                        onPlay: { playLyricsResult(item) },
                                        onPlayNext: {
                                            withLyricsSong(item) { song in
                                                appState.player.addPlayNext(song)
                                                NotificationCenter.default.post(name: .showToast, object: String(localized: "added_to_play_next"))
                                            }
                                        },
                                        onAddToQueue: {
                                            withLyricsSong(item) { song in
                                                appState.player.addToQueue(song)
                                                NotificationCenter.default.post(name: .showToast, object: String(localized: "added_to_queue"))
                                            }
                                        },
                                        onFavorite: {
                                            withLyricsSong(item) { song in
                                                Task { await libraryStore.toggleStarSong(song) }
                                            }
                                        },
                                        onAddToPlaylist: {
                                            NotificationCenter.default.post(name: .addSongsToPlaylist, object: [item.songId])
                                        }
                                    )
                                }
                            }
                        }
                    }
                    .padding(.vertical, 20)
                }
            }
        }
        .navigationTitle(String(localized: "search"))
        .onAppear { isSearchFocused = true }
        .onChange(of: vm.query) { _, newValue in
            if newValue.count >= 2 {
                Task { await vm.search() }
                lyricsTask?.cancel()
                lyricsTask = Task { await performLyricsSearch(query: newValue) }
            } else {
                lyricsResults = []
                vm.clearResults()
            }
        }
    }

    private func performLyricsSearch(query: String) async {
        let serverId = appState.serverStore.activeServerID?.uuidString ?? ""
        guard !serverId.isEmpty else { return }
        var results = await LyricsService.shared.searchLyrics(text: query, serverId: serverId)
        guard !Task.isCancelled else { return }
        if OfflineModeService.shared.isOffline {
            let downloadedIds = Set(DownloadStore.shared.songs.map { $0.songId })
            results = results.filter { downloadedIds.contains($0.songId) }
            lyricsResults = results
            return
        }
        lyricsResults = results
        let missing = results.filter { $0.songTitle == nil || $0.duration == nil }
        for item in missing {
            guard !Task.isCancelled else { return }
            guard let song = try? await SubsonicAPIService.shared.getSong(id: item.songId) else { continue }
            await LyricsService.shared.updateMetadata(
                songId: item.songId, serverId: serverId,
                title: song.title, artist: song.artist, coverArt: song.coverArt,
                duration: song.duration
            )
            if let idx = results.firstIndex(where: { $0.songId == item.songId }) {
                results[idx] = LyricsSearchResult(
                    songId: item.songId, songTitle: song.title,
                    artistName: song.artist, coverArt: song.coverArt,
                    snippet: item.snippet, duration: song.duration
                )
                lyricsResults = results
            }
        }
    }

    private func withLyricsSong(_ item: LyricsSearchResult, _ action: @escaping (Song) -> Void) {
        Task {
            if let song = try? await SubsonicAPIService.shared.getSong(id: item.songId) {
                await MainActor.run { action(song) }
            } else {
                let fallback = Song(
                    id: item.songId, title: item.songTitle ?? item.songId,
                    artist: item.artistName, coverArt: item.coverArt
                )
                await MainActor.run { action(fallback) }
            }
        }
    }

    private func playLyricsResult(_ item: LyricsSearchResult) {
        Task {
            let serverId = appState.serverStore.activeServerID?.uuidString ?? ""
            if let song = try? await SubsonicAPIService.shared.getSong(id: item.songId) {
                appState.player.play(songs: [song], startIndex: 0)
                if (item.songTitle == nil || item.artistName == nil || item.coverArt == nil || item.duration == nil) && !serverId.isEmpty {
                    Task.detached(priority: .utility) {
                        await LyricsService.shared.updateMetadata(
                            songId: item.songId, serverId: serverId,
                            title: song.title, artist: song.artist, coverArt: song.coverArt,
                            duration: song.duration
                        )
                    }
                }
            } else {
                let fallback = Song(
                    id: item.songId, title: item.songTitle ?? item.songId,
                    artist: item.artistName, coverArt: item.coverArt
                )
                appState.player.play(songs: [fallback], startIndex: 0)
            }
        }
    }
}

#Preview {
    SearchView()
        .frame(width: 700, height: 600)
        .environmentObject(AppState.shared)
        .environmentObject(LibraryViewModel())
}
