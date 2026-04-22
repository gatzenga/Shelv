import SwiftUI
import UniformTypeIdentifiers

private struct ShareableFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct SettingsView: View {
    @EnvironmentObject var serverStore: ServerStore
    @EnvironmentObject var libraryStore: LibraryStore
    private let player = AudioPlayerService.shared
    @EnvironmentObject var lyricsStore: LyricsStore
    @EnvironmentObject var recapStore: RecapStore
    @EnvironmentObject var ckStatus: CloudKitSyncStatus
    @AppStorage("appAppearance") private var appAppearance = "system"
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    @AppStorage("crossfadeEnabled") private var crossfadeEnabled = false
    @AppStorage("crossfadeDuration") private var crossfadeDuration = 5
    @AppStorage("autoFetchLyrics") private var autoFetchLyrics = true
    @AppStorage("recapEnabled") private var recapEnabled = false
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = true

    @State private var showAddServer = false
    @State private var editingServer: SubsonicServer?
    @State private var managingServer: SubsonicServer?
    @State private var showDeleteConfirm = false
    @State private var serverToDelete: SubsonicServer?
    @State private var showClearToast = false
    @State private var showClearCacheConfirm = false
    @State private var showResetLyricsConfirm = false
    @State private var cacheSize = "—"

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        ZStack {
        NavigationStack {
            List {
                Section(tr("Servers", "Server")) {
                    ForEach(serverStore.servers) { server in
                        serverRow(server)
                    }
                    Button {
                        showAddServer = true
                    } label: {
                        Label(tr("Add Server", "Server hinzufügen"), systemImage: "plus.circle")
                            .foregroundStyle(accentColor)
                    }
                }

                Section(tr("Appearance", "Erscheinungsbild")) {
                    Picker(tr("Appearance", "Erscheinungsbild"), selection: $appAppearance) {
                        Text(tr("System", "System")).tag("system")
                        Text(tr("Light", "Hell")).tag("light")
                        Text(tr("Dark", "Dunkel")).tag("dark")
                    }
                    .id(appAppearance + themeColorName)
                    Picker(tr("Accent Color", "Akzentfarbe"), selection: $themeColorName) {
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

                Section(tr("Playlists & Favorites", "Playlists & Favoriten")) {
                    Toggle(isOn: $enableFavorites) {
                        Label { Text(tr("Favorites", "Favoriten")) } icon: {
                            Image(systemName: "heart").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)
                    Toggle(isOn: $enablePlaylists) {
                        Label { Text(tr("Playlists", "Playlists")) } icon: {
                            Image(systemName: "music.note.list").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)
                }

                Section(tr("Crossfade", "Crossfade")) {
                    Toggle(isOn: $crossfadeEnabled) {
                        Label { Text(tr("Crossfade", "Crossfade")) } icon: {
                            Image(systemName: "waveform").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)

                    if crossfadeEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label { Text(tr("Duration", "Dauer")) } icon: {
                                    Image(systemName: "timer").foregroundStyle(accentColor)
                                }
                                Spacer()
                                Text("\(crossfadeDuration)s")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(crossfadeDuration) },
                                    set: { crossfadeDuration = Int($0.rounded()) }
                                ),
                                in: 1...12,
                                step: 1
                            )
                            .tint(accentColor)
                        }
                    }
                }

                Section(tr("Recap", "Recap")) {
                    Toggle(isOn: $recapEnabled) {
                        Label { Text(tr("Recap", "Recap")) } icon: {
                            Image(systemName: "calendar.badge.clock").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)

                    if recapEnabled {
                        NavigationLink(destination:
                            RecapSettingsView()
                                .environmentObject(serverStore)
                                .environmentObject(recapStore)
                                .environmentObject(ckStatus)
                        ) {
                            Label { Text(tr("Settings", "Einstellungen")) } icon: {
                                Image(systemName: "slider.horizontal.3").foregroundStyle(accentColor)
                            }
                        }

                        Toggle(isOn: $iCloudSyncEnabled) {
                            Label { Text(tr("iCloud Sync", "iCloud-Sync")) } icon: {
                                Image(systemName: "icloud").foregroundStyle(accentColor)
                            }
                        }
                        .tint(accentColor)
                        .onChange(of: iCloudSyncEnabled) { _, _ in
                            Task { await CloudKitSyncService.shared.handleSyncEnabledChange() }
                        }

                        if !iCloudSyncEnabled {
                            Text(tr(
                                "Data stays local. Multiple devices may create duplicate recap playlists.",
                                "Daten bleiben lokal. Mehrere Geräte können doppelte Recap-Playlists erstellen."
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                Section(tr("Lyrics", "Lyrics")) {
                    HStack {
                        Label { Text(tr("Database", "Datenbank")) } icon: {
                            Image(systemName: "text.bubble").foregroundStyle(accentColor)
                        }
                        Spacer()
                        Group {
                            if lyricsStore.isDownloading {
                                let progress = "\(lyricsStore.downloadFetched) / \(lyricsStore.downloadTotal)"
                                Text(progress)
                            } else {
                                let countText = "\(lyricsStore.fetchedCount) · \(lyricsStore.dbSize)"
                                Text(countText)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }

                    Toggle(isOn: $autoFetchLyrics) {
                        Label { Text(tr("Auto-fetch on playback", "Beim Abspielen laden")) } icon: {
                            Image(systemName: "wand.and.stars").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)

                    if lyricsStore.isDownloading {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(
                                value: Double(lyricsStore.downloadFetched),
                                total: Double(max(lyricsStore.downloadTotal, 1))
                            )
                            .tint(accentColor)
                            Button(tr("Cancel download", "Download abbrechen")) {
                                lyricsStore.cancelBulkDownload()
                            }
                            .foregroundStyle(.red)
                            .font(.caption)
                        }
                    } else {
                        Button {
                            guard let sid = serverStore.activeServerID?.uuidString else { return }
                            lyricsStore.startBulkDownload(serverId: sid)
                        } label: {
                            Label { Text(tr("Download all lyrics", "Alle Lyrics laden")) } icon: {
                            Image(systemName: "arrow.down.circle").foregroundStyle(accentColor)
                        }
                        }
                    }

                    Button(role: .destructive) {
                        showResetLyricsConfirm = true
                    } label: {
                        Label { Text(tr("Reset lyrics database", "Lyrics zurücksetzen")) } icon: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }
                    }
                    .tint(.red)
                }

                Section(tr("Cache", "Cache")) {
                    HStack {
                        Label { Text(tr("Cache Size", "Cache-Größe")) } icon: {
                            Image(systemName: "internaldrive").foregroundStyle(accentColor)
                        }
                        Spacer()
                        Text(cacheSize)
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        showClearCacheConfirm = true
                    } label: {
                        Label { Text(tr("Clear Cache", "Cache leeren")) } icon: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }
                    }
                    .tint(.red)
                }

                Section(tr("Links & Contact", "Links & Kontakt")) {
                    if let url = URL(string: "https://github.com/gatzenga/Shelv") {
                        Link(destination: url) {
                            HStack {
                                Image(systemName: "chevron.left.forwardslash.chevron.right")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                Text("GitHub")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let url = URL(string: "https://gatzenga.github.io/Shelv/privacy.html") {
                        Link(destination: url) {
                            HStack {
                                Image(systemName: "hand.raised")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                Text(tr("Privacy Policy", "Datenschutz"))
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let url = URL(string: "mailto:kontakt@vkugler.ch") {
                        Link(destination: url) {
                            HStack {
                                Image(systemName: "envelope")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                Text(tr("Contact", "Kontakt"))
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let url = URL(string: "https://discord.gg/a8VvwDeR") {
                        Link(destination: url) {
                            HStack {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                Text("Discord")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section(tr("Info", "Info")) {
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
                    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
                    Text("Shelv \(version) (\(build))")
                    Text(tr(
                        "Shelv is an unofficial Navidrome client and has no affiliation with Navidrome or its developers.",
                        "Shelv ist ein inoffizieller Navidrome-Client und steht in keiner Verbindung zu Navidrome oder dessen Entwicklern."
                    ))
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
            .navigationTitle(tr("Settings", "Einstellungen"))
            .task {
                await recalculateCacheSize()
                if let sid = serverStore.activeServerID?.uuidString {
                    await lyricsStore.refreshFetchedCount(serverId: sid)
                }
                lyricsStore.refreshDbSize()
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
                    .environmentObject(libraryStore)
                    .tint(accentColor)
                }
            }
            .alert(
                tr("Delete Server?", "Server löschen?"),
                isPresented: $showDeleteConfirm,
                presenting: serverToDelete
            ) { server in
                Button(tr("Delete", "Löschen"), role: .destructive) {
                    serverStore.delete(server: server)
                }
                Button(tr("Cancel", "Abbrechen"), role: .cancel) {}
            } message: { server in
                Text("\"\(server.displayName)\"")
            }
            .alert(
                tr("Reset lyrics database?", "Lyrics-Datenbank zurücksetzen?"),
                isPresented: $showResetLyricsConfirm
            ) {
                Button(tr("Reset", "Zurücksetzen"), role: .destructive) {
                    Task {
                        guard let sid = serverStore.activeServerID?.uuidString else { return }
                        await lyricsStore.reset(serverId: sid)
                    }
                }
                Button(tr("Cancel", "Abbrechen"), role: .cancel) {}
            } message: {
                Text(tr(
                    "All downloaded lyrics will be removed.",
                    "Alle heruntergeladenen Lyrics werden entfernt."
                ))
            }
            .alert(
                tr("Clear Cache?", "Cache leeren?"),
                isPresented: $showClearCacheConfirm
            ) {
                Button(tr("Clear", "Leeren"), role: .destructive) {
                    Task { await clearCache() }
                }
                Button(tr("Cancel", "Abbrechen"), role: .cancel) {}
            } message: {
                Text(tr(
                    "This will remove all cached images and library data. The library will need to reload on next launch.",
                    "Alle gecachten Bilder und Bibliotheksdaten werden entfernt. Die Bibliothek wird beim nächsten Start neu geladen."
                ))
            }
        }
        .tint(accentColor)

        if showClearToast {
            cacheClearedToast
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
                .allowsHitTesting(false)
        }
        }
        .tint(accentColor)
    }

    private var cacheClearedToast: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.white)
            Text(tr("Cache cleared", "Cache geleert"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(28)
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private func recalculateCacheSize() async {
        let imgBytes = await ImageCacheService.shared.diskUsageBytes()
        let libBytes = LibraryStore.diskCacheSizeBytes()
        let total = imgBytes + libBytes
        cacheSize = total > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
            : tr("Empty", "Leer")
    }

    private func clearCache() async {
        libraryStore.clearCache()
        await ImageCacheService.shared.clearAll()
        await recalculateCacheSize()
        withAnimation { showClearToast = true }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        withAnimation { showClearToast = false }
    }

    @ViewBuilder
    private func serverRow(_ server: SubsonicServer) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(server.displayName).font(.body)
                    if serverStore.activeServerID == server.id {
                        Text(tr("Active", "Aktiv"))
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
                Button(tr("Activate", "Aktivieren")) {
                    serverStore.activate(server: server)
                }
                Button(tr("Edit", "Bearbeiten")) {
                    editingServer = server
                }
                Divider()
                Button(tr("Manage Server", "Server verwalten")) {
                    managingServer = server
                }
                Divider()
                Button(tr("Delete", "Löschen"), role: .destructive) {
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
