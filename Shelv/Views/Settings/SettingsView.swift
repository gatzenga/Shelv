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
    private let player = AudioPlayerService.shared
    @EnvironmentObject var lyricsStore: LyricsStore
    @AppStorage("appAppearance") private var appAppearance = "system"
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    @AppStorage("gaplessEnabled") private var gaplessEnabled = false
    @AppStorage("autoFetchLyrics") private var autoFetchLyrics = true
    @AppStorage("recapEnabled") private var recapEnabled = false
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = true
    @AppStorage("enableDownloads") private var enableDownloads = false
    @AppStorage("offlineModeEnabled") private var offlineModeEnabled = false
    @AppStorage("maxBulkDownloadStorageGB") private var maxBulkStorageGB = 10
    @AppStorage("transcodingEnabled") private var transcodingEnabled = false
    @ObservedObject var offlineMode = OfflineModeService.shared
    @Environment(\.openURL) private var openURL

    @State private var showAddServer = false
    @State private var editingServer: SubsonicServer?
    @State private var managingServer: SubsonicServer?
    @State private var showDeleteConfirm = false
    @State private var serverToDelete: SubsonicServer?
    @State private var showClearToast = false
    @State private var showClearCacheConfirm = false
    @State private var showResetLyricsConfirm = false
    @State private var cacheSize = "—"
    @State private var showBulkDownloadSheet = false
    @State private var showDeleteAllDownloadsConfirm = false

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

                Section(tr("Transcoding", "Transcoding")) {
                    Toggle(isOn: $transcodingEnabled) {
                        Label { Text(tr("Transcoding", "Transcoding")) } icon: {
                            Image(systemName: "waveform.badge.magnifyingglass").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)
                    if transcodingEnabled {
                        NavigationLink(destination: TranscodingSettingsView()) {
                            Label { Text(tr("Settings", "Einstellungen")) } icon: {
                                Image(systemName: "slider.horizontal.3").foregroundStyle(accentColor)
                            }
                        }
                    }
                }

                Section(tr("Gapless", "Gapless")) {
                    Toggle(isOn: $gaplessEnabled) {
                        Label { Text(tr("Gapless", "Gapless")) } icon: {
                            Image(systemName: "waveform.path").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)
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

                downloadsSection

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
                            let lyrTotal = max(lyricsStore.downloadTotal, 1)
                            let lyrDone = max(0, min(lyricsStore.downloadFetched, lyrTotal))
                            ProgressView(
                                value: Double(lyrDone),
                                total: Double(lyrTotal)
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
                    if let url = URL(string: "https://vkugler.app") {
                        Button { openURL(url) } label: {
                            Label {
                                HStack {
                                    Text(tr("Developer Website", "Developer-Website"))
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
                                    Text(tr("Privacy Policy", "Datenschutz"))
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
                                    Text(tr("Contact", "Kontakt"))
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
                                    Text(tr("Support my work", "Support my work"))
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
                    .environmentObject(LibraryStore.shared)
                    .tint(accentColor)
                }
            }
            .sheet(isPresented: $showBulkDownloadSheet) {
                BulkDownloadSheet(maxBytes: Int64(maxBulkStorageGB) * 1024 * 1024 * 1024)
                    .presentationDetents([.large])
                    .presentationCornerRadius(24)
                    .tint(accentColor)
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
        LibraryStore.shared.clearCache()
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

    // MARK: - Downloads Section

    @ViewBuilder
    private var downloadsSection: some View {
        Section(tr("Downloads", "Downloads")) {
            Toggle(isOn: $enableDownloads) {
                Label { Text(tr("Enable Downloads", "Downloads aktivieren")) } icon: {
                    Image(systemName: "arrow.down.circle").foregroundStyle(accentColor)
                }
            }
            .tint(accentColor)

            if enableDownloads {
                Toggle(isOn: Binding(
                    get: { offlineMode.isOffline },
                    set: { newValue in
                        if newValue { offlineMode.enterOfflineMode() } else { offlineMode.exitOfflineMode() }
                    }
                )) {
                    Label { Text(tr("Offline Mode", "Offline-Modus")) } icon: {
                        Image(systemName: "wifi.slash").foregroundStyle(accentColor)
                    }
                }
                .tint(accentColor)

                Button {
                    showBulkDownloadSheet = true
                } label: {
                    Label { Text(tr("Download Everything", "Alles herunterladen")) } icon: {
                        Image(systemName: "square.and.arrow.down.on.square").foregroundStyle(accentColor)
                    }
                }
                .disabled(offlineMode.isOffline)

                HStack {
                    Label { Text(tr("Max Storage", "Max. Speicher")) } icon: {
                        Image(systemName: "externaldrive").foregroundStyle(accentColor)
                    }
                    Spacer()
                    Stepper("\(maxBulkStorageGB) GB",
                            value: $maxBulkStorageGB,
                            in: 10...500,
                            step: 10)
                        .labelsHidden()
                    Text("\(maxBulkStorageGB) GB")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Button(role: .destructive) {
                    showDeleteAllDownloadsConfirm = true
                } label: {
                    Label { Text(tr("Delete All Downloads", "Alle Downloads löschen")) } icon: {
                        Image(systemName: "trash")
                    }
                    .foregroundStyle(.red)
                }
                .tint(.red)

                ActiveDownloadProgressCell()

                DownloadStatsCell()
            }
        }
        .alert(
            tr("Delete all downloads?", "Alle Downloads löschen?"),
            isPresented: $showDeleteAllDownloadsConfirm
        ) {
            Button(tr("Delete", "Löschen"), role: .destructive) {
                DownloadStore.shared.deleteAll()
            }
            Button(tr("Cancel", "Abbrechen"), role: .cancel) {}
        } message: {
            Text(tr(
                "All downloaded songs, albums and artists will be removed from this device.",
                "Alle heruntergeladenen Songs, Alben und Künstler werden von diesem Gerät entfernt."
            ))
        }
        .task(id: enableDownloads) {
            guard enableDownloads, LibraryStore.shared.albums.isEmpty else { return }
            await LibraryStore.shared.loadAlbums()
        }
    }


}

private struct DownloadStatsCell: View {
    @ObservedObject private var downloadStore = DownloadStore.shared
    @State private var stats: DownloadStorageStats?

    var body: some View {
        Group {
            if let stats {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(tr("Used", "Belegt"))
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if let free = stats.freeDiskBytes {
                        HStack {
                            Text(tr("Free on device", "Frei auf Gerät"))
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    HStack {
                        Text(tr("Songs", "Songs"))
                        Spacer()
                        Text("\(stats.songCount)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    HStack {
                        Text(tr("Albums", "Alben"))
                        Spacer()
                        Text("\(stats.albumCount)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    HStack {
                        Text(tr("Artists", "Künstler"))
                        Spacer()
                        Text("\(stats.artistCount)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .font(.subheadline)
            } else {
                ProgressView()
            }
        }
        .task { await refresh() }
        .onChange(of: downloadStore.totalBytes) { _, _ in Task { await refresh() } }
        .onChange(of: downloadStore.songs.count) { _, _ in Task { await refresh() } }
    }

    @MainActor private func refresh() async {
        let albums = LibraryStore.shared.albums
        let counts = Dictionary(uniqueKeysWithValues: albums.compactMap { album -> (String, Int)? in
            guard let c = album.songCount else { return nil }
            return (album.id, c)
        })
        let artistAlbums: [String: Set<String>] = Dictionary(
            grouping: albums.compactMap { album -> (String, String)? in
                guard let aid = album.artistId else { return nil }
                return (aid, album.id)
            },
            by: { $0.0 }
        ).mapValues { Set($0.map(\.1)) }
        stats = await DownloadStore.shared.computeStats(albumSongCounts: counts,
                                                       artistAlbumIds: artistAlbums)
    }
}

private struct ActiveDownloadProgressCell: View {
    @ObservedObject private var store = DownloadStore.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        if let progress = store.batchProgress {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(tr("Active Downloads", "Aktive Downloads"))
                        .font(.subheadline.bold())
                    Spacer()
                    Text("\(progress.completed) / \(progress.total)")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: progress.fraction)
                    .tint(accentColor)
                HStack {
                    if progress.failed > 0 {
                        Text(tr("\(progress.failed) failed", "\(progress.failed) fehlgeschlagen"))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Button(tr("Cancel download", "Download abbrechen")) {
                        Task { await DownloadService.shared.cancelBatch() }
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }
        }
    }
}
