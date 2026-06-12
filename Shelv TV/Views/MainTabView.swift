import SwiftUI

/// Tab-Gerüst der tvOS-App: Now Playing · Discover · Library · Playlists · Suche · Settings.
struct MainTabView: View {
    @AppStorage("enablePlaylists") private var enablePlaylists = true

    var body: some View {
        TabView {
            NowPlayingView()
                .tabItem { Label(String(localized: "now_playing"), systemImage: "play.circle") }

            DiscoverView()
                .tabItem { Label(String(localized: "discover"), systemImage: "sparkles") }

            LibraryView()
                .tabItem { Label(String(localized: "library"), systemImage: "square.stack") }

            if enablePlaylists {
                PlaylistsView()
                    .tabItem { Label(String(localized: "playlists"), systemImage: "music.note.list") }
            }

            SearchView()
                .tabItem { Label(String(localized: "search"), systemImage: "magnifyingglass") }

            SettingsView()
                .tabItem { Label(String(localized: "settings"), systemImage: "gearshape") }
        }
    }
}
