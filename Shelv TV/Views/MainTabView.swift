import SwiftUI

/// Tab-Gerüst der tvOS-App: Now Playing · Discover · Library · Playlists · Suche · Settings.
struct MainTabView: View {
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    // Stabile Tags: Ein- oder Ausblenden eines Tabs verschiebt sonst die Indizes
    // und die Auswahl springt ins Leere.
    @State private var selection = "discover"

    var body: some View {
        TabView(selection: $selection) {
            NowPlayingView()
                .tag("nowplaying")
                .tabItem { Label(String(localized: "now_playing"), systemImage: "play.circle") }

            DiscoverView()
                .tag("discover")
                .tabItem { Label(String(localized: "discover"), systemImage: "sparkles") }

            LibraryView()
                .tag("library")
                .tabItem { Label(String(localized: "library"), systemImage: "square.stack") }

            if enablePlaylists {
                PlaylistsView()
                    .tag("playlists")
                    .tabItem { Label(String(localized: "playlists"), systemImage: "music.note.list") }
            }

            SearchView()
                .tag("search")
                .tabItem { Label(String(localized: "search"), systemImage: "magnifyingglass") }

            SettingsView()
                .tag("settings")
                .tabItem { Label(String(localized: "settings"), systemImage: "gearshape") }
        }
    }
}
