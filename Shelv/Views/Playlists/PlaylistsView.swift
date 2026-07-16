import SwiftUI

struct PlaylistsView: View {
    @ObservedObject var libraryStore = LibraryStore.shared
    @EnvironmentObject var recapStore: RecapStore
    @ObservedObject var downloadStore = DownloadStore.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @ObservedObject var pinStore = PinnedPlaylistStore.shared
    private let player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("enableDownloads") private var enableDownloads = true
    @AppStorage("recapEnabled") private var recapEnabled = false
    @AppStorage(PersonalizationPreferenceKey.showPlaylistActions) private var showPlaylistActions = true
    @AppStorage("playlistSortOption") private var sortOptionRaw: String = PlaylistSortOption.alphabetical.rawValue
    private var sortOption: PlaylistSortOption { PlaylistSortOption(rawValue: sortOptionRaw) ?? .alphabetical }
    @AppStorage("playlistSortDirection") private var sortDirectionRaw: String = SortDirection.ascending.rawValue
    private var sortDirection: SortDirection { SortDirection(rawValue: sortDirectionRaw) ?? .ascending }
    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    private var visiblePlaylists: [Playlist] {
        var noRecap = recapEnabled
            ? libraryStore.playlists.filter { !recapStore.recapPlaylistIds.contains($0.id) }
            : libraryStore.playlists
        if offlineMode.isOffline {
            noRecap = noRecap.filter { downloadStore.offlinePlaylistIds.contains($0.id) }
        }
        return sortedPlaylists(noRecap)
    }

    private var visiblePlaylistTree: [PlaylistTreeNode] {
        PlaylistTreeNode.make(from: visiblePlaylists)
    }

    private func sortedPlaylists(_ playlists: [Playlist]) -> [Playlist] {
        let sorted = applySortOption(playlists)
        // Angepinnte oben, zuletzt angepinnt zuoberst (pinRank 0). Rest behält Sortierung.
        let pinned = sorted.filter { pinStore.isPinned($0.id) }
            .sorted { (pinStore.pinRank($0.id) ?? 0) < (pinStore.pinRank($1.id) ?? 0) }
        let rest = sorted.filter { !pinStore.isPinned($0.id) }
        return pinned + rest
    }

    private func applySortOption(_ playlists: [Playlist]) -> [Playlist] {
        switch sortOption {
        case .alphabetical:
            // Fix A–Z, kein Richtungs-Toggle (analog Alben).
            return playlists.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .lastModified:
            let asc = playlists.sorted { ($0.changed ?? .distantPast) < ($1.changed ?? .distantPast) }
            return sortDirection == .descending ? asc.reversed() : asc
        case .dateCreated:
            let asc = playlists.sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
            return sortDirection == .descending ? asc.reversed() : asc
        }
    }

    @State private var showCreateSheet = false
    @State private var newPlaylistName = ""
    @FocusState private var nameFieldFocused: Bool
    @State private var showDeleteConfirm = false
    @State private var playlistToDelete: Playlist?
    @State private var currentToast: ShelveToast?
    @State private var playlistToDeleteDownloads: Playlist?

