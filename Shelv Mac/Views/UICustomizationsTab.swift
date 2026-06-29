import SwiftUI

struct UICustomizationsTab: View {
    @Environment(\.themeColor) private var themeColor
    @AppStorage(PersonalizationPreferenceKey.showInstantMixActions) private var showInstantMixActions = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        MacPlaylistsPersonalizationView()
                    } label: {
                        Label(String(localized: "playlists"), systemImage: "music.note.list")
                    }

                    NavigationLink {
                        MacFavoritesPersonalizationView()
                    } label: {
                        Label(String(localized: "favorites"), systemImage: "heart")
                    }
                }

                Section {
                    Toggle(String(localized: "show_instant_mix_actions"), isOn: $showInstantMixActions)
                        .toggleStyle(.switch)
                }
            }
            .navigationTitle(String(localized: "ui_customizations"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MacPlaylistsPersonalizationView: View {
    @AppStorage(PersonalizationPreferenceKey.showPlaylistsTab) private var showPlaylistsTab = true
    @AppStorage(PersonalizationPreferenceKey.showPlaylistActions) private var showPlaylistActions = true

    var body: some View {
        Form {
            Toggle(String(localized: "show_playlists_in_sidebar"), isOn: $showPlaylistsTab)
            Toggle(String(localized: "show_add_to_playlist_actions"), isOn: $showPlaylistActions)
        }
        .formStyle(.grouped)
        .padding(24)
        .navigationTitle(String(localized: "playlists"))
    }
}

private struct MacFavoritesPersonalizationView: View {
    @AppStorage(PersonalizationPreferenceKey.showFavoritesInLibrary) private var showFavoritesInLibrary = true
    @AppStorage(PersonalizationPreferenceKey.showFavoriteActions) private var showFavoriteActions = true

    var body: some View {
        Form {
            Toggle(String(localized: "show_favorites_in_sidebar"), isOn: $showFavoritesInLibrary)
            Toggle(String(localized: "show_favorite_actions"), isOn: $showFavoriteActions)
        }
        .formStyle(.grouped)
        .padding(24)
        .navigationTitle(String(localized: "favorites"))
    }
}
