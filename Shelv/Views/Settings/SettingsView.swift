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
    @AppStorage("streamPreCacheEnabled") private var streamPreCacheEnabled = false
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
    @State private var showPreCacheInfo = false

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    private var maxAllowedStorageGB: Int {
        guard let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return 500 }
        let gb = Int(bytes / 1_000_000_000)
        return max(10, (gb / 10) * 10)
    }

    var body: some View {
        ZStack {
        NavigationStack {
            List {
                Section(tr("settings.settings.servers")) {
                    ForEach(serverStore.servers) { server in
                        serverRow(server)
                    }
                    Button {
                        showAddServer = true
                    } label: {
                        Label(tr("settings.add.server.add_server"), systemImage: "plus.circle")
                            .foregroundStyle(accentColor)
                    }
                }

                Section(tr("settings.settings.appearance")) {
                    Picker(tr("settings.settings.appearance"), selection: $appAppearance) {
                        Text(tr("settings.settings.system")).tag("system")
                        Text(tr("settings.settings.light")).tag("light")
                        Text(tr("settings.settings.dark")).tag("dark")
                    }
                    .id(appAppearance + themeColorName)
                    Picker(tr("settings.settings.accent_color"), selection: $themeColorName) {
                        ForEach(AppTheme.options, id: \.name) { option in
                            HStack {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 14, height: 14)
                                Text(tr(option.localizationKey))
                            }
                            .tag(option.name)
                        }
                    }
                    .id(themeColorName)
                }

                Section(tr("settings.settings.playlists_favorites")) {
                    Toggle(isOn: $enableFavorites) {
                        Label { Text(tr("car.play.car.play.library.favorites")) } icon: {
                            Image(systemName: "heart").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)
                    Toggle(isOn: $enablePlaylists) {
                        Label { Text(tr("car.play.car.play.playlists.playlists")) } icon: {
                            Image(systemName: "music.note.list").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)
                }

                Section(tr("settings.settings.transcoding")) {
                    Toggle(isOn: $transcodingEnabled) {
                        Label { Text(tr("settings.settings.transcoding")) } icon: {
                            Image(systemName: "waveform.badge.magnifyingglass").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)
                    if transcodingEnabled {
                        NavigationLink(destination: TranscodingSettingsView()) {
                            Label { Text(tr("content.settings")) } icon: {
                                Image(systemName: "slider.horizontal.3").foregroundStyle(accentColor)
                            }
                        }
                    }
                }

                Section(tr("settings.settings.gapless")) {
                    Toggle(isOn: $gaplessEnabled) {
                        Label { Text(tr("settings.settings.gapless")) } icon: {
                            Image(systemName: "waveform.path").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)
                    if gaplessEnabled {
                        Text(tr("settings.settings.pre_cache_original_file_recommended_transcoded"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Section(tr("car.play.car.play.recap.recap")) {
                    Toggle(isOn: $recapEnabled) {
                        Label { Text(tr("car.play.car.play.recap.recap")) } icon: {
                            Image(systemName: "calendar.badge.clock").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)

                    if recapEnabled {
                        NavigationLink(destination:
                            RecapSettingsView()
                                .environmentObject(serverStore)
                        ) {
                            Label { Text(tr("content.settings")) } icon: {
                                Image(systemName: "slider.horizontal.3").foregroundStyle(accentColor)
                            }
                        }

                        Toggle(isOn: $iCloudSyncEnabled) {
                            Label { Text(tr("settings.recap.settings.icloud_sync")) } icon: {
                                Image(systemName: "icloud").foregroundStyle(accentColor)
                            }
                        }
                        .tint(accentColor)
                        .onChange(of: iCloudSyncEnabled) { _, _ in
                            Task { await CloudKitSyncService.shared.handleSyncEnabledChange() }
                        }

                        if !iCloudSyncEnabled {
                            Text(tr("settings.settings.data_stays_local_multiple_devices_may"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                downloadsSection

                Section(tr("player.lyrics.sheet.lyrics")) {
                    HStack {
                        Label { Text(tr("settings.recap.settings.database")) } icon: {
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
                        Label { Text(tr("settings.settings.auto_fetch_playback")) } icon: {
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
                            Button(tr("settings.settings.cancel_download")) {
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
                            Label { Text(tr("settings.settings.download_lyrics")) } icon: {
                            Image(systemName: "arrow.down.circle").foregroundStyle(accentColor)
                        }
                        }
                    }

                    Button(role: .destructive) {
                        showResetLyricsConfirm = true
                    } label: {
                        Label { Text(tr("settings.settings.reset_lyrics_database")) } icon: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }
                    }
                    .tint(.red)
                }

                Section(tr("settings.settings.cache")) {
                    Toggle(isOn: $streamPreCacheEnabled) {
                        Label { Text(tr("settings.settings.pre_cache_original_file")) } icon: {
                            Image(systemName: "arrow.down.to.line").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)
                    Button {
                        showPreCacheInfo = true
                    } label: {
                        Label {
                            Text(tr("settings.settings.about_pre_cache"))
                                .foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "info.circle").foregroundStyle(accentColor)
                        }
                    }
                    .sheet(isPresented: $showPreCacheInfo) {
                        NavigationStack {
                            ScrollView {
                                Text(tr("settings.settings.stable_network_independent_playback_seamless_gapless"))
                                .font(.body)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .navigationTitle(tr("settings.settings.pre_cache"))
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button(tr("player.queue.done")) { showPreCacheInfo = false }
                                }
                            }
                        }
                        .presentationDetents([.medium, .large])
                    }
                    HStack {
                        Label { Text(tr("settings.settings.cache_size")) } icon: {
                            Image(systemName: "internaldrive").foregroundStyle(accentColor)
                        }
                        Spacer()
                        Text(cacheSize)
                            .foregroundStyle(.secondary)
                    }
                    NavigationLink(destination: CacheLogView()) {
                        Label { Text(tr("settings.recap.settings.logs")) } icon: {
                            Image(systemName: "doc.text.magnifyingglass").foregroundStyle(accentColor)
                        }
                    }
                    Button(role: .destructive) {
                        showClearCacheConfirm = true
                    } label: {
                        Label { Text(tr("settings.settings.clear_cache")) } icon: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }
                    }
                    .tint(.red)
                }

                Section(tr("settings.settings.links_contact")) {
                    if let url = URL(string: "https://vkugler.app") {
                        Button { openURL(url) } label: {
                            Label {
                                HStack {
                                    Text(tr("settings.settings.developer_website"))
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
                                    Text(tr("settings.settings.privacy_policy"))
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
                                    Text(tr("settings.settings.contact"))
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
                                    Text(tr("settings.settings.support_my_work"))
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

                Section(tr("settings.settings.info")) {
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
                    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
                    Text("Shelv \(version) (\(build))")
                    Text(tr("settings.settings.shelv_unofficial_navidrome_client_has_no"))
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
            .navigationTitle(tr("content.settings"))
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
                BulkDownloadSheet(maxBytes: Int64(maxBulkStorageGB) * 1_000_000_000)
                    .presentationDetents([.large])
                    .presentationCornerRadius(24)
                    .tint(accentColor)
            }
            .alert(
                tr("settings.settings.delete_server"),
                isPresented: $showDeleteConfirm,
                presenting: serverToDelete
            ) { server in
                Button(tr("downloads.delete"), role: .destructive) {
                    serverStore.delete(server: server)
                }
                Button(tr("downloads.cancel"), role: .cancel) {}
            } message: { server in
                Text("\"\(server.displayName)\"")
            }
            .alert(
                tr("settings.settings.reset_lyrics_database.14c42cf4"),
                isPresented: $showResetLyricsConfirm
            ) {
                Button(tr("recap.recap.advanced.reset"), role: .destructive) {
                    Task {
                        guard let sid = serverStore.activeServerID?.uuidString else { return }
                        await lyricsStore.reset(serverId: sid)
                    }
                }
                Button(tr("downloads.cancel"), role: .cancel) {}
            } message: {
                Text(tr("settings.settings.downloaded_lyrics_removed"))
            }
            .alert(
                tr("settings.settings.clear_cache.a1be0200"),
                isPresented: $showClearCacheConfirm
            ) {
                Button(tr("player.queue.clear.9529e8af"), role: .destructive) {
                    Task { await clearCache() }
                }
                Button(tr("downloads.cancel"), role: .cancel) {}
            } message: {
                Text(tr("settings.settings.remove_cached_images_library_data_library"))
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
            Text(tr("settings.settings.cache_cleared"))
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
            : tr("view.models.lyrics.empty")
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
                        Text(tr("settings.settings.active"))
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
                Button(tr("settings.settings.activate")) {
                    serverStore.activate(server: server)
                }
                Button(tr("player.queue.edit")) {
                    editingServer = server
                }
                Divider()
                Button(tr("settings.settings.manage_server")) {
                    managingServer = server
                }
                Divider()
                Button(tr("downloads.delete"), role: .destructive) {
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
        Section(tr("car.play.car.play.library.downloads")) {
            Toggle(isOn: $enableDownloads) {
                Label { Text(tr("settings.settings.enable_downloads")) } icon: {
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
                    Label { Text(tr("settings.settings.offline_mode")) } icon: {
                        Image(systemName: "wifi.slash").foregroundStyle(accentColor)
                    }
                }
                .tint(accentColor)

                Button {
                    showBulkDownloadSheet = true
                } label: {
                    Label { Text(tr("settings.bulk.download.download_everything")) } icon: {
                        Image(systemName: "square.and.arrow.down.on.square").foregroundStyle(accentColor)
                    }
                }
                .disabled(offlineMode.isOffline)

                HStack {
                    Label { Text(tr("settings.settings.max_storage")) } icon: {
                        Image(systemName: "externaldrive").foregroundStyle(accentColor)
                    }
                    Spacer()
                    Stepper("\(maxBulkStorageGB) GB",
                            value: $maxBulkStorageGB,
                            in: 10...maxAllowedStorageGB,
                            step: 10)
                        .labelsHidden()
                    Text("\(maxBulkStorageGB) GB")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .onAppear {
                    maxBulkStorageGB = min(maxBulkStorageGB, maxAllowedStorageGB)
                }

                Button(role: .destructive) {
                    showDeleteAllDownloadsConfirm = true
                } label: {
                    Label { Text(tr("settings.settings.delete_downloads")) } icon: {
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
            tr("settings.settings.delete_downloads.eeab6581"),
            isPresented: $showDeleteAllDownloadsConfirm
        ) {
            Button(tr("downloads.delete"), role: .destructive) {
                DownloadStore.shared.deleteAll()
            }
            Button(tr("downloads.cancel"), role: .cancel) {}
        } message: {
            Text(tr("settings.settings.downloaded_songs_albums_artists_removed_from"))
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
                        Text(tr("settings.settings.used"))
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if let free = stats.freeDiskBytes {
                        HStack {
                            Text(tr("settings.settings.free_device"))
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    HStack {
                        Text(tr("settings.settings.songs"))
                        Spacer()
                        Text("\(stats.songCount)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    HStack {
                        Text(tr("car.play.car.play.library.albums"))
                        Spacer()
                        Text("\(stats.albumCount)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    HStack {
                        Text(tr("car.play.car.play.library.artists"))
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
                    Text(tr("settings.settings.active_downloads"))
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
                        Text(tr("settings.settings.value_failed", String(describing: progress.failed)))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Button(tr("settings.settings.cancel_download")) {
                        Task { await DownloadService.shared.cancelBatch() }
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }
        }
    }
}
