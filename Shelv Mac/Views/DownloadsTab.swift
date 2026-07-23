import SwiftUI
@preconcurrency import Combine

@MainActor
private final class SettingsBatchProgressModel: ObservableObject {
    @Published private(set) var progress: BatchProgress?

    private var cancellable: AnyCancellable?

    init() {
        cancellable = DownloadService.shared.batchUpdates
            .removeDuplicates()
            .throttle(for: .milliseconds(750), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] progress in
                self?.progress = progress
            }
    }
}

private struct BatchProgressSection: View {
    @StateObject private var progressModel = SettingsBatchProgressModel()
    @Environment(\.themeColor) private var themeColor
    let serverId: String?

    var body: some View {
        if let progress = progressModel.progress {
            Section(String(localized: "active_downloads")) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(progress.completed) / \(progress.total)")
                            .monospacedDigit()
                        Spacer()
                        if progress.failed > 0 {
                            Text(String(format: String(localized: "failed_count_format"), progress.failed))
                                .foregroundStyle(.red)
                        }
                    }
                    ProgressView(value: progress.fraction)
                        .tint(themeColor)
                    HStack {
                        Spacer()
                        Button(String(localized: "cancel_download")) {
                            cancelDownload()
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .font(.caption)
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

private struct DownloadStatsSection: View {
    @StateObject private var progressModel = SettingsBatchProgressModel()
    @ObservedObject private var downloadStore = DownloadStore.shared
    @ObservedObject private var libraryStore = LibraryViewModel.shared
    @State private var stats: DownloadStorageStats?

    var body: some View {
        Section(String(localized: "statistics")) {
            if let stats {
                LabeledContent(String(localized: "used"),
                               value: ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file))
                if let free = stats.freeDiskBytes {
                    LabeledContent(String(localized: "free_on_device"),
                                   value: ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
                }
                LabeledContent(String(localized: "songs"), value: "\(stats.songCount)")
                LabeledContent(String(localized: "albums"), value: "\(stats.albumCount)")
                LabeledContent(String(localized: "artists"), value: "\(stats.artistCount)")
            } else {
                ProgressView()
            }
        }
        .task { await refreshStats() }
        .onChange(of: downloadStore.totalBytes) { _, _ in Task { await refreshStats() } }
        .onChange(of: downloadStore.songs.count) { _, _ in Task { await refreshStats() } }
        .onChange(of: progressModel.progress) { oldValue, newValue in
            if oldValue != nil, newValue == nil {
                Task { await refreshStats() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadsLibraryChanged)) { _ in
            Task { await refreshStats() }
        }
    }

    @MainActor private func refreshStats() async {
        let counts = Dictionary(uniqueKeysWithValues: libraryStore.albums.compactMap { album -> (String, Int)? in
            guard let c = album.songCount else { return nil }
            return (album.id, c)
        })
        let artistAlbums: [String: Set<String>] = Dictionary(
            grouping: libraryStore.albums.compactMap { album -> (String, String)? in
                guard let aid = album.artistId else { return nil }
                return (aid, album.id)
            },
            by: { $0.0 }
        ).mapValues { Set($0.map(\.1)) }
        stats = await DownloadStore.shared.computeStats(albumSongCounts: counts, artistAlbumIds: artistAlbums)
    }
}

struct DownloadsTab: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var offlineMode = OfflineModeService.shared
    @ObservedObject private var keepOffline = KeepLibraryOfflineService.shared
    @ObservedObject private var downloadStore = DownloadStore.shared
    @AppStorage("enableDownloads") private var enableDownloads = true
    @AppStorage("offlineModeEnabled") private var offlineModeEnabled = false
    @AppStorage("maxBulkDownloadStorageGB") private var maxBulkStorageGB = 10

    @State private var showBulkSheet = false
    @State private var showKeepLibraryOfflineSheet = false
    @State private var showDeleteAllConfirm = false
    @State private var showDisableDownloadsConfirm = false
    @State private var hasBatchProgress = DownloadActivityStore.shared.batchProgress != nil
    @State private var maxAllowedStorageGB: Int?

    private var hasDownloadsToClear: Bool {
        !downloadStore.songs.isEmpty
        || hasBatchProgress
        || !downloadStore.inFlightProgress.isEmpty
        || !downloadStore.inFlightStates.isEmpty
    }

    private var storageStepperMaximumGB: Int {
        maxAllowedStorageGB ?? max(500, maxBulkStorageGB)
    }

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "enable_downloads"), isOn: downloadsEnabledBinding)
                if enableDownloads {
                    DownloadFormatRows()
                }
            }

            if enableDownloads {
                Section {
                    Toggle(String(localized: "offline_mode"),
                           isOn: Binding(
                                get: { offlineMode.isOffline },
                                set: { newValue in
                                    if newValue { offlineMode.enterOfflineMode() } else { offlineMode.exitOfflineMode() }
                                }
                           ))

                    Toggle(String(localized: "keep_library_offline"), isOn: Binding(
                        get: { keepOffline.isEnabled(serverId: appState.serverStore.activeServer?.stableId) },
                        set: { newValue in
                            guard let stable = appState.serverStore.activeServer?.stableId else { return }
                            if newValue {
                                showKeepLibraryOfflineSheet = true
                            } else {
                                keepOffline.disableAndCancel(serverId: stable)
                            }
                        }
                    ))
                    .disabled(offlineMode.isOffline || appState.serverStore.activeServer?.stableId == nil)

                    if keepOffline.isEnabled(serverId: appState.serverStore.activeServer?.stableId) {
                        Label(keepOfflineStatusText, systemImage: keepOfflineStatusIcon)
                            .foregroundStyle(keepOfflineStatusColor)
                    } else {
                        Button {
                            showBulkSheet = true
                        } label: {
                            Label(String(localized: "download_everything"),
                                  systemImage: "square.and.arrow.down.on.square")
                        }
                        .disabled(offlineMode.isOffline)

                        HStack {
                            Text(String(localized: "max_storage"))
                            Spacer()
                            Stepper("\(maxBulkStorageGB) GB",
                                    value: $maxBulkStorageGB,
                                    in: 10...storageStepperMaximumGB,
                                    step: 10)
                                .labelsHidden()
                            Text("\(maxBulkStorageGB) GB")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .task {
                            await refreshStorageLimit()
                        }
                    }

                    Button(role: .destructive) {
                        showDeleteAllConfirm = true
                    } label: {
                        Label(String(localized: "delete_all_downloads"), systemImage: "trash")
                    }
                }

                BatchProgressSection(serverId: appState.serverStore.activeServer?.stableId)

                DownloadStatsSection()
            }
        }
        .formStyle(.grouped)
        .transaction {
            $0.animation = nil
            $0.disablesAnimations = true
        }
        .confirmationDialog(
            String(localized: "delete_all_downloaded_songs"),
            isPresented: $showDeleteAllConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "delete"), role: .destructive) {
                DownloadStore.shared.deleteAll()
            }
            Button(String(localized: "cancel"), role: .cancel) {}
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
        .sheet(isPresented: $showBulkSheet) {
            BulkDownloadSheet(maxBytes: Int64(maxBulkStorageGB) * 1_000_000_000)
                .environmentObject(appState)
                .frame(width: 520, height: 620)
        }
        .sheet(isPresented: $showKeepLibraryOfflineSheet) {
            BulkDownloadSheet(mode: .keepLibraryOffline)
                .environmentObject(appState)
                .frame(width: 520, height: 620)
        }
        .task(id: appState.serverStore.activeServer?.stableId) {
            if let stable = appState.serverStore.activeServer?.stableId {
                keepOffline.prepare(serverId: stable)
            }
        }
        .onReceive(
            DownloadActivityStore.shared.$batchProgress
                .map { $0 != nil }
                .removeDuplicates()
        ) { hasBatchProgress in
            self.hasBatchProgress = hasBatchProgress
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
        if let stable = appState.serverStore.activeServer?.stableId {
            keepOffline.disableAndCancel(serverId: stable)
        }
        if offlineMode.isOffline {
            offlineMode.exitOfflineMode()
        }
        downloadStore.deleteAll()
    }

