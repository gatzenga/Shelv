import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("appColorScheme") private var colorScheme: AppColorScheme = .system

    var body: some View {
        TabView {
            ServerTab()
                .tabItem {
                    Image(systemName: "server.rack")
                    Text(String(localized: "server"))
                }
            AppearanceTab(colorScheme: $colorScheme)
                .tabItem {
                    Image(systemName: "paintpalette")
                    Text(String(localized: "appearance"))
                }
            RecapTab()
                .tabItem {
                    Image(systemName: "calendar.badge.clock")
                    Text(String(localized: "recap"))
                }
            PlaybackTab()
                .tabItem {
                    Image(systemName: "play.circle")
                    Text(String(localized: "playback"))
                }
            DownloadsTab()
                .tabItem {
                    Image(systemName: "arrow.down.circle")
                    Text(String(localized: "downloads"))
                }
            LyricsSettingsPanel()
                .tabItem {
                    Image(systemName: "text.bubble")
                    Text(String(localized: "lyrics"))
                }
            CacheTab()
                .tabItem {
                    Image(systemName: "internaldrive")
                    Text(String(localized: "cache"))
                }
            DatabaseTab()
                .tabItem {
                    Image(systemName: "cylinder")
                    Text(String(localized: "database"))
                }
            ICloudSyncTab()
                .tabItem {
                    Image(systemName: "icloud")
                    Text("iCloud")
                }
            AboutTab()
                .tabItem {
                    Image(systemName: "info.circle")
                    Text(String(localized: "info"))
                }
        }
        .frame(width: 820, height: 660)
        .environmentObject(appState)
        .transaction { $0.animation = nil }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState.shared)
        .environmentObject(LyricsStore.shared)
}
