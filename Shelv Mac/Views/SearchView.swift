import SwiftUI

struct SearchView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var libraryStore = LibraryViewModel.shared
    @ObservedObject private var serverStore = ServerStore.shared
    @StateObject private var vm = SearchViewModel()
    @FocusState private var isSearchFocused: Bool
    @AppStorage(PersonalizationPreferenceKey.showFavoriteActions) private var showFavoriteActions = true
    @AppStorage(PersonalizationPreferenceKey.showPlaylistActions) private var showPlaylistActions = true
    @AppStorage("enableDownloads") private var enableDownloads = true
    @State private var lyricsResults: [LyricsSearchResult] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var lyricsTask: Task<Void, Never>?
    @State private var recentSearches: [String] = []

    private var trimmedQuery: String {
        vm.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(String(localized: "search_artists_albums_tracks"), text: $vm.query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onSubmit {
                        commitCurrentSearch()
                        Task { await vm.search() }
                    }
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
            } else if trimmedQuery.isEmpty && !recentSearches.isEmpty {
                searchHistoryView
            } else if vm.isEmpty && lyricsResults.isEmpty && !trimmedQuery.isEmpty {
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
                    LazyVStack(alignment: .leading, spacing: 28) {
                        if !vm.artists.isEmpty {
                            SearchSection(title: String(localized: "artists")) {
                                ForEach(vm.artists) { artist in
                                    NavigationLink(value: artist) {
                                        SearchArtistRow(
                                            artist: artist,
                                            showsDownloadBadge: enableDownloads
                                        )
                                    }
                                    .simultaneousGesture(
                                        TapGesture().onEnded { commitCurrentSearch() }
                                    )
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
                                    .simultaneousGesture(
                                        TapGesture().onEnded { commitCurrentSearch() }
                                    )
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
                                        commitCurrentSearch()
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
                                        isStarred: libraryStore.starredSongs.contains { $0.id == item.songId },
                                        onPlay: {
                                            commitCurrentSearch()
                                            playLyricsResult(item)
                                        },
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
                                        onInstantMix: {
                                            withLyricsSong(item) { song in
                                                InstantMixService.playSongMix(for: song, player: appState.player)
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
        .onAppear {
            isSearchFocused = true
            reloadSearchHistory()
        }
        .onChange(of: serverStore.activeServerID) { _, _ in
            reloadSearchHistory()
        }
        .onChange(of: vm.query) { _, newValue in
            searchTask?.cancel()
            lyricsTask?.cancel()

            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 2 {
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    await vm.search()
                }
                lyricsTask?.cancel()
                lyricsTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    await performLyricsSearch(query: trimmed)
                }
            } else {
                lyricsResults = []
                vm.clearResults()
            }
        }
        .onDisappear {
            searchTask?.cancel()
            lyricsTask?.cancel()
            vm.cancelSearch()
        }
    }

    private var searchHistoryView: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "recent_searches"))
                    .font(.headline)
                Spacer()
                Button {
                    clearSearchHistory()
                } label: {
                    Text(String(localized: "clear"))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityLabel(String(localized: "clear_search_history"))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(recentSearches, id: \.self) { entry in
                        Button {
                            selectSearchHistoryEntry(entry)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                Text(entry)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Divider()
                            .padding(.leading, 52)
                    }
                }
            }
        }
    }

    private func reloadSearchHistory() {
        recentSearches = SearchHistoryStore.entries(for: serverStore.activeServerID)
    }

    private func commitCurrentSearch() {
        recentSearches = SearchHistoryStore.record(
            vm.query,
            for: serverStore.activeServerID
        )
    }

    private func selectSearchHistoryEntry(_ entry: String) {
        recentSearches = SearchHistoryStore.record(
            entry,
            for: serverStore.activeServerID
        )
        vm.query = entry
        isSearchFocused = true
    }

    private func clearSearchHistory() {
        recentSearches = SearchHistoryStore.clear(for: serverStore.activeServerID)
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