    private func refreshStorageLimit() async {
        let maximumGB = await Task.detached(priority: .utility) {
            Self.loadMaxAllowedStorageGB()
        }.value
        guard !Task.isCancelled else { return }
        maxBulkStorageGB = min(maxBulkStorageGB, maximumGB)
        maxAllowedStorageGB = maximumGB
    }

    private nonisolated static func loadMaxAllowedStorageGB() -> Int {
        guard let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return 500 }
        let gb = Int(bytes / 1_000_000_000)
        return max(10, (gb / 10) * 10)
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
            return .primary
        }
    }
}

private struct DownloadFormatRows: View {
    @AppStorage("transcodingDownloadCodec") private var downloadCodecRaw: String = "raw"
    @AppStorage("transcodingDownloadBitrate") private var downloadBitrate: Int = 192

    private var codec: TranscodingCodec {
        TranscodingCodec(rawValue: downloadCodecRaw) ?? .raw
    }

    var body: some View {
        Picker(String(localized: "download_format"), selection: $downloadCodecRaw) {
            ForEach(TranscodingCodec.downloadOptions) { option in
                Text(option.label).tag(option.rawValue)
            }
        }

        if codec != .raw {
            Picker(String(localized: "bitrate"), selection: $downloadBitrate) {
                ForEach(TranscodingBitrate.allCases) { bitrate in
                    Text(bitrate.label).tag(bitrate.rawValue)
                }
            }
        }
    }
}

