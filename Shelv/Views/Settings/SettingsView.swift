import SwiftUI

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

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        NavigationStack {
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

                    if recapEnabled {
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
                    NavigationLink(destination: UICustomizationsSettingsView()) {
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
                }
                Text(server.baseURL)
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

}

private struct UICustomizationsSettingsView: View {
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage(PersonalizationPreferenceKey.showInstantMixActions) private var showInstantMixActions = true

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    UIPlaylistsSettingsView()
                } label: {
                    Label(String(localized: "playlists"), systemImage: "music.note.list")
                        .foregroundStyle(accentColor)
                }

                NavigationLink {
                    UIFavoritesSettingsView()
                } label: {
                    Label(String(localized: "favorites"), systemImage: "heart")
                        .foregroundStyle(accentColor)
                }
            }

            Section {
                Toggle(isOn: $showInstantMixActions) {
                    Label { Text(String(localized: "instant_mix")) } icon: {
                        Image(systemName: "sparkles").foregroundStyle(accentColor)
                    }
                }
                .tint(accentColor)
            }

            Section {
                NavigationLink {
                    UISwipeActionsSettingsView()
                } label: {
                    Label(String(localized: "swipe_actions"), systemImage: "hand.draw")
                        .foregroundStyle(accentColor)
                }
            }
        }
        .navigationTitle(String(localized: "ui_customizations"))
        .navigationBarTitleDisplayMode(.inline)
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
    @AppStorage(PersonalizationPreferenceKey.showFavoriteActions) private var showFavoriteActions = true
    @AppStorage(PersonalizationPreferenceKey.showPlaylistActions) private var showPlaylistActions = true
    @AppStorage(PersonalizationPreferenceKey.swipeLeftPrimary) private var leftPrimary = PersonalizationSwipeAction.favorite.rawValue
    @AppStorage(PersonalizationPreferenceKey.swipeLeftSecondary) private var leftSecondary = PersonalizationSwipeAction.addToPlaylist.rawValue
    @AppStorage(PersonalizationPreferenceKey.swipeRightPrimary) private var rightPrimary = PersonalizationSwipeAction.playNext.rawValue
    @AppStorage(PersonalizationPreferenceKey.swipeRightSecondary) private var rightSecondary = PersonalizationSwipeAction.addToQueue.rawValue

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        List {
            Section(String(localized: "swipe_left")) {
                SwipeSlotNavigationRow(slot: .leftPrimary, accentColor: accentColor)
                SwipeSlotNavigationRow(slot: .leftSecondary, accentColor: accentColor)
            }

            Section(String(localized: "swipe_right")) {
                SwipeSlotNavigationRow(slot: .rightPrimary, accentColor: accentColor)
                SwipeSlotNavigationRow(slot: .rightSecondary, accentColor: accentColor)
            }

            Section {
                Button(String(localized: "reset_to_defaults")) {
                    PersonalizationSettings.resetSwipeActions()
                }
                .foregroundStyle(accentColor)
            }
        }
        .navigationTitle(String(localized: "swipe_actions"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            PersonalizationSettings.normalizeSwipeActions()
        }
        .onChange(of: showFavoriteActions) { _, _ in
            PersonalizationSettings.normalizeSwipeActions()
        }
        .onChange(of: showPlaylistActions) { _, _ in
            PersonalizationSettings.normalizeSwipeActions()
        }
        .onChange(of: leftPrimary) { _, _ in }
        .onChange(of: leftSecondary) { _, _ in }
        .onChange(of: rightPrimary) { _, _ in }
        .onChange(of: rightSecondary) { _, _ in }
    }
}

private struct SwipeSlotNavigationRow: View {
    let slot: PersonalizationSwipeSlot
    let accentColor: Color

    var body: some View {
        NavigationLink {
            SwipeActionPickerView(slot: slot)
        } label: {
            HStack {
                Text(localized(slot.titleKey))
                Spacer()
                Label(localized(action.titleKey), systemImage: action.systemImage)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var action: PersonalizationSwipeAction {
        PersonalizationSettings.swipeAction(for: slot)
    }
}

private struct SwipeActionPickerView: View {
    let slot: PersonalizationSwipeSlot
    @State private var refreshToken = 0

    var body: some View {
        List {
            ForEach(PersonalizationSwipeAction.allCases, id: \.self) { action in
                Button {
                    PersonalizationSettings.setSwipeAction(action, for: slot)
                    refreshToken += 1
                } label: {
                    HStack(spacing: 12) {
                        Label(localized(action.titleKey), systemImage: action.systemImage)
                        Spacer()
                        if let reason = disabledReason(for: action) {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if currentAction == action {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                        }
                    }
                }
                .disabled(disabledReason(for: action) != nil)
            }
        }
        .id(refreshToken)
        .navigationTitle(localized(slot.titleKey))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            PersonalizationSettings.normalizeSwipeActions()
            refreshToken += 1
        }
    }

    private var currentAction: PersonalizationSwipeAction {
        PersonalizationSettings.swipeAction(for: slot)
    }

    private func disabledReason(for action: PersonalizationSwipeAction) -> String? {
        guard PersonalizationSettings.isAvailable(action) else {
            return localized("unavailable")
        }

        if let usedSlot = PersonalizationSettings.firstSlot(using: action, excluding: slot) {
            return String(format: localized("already_used_in_format"), localized(usedSlot.titleKey))
        }

        return nil
    }
}

private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
