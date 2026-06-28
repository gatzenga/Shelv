import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var serverStore: ServerStore
    @AppStorage("appAppearance") private var appAppearance = "system"
    @AppStorage("themeColor") private var themeColor = "violet"

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
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("recapEnabled") private var recapEnabled = false
    @AppStorage("enableInstantMix") private var enableInstantMix = true

    var body: some View {
        Form {
            Section(String(localized: "ui_customizations")) {
                Toggle(String(localized: "playlists"), isOn: $enablePlaylists)
                Toggle(String(localized: "favorites"), isOn: $enableFavorites)
                Toggle(String(localized: "recaps"), isOn: $recapEnabled)
                Toggle(String(localized: "instant_mix"), isOn: $enableInstantMix)
            }
        }
        .navigationTitle(String(localized: "ui_customizations"))
    }
}