enum BulkDownloadMode {
    case limited(maxBytes: Int64)
    case keepLibraryOffline

    var isKeepLibraryOffline: Bool {
        if case .keepLibraryOffline = self { return true }
        return false
    }

    var title: String {
        isKeepLibraryOffline
            ? String(localized: "keep_library_offline")
            : String(localized: "download_everything_2")
    }
}

struct BulkDownloadSheet: View {
    let mode: BulkDownloadMode
    @EnvironmentObject var appState: AppState
    @ObservedObject var libraryStore = LibraryViewModel.shared
    @ObservedObject var downloadStore = DownloadStore.shared
    @ObservedObject var recapStore = RecapStore.shared
    @ObservedObject private var keepOffline = KeepLibraryOfflineService.shared
    @ObservedObject private var offlineMode = OfflineModeService.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("recapEnabled") private var recapEnabled = false

    @State private var plan: BulkDownloadPlan?
    @State private var planServerID: UUID?
    @State private var isPlanning = false

    init(maxBytes: Int64) {
        self.mode = .limited(maxBytes: maxBytes)
    }

    init(mode: BulkDownloadMode) {
        self.mode = mode
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(mode.title)
                    .font(.title3).bold()
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            Form {
                if let plan {
                    Section {
                        LabeledContent(String(localized: "songs_to_download"),
                                       value: "\(plan.planned.count)")
                        LabeledContent(String(localized: "estimated_size"),
                                       value: ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))
                        LabeledContent(String(localized: "download_format"),
                                       value: downloadFormatDescription)
                        if mode.isKeepLibraryOffline {
                            LabeledContent(String(localized: "available_storage"),
                                           value: ByteCountFormatter.string(fromByteCount: plan.availableBytes ?? 0, countStyle: .file))
                            if !plan.skipped.isEmpty && !plan.isEmpty {
                                Text(String(localized: "keep_library_offline_storage_warning"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            LabeledContent(String(localized: "storage_limit"),
                                           value: ByteCountFormatter.string(fromByteCount: plan.limitBytes, countStyle: .file))
                            if !plan.skipped.isEmpty {
                                LabeledContent(String(localized: "skipped_over_limit"),
                                               value: "\(plan.skipped.count)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if plan.isEmpty {
                        Section {
                            Text(emptyPlanMessage(for: plan))
                            .foregroundStyle(.secondary)
                        }
                    } else {
                        Section(String(localized: "order")) {
                            Label(String(localized: "frequently_played_first"),
                                  systemImage: "chart.line.uptrend.xyaxis")
                            Label(String(localized: "then_recently_played"),
                                  systemImage: "clock.arrow.circlepath")
                            if enableFavorites {
                                Label(String(localized: "then_favorites"),
                                      systemImage: "heart")
                            }
                            Label(String(localized: "then_recently_added"),
                                  systemImage: "sparkles")
                            if recapEnabled && !recapStore.recapPlaylistIds.isEmpty {
                                Label(String(localized: "then_recap_playlists"),
                                      systemImage: "calendar.badge.clock")
                            }
                            Label(String(localized: "then_playlists"),
                                  systemImage: "music.note.list")
                            Label(String(localized: "then_alphabetical_by_artist"),
                                  systemImage: "textformat")
                        }
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    }
                } else {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView(String(localized: "calculating"))
                            Spacer()
                        }
                        .padding(.vertical, 24)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            HStack {
                Button(String(localized: "cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(String(localized: "start")) {
                    guard let plan,
                          !offlineMode.isOffline,
                          let server = appState.serverStore.activeServer,
                          planServerID == server.id
                    else { return }
                    let stable = server.stableId
                    if mode.isKeepLibraryOffline {
                        keepOffline.setEnabled(true, serverId: stable)
                        if !plan.planned.isEmpty {
                            keepOffline.rememberStoragePause(
                                serverId: stable,
                                availableBytes: plan.availableBytes,
                                plan: plan
                            )
                            keepOffline.markDownloadsStarted(serverId: stable)
                        } else if !plan.skipped.isEmpty {
                            keepOffline.markPausedLowStorage(serverId: stable, skippedSongs: plan.skipped)
                        }
                    }
                    let plannedSongs = plan.planned
                    let albumMarkers = plan.albumMarkers
                    Task {
                        await DownloadService.shared.enqueue(
                            songs: plannedSongs,
                            serverId: stable,
                            managedAlbumMarkers: albumMarkers
                        )
                    }
                    let plannedIds = Set(plan.planned.map(\.id))
                    for marker in plan.playlistMarkers {
                        let allCovered = marker.songIds.allSatisfy { downloadStore.isDownloaded(songId: $0) || plannedIds.contains($0) }
                        if allCovered {
                            downloadStore.markPlaylistDownloaded(id: marker.id, name: marker.name, songIds: marker.songIds)
                        }
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(offlineMode.isOffline || plan == nil || (!mode.isKeepLibraryOffline && (plan?.isEmpty ?? true)))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .task { await recompute() }
    }

    private var downloadFormatDescription: String {
        let codecRaw = UserDefaults.standard.string(forKey: "transcodingDownloadCodec") ?? "raw"
        let codec = TranscodingCodec(rawValue: codecRaw) ?? .raw
        guard codec != .raw else { return codec.label }
        let bitrate = UserDefaults.standard.integer(forKey: "transcodingDownloadBitrate")
        return "\(codec.label) · \(bitrate > 0 ? bitrate : 192) kbps"
    }

    private func emptyPlanMessage(for plan: BulkDownloadPlan) -> String {
        if mode.isKeepLibraryOffline {
            return plan.skipped.isEmpty
                ? String(localized: "library_already_offline")
                : String(localized: "keep_library_offline_storage_warning")
        }
        return String(localized: "nothing_new_fits_in_the_configured_storage_limit")
    }

    private func recompute() async {
        isPlanning = true
        plan = nil
        planServerID = nil
        defer { isPlanning = false }
        guard let server = appState.serverStore.activeServer,
              !server.stableId.isEmpty
        else { return }
        let stable = server.stableId
        let serverID = server.id
        if libraryStore.albums.isEmpty {
            await libraryStore.loadAlbums()
        }
        guard !Task.isCancelled,
              appState.serverStore.activeServer?.id == serverID
        else { return }
        let libraryAlbums = libraryStore.albums
        let recapIds = recapEnabled ? Array(recapStore.recapPlaylistIds) : []
        let computed: BulkDownloadPlan
        switch mode {
        case .limited(let maxBytes):
            computed = await DownloadService.shared.planBulkDownload(
                serverId: stable, maxBytes: maxBytes,
                favorites: enableFavorites,
                recapPlaylistIds: recapIds,
                libraryAlbums: libraryAlbums
            )
        case .keepLibraryOffline:
            let available = KeepLibraryOfflineService.availableDiskBytes()
            let maxBytes = await KeepLibraryOfflineService.keepOfflineBudgetBytes(
                serverId: stable,
                availableBytes: available
            )
            let planned = await DownloadService.shared.planKeepLibraryOffline(
                serverId: stable,
                maxBytes: maxBytes,
                favorites: enableFavorites,
                recapPlaylistIds: recapIds,
                libraryAlbums: libraryAlbums
            )
            computed = BulkDownloadPlan(
                planned: planned.planned,
                skipped: planned.skipped,
                totalBytes: planned.totalBytes,
                limitBytes: maxBytes,
                availableBytes: available,
                isKeepLibraryOffline: true,
                playlistMarkers: planned.playlistMarkers,
                albumMarkers: planned.albumMarkers,
                recapPlaylistSongIds: planned.recapPlaylistSongIds
            )
        }
        guard !Task.isCancelled,
              appState.serverStore.activeServer?.id == serverID
        else { return }
        planServerID = serverID
        plan = computed
    }
}
