import SwiftUI

struct DownloadsSettingsView: View {
    @EnvironmentObject var serverStore: ServerStore
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("enableDownloads") private var enableDownloads = true
    @AppStorage("maxBulkDownloadStorageGB") private var maxBulkStorageGB = 10
    @AppStorage("preventSleepDuringDownloads") private var preventSleepDuringDownloads = false
    @ObservedObject var offlineMode = OfflineModeService.shared
    @ObservedObject private var keepOffline = KeepLibraryOfflineService.shared
    @ObservedObject private var downloadStore = DownloadStore.shared

    @State private var showBulkDownloadSheet = false
    @State private var showKeepLibraryOfflineSheet = false
    @State private var showDeleteAllDownloadsConfirm = false
    @State private var showDisableDownloadsConfirm = false

    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    private var activeServerId: String? { serverStore.activeServer?.stableId }
    private var hasDownloadsToClear: Bool {
        !downloadStore.songs.isEmpty
        || downloadStore.batchProgress != nil
        || !downloadStore.inFlightProgress.isEmpty
        || !downloadStore.inFlightStates.isEmpty
    }

    private var maxAllowedStorageGB: Int {
        guard let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return 500 }
        let gb = Int(bytes / 1_000_000_000)
        return max(10, (gb / 10) * 10)
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: downloadsEnabledBinding) {
                    Label { Text(String(localized: "enable_downloads")) } icon: {
                        Image(systemName: "arrow.down.circle").foregroundStyle(accentColor)
                    }
                }
                .tint(accentColor)

                if enableDownloads {
                    DownloadFormatRows(accentColor: accentColor)
                }
            }

            if enableDownloads {
                Section {
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

                    Toggle(isOn: $preventSleepDuringDownloads) {
                        Label { Text(String(localized: "prevent_sleep_during_downloads")) } icon: {
                            Image(systemName: "lock.open.display").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)

                    Toggle(isOn: Binding(
                        get: { keepOffline.isEnabled(serverId: activeServerId) },
                        set: { newValue in
                            guard let activeServerId else { return }
                            if newValue {
                                showKeepLibraryOfflineSheet = true
                            } else {
                                keepOffline.disableAndCancel(serverId: activeServerId)
                            }
                        }
                    )) {
                        Label { Text(String(localized: "keep_library_offline")) } icon: {
                            Image(systemName: "externaldrive.badge.checkmark").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)
                    .disabled(offlineMode.isOffline || activeServerId == nil)

                    if keepOffline.isEnabled(serverId: activeServerId) {
                        Label { Text(keepOfflineStatusText) } icon: {
                            Image(systemName: keepOfflineStatusIcon).foregroundStyle(keepOfflineStatusColor)
                        }
                    } else {
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
                }

                ActiveDownloadProgressCell(serverId: activeServerId)

                DownloadStatsCell()

                PlayerBottomSpacer()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .tint(accentColor)
        .listStyle(.insetGrouped)
        .scrollIndicators(.hidden)
        .navigationTitle(String(localized: "downloads"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showBulkDownloadSheet) {
            BulkDownloadSheet(maxBytes: Int64(maxBulkStorageGB) * 1_000_000_000)
                .presentationDetents([.large])
                .presentationCornerRadius(24)
                .tint(accentColor)
        }
        .sheet(isPresented: $showKeepLibraryOfflineSheet) {
            BulkDownloadSheet(mode: .keepLibraryOffline)
                .presentationDetents([.large])
                .presentationCornerRadius(24)
                .tint(accentColor)
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
        .alert(
            String(localized: "disable_downloads_2"),
            isPresented: $showDisableDownloadsConfirm
        ) {
            Button(String(localized: "disable"), role: .destructive) {
                disableDownloadsAndClearData()
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "disabling_downloads_will_cancel_active_downloads_and_remove_downloads"))
        }
        .task(id: enableDownloads) {
            guard enableDownloads, LibraryStore.shared.albums.isEmpty else { return }
            await LibraryStore.shared.loadAlbums()
        }
        .task(id: activeServerId) {
            if let activeServerId {
                keepOffline.prepare(serverId: activeServerId)
            }
        }
    }

    private var downloadsEnabledBinding: Binding<Bool> {
        Binding(
            get: { enableDownloads },
            set: { newValue in
                if newValue {
                    enableDownloads = true
                    offlineMode.downloadsFeatureEnabled = true
                } else if hasDownloadsToClear {
                    showDisableDownloadsConfirm = true
                } else {
                    disableDownloadsAndClearData()
                }
            }
        )
    }

    private func disableDownloadsAndClearData() {
        enableDownloads = false
        offlineMode.downloadsFeatureEnabled = false
        if let activeServerId {
            keepOffline.disableAndCancel(serverId: activeServerId)
        }
        if offlineMode.isOffline {
            offlineMode.exitOfflineMode()
        }
        downloadStore.deleteAll()
    }

    private var keepOfflineStatusText: String {
        switch keepOffline.status {
        case .inactive:
            return String(localized: "inactive")
        case .idle:
            return String(localized: "keep_library_offline_ready")
        case .nothingToDo:
            return String(localized: "keep_library_offline_nothing_to_do")
        case .checking:
            return String(localized: "checking")
        case .downloading:
            return String(localized: "downloading")
        case .pausedLowStorage:
            return String(localized: "keep_library_offline_paused_storage")
        case .failed(let message):
            return message
        }
    }

    private var keepOfflineStatusIcon: String {
        switch keepOffline.status {
        case .pausedLowStorage, .failed:
            return "exclamationmark.triangle"
        case .checking:
            return "arrow.triangle.2.circlepath"
        case .downloading:
            return "arrow.down.circle"
        case .idle:
            return "clock"
        default:
            return "checkmark.circle"
        }
    }

    private var keepOfflineStatusColor: Color {
        switch keepOffline.status {
        case .pausedLowStorage, .failed:
            return .red
        default:
            return accentColor
        }
    }
}

private struct DownloadFormatRows: View {
    let accentColor: Color

    @AppStorage("transcodingDownloadCodec") private var downloadCodecRaw: String = "raw"
    @AppStorage("transcodingDownloadBitrate") private var downloadBitrate: Int = 192

    private var codec: TranscodingCodec {
        TranscodingCodec(rawValue: downloadCodecRaw) ?? .raw
    }

    var body: some View {
        Picker(selection: $downloadCodecRaw) {
            ForEach(TranscodingCodec.downloadOptions) { option in
                Text(option.label).tag(option.rawValue)
            }
        } label: {
            Label { Text(String(localized: "download_format")) } icon: {
                Image(systemName: "waveform.badge.magnifyingglass").foregroundStyle(accentColor)
            }
        }

        if codec != .raw {
            Picker(selection: $downloadBitrate) {
                ForEach(TranscodingBitrate.allCases) { bitrate in
                    Text(bitrate.label).tag(bitrate.rawValue)
                }
            } label: {
                Label { Text(String(localized: "bitrate")) } icon: {
                    Image(systemName: "speedometer").foregroundStyle(accentColor)
                }
            }
        }
    }
}

private struct DownloadStatsCell: View {
    @ObservedObject private var downloadStore = DownloadStore.shared
    @State private var stats: DownloadStorageStats?

    var body: some View {
        Section {
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
    let serverId: String?

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        if let progress = store.batchProgress {
            Section {
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
                            cancelDownload()
                        }
                        .font(.caption)
                        .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func cancelDownload() {
        if let serverId, KeepLibraryOfflineService.shared.isEnabled(serverId: serverId) {
            KeepLibraryOfflineService.shared.cancelCurrentRun(serverId: serverId)
        } else {
            Task { await DownloadService.shared.cancelBatch() }
        }
    }
}
