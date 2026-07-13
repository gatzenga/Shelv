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
                    if recapEnabled {
                        NavigationLink(String(localized: "about")) {
                            TVRecapAboutView()
                        }
                    }
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

private struct TVRecapAboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(String(localized: "tvos_recap_about_display"))
                Text(String(localized: "tvos_recap_about_manage"))
                Text(String(localized: "tvos_recap_about_history"))
                Spacer()
            }
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 900, alignment: .leading)
            .padding(60)
        }
        .navigationTitle(String(localized: "about"))
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "done")) { dismiss() }
            }
        }
    }
}

private struct TVUICustomizationsSettingsView: View {
    @AppStorage(PersonalizationPreferenceKey.showInstantMixActions) private var showInstantMixActions = true
    @AppStorage(PersonalizationPreferenceKey.showDiscoverInsights) private var showDiscoverInsights = true
    @AppStorage(PersonalizationPreferenceKey.showRadio) private var showRadio = true
    @AppStorage(PersonalizationPreferenceKey.showGenreFilter) private var showGenreFilter = true

    var body: some View {
        Form {
            Text(String(localized: "ui_customizations"))
                .font(.largeTitle).bold()
                .listRowBackground(Color.clear)

            Section(String(localized: "ui_customizations")) {
                NavigationLink(String(localized: "discover")) {
                    TVDiscoverPersonalizationView()
                }
                NavigationLink(String(localized: "playlists")) {
                    TVPlaylistsPersonalizationView()
                }
                NavigationLink(String(localized: "favorites")) {
                    TVFavoritesPersonalizationView()
                }
                Toggle(String(localized: "show_instant_mix_actions"), isOn: $showInstantMixActions)
                Toggle(String(localized: "show_insights"), isOn: $showDiscoverInsights)
                Toggle(String(localized: "show_radio"), isOn: $showRadio)
                Toggle(String(localized: "show_genre"), isOn: $showGenreFilter)
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .onChange(of: showGenreFilter) { _, enabled in
            if !enabled {
                PersonalizationSettings.clearAlbumGenreFilter()
            }
        }
    }
}

private struct TVDiscoverPersonalizationView: View {
    @AppStorage(PersonalizationPreferenceKey.discoverySectionOrder) private var sectionOrderRaw = PersonalizationSettings.defaultDiscoverySectionOrderRaw

    private var sectionOrder: [PersonalizationDiscoverySection] {
        PersonalizationSettings.discoverySectionOrder(from: sectionOrderRaw)
    }

    var body: some View {
        Form {
            Text(String(localized: "discover"))
                .font(.largeTitle).bold()
                .listRowBackground(Color.clear)

            Section(String(localized: "smart_mixes")) {
                ForEach(PersonalizationSmartMix.allCases) { mix in
                    TVSmartMixToggleRow(mix: mix)
                }
            }

            Section(String(localized: "home_sections")) {
                ForEach(Array(sectionOrder.enumerated()), id: \.element) { index, section in
                    TVDiscoverySectionOrderRow(
                        section: section,
                        index: index,
                        count: sectionOrder.count,
                        moveSection: moveSection
                    )
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .onAppear(perform: normalizeSectionOrder)
    }

    private func moveSection(at index: Int, by offset: Int) {
        let target = index + offset
        guard sectionOrder.indices.contains(index), sectionOrder.indices.contains(target) else { return }
        var updated = sectionOrder
        updated.swapAt(index, target)
        sectionOrderRaw = PersonalizationSettings.rawDiscoverySectionOrder(updated)
    }

    private func normalizeSectionOrder() {
        let normalized = PersonalizationSettings.rawDiscoverySectionOrder(sectionOrder)
        if normalized != sectionOrderRaw {
            sectionOrderRaw = normalized
        }
    }
}

private struct TVDiscoverySectionOrderRow: View {
    let section: PersonalizationDiscoverySection
    let index: Int
    let count: Int
    let moveSection: (Int, Int) -> Void
    @State private var showMoveOptions = false

    var body: some View {
        Button {
            showMoveOptions = true
        } label: {
            HStack(spacing: 16) {
                Label {
                    Text(localized(section.titleKey))
                } icon: {
                    Image(systemName: section.systemImage)
                }

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44)
            }
            .contentShape(Rectangle())
        }
        .confirmationDialog(localized(section.titleKey), isPresented: $showMoveOptions, titleVisibility: .visible) {
            Button(String(localized: "move_up")) {
                moveSection(index, -1)
            }
            .disabled(index == 0)

            Button(String(localized: "move_down")) {
                moveSection(index, 1)
            }
            .disabled(index == count - 1)

            Button(String(localized: "cancel"), role: .cancel) {}
        }
    }
}

private struct TVSmartMixToggleRow: View {
    let mix: PersonalizationSmartMix
    @AppStorage private var isEnabled: Bool

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
            }
        }
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

private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
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
