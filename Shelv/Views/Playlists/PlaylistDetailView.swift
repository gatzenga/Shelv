import Combine
import SwiftUI

struct PlaylistDetailView: View {
    private struct PresentedSongRow: Identifiable {
        struct ID: Hashable {
            let occurrenceID: IndexedSongOccurrence.ID
            let deletionRevision: Int
        }

        let occurrence: IndexedSongOccurrence
        let deletionRevision: Int

        var id: ID {
            ID(occurrenceID: occurrence.id, deletionRevision: deletionRevision)
        }

        var occurrenceID: IndexedSongOccurrence.ID { occurrence.id }
        var index: Int { occurrence.index }
        var song: Song { occurrence.song }
    }

    let playlist: Playlist

    @ObservedObject var libraryStore = LibraryStore.shared
    private let downloadStore = DownloadStore.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    private let player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    @AppStorage(PersonalizationPreferenceKey.showFavoriteActions) private var showFavoriteActions = true
    @AppStorage(PersonalizationPreferenceKey.showPlaylistActions) private var showPlaylistActions = true
    @AppStorage("enableDownloads") private var enableDownloads = true

    @State private var songs: [Song] = []
    @State private var displayName: String = ""
    @State private var showAddToPlaylist = false
    @State private var playlistSongIds: [String] = []
    @State private var isLoading = true
    @State private var isEditMode = false
    @State private var searchQuery = ""
    @State private var showRenameAlert = false
    @State private var newName = ""
    @State private var newComment = ""
    @State private var pendingSongDeletionOffsets = IndexSet()
    @State private var showRemoveSongsConfirm = false
    @State private var songDeletionRevisions: [IndexedSongOccurrence.ID: Int] = [:]
    @State private var showDeleteConfirm = false
    @State private var showDeleteDownloadConfirm = false
    @State private var currentToast: ShelveToast?
    @State private var isSyncing = false
    @State private var originalRanks: [String: Int] = [:]
    @State private var isMarkedForOffline: Bool
    @State private var trackedPlaylistSongIDs: Set<String>
    @State private var downloadedSongIDs: Set<String>
    @Environment(\.dismiss) private var dismiss

    init(playlist: Playlist) {
        self.playlist = playlist
        let downloadStore = DownloadStore.shared
        let trackedSongIDs = Set(downloadStore.playlistSongIds[playlist.id] ?? [])
        _isMarkedForOffline = State(
            initialValue: downloadStore.offlinePlaylistIds.contains(playlist.id)
        )
        _trackedPlaylistSongIDs = State(initialValue: trackedSongIDs)
        _downloadedSongIDs = State(
            initialValue: DownloadUIStateHub.shared.downloadedSongIDs(in: trackedSongIDs)
        )
    }

    private var displayedSongRows: [PresentedSongRow] {
        let rows = IndexedSongOccurrence.rows(for: songs)
        let filteredRows: [IndexedSongOccurrence]
        if !searchQuery.isEmpty, !isEditMode {
            filteredRows = rows.filter { row in
                row.song.title.localizedCaseInsensitiveContains(searchQuery)
                    || (row.song.artist?.localizedCaseInsensitiveContains(searchQuery) ?? false)
                    || (row.song.album?.localizedCaseInsensitiveContains(searchQuery) ?? false)
            }
        } else {
            filteredRows = rows
        }
        return filteredRows.map { row in
            PresentedSongRow(
                occurrence: row,
                deletionRevision: songDeletionRevisions[row.id, default: 0]
            )
        }
    }

    private var relevantDownloadedSongIDsPublisher: AnyPublisher<Set<String>, Never> {
        let songIDs = trackedPlaylistSongIDs.isEmpty
            ? Set(songs.map(\.id))
            : trackedPlaylistSongIDs
        return DownloadUIStateHub.shared.downloadedSongSubsetPublisher(songIDs: songIDs)
    }

