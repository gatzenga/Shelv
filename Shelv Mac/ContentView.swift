import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("appColorScheme") private var storedColorScheme: AppColorScheme = .system
    @AppStorage("themeColor") private var themeColorName: String = "violet"

    var body: some View {
        Group {
            if appState.isLoggedIn {
                MainWindowView()
            } else {
                LoginView()
                    .frame(minWidth: 480, minHeight: 360)
            }
        }
        .tint(AppTheme.color(for: themeColorName))
        .environment(\.themeColor, AppTheme.color(for: themeColorName))
        .onAppear {
            NSApp.appearance = storedColorScheme.nsAppearance
            #if DEBUG
            appState.player.ensureDemoStandby()
            #endif
        }
        .onChange(of: storedColorScheme) { _, new in NSApp.appearance = new.nsAppearance }
    }
}

struct ToastView: View {
    let message: String
    var isError = false

    var body: some View {
        Label(message, systemImage: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isError ? Color.red : Color.black.opacity(0.8), in: Capsule())
            .allowsHitTesting(false)
    }
}

private struct KeepLibraryOfflineBanner: View {
    @ObservedObject private var keepOffline = KeepLibraryOfflineService.shared

    var body: some View {
        if keepOffline.lowStorageBannerVisible {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "keep_library_offline_storage_title"))
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Text(String(localized: "keep_library_offline_storage_message"))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Button {
                    keepOffline.dismissLowStorageBanner()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.red.gradient, in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: 520)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

struct MainWindowView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var serverStore: ServerStore
    @EnvironmentObject var lyricsStore: LyricsStore
    @ObservedObject var libraryStore = LibraryViewModel.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @ObservedObject var downloadStore = DownloadStore.shared

    @State private var showAddToPlaylist = false
    @State private var playlistSongIds: [String] = []
    @State private var toastMessage: String?
    @State private var toastIsError = false
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                NavigationSplitView {
                    SidebarView(
                        selection: $appState.selectedSidebar,
                        selectedPlaylist: $appState.selectedPlaylist
                    )
                    .environmentObject(libraryStore)
                } detail: {
                    NavigationStack(path: $appState.navigationPath) {
                        sectionRoot
                            .navigationDestination(for: Album.self) { album in
                                AlbumDetailView(albumId: album.id, albumName: album.name, initialCoverArtId: album.coverArt)
                                    .environmentObject(libraryStore)
                            }
                            .navigationDestination(for: Artist.self) { artist in
                                ArtistDetailView(artistId: artist.id, artistName: artist.name)
                                    .environmentObject(libraryStore)
                            }
                    }
                    .environmentObject(libraryStore)
                }
                .onChange(of: serverStore.activeServerID) { _, _ in
                    appState.player.stop()
                    QueueSyncService.shared.handleServerChange()
                    DiscoverViewModel.shared.reset()
                    RadioStationStore.shared.resetInMemory()
                    #if DEBUG
                    // Demo-Server aktiv -> festes Player-Standbild (nach stop(), sonst sofort
                    // wieder gelöscht). Wie iOS-ContentView.
                    if SubsonicAPIService.shared.isDemoActive {
                        appState.player.ensureDemoStandby(force: true)
                    }
                    #endif
                }
                .background(Color(NSColor.windowBackgroundColor))

                if appState.activePanel != nil {
                    Divider()
                    sidePanelContent
                        .frame(width: 410)
                        .frame(maxHeight: .infinity)
                        .background(Color(NSColor.windowBackgroundColor))
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: appState.activePanel)

            PlayerBarView()
                .environmentObject(libraryStore)
                .environmentObject(lyricsStore)
        }
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                ServerErrorBanner()
                    .animation(.easeInOut, value: offlineMode.serverErrorBannerVisible)
                QueueSyncBanner()
                    .animation(.easeInOut, value: QueueSyncService.shared.pendingRemote != nil)
                KeepLibraryOfflineBanner()
                    .animation(.easeInOut, value: KeepLibraryOfflineService.shared.lowStorageBannerVisible)
                if let msg = toastMessage {
                    ToastView(message: msg, isError: toastIsError)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 12)
                }
            }
        }
        .animation(.spring(duration: 0.35), value: toastMessage)
        .onChange(of: libraryStore.errorMessage) { _, msg in
            guard let msg else { return }
            Task { @MainActor in
                await Task.yield()
                offlineMode.notifyServerErrorIfPresentationAllowed(msg)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .addSongsToPlaylist)) { notification in
            if let ids = notification.object as? [String] {
                playlistSongIds = ids
                showAddToPlaylist = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showToast)) { notification in
            if let msg = notification.object as? String {
                showToast(msg)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .instantMixUnavailable)) { _ in
            showToast(String(localized: "no_instant_mix_available"), isError: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .shelvShortcutDestinationRequested)) { note in
            let pendingDestination = ShelvShortcutHandoff.consumePendingDestination()
            guard let rawValue = note.object as? String,
                  let destination = ShelvShortcutDestination(rawValue: rawValue)
            else {
                if let pendingDestination { handleShortcutDestination(pendingDestination) }
                return
            }
            handleShortcutDestination(destination)
        }
        .onAppear {
            if let destination = ShelvShortcutHandoff.consumePendingDestination() {
                handleShortcutDestination(destination)
            }
        }
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistPanel(songIds: playlistSongIds)
                .environmentObject(libraryStore)
        }
    }

    private func showToast(_ message: String, isError: Bool = false) {
        toastMessage = message
        toastIsError = isError
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            toastMessage = nil
            toastIsError = false
        }
    }

    private func handleShortcutDestination(_ destination: ShelvShortcutDestination) {
        switch destination {
        case .discover:
            resetMainNavigation()
            appState.selectedSidebar = .discover
        case .library:
            resetMainNavigation()
            appState.selectedSidebar = .albums
        case .search:
            resetMainNavigation()
            appState.selectedSidebar = .search
        case .recap:
            openWindow(id: "recap")
        case .nowPlaying:
            appState.activePanel = nil
        }
    }

    private func resetMainNavigation() {
        appState.selectedPlaylist = nil
        appState.navigationPath = NavigationPath()
    }

    @ViewBuilder
    private var sidePanelContent: some View {
        switch appState.activePanel {
        case .lyrics:
            LyricsPanel()
                .environmentObject(lyricsStore)
        case .queue:
            QueuePopover()
        case .songInfo:
            SongInfoPanel()
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var sectionRoot: some View {
        if let playlist = appState.selectedPlaylist {
            PlaylistDetailView(playlist: playlist)
                .environmentObject(libraryStore)
        } else {
            switch appState.selectedSidebar {
            case .discover, .none: DiscoverView()
            case .albums:          AlbumsView().environmentObject(libraryStore)
            case .artists:         ArtistsView().environmentObject(libraryStore)
            case .favorites:       FavoritesView().environmentObject(libraryStore)
            case .radio:           RadioView()
            case .search:          SearchView().environmentObject(libraryStore)
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState.shared)
        .environmentObject(AppState.shared.serverStore)
        .frame(width: 1200, height: 760)
}
