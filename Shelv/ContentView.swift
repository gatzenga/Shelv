import SwiftUI

extension Notification.Name {
    static let addSongsToPlaylist = Notification.Name("addSongsToPlaylist")
}

struct ContentView: View {
    @EnvironmentObject var serverStore: ServerStore
    @EnvironmentObject var libraryStore: LibraryStore
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @State private var selectedTab = 0
    @State private var showPlayer = false
    @State private var showAddServer = false
    @State private var playlistSongIds: [String]? = nil
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("enablePlaylists") private var enablePlaylists = true

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
                        .tabItem { Label(tr("Library", "Bibliothek"), systemImage: "books.vertical.fill") }
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
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBarInset(isRegularWidth: isRegularWidth, showPlayer: $showPlayer)
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
