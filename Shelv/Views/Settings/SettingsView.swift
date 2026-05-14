import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var serverStore: ServerStore
    @EnvironmentObject var lyricsStore: LyricsStore
    @AppStorage("appAppearance") private var appAppearance = "system"
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    @AppStorage("recapEnabled") private var recapEnabled = false
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = true
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

                Section(String(localized: "playlists_favorites")) {
                    Toggle(isOn: $enableFavorites) {
                        Label { Text(String(localized: "favorites")) } icon: {
                            Image(systemName: "heart").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)
                    Toggle(isOn: $enablePlaylists) {
                        Label { Text(String(localized: "playlists")) } icon: {
                            Image(systemName: "music.note.list").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)
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

                        Toggle(isOn: $iCloudSyncEnabled) {
                            Label { Text(String(localized: "icloud_sync")) } icon: {
                                Image(systemName: "icloud").foregroundStyle(accentColor)
                            }
                        }
                        .tint(accentColor)
                        .onChange(of: iCloudSyncEnabled) { _, _ in
                            Task { await CloudKitSyncService.shared.handleSyncEnabledChange() }
                        }

                        if !iCloudSyncEnabled {
                            Text(String(localized: "data_stays_local_multiple_devices_may_create_dupli"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                Section(String(localized: "settings")) {
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
                    if let url = URL(string: "https://ko-fi.com/Shelv") {
                        Button { openURL(url) } label: {
                            Label {
                                HStack {
                                    Text(String(localized: "support_my_work"))
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "cup.and.saucer")
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
