import SwiftUI

struct PlaylistDetailView: View {
    let playlist: Playlist
    @ObservedObject var libraryStore = LibraryViewModel.shared
    @EnvironmentObject var appState: AppState
    @ObservedObject var downloadStore = DownloadStore.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @ObservedObject var pinStore = PinnedPlaylistStore.shared
    @ObservedObject private var personalizationVisibility = MacPersonalizationVisibilityStore.shared
    @AppStorage("enableDownloads") private var enableDownloads = true

    private var showFavoriteActions: Bool {
        personalizationVisibility.showFavoriteActions
    }

    private var showPlaylistActions: Bool {
        personalizationVisibility.showPlaylistActions
    }

    @ViewBuilder
    private func playlistDownloadButtons(iconOnly: Bool) -> some View {
        let isMarked = downloadStore.downloadedPlaylistIds.contains(playlist.id)
        let remaining = isMarked ? songs.filter { !downloadStore.isDownloaded(songId: $0.id) }.count : 0
        if !isMarked && !offlineMode.isOffline {
            Button {
                let missing = songs.filter { !downloadStore.isDownloaded(songId: $0.id) }
                if !missing.isEmpty { downloadStore.enqueueSongs(missing) }
                let currentName = displayName.isEmpty ? playlist.name : displayName
                downloadStore.markPlaylistDownloaded(id: playlist.id, name: currentName, songIds: songs.map { $0.id })
                NotificationCenter.default.post(name: .showToast, object: String(localized: "download_started"))
            } label: {
                Label(String(localized: "download"), systemImage: "arrow.down.circle")
                    .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(themeColor)
        }
        if isMarked && remaining > 0 && !offlineMode.isOffline {
            Button {
                let missing = songs.filter { !downloadStore.isDownloaded(songId: $0.id) }
                if !missing.isEmpty { downloadStore.enqueueSongs(missing) }
                downloadStore.syncPlaylistSongIds(playlist.id, songIds: songs.map(\.id))
                NotificationCenter.default.post(name: .showToast, object: String(localized: "download_started"))
            } label: {
                Label("Rest (\(remaining))", systemImage: "arrow.down.circle")
                    .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(themeColor)
        }
        if isMarked {
            Button(role: .destructive) {
                showDeleteDownloadConfirm = true
            } label: {
                Label {
                    Text(String(localized: "delete_downloads"))
                } icon: {
                    DeleteDownloadIcon(tint: .red)
                }
                .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(.red)
        }
    }

    @ViewBuilder
    private func actionButtons(iconOnly: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                if !songs.isEmpty { appState.player.play(songs: songs) }
            } label: {
                Label(String(localized: "play"), systemImage: "play.fill")
                    .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
                    .frame(minWidth: iconOnly ? nil : 110)
            }
            .buttonStyle(.borderedProminent)
            .tint(themeColor)
            .controlSize(.large)
            .disabled(isLoading || songs.isEmpty)

            Button {
                if !songs.isEmpty { appState.player.playShuffled(songs: songs) }
            } label: {
                Label(String(localized: "shuffle"), systemImage: "shuffle")
                    .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
                    .frame(minWidth: iconOnly ? nil : 100)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isLoading || songs.isEmpty)

            Button {
                appState.player.addPlayNext(songs)
                NotificationCenter.default.post(name: .showToast, object: String(localized: "added_to_play_next"))
            } label: {
                Label(String(localized: "play_next"), systemImage: "text.insert")
                    .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isLoading || songs.isEmpty)

            Button {
                appState.player.addToQueue(songs)
                NotificationCenter.default.post(name: .showToast, object: String(localized: "added_to_queue"))
            } label: {
                Label(String(localized: "add_to_queue"), systemImage: "text.badge.plus")
                    .labelStyle(AdaptiveLabelStyle(iconOnly: iconOnly))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isLoading || songs.isEmpty)

            if enableDownloads && !songs.isEmpty {
                playlistDownloadButtons(iconOnly: iconOnly)
            }
        }
    }
    @Environment(\.themeColor) private var themeColor

    @State private var detail: PlaylistDetail?
    @State private var songs: [Song] = []
    @State private var songOriginalRanks: [String: Int] = [:]
    @State private var isLoading = true
    @State private var showDeleteConfirm = false
    @State private var showDeleteDownloadConfirm = false
    @State private var pendingSongDeletionOffsets = IndexSet()
    @State private var showRemoveSongsConfirm = false
    @State private var isMutatingSongs = false
    @State private var isSavingMetadata = false
    @State private var isEditMode = false
    @State private var editName: String = ""
    @State private var editComment: String = ""
    @State private var displayName: String = ""
    @State private var displayComment: String = ""
    @State private var searchQuery = ""

    private var displayedSongRows: [IndexedSongOccurrence] {
        let rows = IndexedSongOccurrence.rows(for: songs)
        guard !searchQuery.isEmpty, !isEditMode else { return rows }
        return rows.filter { row in
            row.song.title.localizedCaseInsensitiveContains(searchQuery)
                || (row.song.artist?.localizedCaseInsensitiveContains(searchQuery) ?? false)
                || (row.song.album?.localizedCaseInsensitiveContains(searchQuery) ?? false)
        }
    }

    private var displayedSongs: [Song] { displayedSongRows.map(\.song) }

    var body: some View {
        List {
            Section {
                headerView
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .moveDisabled(true)
                    .deleteDisabled(true)
            }

            PlaylistTracksList(
                playlist: playlist,
                songs: $songs,
                displayRows: displayedSongRows,
                isLoading: isLoading,
                isEditMode: isEditMode,
                isMutationDisabled: isMutatingSongs,
                enableFavorites: showFavoriteActions,
                enablePlaylists: showPlaylistActions,
                themeColor: themeColor,
                currentSongId: appState.player.currentSong?.id,
                libraryStore: libraryStore,
                originalRanks: songOriginalRanks,
                onPlayAt: { index in appState.player.play(songs: displayedSongs, startIndex: index) },
                onPlayNext: { song in
                    appState.player.addPlayNext(song)
                    NotificationCenter.default.post(name: .showToast, object: String(localized: "added_to_play_next"))
                },
                onAddToQueue: { song in
                    appState.player.addToQueue(song)
                    NotificationCenter.default.post(name: .showToast, object: String(localized: "added_to_queue"))
                },
                onRemoveAt: { index in
                    requestSongDeletion(at: IndexSet(integer: index))
                },
                onMove: moveSongs,
                onDelete: requestSongDeletion
            )
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle(displayName.isEmpty ? playlist.name : displayName)
        .searchable(text: $searchQuery, prompt: String(localized: "search_songs"))
        .toolbar(content: toolbarContent)
        .alert(String(localized: "delete_downloads_2"), isPresented: $showDeleteDownloadConfirm) {
            Button(String(localized: "delete"), role: .destructive) {
                for song in songs { downloadStore.deleteSong(song.id) }
                downloadStore.unmarkPlaylistDownloaded(id: playlist.id)
                NotificationCenter.default.post(name: .showToast, object: String(localized: "downloads_deleted"))
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "the_downloads_will_be_removed_from_this_device"))
        }
        .alert(
            String(localized: "remove_from_playlist"),
            isPresented: $showRemoveSongsConfirm
        ) {
            Button(String(localized: "delete"), role: .destructive) {
                let offsets = pendingSongDeletionOffsets
                pendingSongDeletionOffsets = []
                deleteSongs(at: offsets)
            }
            Button(String(localized: "cancel"), role: .cancel) {
                pendingSongDeletionOffsets = []
            }
        } message: {
            Text(pendingSongDeletionDescription)
        }
        .alert(String(localized: "delete_playlist"), isPresented: $showDeleteConfirm) {
            Button(String(localized: "delete"), role: .destructive) {
                Task {
                    await libraryStore.deletePlaylist(playlist)
                    appState.selectedPlaylist = nil
                }
            }
            Button(String(localized: "cancel"), role: .cancel) { }
        } message: {
            Text(String(localized: "this_action_cannot_be_undone"))
        }
        .task(id: playlist.id) {
            displayName = playlist.name
            displayComment = playlist.comment ?? ""
            await loadDetail()
        }
        .onChange(of: offlineMode.isOffline) { _, _ in
            songs = []
            Task { await loadDetail() }
        }
        .onChange(of: downloadStore.songs.count) { _, _ in
            guard offlineMode.isOffline else { return }
            Task { await loadDetail() }
        }
        .refreshable {
            if await offlineMode.beginUserInitiatedServerRefresh() { return }
            defer { offlineMode.finishUserInitiatedServerRefresh() }
            Task { await CloudKitSyncService.shared.syncNow() }
            await loadDetail()
        }
    }

    @ToolbarContentBuilder
    private func toolbarContent() -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                pinStore.togglePin(playlist.id)
            } label: {
                Label(
                    pinStore.isPinned(playlist.id) ? String(localized: "unpin") : String(localized: "pin"),
                    systemImage: pinStore.isPinned(playlist.id) ? "pin.slash" : "pin"
                )
            }
            .help(pinStore.isPinned(playlist.id) ? String(localized: "unpin") : String(localized: "pin"))
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                if isEditMode {
                    commitEdits()
                } else {
                    editName = displayName
                    editComment = displayComment
                }
                isEditMode.toggle()
            } label: {
                Label(
                    isEditMode ? String(localized: "done") : String(localized: "edit"),
                    systemImage: isEditMode ? "checkmark" : "pencil"
                )
            }
            .help(isEditMode ? String(localized: "finish_editing") : String(localized: "edit_playlist"))
            .disabled(isLoading || isMutatingSongs || isSavingMetadata)
        }
        ToolbarItem(placement: .primaryAction) {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label(String(localized: "delete"), systemImage: "trash")
            }
            .help(String(localized: "delete_playlist_2"))
            .tint(.red)
        }
    }

    @ViewBuilder
    private var headerView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                CoverArtView(
                    url: playlist.coverArt.flatMap { SubsonicAPIService.shared.coverArtURL(id: $0, size: 320) },
                    size: 160,
                    cornerRadius: 12
                )
                .shadow(color: .black.opacity(0.25), radius: 14)

                VStack(alignment: .leading, spacing: 8) {
                    if isEditMode {
                        TextField(String(localized: "name"), text: $editName)
                            .font(.title.bold())
                            .textFieldStyle(.roundedBorder)
                        TextField(String(localized: "comment_optional"), text: $editComment, axis: .vertical)
                            .font(.body)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...3)
                    } else {
                        Text(displayName)
                            .font(.title.bold())
                            .lineLimit(2)
                        if !displayComment.isEmpty {
                            Text(displayComment)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !isLoading {
                        TrackCollectionSummaryView(songs: songs)
                    }

                    Spacer(minLength: 12)

                    ViewThatFits(in: .horizontal) {
                        actionButtons(iconOnly: false)
                        actionButtons(iconOnly: true)
                    }
                }

                Spacer()
            }
            .padding(28)

            Divider()
                .padding(.horizontal, 28)
                .padding(.bottom, 8)
        }
    }

    private func loadDetail() async {
        isLoading = true
        if let loaded = await libraryStore.loadPlaylistDetail(id: playlist.id) {
            detail = loaded
            let allSongs = loaded.songs ?? []
            songOriginalRanks = Dictionary(allSongs.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { first, _ in first })
            songs = offlineMode.isOffline
                ? allSongs.filter { downloadStore.isDownloaded(songId: $0.id) }
                : allSongs
            displayName = loaded.name
            displayComment = loaded.comment ?? ""
            if !offlineMode.isOffline {
                downloadStore.syncPlaylistSongIds(playlist.id, songIds: allSongs.map(\.id))
            }
        }
        if songs.isEmpty && !offlineMode.isOffline && downloadStore.downloadedPlaylistIds.contains(playlist.id) {
            let ids = downloadStore.playlistSongIds[playlist.id] ?? []
            songs = ids.compactMap { id in downloadStore.songs.first { $0.songId == id }?.asSong() }
        }
        isLoading = false
    }

    private func moveSongs(from: IndexSet, to: Int) {
        guard !isMutatingSongs else { return }
        let previousSongs = songs
        isMutatingSongs = true
        songs.move(fromOffsets: from, toOffset: to)
        Task {
            await syncOrder(previousSongs: previousSongs)
            isMutatingSongs = false
        }
    }

    private var pendingSongDeletionDescription: String {
        pendingSongDeletionOffsets
            .compactMap { songs.indices.contains($0) ? songs[$0].title : nil }
            .map { "\"\($0)\"" }
            .joined(separator: "\n")
    }

    private func requestSongDeletion(at offsets: IndexSet) {
        guard !isMutatingSongs else { return }
        let validOffsets = IndexSet(offsets.filter { songs.indices.contains($0) })
        guard !validOffsets.isEmpty else { return }
        pendingSongDeletionOffsets = validOffsets
        showRemoveSongsConfirm = true
    }

    private func deleteSongs(at offsets: IndexSet) {
        guard !isMutatingSongs else { return }
        let validOffsets = IndexSet(offsets.filter { songs.indices.contains($0) })
        guard !validOffsets.isEmpty else { return }
        let previousSongs = songs
        let indices = Array(validOffsets)
        isMutatingSongs = true
        songs.remove(atOffsets: validOffsets)
        Task {
            if await libraryStore.removeSongsFromPlaylist(playlist, indices: indices) {
                await loadDetail()
            } else {
                songs = previousSongs
            }
            isMutatingSongs = false
        }
    }

    private func commitEdits() {
        let name = editName.trimmingCharacters(in: .whitespaces)
        let comment = editComment.trimmingCharacters(in: .whitespaces)
        let nameChanged = !name.isEmpty && name != displayName
        let commentChanged = comment != displayComment
        guard nameChanged || commentChanged else { return }

        let previousName = displayName
        let previousComment = displayComment
        let newName = nameChanged ? name : displayName
        let newComment = commentChanged ? comment : displayComment
        displayName = newName
        displayComment = newComment
        editName = newName
        editComment = newComment
        isSavingMetadata = true

        Task {
            defer { isSavingMetadata = false }
            do {
                try await SubsonicAPIService.shared.updatePlaylist(
                    id: playlist.id,
                    name: nameChanged ? name : nil,
                    comment: commentChanged ? comment : nil
                )
                let updated = libraryStore.applyPlaylistMetadata(
                    playlist,
                    name: newName,
                    comment: newComment
                )
                if let currentDetail = detail {
                    detail = PlaylistDetail(
                        id: currentDetail.id,
                        name: newName,
                        comment: newComment,
                        songCount: currentDetail.songCount,
                        duration: currentDetail.duration,
                        coverArt: currentDetail.coverArt,
                        songs: currentDetail.songs
                    )
                }
                appState.selectedPlaylist = updated
            } catch {
                displayName = previousName
                displayComment = previousComment
                editName = previousName
                editComment = previousComment
                if !OfflineModeService.shared.presentConnectivityErrorIfNeeded(error, userInitiated: true) {
                    NotificationCenter.default.post(
                        name: .showToast,
                        object: String(localized: "changes_could_not_be_saved")
                    )
                }
            }
        }
    }

    private func syncOrder(previousSongs: [Song]) async {
        let newIds = songs.map(\.id)
        let allOldIndices = Array(0..<newIds.count)
        do {
            try await SubsonicAPIService.shared.updatePlaylist(
                id: playlist.id,
                songIdsToAdd: newIds,
                songIndicesToRemove: allOldIndices
            )
            await loadDetail()
        } catch {
            if !OfflineModeService.shared.presentConnectivityErrorIfNeeded(error, userInitiated: true) {
                NotificationCenter.default.post(
                    name: .showToast,
                    object: String(localized: "order_could_not_be_saved")
                )
            }
            songs = previousSongs
        }
    }

}
