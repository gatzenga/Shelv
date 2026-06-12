import SwiftUI

struct SettingsView: View {
    @AppStorage("appAppearance") private var appAppearance = "system"
    @AppStorage("themeColor") private var themeColor = "violet"
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    @AppStorage("enableFavorites") private var enableFavorites = true

    private var isGerman: Bool { Locale.preferredLanguages.first?.hasPrefix("de") == true }

    var body: some View {
        NavigationStack {
            Form {
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
                }

                Section {
                    NavigationLink(String(localized: "playback")) { PlaybackSettingsView() }
                }
            }
            .navigationTitle(String(localized: "settings"))
        }
    }
}
