import SwiftUI
#if os(iOS)
import UIKit
#endif

private enum SettingsRoute: Hashable {
    case uiCustomizations
}

struct SettingsView: View {
    @EnvironmentObject var serverStore: ServerStore
    @EnvironmentObject var lyricsStore: LyricsStore
    @AppStorage("appAppearance") private var appAppearance = "system"
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("recapEnabled") private var recapEnabled = false
    @Environment(\.openURL) private var openURL

    @State private var showAddServer = false
    @State private var editingServer: SubsonicServer?
    @State private var managingServer: SubsonicServer?
    @State private var showDeleteConfirm = false
    @State private var serverToDelete: SubsonicServer?
    @State private var showAboutRecap = false
    @Binding private var path: NavigationPath

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    init(path: Binding<NavigationPath> = .constant(NavigationPath())) {
        _path = path
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section(String(localized: "servers")) {
                    ForEach(serverStore.servers) { server in
                        serverRow(server)
                    }
                    Button {
                        showAddServer = true
                    } label: {
                        Label(String(localized: "add_server"), systemImage: "plus.circle")
                            .foregroundStyle(accentColor)
                    }
                }

                Section(String(localized: "appearance")) {
                    Picker(String(localized: "appearance"), selection: $appAppearance) {
                        Text(String(localized: "system")).tag("system")
                        Text(String(localized: "light")).tag("light")
                        Text(String(localized: "dark")).tag("dark")
                    }
                    .id(appAppearance + themeColorName)
                    Picker(String(localized: "accent_color"), selection: $themeColorName) {
                        ForEach(AppTheme.options, id: \.name) { option in
                            HStack {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 14, height: 14)
                                Text(appLang == "de" ? option.nameDE : option.nameEN)
                            }
                            .tag(option.name)
                        }
                    }
                    .id(themeColorName)
                }

                Section(String(localized: "recap")) {
                    Toggle(isOn: $recapEnabled) {
                        Label { Text(String(localized: "recap")) } icon: {
                            Image(systemName: "calendar.badge.clock").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)
                    .onChange(of: recapEnabled) { _, enabled in
                        guard enabled, let server = serverStore.activeServer else { return }
                        Task { await RecapStore.shared.setup(serverId: server.stableId) }
                    }

                    if recapEnabled {
                        Button {
                            showAboutRecap = true
                        } label: {
                            Label {
                                Text(String(localized: "about")).foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: "info.circle").foregroundStyle(accentColor)
                            }
                        }

                        NavigationLink(destination:
                            RecapSettingsView()
                                .environmentObject(serverStore)
                        ) {
                            Label { Text(String(localized: "settings")) } icon: {
                                Image(systemName: "slider.horizontal.3").foregroundStyle(accentColor)
                            }
                        }
                    }
                }

                Section {
                    NavigationLink(value: SettingsRoute.uiCustomizations) {
                        Label { Text(String(localized: "ui_customizations")) } icon: {
                            Image(systemName: "slider.horizontal.2.square").foregroundStyle(accentColor)
                        }
                    }
                    NavigationLink(destination: PlaybackSettingsView()) {
                        Label { Text(String(localized: "playback")) } icon: {
                            Image(systemName: "waveform.path").foregroundStyle(accentColor)
                        }
                    }
                    NavigationLink(destination: DownloadsSettingsView()) {
                        Label { Text(String(localized: "downloads")) } icon: {
                            Image(systemName: "arrow.down.circle").foregroundStyle(accentColor)
                        }
                    }
                    NavigationLink(destination: LyricsSettingsView()
                        .environmentObject(serverStore)
                        .environmentObject(lyricsStore)
                    ) {
                        Label { Text(String(localized: "lyrics")) } icon: {
                            Image(systemName: "text.bubble").foregroundStyle(accentColor)
                        }
                    }
                    NavigationLink(destination: CacheSettingsView()) {
                        Label { Text(String(localized: "cache")) } icon: {
                            Image(systemName: "internaldrive").foregroundStyle(accentColor)
                        }
                    }
                    NavigationLink(destination:
                        DatabaseSettingsView()
                            .environmentObject(serverStore)
                    ) {
                        Label { Text(String(localized: "database")) } icon: {
                            Image(systemName: "cylinder").foregroundStyle(accentColor)
                        }
                    }
                    NavigationLink(destination: ICloudSyncSettingsView()) {
                        Label { Text("iCloud") } icon: {
                            Image(systemName: "icloud").foregroundStyle(accentColor)
                        }
                    }
                }

