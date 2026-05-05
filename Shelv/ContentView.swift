import SwiftUI

extension Notification.Name {
    static let addSongsToPlaylist = Notification.Name("addSongsToPlaylist")
    static let offlinePlaybackBlocked = Notification.Name("shelv.offlinePlaybackBlocked")
}

struct ContentView: View {
    @EnvironmentObject var serverStore: ServerStore
    @ObservedObject var libraryStore = LibraryStore.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @State private var selectedTab = 0
    @State private var showPlayer = false
    @State private var showAddServer = false
    @State private var playlistSongIds: [String]? = nil
    @State private var offlineToast: ShelveToast?
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    @AppStorage("enableDownloads") private var enableDownloads = false

    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                TabView(selection: $selectedTab) {
                    DiscoverView()
                        .tabItem { Label(tr("Discover", "Entdecken"), systemImage: "sparkles") }
                        .tag(0)
                    LibraryView()
                        .tabItem {
                            if offlineMode.isOffline && enableDownloads {
                                Label(tr("Downloads", "Downloads"), systemImage: "arrow.down.circle.fill")
                            } else {
                                Label(tr("Library", "Bibliothek"), systemImage: "books.vertical.fill")
                            }
                        }
                        .tag(1)
                    if enablePlaylists {
                        PlaylistsView()
                            .tabItem { Label(tr("Playlists", "Playlists"), systemImage: "music.note.list") }
                            .tag(2)
                    }
                    SettingsView()
                        .tabItem { Label(tr("Settings", "Einstellungen"), systemImage: "gearshape.fill") }
                        .tag(3)
                }
                .tint(accentColor)

                PlayerBarOverlay(
                    isRegularWidth: isRegularWidth,
                    showPlayer: $showPlayer,
                    bottomInset: geometry.safeAreaInsets.bottom
                )

                VStack {
                    ServerErrorBanner()
                        .padding(.top, geometry.safeAreaInsets.top + 4)
                        .animation(.easeInOut, value: offlineMode.serverErrorBannerVisible)
                    Spacer()
                }
                .allowsHitTesting(offlineMode.serverErrorBannerVisible)
                .ignoresSafeArea(edges: .top)
            }
        }
        .ignoresSafeArea(.keyboard)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBarInset(isRegularWidth: isRegularWidth, showPlayer: $showPlayer)
        }
        .onChange(of: libraryStore.errorMessage) { _, msg in
            guard let msg else { return }
            libraryStore.errorMessage = nil
            offlineMode.notifyServerError(msg)
        }
        .sheet(isPresented: $showPlayer) {
            PlayerView()
                .presentationDetents([.large])
                .presentationSizing(.page)
                .presentationBackgroundInteraction(.enabled)
                .presentationCornerRadius(24)
                .presentationDragIndicator(.visible)
                .tint(accentColor)
        }
        .sheet(isPresented: $showAddServer) {
            AddServerView()
                .environmentObject(serverStore)
                .tint(accentColor)
        }
        .sheet(item: Binding(
            get: { playlistSongIds.map { IdentifiableStrings(ids: $0) } },
            set: { if $0 == nil { playlistSongIds = nil } }
        )) { wrapper in
            AddToPlaylistSheet(songIds: wrapper.ids)
                .environmentObject(libraryStore)
                .tint(accentColor)
        }
        .onReceive(NotificationCenter.default.publisher(for: .addSongsToPlaylist)) { note in
            if let ids = note.object as? [String] {
                playlistSongIds = ids
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .offlinePlaybackBlocked)) { _ in
            offlineToast = ShelveToast(message: tr("Not available offline", "Offline nicht verfügbar"), isError: true)
        }
        .shelveToast($offlineToast)
        .onChange(of: serverStore.activeServerID) { _, _ in
            AudioPlayerService.shared.stop()
            libraryStore.resetInMemory()
        }
        .onChange(of: enablePlaylists) { _, enabled in
            if !enabled && selectedTab == 2 { selectedTab = 0 }
        }
        .onAppear {
            if serverStore.servers.isEmpty {
                showAddServer = true
            }
        }
    }
}

private struct IdentifiableStrings: Identifiable {
    var id: String { ids.joined(separator: ",") }
    let ids: [String]
}

/// Isoliertes PlayerBar-Overlay für iPhone — beobachtet Player ohne ContentView zu invalidieren
private struct PlayerBarOverlay: View {
    let isRegularWidth: Bool
    @Binding var showPlayer: Bool
    let bottomInset: CGFloat
    @ObservedObject private var player = AudioPlayerService.shared

    var body: some View {
        if player.currentSong != nil && !isRegularWidth {
            VStack {
                Spacer()
                PlayerBarView()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            showPlayer = true
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, bottomInset + 49 + 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// Isoliertes PlayerBar-Inset für iPad
private struct PlayerBarInset: View {
    let isRegularWidth: Bool
    @Binding var showPlayer: Bool
    @ObservedObject private var player = AudioPlayerService.shared

    var body: some View {
        if player.currentSong != nil && isRegularWidth {
            PlayerBarView()
                .onTapGesture {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showPlayer = true
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
    }
}
