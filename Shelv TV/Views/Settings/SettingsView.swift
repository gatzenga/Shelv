import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var serverStore: ServerStore
    @AppStorage("appAppearance") private var appAppearance = "system"
    @AppStorage("themeColor") private var themeColor = "violet"
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("recapEnabled") private var recapEnabled = false
    @AppStorage("autoFetchLyrics") private var autoFetchLyrics = true

    private var isGerman: Bool { Locale.preferredLanguages.first?.hasPrefix("de") == true }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "servers")) {
                    NavigationLink {
                        ServerSettingsView()
                    } label: {
                        HStack {
                            Text(String(localized: "server"))
                            Spacer()
                            Text(serverStore.activeServer?.displayName ?? "—")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section(String(localized: "appearance")) {
                    Picker(String(localized: "appearance"), selection: $appAppearance) {
                        Text(String(localized: "system")).tag("system")
                        Text(String(localized: "light")).tag("light")
                        Text(String(localized: "dark")).tag("dark")
                    }
                    Picker(String(localized: "accent_color"), selection: $themeColor) {
                        ForEach(AppTheme.options, id: \.name) { opt in
                            Text(isGerman ? opt.nameDE : opt.nameEN).tag(opt.name)
                        }
                    }
                }

                Section(String(localized: "library")) {
                    Toggle(String(localized: "playlists"), isOn: $enablePlaylists)
                    Toggle(String(localized: "favorites"), isOn: $enableFavorites)
                    Toggle(String(localized: "recaps"), isOn: $recapEnabled)
                }

                Section {
                    NavigationLink(String(localized: "playback")) { PlaybackSettingsView() }
                }

                Section(String(localized: "lyrics")) {
                    Toggle(String(localized: "auto_fetch_lyrics"), isOn: $autoFetchLyrics)
                }

                Section {
                    NavigationLink(String(localized: "cache")) { CacheSettingsView() }
                    NavigationLink(String(localized: "database")) { DatabaseSettingsView() }
                }
            }
        }
    }
}
