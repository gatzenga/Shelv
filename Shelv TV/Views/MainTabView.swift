import SwiftUI

/// Tab-Gerüst der tvOS-App. Tab-Inhalte werden in den jeweiligen Tasks gefüllt;
/// hier zunächst Platzhalter, damit Navigation und Struktur stehen.
struct MainTabView: View {
    @AppStorage("enablePlaylists") private var enablePlaylists = true

    var body: some View {
        TabView {
            Placeholder("Now Playing")
                .tabItem { Label(String(localized: "now_playing"), systemImage: "play.circle") }

            Placeholder("Discover")
                .tabItem { Label(String(localized: "discover"), systemImage: "sparkles") }

            Placeholder("Library")
                .tabItem { Label(String(localized: "library"), systemImage: "square.stack") }

            if enablePlaylists {
                Placeholder("Playlists")
                    .tabItem { Label(String(localized: "playlists"), systemImage: "music.note.list") }
            }

            Placeholder("Search")
                .tabItem { Label(String(localized: "search"), systemImage: "magnifyingglass") }

            Placeholder("Settings")
                .tabItem { Label(String(localized: "settings"), systemImage: "gearshape") }
        }
    }
}

private struct Placeholder: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.largeTitle)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
