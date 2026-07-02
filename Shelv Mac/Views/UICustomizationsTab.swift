import SwiftUI

struct UICustomizationsTab: View {
    @State private var section: CustomizationSection = .playlists

    private enum CustomizationSection: String, CaseIterable, Identifiable {
        case playlists
        case favorites
        case instantMix
        case radio
        case genre

        var id: String { rawValue }

        var title: String {
            switch self {
            case .playlists: return String(localized: "playlists")
            case .favorites: return String(localized: "favorites")
            case .instantMix: return String(localized: "instant_mix")
            case .radio: return String(localized: "radio")
            case .genre: return String(localized: "genre")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(CustomizationSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            Group {
                switch section {
                case .playlists: MacPlaylistsPersonalizationPanel()
                case .favorites: MacFavoritesPersonalizationPanel()
                case .instantMix: MacInstantMixPersonalizationPanel()
                case .radio: MacRadioPersonalizationPanel()
                case .genre: MacGenrePersonalizationPanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .transaction { $0.animation = nil }
    }
}

private struct MacPlaylistsPersonalizationPanel: View {
    @AppStorage(PersonalizationPreferenceKey.showPlaylistsTab) private var showPlaylistsTab = true
    @AppStorage(PersonalizationPreferenceKey.showPlaylistActions) private var showPlaylistActions = true
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $showPlaylistsTab) {
                    Label(String(localized: "show_playlists_in_sidebar"), systemImage: "sidebar.left")
                }
                .tint(themeColor)

                Toggle(isOn: $showPlaylistActions) {
                    Label(String(localized: "show_add_to_playlist_actions"), systemImage: "text.badge.plus")
                }
                .tint(themeColor)
            }
        }
        .formStyle(.grouped)
    }
}

private struct MacFavoritesPersonalizationPanel: View {
    @AppStorage(PersonalizationPreferenceKey.showFavoritesInLibrary) private var showFavoritesInLibrary = true
    @AppStorage(PersonalizationPreferenceKey.showFavoriteActions) private var showFavoriteActions = true
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $showFavoritesInLibrary) {
                    Label(String(localized: "show_favorites_in_sidebar"), systemImage: "heart.text.square")
                }
                .tint(themeColor)

                Toggle(isOn: $showFavoriteActions) {
                    Label(String(localized: "show_favorite_actions"), systemImage: "heart")
                }
                .tint(themeColor)
            }
        }
        .formStyle(.grouped)
    }
}

private struct MacInstantMixPersonalizationPanel: View {
    @AppStorage(PersonalizationPreferenceKey.showInstantMixActions) private var showInstantMixActions = true
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $showInstantMixActions) {
                    Label(String(localized: "show_instant_mix_actions"), systemImage: "sparkles")
                }
                .tint(themeColor)
            }
        }
        .formStyle(.grouped)
    }
}

private struct MacRadioPersonalizationPanel: View {
    @AppStorage(PersonalizationPreferenceKey.showRadio) private var showRadio = true
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $showRadio) {
                    Label(String(localized: "show_radio"), systemImage: "dot.radiowaves.left.and.right")
                }
                .tint(themeColor)
            }
        }
        .formStyle(.grouped)
    }
}

private struct MacGenrePersonalizationPanel: View {
    @AppStorage(PersonalizationPreferenceKey.showGenreFilter) private var showGenreFilter = true
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $showGenreFilter) {
                    Label(String(localized: "show_genre"), systemImage: "guitars")
                }
                .tint(themeColor)
            }
        }
        .formStyle(.grouped)
        .onChange(of: showGenreFilter) { _, enabled in
            if !enabled {
                PersonalizationSettings.clearAlbumGenreFilter()
            }
        }
    }
}
