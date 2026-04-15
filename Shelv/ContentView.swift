import SwiftUI

struct ContentView: View {
    @EnvironmentObject var serverStore: ServerStore
    @EnvironmentObject var libraryStore: LibraryStore
    @EnvironmentObject var player: AudioPlayerService
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @State private var selectedTab = 0
    @State private var showPlayer = false
    @State private var showAddServer = false
    @AppStorage("themeColor") private var themeColorName = "violet"

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
                    SearchView()
                        .tabItem { Label(tr("Search", "Suchen"), systemImage: "magnifyingglass") }
                        .tag(2)
                    SettingsView()
                        .tabItem { Label(tr("Settings", "Einstellungen"), systemImage: "gearshape.fill") }
                        .tag(3)
                }
                .tint(accentColor)

                // iPhone: PlayerBar über TabBar, Abstand dynamisch via GeometryReader
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
        // iPad: safeAreaInset schiebt TabBar automatisch hoch, PlayerBar sitzt ganz unten
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
                .tint(accentColor)
        }
        .sheet(isPresented: $showAddServer) {
            AddServerView()
                .environmentObject(serverStore)
                .tint(accentColor)
        }
        .onAppear {
            if serverStore.servers.isEmpty {
                showAddServer = true
            }
        }
    }
}
