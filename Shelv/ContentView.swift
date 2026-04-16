import SwiftUI

extension Notification.Name {
    static let addSongsToPlaylist = Notification.Name("addSongsToPlaylist")
}

struct ContentView: View {
    @EnvironmentObject var serverStore: ServerStore
    @EnvironmentObject var libraryStore: LibraryStore
    @EnvironmentObject var player: AudioPlayerService
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @State private var selectedTab = 0
    @State private var showPlayer = false
    @State private var showAddServer = false
    @State private var playlistSongIds: [String]? = nil
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("enablePlaylists") private var enablePlaylists = true

    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    private var playerBar: some View {
        PlayerBarView()
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showPlayer = true
                }
            }
    }

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

                if player.currentSong != nil && !isRegularWidth {
                    VStack {
                        Spacer()
                        playerBar
                            .padding(.horizontal, 16)
                            .padding(.bottom, geometry.safeAreaInsets.bottom + 49 + 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(edges: .bottom)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if player.currentSong != nil && isRegularWidth {
                playerBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
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
            player.stop()
            libraryStore.resetInMemory()
        }
        .onAppear {
            if serverStore.servers.isEmpty {
                showAddServer = true
            }
        }
    }
}

private struct IdentifiableStrings: Identifiable {
    let id = UUID()
    let ids: [String]
}