    var body: some View {
        NavigationStack {
            Group {
                if libraryStore.isLoadingPlaylists && libraryStore.playlists.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visiblePlaylists.isEmpty {
                    List {
                        ContentUnavailableView(
                            String(localized: "no_playlists_2"),
                            systemImage: "music.note.list",
                            description: Text(String(localized: "create_a_playlist_to_get_started"))
                        )
                        .frame(maxWidth: .infinity, minHeight: 400)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                    }
                    .listStyle(.plain)
                    .scrollIndicators(.hidden)
                } else {
                    List {
                        Section {
                            OutlineGroup(visiblePlaylistTree, children: \.children) { node in
                                playlistTreeRow(node)
                            }
                        }
                        .listSectionSeparator(.hidden, edges: .top)

                        PlayerBottomSpacer()
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .scrollIndicators(.hidden)
                    // Deklaratives Move statt Fade: animiert das Diff sobald sich die
                    // Reihenfolge (ID-Sequenz) ändert — z.B. beim An-/Abpinnen.
                    .animation(.snappy, value: visiblePlaylists.map(\.id))
                }
            }
            .navigationTitle(String(localized: "playlists"))
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(playlist: playlist)
                    .id(playlist.id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    playlistSortMenu
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newPlaylistName = ""
                        showCreateSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .task(id: libraryStore.reloadID) {
                await libraryStore.loadPlaylists()
            }
            .refreshable {
                if await offlineMode.beginUserInitiatedServerRefresh() { return }
                defer { offlineMode.finishUserInitiatedServerRefresh() }
                Task { await CloudKitSyncService.shared.syncNow() }
                await libraryStore.loadPlaylists()
            }
            .alert(
                String(localized: "delete_playlist_2"),
                isPresented: $showDeleteConfirm,
                presenting: playlistToDelete
            ) { playlist in
                Button(String(localized: "delete"), role: .destructive) {
                    Task {
                        do {
                            try await libraryStore.deletePlaylist(playlist)
                        } catch {
                            if !(error is CancellationError),
                               !OfflineModeService.shared.presentConnectivityErrorIfNeeded(error, userInitiated: true) {
                                currentToast = ShelveToast(message: String(localized: "could_not_delete_playlist"), isError: true)
                            }
                        }
                    }
                }
                Button(String(localized: "cancel"), role: .cancel) {}
            } message: { playlist in
                Text("\"\(playlist.hierarchyDisplayName)\"")
            }
            .shelveToast($currentToast)
            .alert(
                String(localized: "delete_downloads"),
                isPresented: Binding(get: { playlistToDeleteDownloads != nil }, set: { if !$0 { playlistToDeleteDownloads = nil } }),
                presenting: playlistToDeleteDownloads
            ) { playlist in
                Button(String(localized: "delete"), role: .destructive) {
                    deletePlaylistDownloads(playlist)
                    currentToast = ShelveToast(message: String(localized: "downloads_deleted"))
                }
                Button(String(localized: "cancel"), role: .cancel) {}
            } message: { _ in
                Text(String(localized: "the_downloads_will_be_removed_from_this_device"))
            }
            .sheet(isPresented: $showCreateSheet) {
                createPlaylistSheet
            }
        }
    }

    private var playlistSortMenu: some View {
        Menu {
            Picker(selection: $sortOptionRaw) {
                ForEach(PlaylistSortOption.allCases, id: \.rawValue) { option in
                    Text(option.label).tag(option.rawValue)
                }
            } label: {
                Label(String(localized: "sort"), systemImage: "arrow.up.arrow.down")
            }

            if sortOption != .alphabetical {
                Picker(selection: $sortDirectionRaw) {
                    ForEach(SortDirection.allCases, id: \.rawValue) { dir in
                        Text(dir.label).tag(dir.rawValue)
                    }
                } label: {
                    Label(String(localized: "direction"), systemImage: "arrow.up.and.down")
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }

    @ViewBuilder
    private func playlistContextMenu(_ playlist: Playlist) -> some View {
        Button {
            Task {
                if let loaded = await libraryStore.loadPlaylistDetail(id: playlist.id),
                   let songs = loaded.songs, !songs.isEmpty {
                    _ = await MainActor.run { player.play(songs: songs, startIndex: 0) }
                }
            }
        } label: { Label(String(localized: "play"), systemImage: "play.fill") }

        Button {
            Task {
                if let loaded = await libraryStore.loadPlaylistDetail(id: playlist.id),
                   let songs = loaded.songs, !songs.isEmpty {
                    _ = await MainActor.run { player.playShuffled(songs: songs) }
                }
            }
        } label: { Label(String(localized: "shuffle"), systemImage: "shuffle") }

        Divider()

        Button {
            Task {
                if let loaded = await libraryStore.loadPlaylistDetail(id: playlist.id),
                   let songs = loaded.songs, !songs.isEmpty {
                    await MainActor.run {
                        player.addPlayNext(songs)
                        currentToast = ShelveToast(message: String(localized: "plays_next"))
                    }
                }
            }
        } label: { Label(String(localized: "play_next"), systemImage: "text.insert") }

        Button {
            Task {
                if let loaded = await libraryStore.loadPlaylistDetail(id: playlist.id),
                   let songs = loaded.songs, !songs.isEmpty {
                    await MainActor.run {
                        player.addToQueue(songs)
                        currentToast = ShelveToast(message: String(localized: "added_to_queue"))
                    }
                }
            }
        } label: { Label(String(localized: "add_to_queue"), systemImage: "text.badge.plus") }

        if showPlaylistActions {
            Button {
                Task {
                    if let loaded = await libraryStore.loadPlaylistDetail(id: playlist.id),
                       let songs = loaded.songs, !songs.isEmpty {
                        NotificationCenter.default.post(name: .addSongsToPlaylist, object: songs.map(\.id))
                    }
                }
            } label: { Label(String(localized: "add_to_playlist"), systemImage: "music.note.list") }
        }

        if enableDownloads {
            Divider()
            if !offlineMode.isOffline && !downloadStore.offlinePlaylistIds.contains(playlist.id) {
                Button {
                    Task {
                        let loaded = await libraryStore.loadPlaylistDetail(id: playlist.id)
                        libraryStore.errorMessage = nil
                        if let songs = loaded?.songs, !songs.isEmpty {
                            let missing = songs.filter { !downloadStore.isDownloaded(songId: $0.id) }
                            if !missing.isEmpty { downloadStore.enqueueSongs(missing) }
                            downloadStore.addOfflinePlaylist(
                                playlist.id,
                                name: playlist.name,
                                songIds: songs.map(\.id)
                            )
                            currentToast = ShelveToast(message: String(localized: "download_started"))
                        }
                    }
                } label: { Label(String(localized: "download_playlist"), systemImage: "arrow.down.circle") }
            }

            if downloadStore.offlinePlaylistIds.contains(playlist.id) {
                Button(role: .destructive) {
                    playlistToDeleteDownloads = playlist
                } label: {
                    Label(String(localized: "delete_downloads_2"), systemImage: "arrow.down.circle")
                }
            }
        }

        Divider()

        if !offlineMode.isOffline {
            Button(role: .destructive) {
                playlistToDelete = playlist
                showDeleteConfirm = true
            } label: { Label(String(localized: "delete_playlist"), systemImage: "trash") }
        }
    }

    private func playlistDownloadState(_ playlist: Playlist) -> PersonalizedDownloadSwipeState {
        guard enableDownloads else { return .hidden }
        if downloadStore.offlinePlaylistIds.contains(playlist.id) {
            return .delete
        }
        return offlineMode.isOffline ? .hidden : .download
    }

    private func handlePlaylistDownloadSwipe(_ playlist: Playlist) {
        if downloadStore.offlinePlaylistIds.contains(playlist.id) {
            haptic(); playlistToDeleteDownloads = playlist
        } else if !offlineMode.isOffline, enableDownloads {
            haptic()
            Task {
                let loaded = await libraryStore.loadPlaylistDetail(id: playlist.id)
                libraryStore.errorMessage = nil
                if let songs = loaded?.songs, !songs.isEmpty {
                    let missing = songs.filter { !downloadStore.isDownloaded(songId: $0.id) }
                    if !missing.isEmpty { downloadStore.enqueueSongs(missing) }
                    downloadStore.addOfflinePlaylist(
                        playlist.id,
                        name: playlist.name,
                        songIds: songs.map(\.id)
                    )
                    currentToast = ShelveToast(message: String(localized: "download_started"))
                }
            }
        }
    }

    private func queuePlaylist(_ playlist: Playlist) {
        Task {
            if let loaded = await libraryStore.loadPlaylistDetail(id: playlist.id),
               let songs = loaded.songs, !songs.isEmpty {
                await MainActor.run {
                    haptic(); player.addToQueue(songs)
                    currentToast = ShelveToast(message: String(localized: "added_to_queue"))
                }
            }
        }
    }

    private func playNextPlaylist(_ playlist: Playlist) {
        Task {
            if let loaded = await libraryStore.loadPlaylistDetail(id: playlist.id),
               let songs = loaded.songs, !songs.isEmpty {
                await MainActor.run {
                    haptic(); player.addPlayNext(songs)
                    currentToast = ShelveToast(message: String(localized: "plays_next"))
                }
            }
        }
    }

    private func deletePlaylistDownloads(_ playlist: Playlist) {
        // Marker zuerst entfernen — Row verschwindet sofort aus der Liste,
        // verhindert dass weiteres Swipe/Tap auf der gerade verschwindenden Row crasht.
        let playlistId = playlist.id
        downloadStore.removeOfflinePlaylist(playlistId)
        Task {
            if let loaded = await libraryStore.loadPlaylistDetail(id: playlistId),
               let songs = loaded.songs {
                for song in songs {
                    downloadStore.deleteSong(song.id)
                }
            }
        }
    }

    @ViewBuilder
    private func playlistTreeRow(_ node: PlaylistTreeNode) -> some View {
        if let playlist = node.playlist {
            NavigationLink(value: playlist) {
                playlistRow(playlist, displayName: node.title)
            }
            .contextMenu { playlistContextMenu(playlist) }
            .personalizedPlaylistSwipeActions(
                isPinned: pinStore.isPinned(playlist.id),
                canDelete: !offlineMode.isOffline,
                downloadState: playlistDownloadState(playlist),
                accentColor: accentColor,
                onPin: {
                    haptic()
                    pinStore.togglePin(playlist.id)
                },
                onDelete: {
                    playlistToDelete = playlist
                    showDeleteConfirm = true
                },
                onDownload: {
                    handlePlaylistDownloadSwipe(playlist)
                },
                onPlayNext: {
                    playNextPlaylist(playlist)
                },
                onAddToQueue: {
                    queuePlaylist(playlist)
                }
            )
        } else {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.title3)
                    .foregroundStyle(accentColor)
                    .frame(width: 52, height: 52)
                Text(node.title)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
                Text(node.playlistCount, format: .number)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private func playlistRow(_ playlist: Playlist, displayName: String? = nil) -> some View {
        HStack(spacing: 12) {
            AlbumArtView(coverArtId: playlist.coverArt, size: 150, cornerRadius: 8)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName ?? playlist.hierarchyDisplayName)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                let count = playlist.songCount
                if let count {
                    Text("\(count) \(String(localized: "songs"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if pinStore.isPinned(playlist.id) {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(accentColor)
            }
            PlaylistDownloadBadge(playlistId: playlist.id)
        }
        .padding(.vertical, 4)
    }

    private var createPlaylistSheet: some View {
        NavigationStack {
            Form {
                Section(String(localized: "name")) {
                    TextField(String(localized: "my_playlist"), text: $newPlaylistName)
                        .focused($nameFieldFocused)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle(String(localized: "new_playlist_2"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    nameFieldFocused = true
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "cancel"), role: .cancel) {
                        showCreateSheet = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "create")) {
                        let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        showCreateSheet = false
                        Task { await libraryStore.createPlaylist(name: name) }
                    }
                    .bold()
                    .disabled(newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .tint(accentColor)
        }
        .presentationSizing(.page)
        .presentationCornerRadius(24)
        .presentationDragIndicator(.visible)
    }
}
