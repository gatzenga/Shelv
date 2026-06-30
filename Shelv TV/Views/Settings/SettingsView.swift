import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var serverStore: ServerStore
    @AppStorage("appAppearance") private var appAppearance = "system"
    @AppStorage("themeColor") private var themeColor = "violet"
    @AppStorage("recapEnabled") private var recapEnabled = false

    private var isGerman: Bool { Locale.preferredLanguages.first?.hasPrefix("de") == true }
    private var appearanceOptions: [TVSettingsChoiceOption<String>] {
        [
            TVSettingsChoiceOption(value: "system", title: String(localized: "system")),
            TVSettingsChoiceOption(value: "light", title: String(localized: "light")),
            TVSettingsChoiceOption(value: "dark", title: String(localized: "dark")),
        ]
    }
    private var themeOptions: [TVSettingsChoiceOption<String>] {
        AppTheme.options.map { opt in
            TVSettingsChoiceOption(value: opt.name, title: isGerman ? opt.nameDE : opt.nameEN)
        }
    }

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
                    TVSettingsChoiceRow(
                        title: String(localized: "appearance"),
                        selection: $appAppearance,
                        options: appearanceOptions
                    )
                    TVSettingsChoiceRow(
                        title: String(localized: "accent_color"),
                        selection: $themeColor,
                        options: themeOptions
                    )
                }

                Section {
                    Toggle(String(localized: "recaps"), isOn: $recapEnabled)
                    NavigationLink(String(localized: "ui_customizations")) { TVUICustomizationsSettingsView() }
                    NavigationLink(String(localized: "playback")) { PlaybackSettingsView() }
                    NavigationLink(String(localized: "cache")) { CacheSettingsView() }
                    NavigationLink(String(localized: "database")) { DatabaseSettingsView() }
                    NavigationLink(String(localized: "icloud_sync")) { ICloudSyncSettingsView() }
                }

                Section(String(localized: "info")) {
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
                    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
                    // tvOS scrollt nur, wenn der Fokus auf ein Element wandern kann — reiner Text
                    // ist nicht fokussierbar, sonst bliebe der untere Hinweis unerreichbar.
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Shelv \(version) (\(build))")
                        Text(String(localized: "shelv_is_an_unofficial_navidrome_client_and_has_no"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focusable()
                }
            }
        }
    }
}

private struct TVUICustomizationsSettingsView: View {
    @AppStorage(PersonalizationPreferenceKey.showInstantMixActions) private var showInstantMixActions = true
    @AppStorage(PersonalizationPreferenceKey.showRadio) private var showRadio = true

    var body: some View {
        Form {
            Text(String(localized: "ui_customizations"))
                .font(.largeTitle).bold()
                .listRowBackground(Color.clear)

            Section(String(localized: "ui_customizations")) {
                NavigationLink(String(localized: "playlists")) {
                    TVPlaylistsPersonalizationView()
                }
                NavigationLink(String(localized: "favorites")) {
                    TVFavoritesPersonalizationView()
                }
                Toggle(String(localized: "show_instant_mix_actions"), isOn: $showInstantMixActions)
                Toggle(String(localized: "show_radio"), isOn: $showRadio)
            }
        }
        .toolbar(.hidden, for: .tabBar)
    }
}

private struct TVPlaylistsPersonalizationView: View {
    @AppStorage(PersonalizationPreferenceKey.showPlaylistsTab) private var showPlaylists = true
    @AppStorage(PersonalizationPreferenceKey.showPlaylistActions) private var showPlaylistActions = true

    var body: some View {
        Form {
            Text(String(localized: "playlists"))
                .font(.largeTitle).bold()
                .listRowBackground(Color.clear)

            Section(String(localized: "playlists")) {
                Toggle(String(localized: "show_playlists"), isOn: $showPlaylists)
                Toggle(String(localized: "show_add_to_playlist_actions"), isOn: $showPlaylistActions)
            }
        }
        .toolbar(.hidden, for: .tabBar)
    }
}

private struct TVFavoritesPersonalizationView: View {
    @AppStorage(PersonalizationPreferenceKey.showFavoritesInLibrary) private var showFavorites = true
    @AppStorage(PersonalizationPreferenceKey.showFavoriteActions) private var showFavoriteActions = true

    var body: some View {
        Form {
            Text(String(localized: "favorites"))
                .font(.largeTitle).bold()
                .listRowBackground(Color.clear)

            Section(String(localized: "favorites")) {
                Toggle(String(localized: "show_favorites"), isOn: $showFavorites)
                Toggle(String(localized: "show_favorite_actions"), isOn: $showFavoriteActions)
            }
        }
        .toolbar(.hidden, for: .tabBar)
    }
}