    var body: some View {
        List {
            if searchQuery.isEmpty {
                Section {
                    headerView
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }

            if isLoading {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .listRowSeparator(.hidden)
                }
            } else if songs.isEmpty {
                Section {
                    Text(String(localized: "no_songs_in_this_playlist"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .listRowSeparator(.hidden)
                }
            } else {
                Section {
                    ForEach(displayedSongRows) { row in
                        let song = row.song
                        let songsIndex = row.index
                        Button {
                            player.play(songs: songs, startIndex: songsIndex)
                        } label: {
                            HStack(spacing: 14) {
                                if !isEditMode {
                                    NowPlayingIndicator(
                                        songId: song.id,
                                        fallbackIndex: originalRanks[song.id] ?? (songsIndex + 1),
                                        accentColor: accentColor
                                    )
                                }
                                AlbumArtView(coverArtId: song.coverArt, size: 100, cornerRadius: 6)
                                    .frame(width: 40, height: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(song.title)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if let artist = song.artist {
                                        Text(artist)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                if !isEditMode {
                                    HStack(spacing: 4) {
                                        SongFavoriteBadge(songId: song.id)
                                        DownloadStatusIcon(songId: song.id)
                                    }
                                    Text(song.durationFormatted)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .personalizedSongSwipeActions(
                            song: song,
                            isOffline: offlineMode.isOffline,
                            isFavorite: libraryStore.isSongStarred(song),
                            accentColor: accentColor,
                            isEnabled: !isEditMode,
                            onPlay: {
                                player.play(songs: songs, startIndex: songsIndex)
                            },
                            onFavorite: {
                                haptic(.medium)
                                Task { await libraryStore.toggleStarSong(song) }
                            },
                            onAddToPlaylist: {
                                playlistSongIds = [song.id]
                                showAddToPlaylist = true
                            },
                            onPlayNext: {
                                haptic()
                                player.addPlayNext(song)
                                currentToast = ShelveToast(message: String(localized: "plays_next"))
                            },
                            onAddToQueue: {
                                haptic()
                                player.addToQueue(song)
                                currentToast = ShelveToast(message: String(localized: "added_to_queue"))
                            }
                        )
                    }
                    .onMove { from, to in
                        songs.move(fromOffsets: from, toOffset: to)
                        Task { await syncOrder() }
                    }
                    .onDelete { offsets in
                        requestSongDeletion(at: offsets)
                    }
                    .deleteDisabled(!isEditMode)

                    PlayerBottomSpacer(activeHeight: 110, inactiveHeight: 0)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .scrollIndicators(.hidden)
        .searchable(text: $searchQuery, prompt: String(localized: "search_songs"))
        .environment(\.editMode, .constant(isEditMode ? .active : .inactive))
        .navigationTitle(displayName.isEmpty ? playlist.name : displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isEditMode {
                    Button(String(localized: "done")) {
                        isEditMode = false
                    }
                    .bold()
                } else {
                    Menu {
                        Button {
                            if !songs.isEmpty {
                                player.addPlayNext(songs)
                                currentToast = ShelveToast(message: String(localized: "plays_next"))
                            }
                        } label: {
                            Label(String(localized: "play_next"), systemImage: "text.insert")
                        }
                        .disabled(songs.isEmpty)

                        Button {
                            if !songs.isEmpty {
                                player.addToQueue(songs)
                                currentToast = ShelveToast(message: String(localized: "added_to_queue"))
                            }
                        } label: {
                            Label(String(localized: "add_to_queue"), systemImage: "text.badge.plus")
                        }
                        .disabled(songs.isEmpty)

                        if enableDownloads
                            && !songs.isEmpty
                            && (!offlineMode.isOffline || isMarkedForOffline) {
                            Divider()
                            playlistDownloadMenuItems
                        }

                        Divider()

                        Button {
                            searchQuery = ""
                            isEditMode = true
                        } label: {
                            Label(String(localized: "reorder_delete"), systemImage: "pencil")
                        }

                        Button {
                            newName = displayName.isEmpty ? playlist.name : displayName
                            newComment = playlist.comment ?? ""
                            showRenameAlert = true
                        } label: {
                            Label(String(localized: "rename"), systemImage: "pencil.line")
                        }

                        Divider()

                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label(String(localized: "delete_playlist"), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .symbolRenderingMode(.hierarchical)
                    }
                }
            }
        }
        .shelveToast($currentToast)
        .alert(String(localized: "rename_playlist"), isPresented: $showRenameAlert) {
            TextField(String(localized: "name"), text: $newName)
            TextField(String(localized: "comment"), text: $newComment)
            Button(String(localized: "save")) {
                let name = newName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                let comment = newComment.trimmingCharacters(in: .whitespaces)
                Task {
                    await libraryStore.renamePlaylist(playlist, newName: name, newComment: comment)
                    displayName = name
                }
            }
            .bold()
            Button(String(localized: "cancel"), role: .cancel) {}
        }
        .alert(
            String(localized: "delete_downloads"),
            isPresented: $showDeleteDownloadConfirm
        ) {
            Button(String(localized: "delete"), role: .destructive) {
                for song in songs { downloadStore.deleteSong(song.id) }
                downloadStore.removeOfflinePlaylist(playlist.id)
                currentToast = ShelveToast(message: String(localized: "downloads_deleted"))
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
                withAnimation(.easeInOut(duration: 0.2)) {
                    removeSongs(at: offsets)
                }
            }
            Button(String(localized: "cancel"), role: .cancel) {
                pendingSongDeletionOffsets = []
            }
        } message: {
            Text(pendingSongDeletionDescription)
        }
        .alert(String(localized: "delete_playlist_2"), isPresented: $showDeleteConfirm) {
            Button(String(localized: "delete"), role: .destructive) {
                Task {
                    do {
                        try await libraryStore.deletePlaylist(playlist)
                        dismiss()
                    } catch {
                        if !(error is CancellationError),
                           !OfflineModeService.shared.presentConnectivityErrorIfNeeded(error, userInitiated: true) {
                            currentToast = ShelveToast(message: String(localized: "could_not_delete_playlist"), isError: true)
                        }
                    }
                }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text("\"\(playlist.name)\"")
        }
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistSheet(songIds: playlistSongIds)
                .environmentObject(libraryStore)
                .tint(accentColor)
        }
        .task(id: playlist.id) {
            displayName = playlist.name
            songs = []
            await loadSongs()
        }
        .onChange(of: offlineMode.isOffline) { _, _ in
            songs = []
            Task { await loadSongs() }
        }
        .onReceive(
            downloadStore.$offlinePlaylistIds
                .map { $0.contains(playlist.id) }
                .removeDuplicates()
        ) { isMarkedForOffline = $0 }
        .onReceive(
            downloadStore.$playlistSongIds
                .map { Set($0[playlist.id] ?? []) }
                .removeDuplicates()
        ) { trackedPlaylistSongIDs = $0 }
        .onReceive(relevantDownloadedSongIDsPublisher) { songIDs in
            guard downloadedSongIDs != songIDs else { return }
            downloadedSongIDs = songIDs
            if offlineMode.isOffline {
                Task { await loadSongs() }
            }
        }
    }

    private var headerView: some View {
        VStack(spacing: 16) {
            AlbumArtView(coverArtId: playlist.coverArt, size: 600, cornerRadius: 16)
                .frame(width: 220, height: 220)
                .shadow(color: .black.opacity(0.3), radius: 20, y: 10)

            VStack(spacing: 4) {
                Text(displayName.isEmpty ? playlist.name : displayName)
                    .font(.title2).bold()
                    .multilineTextAlignment(.center)
                if let comment = playlist.comment, !comment.isEmpty {
                    Text(comment)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if !isLoading {
                    TrackCollectionSummaryView(songs: songs, alignment: .center)
                }
            }
            .padding(.horizontal)

            HStack(spacing: 14) {
                Button {
                    if !songs.isEmpty { player.play(songs: songs, startIndex: 0) }
                } label: {
                    Label(String(localized: "play"), systemImage: "play.fill")
                        .font(.body).bold()
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(accentColor)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(songs.isEmpty)

                Button {
                    if !songs.isEmpty { player.playShuffled(songs: songs) }
                } label: {
                    Label(String(localized: "shuffle"), systemImage: "shuffle")
                        .font(.body).bold()
                        .foregroundStyle(accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(accentColor.opacity(0.15))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(songs.isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .padding(.top, 16)
    }

    @ViewBuilder
    private var playlistDownloadMenuItems: some View {
        let isMarked = isMarkedForOffline
        let remaining = isMarked ? songs.filter { !downloadedSongIDs.contains($0.id) }.count : 0
        if !isMarked && !offlineMode.isOffline {
            Button {
                haptic()
                let missing = songs.filter {
                    !DownloadUIStateHub.shared.isSongDownloaded($0.id)
                }
                if !missing.isEmpty { downloadStore.enqueueSongs(missing) }
                downloadStore.addOfflinePlaylist(playlist.id, songIds: songs.map(\.id))
                currentToast = ShelveToast(message: String(localized: "download_started"))
            } label: {
                Label(String(localized: "download"), systemImage: "arrow.down.circle")
                    .foregroundStyle(accentColor)
            }
            .tint(accentColor)
        }
        if isMarked && remaining > 0 && !offlineMode.isOffline {
            Button {
                haptic()
                let missing = songs.filter {
                    !DownloadUIStateHub.shared.isSongDownloaded($0.id)
                }
                if !missing.isEmpty { downloadStore.enqueueSongs(missing) }
                downloadStore.syncPlaylistSongIds(playlist.id, songIds: songs.map(\.id))
                currentToast = ShelveToast(message: String(localized: "download_started"))
            } label: {
                Label("Rest (\(remaining))", systemImage: "arrow.down.circle")
                    .foregroundStyle(accentColor)
            }
            .tint(accentColor)
        }
        if isMarked {
            Button(role: .destructive) {
                haptic()
                showDeleteDownloadConfirm = true
            } label: {
                Label {
                    Text(String(localized: "delete_downloads_2"))
                } icon: {
                    DeleteDownloadIcon(tint: .red)
                }
            }
            .tint(.red)
        }
    }

    private func loadSongs() async {
        isLoading = true
        if let loaded = await libraryStore.loadPlaylistDetail(id: playlist.id) {
            let allSongs = loaded.songs ?? []
            originalRanks = Dictionary(allSongs.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { first, _ in first })
            songs = offlineMode.isOffline
                ? allSongs.filter { DownloadUIStateHub.shared.isSongDownloaded($0.id) }
                : allSongs
            if !offlineMode.isOffline {
                downloadStore.syncPlaylistSongIds(playlist.id, songIds: allSongs.map(\.id))
            }
        }
        // Fallback auf heruntergeladene Songs wenn API fehlschlug und Playlist markiert ist
        if songs.isEmpty && !offlineMode.isOffline && downloadStore.offlinePlaylistIds.contains(playlist.id) {
            let ids = downloadStore.playlistSongIds[playlist.id] ?? []
            if originalRanks.isEmpty {
                originalRanks = Dictionary(ids.enumerated().map { ($1, $0 + 1) }, uniquingKeysWith: { first, _ in first })
            }
            songs = ids.compactMap { id in downloadStore.songs.first { $0.songId == id }?.asSong() }
        }
        let currentTrackedSongIDs = Set(downloadStore.playlistSongIds[playlist.id] ?? songs.map(\.id))
        trackedPlaylistSongIDs = currentTrackedSongIDs
        downloadedSongIDs = DownloadUIStateHub.shared.downloadedSongIDs(in: currentTrackedSongIDs)
        isLoading = false
    }

    private var pendingSongDeletionDescription: String {
        pendingSongDeletionOffsets
            .compactMap { songs.indices.contains($0) ? songs[$0].title : nil }
            .map { "\"\($0)\"" }
            .joined(separator: "\n")
    }

    private func requestSongDeletion(at offsets: IndexSet) {
        guard isEditMode, !isSyncing else { return }
        let validOffsets = IndexSet(offsets.filter { songs.indices.contains($0) })
        guard !validOffsets.isEmpty else { return }
        let currentRows = displayedSongRows
        let affectedRowIDs = validOffsets.compactMap { offset in
            currentRows.indices.contains(offset)
                ? currentRows[offset].occurrenceID
                : nil
        }
        haptic()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            // SwiftUI calls onDelete after visually removing the native row.
            // Refresh only that row's presentation identity so it remains in
            // place while the unchanged source data awaits confirmation.
            for rowID in affectedRowIDs {
                songDeletionRevisions[rowID, default: 0] += 1
            }
            pendingSongDeletionOffsets = validOffsets
            showRemoveSongsConfirm = true
        }
    }

    private func removeSongs(at offsets: IndexSet) {
        guard !isSyncing else { return }
        let validOffsets = IndexSet(offsets.filter { songs.indices.contains($0) })
        guard !validOffsets.isEmpty else { return }
        isSyncing = true
        let indices = Array(validOffsets).sorted(by: >)
        songs.remove(atOffsets: validOffsets)
        Task {
            await libraryStore.removeSongsFromPlaylist(playlist, indices: indices)
            isSyncing = false
        }
    }

    private func syncOrder() async {
        guard !isSyncing else { return }
        isSyncing = true
        let newIds = songs.map(\.id)
        let allOldIndices = Array(0..<newIds.count)
        do {
            try await SubsonicAPIService.shared.updatePlaylist(
                id: playlist.id,
                songIdsToAdd: newIds,
                songIndicesToRemove: allOldIndices
            )
        } catch {
            currentToast = ShelveToast(message: String(localized: "order_could_not_be_saved"), isError: true)
            await loadSongs()
        }
        isSyncing = false
    }
}
