import SwiftUI

struct UICustomizationsTab: View {
    @State private var section: CustomizationSection = .general

    private enum CustomizationSection: String, CaseIterable, Identifiable {
        case general
        case discover
        case playlists
        case favorites

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return String(localized: "general")
            case .discover: return String(localized: "discover")
            case .playlists: return String(localized: "playlists")
            case .favorites: return String(localized: "favorites")
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
                case .general: MacGeneralPersonalizationPanel()
                case .discover: MacDiscoveryPersonalizationPanel()
                case .playlists: MacPlaylistsPersonalizationPanel()
                case .favorites: MacFavoritesPersonalizationPanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .transaction { $0.animation = nil }
    }
}

private struct MacDiscoveryPersonalizationPanel: View {
    @AppStorage(PersonalizationPreferenceKey.discoverySectionOrder) private var sectionOrderRaw = PersonalizationSettings.defaultDiscoverySectionOrderRaw
    @Environment(\.themeColor) private var themeColor

    private var sectionOrder: [PersonalizationDiscoverySection] {
        PersonalizationSettings.discoverySectionOrder(from: sectionOrderRaw)
    }

    var body: some View {
        List {
            Section(String(localized: "smart_mixes")) {
                ForEach(Array(PersonalizationSmartMix.allCases.enumerated()), id: \.element) { index, mix in
                    MacSmartMixToggleRow(mix: mix)
                        .listRowSeparator(index == 0 ? .hidden : .automatic, edges: .top)
                }
            }

            Section(String(localized: "home_sections")) {
                ForEach(Array(sectionOrder.enumerated()), id: \.element) { index, section in
                    HStack(spacing: 10) {
                        Image(systemName: section.systemImage)
                            .foregroundStyle(themeColor)
                            .frame(width: 20)
                        Text(localized(section.titleKey))
                        Spacer()
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                    }
                    .listRowSeparator(index == 0 ? .hidden : .automatic, edges: .top)
                }
                .onMove(perform: moveSections)
            }
        }
        .listStyle(.inset)
        .onAppear(perform: normalizeSectionOrder)
    }

    private func moveSections(from source: IndexSet, to destination: Int) {
        var updated = sectionOrder
        updated.move(fromOffsets: source, toOffset: destination)
        sectionOrderRaw = PersonalizationSettings.rawDiscoverySectionOrder(updated)
    }

    private func normalizeSectionOrder() {
        let normalized = PersonalizationSettings.rawDiscoverySectionOrder(sectionOrder)
        if normalized != sectionOrderRaw {
            sectionOrderRaw = normalized
        }
    }
}

private struct MacSmartMixToggleRow: View {
    let mix: PersonalizationSmartMix
    @AppStorage private var isEnabled: Bool
    @Environment(\.themeColor) private var themeColor

    init(mix: PersonalizationSmartMix) {
        self.mix = mix
        _isEnabled = AppStorage(wrappedValue: true, mix.storageKey)
    }

    var body: some View {
        Toggle(isOn: $isEnabled) {
            Label {
                Text(localized(mix.titleKey))
            } icon: {
                Image(systemName: mix.systemImage)
                    .foregroundStyle(themeColor)
            }
        }
        .tint(themeColor)
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

private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

private struct MacGeneralPersonalizationPanel: View {
    @AppStorage(PersonalizationPreferenceKey.miniPlayerStyle) private var miniPlayerStyleRaw = PersonalizationMiniPlayerStyle.shelv.rawValue
    @AppStorage(PersonalizationPreferenceKey.showInstantMixActions) private var showInstantMixActions = true
    @AppStorage(PersonalizationPreferenceKey.showDiscoverInsights) private var showDiscoverInsights = true
    @AppStorage(PersonalizationPreferenceKey.showRadio) private var showRadio = true
    @AppStorage(PersonalizationPreferenceKey.showGenreFilter) private var showGenreFilter = true
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        Form {
            Section(String(localized: "interface_style")) {
                Picker(selection: $miniPlayerStyleRaw) {
                    ForEach(PersonalizationMiniPlayerStyle.allCases, id: \.self) { style in
                        Label(localized(style.titleKey), systemImage: style.systemImage)
                            .tag(style.rawValue)
                    }
                } label: {
                    Label(String(localized: "interface_style"), systemImage: "play.rectangle")
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle(isOn: $showInstantMixActions) {
                    Label(String(localized: "show_instant_mix_actions"), systemImage: "sparkles")
                }
                .tint(themeColor)

                Toggle(isOn: $showDiscoverInsights) {
                    Label(String(localized: "show_insights"), systemImage: "chart.bar.xaxis")
                }
                .tint(themeColor)

                Toggle(isOn: $showRadio) {
                    Label(String(localized: "show_radio"), systemImage: "dot.radiowaves.left.and.right")
                }
                .tint(themeColor)

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
