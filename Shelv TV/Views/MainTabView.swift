import SwiftUI

/// Tab-Gerüst der tvOS-App: Now Playing · Discover · Library · Playlists · Recap · Suche · Settings.
/// Nutzt die neue `Tab`-API (tvOS 18+) mit value-basierter Selection — die Legacy-
/// tabItem-API hatte auf tvOS kaputtes Menü-/Fokus-Verhalten (Tab-Bar unerreichbar,
/// leerer Tab nach Feature-Toggle).
struct MainTabView: View {
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    @AppStorage("recapEnabled") private var recapEnabled = false
    @ObservedObject private var queueSync = QueueSyncService.shared
    @State private var selection = "discover"

    var body: some View {
        TabView(selection: $selection) {
            Tab(String(localized: "now_playing"), systemImage: "play.circle", value: "nowplaying") {
                NowPlayingView()
            }

            Tab(String(localized: "discover"), systemImage: "sparkles", value: "discover") {
                DiscoverView()
            }

            Tab(String(localized: "library"), systemImage: "square.stack", value: "library") {
                LibraryView()
            }

            if enablePlaylists {
                Tab(String(localized: "playlists"), systemImage: "music.note.list", value: "playlists") {
                    PlaylistsView()
                }
            }

            if recapEnabled {
                Tab(String(localized: "recaps"), systemImage: "sparkles.rectangle.stack", value: "recap") {
                    RecapView()
                }
            }

            Tab(String(localized: "search"), systemImage: "magnifyingglass", value: "search") {
                SearchView()
            }

            Tab(String(localized: "settings"), systemImage: "gearshape", value: "settings") {
                SettingsView()
            }
        }
        .onPlayPauseCommand {
            // tvOS liefert die physische Play/Pause-Taste der Siri Remote im Vordergrund über
            // diesen SwiftUI-Befehl. MPRemoteCommandCenter erreicht der Resume-Druck im
            // Vordergrund nicht zuverlässig (Pause kommt an, Play nicht), daher hier abfangen.
            AudioPlayerService.shared.togglePlayPause()
        }
        .onChange(of: enablePlaylists) { _, on in
            if !on && selection == "playlists" { selection = "settings" }
        }
        .onChange(of: recapEnabled) { _, on in
            if !on && selection == "recap" { selection = "settings" }
        }
        // Fremde Queue von einem anderen Gerät — auf tvOS als nativer Alert (zuverlässig
        // fokussierbar, im Gegensatz zu einem Custom-Top-Banner). Nie automatisch.
        .alert(String(localized: "queue_available_title"), isPresented: Binding(
            get: { queueSync.pendingRemote != nil },
            set: { if !$0 { queueSync.dismissPending() } }
        )) {
            Button(String(localized: "queue_take_over")) { queueSync.acceptPending() }
            Button(String(localized: "cancel"), role: .cancel) { queueSync.dismissPending() }
        } message: {
            Text(String(localized: "queue_available_subtitle"))
        }
    }
}
