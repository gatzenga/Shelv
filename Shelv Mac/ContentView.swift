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
        .onAppear { NSApp.appearance = storedColorScheme.nsAppearance }
        .onChange(of: storedColorScheme) { _, new in NSApp.appearance = new.nsAppearance }
    }
}

struct ToastView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "checkmark")
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.8), in: Capsule())
            .allowsHitTesting(false)
    }
}

struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var lyricsStore: LyricsStore
    @ObservedObject var libraryStore = LibraryViewModel.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @ObservedObject var downloadStore = DownloadStore.shared

    @State private var showAddToPlaylist = false
    @State private var playlistSongIds: [String] = []
    @State private var toastMessage: String?
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
                .onChange(of: appState.serverStore.activeServerID) { _, _ in
                    appState.player.stop()
                    libraryStore.reset()
                    #if DEBUG
                    // Demo-Server aktiv → festes Player-Standbild (nach stop(), sonst sofort
                    // wieder gelöscht) + Recap-Anzeige aktivieren. Wie iOS-ContentView.
                    if SubsonicAPIService.shared.isDemoActive {
                        appState.player.loadDemoStandby()
                        UserDefaults.standard.set(true, forKey: "recapEnabled")
                    }
                    #endif
                }
                .background(Color(NSColor.windowBackgroundColor))

                if appState.activePanel != nil {
                    Divider()
                    sidePanelContent
                        .frame(width: 380)
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
                if let msg = toastMessage {
                    ToastView(message: msg)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 12)
                }
            }
        }
        .animation(.spring(duration: 0.35), value: toastMessage)
        .onChange(of: libraryStore.errorMessage) { _, msg in
            guard let msg else { return }
            offlineMode.notifyServerError(msg)
        }
        .onReceive(NotificationCenter.default.publisher(for: .addSongsToPlaylist)) { notification in
            if let ids = notification.object as? [String] {
                playlistSongIds = ids
                showAddToPlaylist = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showToast)) { notification in
            if let msg = notification.object as? String {
                toastMessage = msg
                toastTask?.cancel()
                toastTask = Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    toastMessage = nil
                }
            }
        }
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistPanel(songIds: playlistSongIds)
                .environmentObject(libraryStore)
        }
    }

    @ViewBuilder
    private var sidePanelContent: some View {
        switch appState.activePanel {
        case .lyrics:
            LyricsPanel()
                .environmentObject(lyricsStore)
        case .queue:
            QueuePopover()
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
            case .search:          SearchView().environmentObject(libraryStore)
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState.shared)
        .frame(width: 1200, height: 760)
}
