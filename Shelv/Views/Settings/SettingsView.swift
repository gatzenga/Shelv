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

                Section(String(localized: "transcoding")) {
                    Toggle(isOn: $transcodingEnabled) {
                        Label { Text(String(localized: "transcoding")) } icon: {
                            Image(systemName: "waveform.badge.magnifyingglass").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)
                    if transcodingEnabled {
                        NavigationLink(destination: TranscodingSettingsView()) {
                            Label { Text(String(localized: "settings")) } icon: {
                                Image(systemName: "slider.horizontal.3").foregroundStyle(accentColor)
                            }
                        }
                    }
                }

                Section(String(localized: "gapless")) {
                    Toggle(isOn: $gaplessEnabled) {
                        Label { Text(String(localized: "gapless")) } icon: {
                            Image(systemName: "waveform.path").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)
                    if gaplessEnabled {
                        Text(String(localized: "precache_original_file_recommendedntranscoded_stre"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
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

                downloadsSection

                Section(String(localized: "lyrics")) {
                    HStack {
                        Label { Text(String(localized: "database")) } icon: {
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
                        Label { Text(String(localized: "autofetch_on_playback")) } icon: {
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
                            Button(String(localized: "cancel_download")) {
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
                            Label { Text(String(localized: "download_all_lyrics")) } icon: {
                            Image(systemName: "arrow.down.circle").foregroundStyle(accentColor)
                        }
                        }
                    }

                    Button(role: .destructive) {
                        showResetLyricsConfirm = true
                    } label: {
                        Label { Text(String(localized: "reset_lyrics_database")) } icon: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }
                    }
                    .tint(.red)
                }

                Section(String(localized: "cache")) {
                    Toggle(isOn: $streamPreCacheEnabled) {
                        Label { Text(String(localized: "precache_original_file")) } icon: {
                            Image(systemName: "arrow.down.to.line").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)
                    Button {
                        showPreCacheInfo = true
                    } label: {
                        Label {
                            Text(String(localized: "about_precache"))
                                .foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "info.circle").foregroundStyle(accentColor)
                        }
                    }
                    .sheet(isPresented: $showPreCacheInfo) {
                        NavigationStack {
                            ScrollView {
                                Text(String(localized: "stable_networkindependent_playback_with_seamless_g"))
                                .font(.body)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .navigationTitle(String(localized: "precache"))
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button(String(localized: "done")) { showPreCacheInfo = false }
                                }
                            }
                        }
                        .presentationDetents([.medium, .large])
                    }
                    HStack {
                        Label { Text(String(localized: "cache_size")) } icon: {
                            Image(systemName: "internaldrive").foregroundStyle(accentColor)
                        }
                        Spacer()
                        Text(cacheSize)
                            .foregroundStyle(.secondary)
                    }
                    NavigationLink(destination: CacheLogView()) {
                        Label { Text(String(localized: "logs")) } icon: {
                            Image(systemName: "doc.text.magnifyingglass").foregroundStyle(accentColor)
                        }
                    }
                    Button(role: .destructive) {
                        showClearCacheConfirm = true
                    } label: {
                        Label { Text(String(localized: "clear_cache")) } icon: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }
                    }
                    .tint(.red)
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
            .alert(
                String(localized: "reset_lyrics_database_2"),
                isPresented: $showResetLyricsConfirm
            ) {
                Button(String(localized: "reset"), role: .destructive) {
                    Task {
                        guard let sid = serverStore.activeServerID?.uuidString else { return }
                        await lyricsStore.reset(serverId: sid)
                    }
                }
                Button(String(localized: "cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "all_downloaded_lyrics_will_be_removed"))
            }
            .alert(
                String(localized: "clear_cache_2"),
                isPresented: $showClearCacheConfirm
            ) {
                Button(String(localized: "clear"), role: .destructive) {
                    Task { await clearCache() }
                }
                Button(String(localized: "cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "this_will_remove_all_cached_images_and_library_dat"))
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
            Text(String(localized: "cache_cleared"))
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
            : String(localized: "empty")
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

    // MARK: - Downloads Section

    @ViewBuilder
    private var downloadsSection: some View {
        Section(String(localized: "downloads")) {
            Toggle(isOn: $enableDownloads) {
                Label { Text(String(localized: "enable_downloads")) } icon: {
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
                    Label { Text(String(localized: "offline_mode")) } icon: {
                        Image(systemName: "wifi.slash").foregroundStyle(accentColor)
                    }
                }
                .tint(accentColor)

                Button {
                    showBulkDownloadSheet = true
                } label: {
                    Label { Text(String(localized: "download_everything")) } icon: {
                        Image(systemName: "square.and.arrow.down.on.square").foregroundStyle(accentColor)
                    }
                }
                .disabled(offlineMode.isOffline)

                HStack {
                    Label { Text(String(localized: "max_storage")) } icon: {
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
                    Label { Text(String(localized: "delete_all_downloads")) } icon: {
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
            String(localized: "delete_all_downloads_2"),
            isPresented: $showDeleteAllDownloadsConfirm
        ) {
            Button(String(localized: "delete"), role: .destructive) {
                DownloadStore.shared.deleteAll()
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "all_downloaded_songs_albums_and_artists_will_be_re"))
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
                        Text(String(localized: "used"))
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if let free = stats.freeDiskBytes {
                        HStack {
                            Text(String(localized: "free_on_device"))
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    HStack {
                        Text(String(localized: "songs"))
                        Spacer()
                        Text("\(stats.songCount)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    HStack {
                        Text(String(localized: "albums"))
                        Spacer()
                        Text("\(stats.albumCount)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    HStack {
                        Text(String(localized: "artists"))
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
                    Text(String(localized: "active_downloads"))
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
                        Text(String(format: String(localized: "failed_count_format"), progress.failed))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Button(String(localized: "cancel_download")) {
                        Task { await DownloadService.shared.cancelBatch() }
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }
        }
    }
}
