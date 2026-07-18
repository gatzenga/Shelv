import SwiftUI

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
            : String(localized: "download_everything")
    }
}

struct BulkDownloadSheet: View {
    let mode: BulkDownloadMode

    @ObservedObject var libraryStore = LibraryStore.shared
    @EnvironmentObject var serverStore: ServerStore
    @EnvironmentObject var recapStore: RecapStore
    private let downloadStore = DownloadStore.shared
    @ObservedObject private var keepOffline = KeepLibraryOfflineService.shared
    @ObservedObject private var offlineMode = OfflineModeService.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("recapEnabled") private var recapEnabled = false
    @AppStorage("themeColor") private var themeColorName = "violet"

    @State private var plan: BulkDownloadPlan?
    @State private var isPlanning = false

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    init(maxBytes: Int64) {
        self.mode = .limited(maxBytes: maxBytes)
    }

    init(mode: BulkDownloadMode) {
        self.mode = mode
    }

    var body: some View {
        NavigationStack {
            Group {
                if let plan {
                    planDetails(plan)
                } else if isPlanning {
                    ProgressView(String(localized: "calculating"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "start")) {
                        guard let plan, !offlineMode.isOffline else { return }
                        if mode.isKeepLibraryOffline,
                           let stable = serverStore.activeServer?.stableId {
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
                        downloadStore.enqueueSongs(plan.planned)
                        let plannedIds = Set(plan.planned.map(\.id))
                        for marker in plan.playlistMarkers {
                            let allCovered = marker.songIds.allSatisfy { downloadStore.isDownloaded(songId: $0) || plannedIds.contains($0) }
                            if allCovered {
                                downloadStore.addOfflinePlaylist(marker.id, songIds: marker.songIds)
                            }
                        }
                        dismiss()
                    }
                    .disabled(offlineMode.isOffline || plan == nil || (!mode.isKeepLibraryOffline && (plan?.isEmpty ?? true)))
                }
            }
            .task(id: serverStore.activeServer?.stableId) { await recompute() }
        }
    }

    @ViewBuilder
    private func planDetails(_ plan: BulkDownloadPlan) -> some View {
        List {
            Section {
                HStack {
                    Text(String(localized: "songs_to_download")).font(.subheadline)
                    Spacer()
                    Text("\(plan.planned.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(String(localized: "estimated_size")).font(.subheadline)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(String(localized: "download_format")).font(.subheadline)
                    Spacer()
                    Text(downloadFormatDescription)
                        .foregroundStyle(.secondary)
                }
                if mode.isKeepLibraryOffline {
                    HStack {
                        Text(String(localized: "available_storage")).font(.subheadline)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: plan.availableBytes ?? 0, countStyle: .file))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Text(String(localized: "storage_limit")).font(.subheadline)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: plan.limitBytes, countStyle: .file))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    if !plan.skipped.isEmpty {
                        HStack {
                            Text(String(localized: "skipped_over_limit")).font(.subheadline)
                            Spacer()
                            Text("\(plan.skipped.count)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if mode.isKeepLibraryOffline && !plan.skipped.isEmpty && !plan.isEmpty {
                    Text(String(localized: "keep_library_offline_storage_warning"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                .font(.caption)
            }
        }
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
        defer { isPlanning = false }
        guard let stable = serverStore.activeServer?.stableId, !stable.isEmpty else { return }
        if libraryStore.albums.isEmpty {
            await libraryStore.loadAlbums()
        }
        guard !Task.isCancelled else { return }
        let albums = libraryStore.albums
        guard !albums.isEmpty else { return }
        let recapIds = await MainActor.run { recapEnabled ? Array(recapStore.recapPlaylistIds) : [] }
        let computed: BulkDownloadPlan
        switch mode {
        case .limited(let maxBytes):
            computed = await DownloadService.shared.planBulkDownload(
                serverId: stable, maxBytes: maxBytes,
                favorites: enableFavorites,
                recapPlaylistIds: recapIds,
                libraryAlbums: albums
            )
        case .keepLibraryOffline:
            let available = KeepLibraryOfflineService.availableDiskBytes()
            let maxBytes = await KeepLibraryOfflineService.keepOfflineBudgetBytes(
                serverId: stable,
                availableBytes: available
            )
            let planned = await DownloadService.shared.planKeepLibraryOffline(
                serverId: stable, maxBytes: maxBytes,
                favorites: enableFavorites,
                recapPlaylistIds: recapIds,
                libraryAlbums: albums
            )
            computed = BulkDownloadPlan(
                planned: planned.planned,
                skipped: planned.skipped,
                totalBytes: planned.totalBytes,
                limitBytes: maxBytes,
                availableBytes: available,
                isKeepLibraryOffline: true,
                playlistMarkers: planned.playlistMarkers,
                recapPlaylistSongIds: planned.recapPlaylistSongIds
            )
        }
        guard !Task.isCancelled else { return }
        plan = computed
    }
}