                Section(String(localized: "links_contact")) {
                    if let url = URL(string: "https://vkugler.app") {
                        Button { openURL(url) } label: {
                            Label {
                                HStack {
                                    Text(String(localized: "developer_website"))
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "globe")
                                    .foregroundStyle(accentColor)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    if let url = URL(string: "https://github.com/gatzenga/Shelv") {
                        Button { openURL(url) } label: {
                            Label {
                                HStack {
                                    Text("GitHub")
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "chevron.left.forwardslash.chevron.right")
                                    .foregroundStyle(accentColor)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    if let url = URL(string: "https://vkugler.app/shelv_privacy.html") {
                        Button { openURL(url) } label: {
                            Label {
                                HStack {
                                    Text(String(localized: "privacy_policy"))
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "hand.raised")
                                    .foregroundStyle(accentColor)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    if let url = URL(string: "mailto:contact@vkugler.app") {
                        Button { openURL(url) } label: {
                            Label {
                                HStack {
                                    Text(String(localized: "contact"))
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "envelope")
                                    .foregroundStyle(accentColor)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    if let url = URL(string: "https://discord.gg/UdJK5mpmZu") {
                        Button { openURL(url) } label: {
                            Label {
                                HStack {
                                    Text("Discord")
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .foregroundStyle(accentColor)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }

                Section(String(localized: "info")) {
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
                    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
                    Text("Shelv \(version) (\(build))")
                    Text(String(localized: "shelv_is_an_unofficial_navidrome_client_and_has_no"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                PlayerBottomSpacer()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            .tint(accentColor)
            .listStyle(.insetGrouped)
            .scrollIndicators(.hidden)
            .navigationTitle(String(localized: "settings"))
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .uiCustomizations:
                    UICustomizationsSettingsView()
                }
            }
            .sheet(isPresented: $showAboutRecap) {
                RecapAboutSheet()
            }
            .sheet(isPresented: $showAddServer) {
                AddServerView()
                    .environmentObject(serverStore)
                    .tint(accentColor)
            }
            .sheet(item: $editingServer) { server in
                AddServerView(editingServer: server)
                    .environmentObject(serverStore)
                    .tint(accentColor)
            }
            .sheet(item: $managingServer) { server in
                NavigationStack {
                    ServerDetailView(
                        server: server,
                        password: serverStore.password(for: server)
                    )
                    .environmentObject(LibraryStore.shared)
                    .tint(accentColor)
                }
            }
            .alert(
                String(localized: "delete_server"),
                isPresented: $showDeleteConfirm,
                presenting: serverToDelete
            ) { server in
                Button(String(localized: "delete"), role: .destructive) {
                    serverStore.delete(server: server)
                }
                Button(String(localized: "cancel"), role: .cancel) {}
            } message: { server in
                Text("\"\(server.displayName)\"")
            }
        }
        .tint(accentColor)
    }

    @ViewBuilder
    private func serverRow(_ server: SubsonicServer) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(server.displayName).font(.body)
                    if serverStore.activeServerID == server.id {
                        Text(String(localized: "active"))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(accentColor.opacity(0.2))
                            .foregroundStyle(accentColor)
                            .clipShape(Capsule())
                    }
                    if server.hasSecondaryURL {
                        Text(server.isUsingSecondaryURL
                             ? String(localized: "secondary_url")
                             : String(localized: "primary_url"))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .foregroundStyle(.secondary)
                            .clipShape(Capsule())
                    }
                }
                Text(server.activeBaseURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(server.username)
                    if let uid = server.remoteUserId {
                        Text("·")
                        Text(uid)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer()
            Menu {
                Button(String(localized: "activate")) {
                    serverStore.activate(server: server)
                }
                Button(String(localized: "edit")) {
                    editingServer = server
                }
                if server.hasSecondaryURL {
                    Button(server.isUsingSecondaryURL
                           ? String(localized: "use_primary_url")
                           : String(localized: "use_secondary_url")) {
                        Task { await switchServerURLSlot(from: server) }
                    }
                }
                Divider()
                Button(String(localized: "manage_server")) {
                    managingServer = server
                }
                Divider()
                Button(String(localized: "delete"), role: .destructive) {
                    serverToDelete = server
                    showDeleteConfirm = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            serverStore.activate(server: server)
        }
    }

    @MainActor
    private func switchServerURLSlot(from server: SubsonicServer) async {
        serverStore.toggleURLSlot(for: server)
        guard serverStore.activeServerID == server.id else { return }

        LibraryStore.shared.resetInMemory()
        RadioStationStore.shared.resetInMemory()

        if await OfflineModeService.shared.beginUserInitiatedServerRefresh() { return }
        defer { OfflineModeService.shared.finishUserInitiatedServerRefresh() }

        await LibraryStore.shared.loadDiscover()
        await RadioStationStore.shared.refresh()
    }

}

private struct UICustomizationsSettingsView: View {
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage(PersonalizationPreferenceKey.showInstantMixActions) private var showInstantMixActions = true
    @AppStorage(PersonalizationPreferenceKey.showDiscoverInsights) private var showDiscoverInsights = true
    @AppStorage(PersonalizationPreferenceKey.showRadio) private var showRadio = true
    @AppStorage(PersonalizationPreferenceKey.showGenreFilter) private var showGenreFilter = true
    @AppStorage(PersonalizationPreferenceKey.showDiscoverAirPlay) private var showDiscoverAirPlay = false
    @AppStorage(PersonalizationPreferenceKey.miniPlayerStyle) private var miniPlayerStyleRaw = PersonalizationMiniPlayerStyle.shelv.rawValue

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    UIDiscoverSettingsView()
                } label: {
                    Label { Text(String(localized: "discover")) } icon: {
                        Image(systemName: "sparkles").foregroundStyle(accentColor)
                    }
                }

                NavigationLink {
                    UIPlaylistsSettingsView()
                } label: {
                    Label { Text(String(localized: "playlists")) } icon: {
                        Image(systemName: "music.note.list").foregroundStyle(accentColor)
                    }
                }

                NavigationLink {
                    UIFavoritesSettingsView()
                } label: {
                    Label { Text(String(localized: "favorites")) } icon: {
                        Image(systemName: "heart").foregroundStyle(accentColor)
                    }
                }
            }

            Section {
                Toggle(isOn: $showInstantMixActions) {
                    Label { Text(String(localized: "show_instant_mix_actions")) } icon: {
                        Image(systemName: "sparkles").foregroundStyle(accentColor)
                    }
                }
                .tint(accentColor)

                Toggle(isOn: $showDiscoverInsights) {
                    Label { Text(String(localized: "show_insights")) } icon: {
                        Image(systemName: "chart.bar.xaxis").foregroundStyle(accentColor)
                    }
                }
                .tint(accentColor)

                Toggle(isOn: $showRadio) {
                    Label { Text(String(localized: "show_radio")) } icon: {
                        Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(accentColor)
                    }
                }
                .tint(accentColor)

                Toggle(isOn: $showGenreFilter) {
                    Label { Text(String(localized: "show_genre")) } icon: {
                        Image(systemName: "guitars").foregroundStyle(accentColor)
                    }
                }
                .tint(accentColor)

                Toggle(isOn: $showDiscoverAirPlay) {
                    Label { Text(String(localized: "show_airplay_on_discover")) } icon: {
                        Image(systemName: "airplayaudio").foregroundStyle(accentColor)
                    }
                }
                .tint(accentColor)
            }

            Section {
                Picker(selection: $miniPlayerStyleRaw) {
                    ForEach(PersonalizationMiniPlayerStyle.allCases, id: \.self) { style in
                        Text(localized(style.titleKey)).tag(style.rawValue)
                    }
                } label: {
                    Label { Text(String(localized: "interface_style")) } icon: {
                        Image(systemName: "play.rectangle").foregroundStyle(accentColor)
                    }
                }

                NavigationLink {
                    UISwipeActionsSettingsView()
                } label: {
                    Label { Text(String(localized: "swipe_actions")) } icon: {
                        Image(systemName: "hand.draw").foregroundStyle(accentColor)
                    }
                }
            }

            PlayerBottomSpacer()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
        .tint(accentColor)
        .listStyle(.insetGrouped)
        .scrollIndicators(.hidden)
        .navigationTitle(String(localized: "ui_customizations"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: showGenreFilter) { _, enabled in
            if !enabled {
                PersonalizationSettings.clearAlbumGenreFilter()
            }
        }
    }
}

private struct UIDiscoverSettingsView: View {
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage(PersonalizationPreferenceKey.discoverySectionOrder) private var sectionOrderRaw = PersonalizationSettings.defaultDiscoverySectionOrderRaw
    @State private var editMode = EditMode.inactive

    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    private var sectionOrder: [PersonalizationDiscoverySection] {
        PersonalizationSettings.discoverySectionOrder(from: sectionOrderRaw)
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    UISmartMixesSettingsView()
                } label: {
                    Label { Text(String(localized: "smart_mixes")) } icon: {
                        Image(systemName: "sparkles").foregroundStyle(accentColor)
                    }
                }
            }

            Section(String(localized: "home_sections")) {
                ForEach(sectionOrder) { section in
                    DiscoverySectionOrderRow(section: section, accentColor: accentColor)
                }
                .onMove(perform: moveSections)
            }

            PlayerBottomSpacer()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
        .tint(accentColor)
        .listStyle(.insetGrouped)
        .scrollIndicators(.hidden)
        .navigationTitle(String(localized: "discover"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditButton()
        }
        .environment(\.editMode, $editMode)
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

private struct UISmartMixesSettingsView: View {
    @AppStorage("themeColor") private var themeColorName = "violet"

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        List {
            Section {
                ForEach(PersonalizationSmartMix.allCases) { mix in
                    SmartMixToggleRow(mix: mix, accentColor: accentColor)
                }
            }

            PlayerBottomSpacer()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
        .tint(accentColor)
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "smart_mixes"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SmartMixToggleRow: View {
    let mix: PersonalizationSmartMix
    let accentColor: Color
    @AppStorage private var isEnabled: Bool

    init(mix: PersonalizationSmartMix, accentColor: Color) {
        self.mix = mix
        self.accentColor = accentColor
        _isEnabled = AppStorage(wrappedValue: true, mix.storageKey)
    }

    var body: some View {
        Toggle(isOn: $isEnabled) {
            Label { Text(localized(mix.titleKey)) } icon: {
                Image(systemName: mix.systemImage).foregroundStyle(accentColor)
            }
        }
        .tint(accentColor)
    }
}

private struct DiscoverySectionOrderRow: View {
    let section: PersonalizationDiscoverySection
    let accentColor: Color

    var body: some View {
        Label { Text(localized(section.titleKey)) } icon: {
            Image(systemName: section.systemImage).foregroundStyle(accentColor)
        }
    }
}

private struct UIPlaylistsSettingsView: View {
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage(PersonalizationPreferenceKey.showPlaylistsTab) private var showPlaylistsTab = true
    @AppStorage(PersonalizationPreferenceKey.showPlaylistActions) private var showPlaylistActions = true

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        List {
            Section {
                Toggle(String(localized: "show_playlists_in_tab_bar"), isOn: $showPlaylistsTab)
                    .tint(accentColor)
                Toggle(String(localized: "show_add_to_playlist_actions"), isOn: $showPlaylistActions)
                    .tint(accentColor)
            }

            PlayerBottomSpacer()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
        .navigationTitle(String(localized: "playlists"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: showPlaylistActions) { _, _ in
            PersonalizationSettings.normalizeSwipeActions()
        }
    }
}

private struct UIFavoritesSettingsView: View {
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage(PersonalizationPreferenceKey.showFavoritesInLibrary) private var showFavoritesInLibrary = true
    @AppStorage(PersonalizationPreferenceKey.showFavoriteActions) private var showFavoriteActions = true

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        List {
            Section {
                Toggle(String(localized: "show_favorites_in_library"), isOn: $showFavoritesInLibrary)
                    .tint(accentColor)
                Toggle(String(localized: "show_favorite_actions"), isOn: $showFavoriteActions)
                    .tint(accentColor)
            }

            PlayerBottomSpacer()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
        .navigationTitle(String(localized: "favorites"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: showFavoriteActions) { _, _ in
            PersonalizationSettings.normalizeSwipeActions()
        }
    }
}

private struct UISwipeActionsSettingsView: View {
    @AppStorage("themeColor") private var themeColorName = "violet"

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        List {
            Section {
                ForEach(PersonalizationSwipeGroup.allCases, id: \.self) { group in
                    NavigationLink {
                        UISwipeActionGroupSettingsView(group: group)
                    } label: {
                        Label { Text(localized(group.titleKey)) } icon: {
                            Image(systemName: group.systemImage).foregroundStyle(accentColor)
                        }
                    }
                }
            }

            Section {
                ResetDefaultsButton(accentColor: accentColor) {
                    PersonalizationSettings.resetSwipeActions()
                }
            }

            PlayerBottomSpacer()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
        .navigationTitle(String(localized: "swipe_actions"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            PersonalizationSettings.normalizeSwipeActions()
        }
    }
}

private struct UISwipeActionGroupSettingsView: View {
    let group: PersonalizationSwipeGroup
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage(PersonalizationPreferenceKey.showFavoriteActions) private var showFavoriteActions = true
    @AppStorage(PersonalizationPreferenceKey.showPlaylistActions) private var showPlaylistActions = true
    @AppStorage(PersonalizationPreferenceKey.showInstantMixActions) private var showInstantMixActions = true

    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    private var leadingSlots: [PersonalizationSwipeSlot] { group.slots.filter(\.isLeading) }
    private var trailingSlots: [PersonalizationSwipeSlot] { group.slots.filter { !$0.isLeading } }

    var body: some View {
        List {
            Section(String(localized: "swipe_left")) {
                ForEach(leadingSlots, id: \.self) { slot in
                    SwipeSlotNavigationRow(slot: slot, accentColor: accentColor)
                }
            }

            Section(String(localized: "swipe_right")) {
                ForEach(trailingSlots, id: \.self) { slot in
                    SwipeSlotNavigationRow(slot: slot, accentColor: accentColor)
                }
            }

            Section {
                ResetDefaultsButton(accentColor: accentColor) {
                    PersonalizationSettings.resetSwipeActions(for: group)
                }
            }

            PlayerBottomSpacer()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
        .navigationTitle(localized(group.titleKey))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            PersonalizationSettings.normalizeSwipeActions(for: group)
        }
        .onChange(of: showFavoriteActions) { _, _ in
            PersonalizationSettings.normalizeSwipeActions(for: group)
        }
        .onChange(of: showPlaylistActions) { _, _ in
            PersonalizationSettings.normalizeSwipeActions(for: group)
        }
        .onChange(of: showInstantMixActions) { _, _ in
            PersonalizationSettings.normalizeSwipeActions(for: group)
        }
        .transaction { $0.animation = nil }
    }
}

private struct ResetDefaultsButton: View {
    let accentColor: Color
    let action: () -> Bool

    @State private var showsConfirmation = false
    @State private var confirmationToken = 0

    var body: some View {
        Button {
            guard action() else { return }

#if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
#endif
            showsConfirmation = true
            confirmationToken += 1
        } label: {
            Label {
                Text(String(localized: "reset_to_defaults"))
            } icon: {
                Image(systemName: showsConfirmation ? "checkmark" : "arrow.counterclockwise")
                    .foregroundStyle(showsConfirmation ? Color.green : accentColor)
                    .frame(width: 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .foregroundStyle(accentColor)
        .buttonStyle(.plain)
        .task(id: confirmationToken) {
            guard confirmationToken > 0 else { return }
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            showsConfirmation = false
        }
    }
}

private struct SwipeSlotNavigationRow: View {
    let slot: PersonalizationSwipeSlot
    let accentColor: Color
    @AppStorage private var rawAction: String

    init(slot: PersonalizationSwipeSlot, accentColor: Color) {
        self.slot = slot
        self.accentColor = accentColor
        _rawAction = AppStorage(wrappedValue: slot.defaultAction.rawValue, slot.storageKey)
    }

    var body: some View {
        NavigationLink {
            SwipeActionPickerView(slot: slot)
        } label: {
            LabeledContent {
                SwipeActionInlineValue(action: action, accentColor: accentColor)
            } label: {
                Text(localized(slot.titleKey))
            }
        }
    }

    private var action: PersonalizationSwipeAction {
        _ = rawAction
        return PersonalizationSettings.swipeAction(for: slot)
    }
}

private struct SwipeActionPickerView: View {
    let slot: PersonalizationSwipeSlot
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage private var rawAction: String

    init(slot: PersonalizationSwipeSlot) {
        self.slot = slot
        _rawAction = AppStorage(wrappedValue: slot.defaultAction.rawValue, slot.storageKey)
    }

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        List {
            ForEach(slot.group.availableActions, id: \.self) { action in
                let reason = disabledReason(for: action)
                Button {
                    PersonalizationSettings.setSwipeAction(action, for: slot)
                    rawAction = UserDefaults.standard.string(forKey: slot.storageKey) ?? action.rawValue
                } label: {
                    SwipeActionOptionRow(
                        action: action,
                        isSelected: currentAction == action,
                        disabledReason: reason,
                        accentColor: accentColor
                    )
                }
                .buttonStyle(.plain)
                .disabled(reason != nil)
            }

            PlayerBottomSpacer()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
        .navigationTitle(localized(slot.titleKey))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            PersonalizationSettings.normalizeSwipeActions(for: slot.group)
            rawAction = UserDefaults.standard.string(forKey: slot.storageKey) ?? slot.defaultAction.rawValue
        }
        .transaction { $0.animation = nil }
    }

    private var currentAction: PersonalizationSwipeAction {
        _ = rawAction
        return PersonalizationSettings.swipeAction(for: slot)
    }

    private func disabledReason(for _: PersonalizationSwipeAction) -> String? {
        return nil
    }
}

private struct SwipeActionInlineValue: View {
    let action: PersonalizationSwipeAction
    let accentColor: Color

    var body: some View {
        HStack(spacing: 8) {
            SwipeActionIcon(action: action, accentColor: accentColor, size: 24)
            Text(localized(action.titleKey))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 176, alignment: .leading)
        .foregroundStyle(.secondary)
    }
}

private struct SwipeActionOptionRow: View {
    let action: PersonalizationSwipeAction
    let isSelected: Bool
    let disabledReason: String?
    let accentColor: Color

    var body: some View {
        HStack(spacing: 12) {
            SwipeActionIcon(action: action, accentColor: accentColor, size: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(localized(action.titleKey))
                    .foregroundStyle(.primary)
                if let disabledReason {
                    Text(disabledReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(accentColor)
            }
        }
        .contentShape(Rectangle())
        .opacity(disabledReason == nil ? 1 : 0.45)
    }
}

private struct SwipeActionIcon: View {
    let action: PersonalizationSwipeAction
    let accentColor: Color
    let size: CGFloat

    var body: some View {
        Image(systemName: action.systemImage)
            .font(.body.weight(.semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(action.displayColor(accentColor: accentColor))
            .frame(width: size, height: 24, alignment: .center)
    }
}

private struct RecapAboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                RecapAboutContent()
                    .padding()
            }
            .navigationTitle(String(localized: "recap"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct RecapAboutContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "recap_about_server_playlists"))
            Text(String(localized: "recap_about_icloud_recommended"))
            Text(String(localized: "recap_about_icloud_benefits"))
        }
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension PersonalizationSwipeAction {
    func displayColor(accentColor: Color) -> Color {
        switch self {
        case .none:
            return .secondary
        case .favorite:
            return .pink
        case .addToPlaylist, .addToQueue, .download, .pin:
            return accentColor
        case .instantMix:
            return .purple
        case .delete:
            return .red
        case .playNext:
            return .orange
        }
    }
}

private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
