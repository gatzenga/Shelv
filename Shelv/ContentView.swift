import SwiftUI

struct ContentView: View {
    @EnvironmentObject var serverStore: ServerStore
    @EnvironmentObject var libraryStore: LibraryStore
    @EnvironmentObject var player: AudioPlayerService
    @State private var selectedTab = 0
    @State private var showPlayer = false
    @State private var showAddServer = false
    @AppStorage("themeColor") private var themeColorName = "violet"

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    @State private var safeAreaBottom: CGFloat = 0

    private var playerBar: some View {
        PlayerBarView()
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showPlayer = true
                }
            }
    }

    var body: some View {
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

            if player.currentSong != nil {
                VStack {
                    Spacer()
                    playerBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, safeAreaBottom + 49 + 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $showPlayer) {
            PlayerView()
                .presentationDetents([.large])
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
            safeAreaBottom = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.windows.first?.safeAreaInsets.bottom ?? 0
            if serverStore.servers.isEmpty {
                showAddServer = true
            }
        }
    }
}
