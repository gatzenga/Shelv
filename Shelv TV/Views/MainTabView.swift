import SwiftUI

/// Tab-Gerüst der tvOS-App: Now Playing · Discover · Library · Playlists · Radio · Suche · Settings.
/// Nutzt die neue `Tab`-API (tvOS 18+) mit value-basierter Selection — die Legacy-
/// tabItem-API hatte auf tvOS kaputtes Menü-/Fokus-Verhalten (Tab-Bar unerreichbar,
/// leerer Tab nach Feature-Toggle).
struct MainTabView: View {
    @AppStorage(PersonalizationPreferenceKey.showPlaylistsTab) private var showPlaylistsTab = true
    @AppStorage(PersonalizationPreferenceKey.showRadio) private var showRadio = true
    @ObservedObject private var offlineMode = OfflineModeService.shared
    @ObservedObject private var queueSync = QueueSyncService.shared
    @State private var selection = MainTabView.initialSelection
    @State private var visibleShowPlaylistsTab = MainTabView.initialBoolPreference(
        PersonalizationPreferenceKey.showPlaylistsTab,
        default: true
    )
    @State private var visibleShowRadio = MainTabView.initialRadioVisible

    private static var initialSelection: String {
        #if DEBUG
        if DemoContent.isLargeLibraryFixtureEnabled {
            return "library"
        }
        #endif
        return "discover"
    }

    private static func initialBoolPreference(_ key: String, default defaultValue: Bool) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    private static var initialRadioVisible: Bool {
        guard !OfflineModeService.shared.isOffline else { return false }
        return initialBoolPreference(PersonalizationPreferenceKey.showRadio, default: true)
    }

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

            if visibleShowPlaylistsTab {
                Tab(String(localized: "playlists"), systemImage: "music.note.list", value: "playlists") {
                    PlaylistsView()
                }
            }

            if visibleShowRadio {
                Tab(String(localized: "radio"), systemImage: "dot.radiowaves.left.and.right", value: "radio") {
                    RadioView()
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
        .onChange(of: showPlaylistsTab) { _, _ in
            syncVisibleTabsIfAllowed()
        }
        .onChange(of: showRadio) { _, _ in
            syncVisibleTabsIfAllowed()
        }
        .onChange(of: offlineMode.isOffline) { _, _ in
            syncVisibleTabs()
        }
        .onChange(of: selection) { _, newSelection in
            if newSelection != "settings" {
                syncVisibleTabs()
            }
        }
        .onChange(of: visibleShowPlaylistsTab) { _, on in
            if !on && selection == "playlists" { selection = "settings" }
        }
        .onChange(of: visibleShowRadio) { _, on in
            if !on && selection == "radio" { selection = "search" }
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
        .task(id: queueSync.pendingRemote != nil) {
            guard queueSync.pendingRemote != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            queueSync.dismissPending()
        }
    }

    private func syncVisibleTabsIfAllowed() {
        guard selection != "settings" else { return }
        syncVisibleTabs()
    }

    private func syncVisibleTabs() {
        visibleShowPlaylistsTab = showPlaylistsTab
        visibleShowRadio = showRadio && !offlineMode.isOffline
    }
}
