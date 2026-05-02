import SwiftUI

struct PlaylistsView: View {
    @ObservedObject var libraryStore = LibraryStore.shared
    @EnvironmentObject var recapStore: RecapStore
    @ObservedObject var downloadStore = DownloadStore.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    private let player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("enableDownloads") private var enableDownloads = false
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    private var visiblePlaylists: [Playlist] {
        let noRecap = libraryStore.playlists.filter { !recapStore.recapPlaylistIds.contains($0.id) }
        if offlineMode.isOffline {
            return noRecap.filter { downloadStore.offlinePlaylistIds.contains($0.id) }
        }
        return noRecap
    }

    @State private var showCreateSheet = false
    @State private var newPlaylistName = ""
    @FocusState private var nameFieldFocused: Bool
    @State private var showDeleteConfirm = false
    @State private var playlistToDelete: Playlist?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var currentToast: ShelveToast?
    @State private var refreshContinuation: CheckedContinuation<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if libraryStore.isLoadingPlaylists && libraryStore.playlists.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visiblePlaylists.isEmpty {
                    List {
                        ContentUnavailableView(
                            tr("No Playlists", "Keine Playlists"),
                            systemImage: "music.note.list",
                            description: Text(tr(
                                "Create a playlist to get started.",
                                "Erstelle eine Playlist, um loszulegen."
                            ))
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
                            ForEach(visiblePlaylists) { playlist in
                                NavigationLink(value: playlist) {
                                    playlistRow(playlist)
                                }
                                .contextMenu { playlistContextMenu(playlist) }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button {
                                        Task {
                                            if let loaded = await libraryStore.loadPlaylistDetail(id: playlist.id),
                                               let songs = loaded.songs, !songs.isEmpty {
                                                await MainActor.run {
                                                    haptic(); player.addToQueue(songs)
                                                    currentToast = ShelveToast(message: tr("Added to Queue", "Zur Warteschlange hinzugefügt"))
                                                }
                                            }
                                        }
                                    } label: { Image(systemName: "text.badge.plus") }
                                    .tint(accentColor)
                                    Button {
                                        Task {
                                            if let loaded = await libraryStore.loadPlaylistDetail(id: playlist.id),
                                               let songs = loaded.songs, !songs.isEmpty {
                                                await MainActor.run {
                                                    haptic(); player.addPlayNext(songs)
                                                    currentToast = ShelveToast(message: tr("Plays Next", "Wird als nächstes gespielt"))
                                                }
                                            }
                                        }
                                    } label: { Image(systemName: "text.insert") }
                                    .tint(.orange)
                                    if enableDownloads {
                                        playlistDownloadSwipe(playlist)
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        playlistToDelete = playlist
                                        showDeleteConfirm = true
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .tint(.red)
                                }
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
                }
            }
            .navigationTitle(tr("Playlists", "Playlists"))
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(playlist: playlist)
                    .id(playlist.id)
            }
            .toolbar {
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
                await withCheckedContinuation { cont in
                    refreshContinuation = cont
                    Task { @MainActor in
                        let bannerTask = Task {
                            try? await Task.sleep(for: .seconds(3))
                            if !Task.isCancelled { offlineMode.notifyServerError() }
                        }
                        async let reload: Void = libraryStore.loadPlaylists()
                        async let sync:   Void = CloudKitSyncService.shared.syncNow()
                        _ = await (reload, sync)
                        bannerTask.cancel()
                        if let cont = refreshContinuation {
                            refreshContinuation = nil
                            cont.resume()
                        }
                    }
                }
            }
            .onChange(of: offlineMode.isOffline) { _, isOffline in
                if isOffline, let cont = refreshContinuation {
                    refreshContinuation = nil
                    cont.resume()
                }
            }
            .alert(
                tr("Delete Playlist?", "Playlist löschen?"),
                isPresented: $showDeleteConfirm,
                presenting: playlistToDelete
            ) { playlist in
                Button(tr("Delete", "Löschen"), role: .destructive) {
                    Task { await libraryStore.deletePlaylist(playlist) }
                }
                Button(tr("Cancel", "Abbrechen"), role: .cancel) {}
            } message: { playlist in
                Text("\"\(playlist.name)\"")
            }
            .onChange(of: libraryStore.errorMessage) { _, msg in
                if let msg {
                    errorMessage = msg
                    showError = true
                    libraryStore.errorMessage = nil
                }
            }
            .alert(tr("Error", "Fehler"), isPresented: $showError, presenting: errorMessage) { _ in
                Button(tr("OK", "OK"), role: .cancel) {}
            } message: { msg in
                Text(msg)
            }
            .shelveToast($currentToast)
            .sheet(isPresented: $showCreateSheet) {
                createPlaylistSheet
            }
        }
    }

    @ViewBuilder
    private func playlistContextMenu(_ playlist: Playlist) -> some View {
        Button {
            Task {
                if let loaded = await libraryStore.loadPlaylistDetail(id: playlist.id),
                   let songs = loaded.songs, !songs.isEmpty {
                    await MainActor.run { player.play(songs: songs, startIndex: 0) }
                }
            }
        } label: { Label(tr("Play", "Abspielen"), systemImage: "play.fill") }

        Button {
            Task {
                if let loaded = await libraryStore.loadPlaylistDetail(id: playlist.id),
                   let songs = loaded.songs, !songs.isEmpty {
                    await MainActor.run { player.playShuffled(songs: songs) }
                }
            }
        } label: { Label(tr("Shuffle", "Zufällig"), systemImage: "shuffle") }

        Divider()

        Button {
            Task {
                if let loaded = await libraryStore.loadPlaylistDetail(id: playlist.id),
                   let songs = loaded.songs, !songs.isEmpty {
                    await MainActor.run {
                        player.addPlayNext(songs)
                        currentToast = ShelveToast(message: tr("Plays Next", "Wird als nächstes gespielt"))
                    }
                }
            }
        } label: { Label(tr("Play Next", "Als nächstes"), systemImage: "text.insert") }

        Button {
            Task {
                if let loaded = await libraryStore.loadPlaylistDetail(id: playlist.id),
                   let songs = loaded.songs, !songs.isEmpty {
                    await MainActor.run {
                        player.addToQueue(songs)
                        currentToast = ShelveToast(message: tr("Added to Queue", "Zur Warteschlange hinzugefügt"))
                    }
                }
            }
        } label: { Label(tr("Add to Queue", "Zur Warteschlange"), systemImage: "text.badge.plus") }

        if enablePlaylists {
            Button {
                Task {
                    if let loaded = await libraryStore.loadPlaylistDetail(id: playlist.id),
                       let songs = loaded.songs, !songs.isEmpty {
                        NotificationCenter.default.post(name: .addSongsToPlaylist, object: songs.map(\.id))
                    }
                }
            } label: { Label(tr("Add to Playlist…", "Zur Playlist hinzufügen…"), systemImage: "music.note.list") }
        }

        if enableDownloads {
            Divider()
            if !offlineMode.isOffline && !downloadStore.offlinePlaylistIds.contains(playlist.id) {
                Button {
                    Task {
                        if let loaded = await libraryStore.loadPlaylistDetail(id: playlist.id),
                           let songs = loaded.songs, !songs.isEmpty {
                            let missing = songs.filter { !downloadStore.isDownloaded(songId: $0.id) }
                            if !missing.isEmpty { downloadStore.enqueueSongs(missing) }
                            downloadStore.addOfflinePlaylist(playlist.id, songIds: songs.map(\.id))
                            currentToast = ShelveToast(message: tr("Download started", "Download gestartet"))
                        }
                    }
                } label: { Label(tr("Download Playlist", "Playlist herunterladen"), systemImage: "arrow.down.circle") }
            }

            if downloadStore.offlinePlaylistIds.contains(playlist.id) {
                Button(role: .destructive) {
                    deletePlaylistDownloads(playlist)
                } label: {
                    Label { Text(tr("Delete Downloads", "Downloads löschen")) } icon: { DeleteDownloadIcon(tint: .red) }
                }
            }
        }

        Divider()

        Button(role: .destructive) {
            playlistToDelete = playlist
            showDeleteConfirm = true
        } label: { Label(tr("Delete Playlist", "Playlist löschen"), systemImage: "trash") }
    }

    @ViewBuilder
    private func playlistDownloadSwipe(_ playlist: Playlist) -> some View {
        if downloadStore.offlinePlaylistIds.contains(playlist.id) {
            Button(role: .destructive) {
                haptic(); deletePlaylistDownloads(playlist)
            } label: { DeleteDownloadIcon() }
            .tint(.red)
        } else if !offlineMode.isOffline {
            Button {
                haptic()
                Task {
                    if let loaded = await libraryStore.loadPlaylistDetail(id: playlist.id),
                       let songs = loaded.songs, !songs.isEmpty {
                        let missing = songs.filter { !downloadStore.isDownloaded(songId: $0.id) }
                        if !missing.isEmpty { downloadStore.enqueueSongs(missing) }
                        downloadStore.addOfflinePlaylist(playlist.id, songIds: songs.map(\.id))
                    }
                }
            } label: { Image(systemName: "arrow.down.circle") }
            .tint(accentColor)
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
                for song in songs where downloadStore.isDownloaded(songId: song.id) {
                    downloadStore.deleteSong(song.id)
                }
            }
        }
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        HStack(spacing: 12) {
            AlbumArtView(coverArtId: playlist.coverArt, size: 150, cornerRadius: 8)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                let count = offlineMode.isOffline
                    ? downloadStore.downloadedCount(for: playlist.id)
                    : playlist.songCount
                if let count {
                    Text("\(count) \(tr("Songs", "Titel"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            PlaylistDownloadBadge(playlistId: playlist.id)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var createPlaylistSheet: some View {
        NavigationStack {
            Form {
                Section(tr("Name", "Name")) {
                    TextField(tr("My Playlist", "Meine Playlist"), text: $newPlaylistName)
                        .focused($nameFieldFocused)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle(tr("New Playlist", "Neue Playlist"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    nameFieldFocused = true
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(tr("Cancel", "Abbrechen"), role: .cancel) {
                        showCreateSheet = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(tr("Create", "Erstellen")) {
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
        .presentationDetents([.medium])
        .presentationCornerRadius(24)
    }
}
