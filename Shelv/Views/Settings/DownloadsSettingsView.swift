import SwiftUI

struct DownloadsSettingsView: View {
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("enableDownloads") private var enableDownloads = false
    @AppStorage("maxBulkDownloadStorageGB") private var maxBulkStorageGB = 10
    @ObservedObject var offlineMode = OfflineModeService.shared

    @State private var showBulkDownloadSheet = false
    @State private var showDeleteAllDownloadsConfirm = false

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

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
                Toggle(isOn: $enableDownloads) {
                    Label { Text(String(localized: "enable_downloads")) } icon: {
                        Image(systemName: "arrow.down.circle").foregroundStyle(accentColor)
                    }
                }
                .tint(accentColor)
            }

            if enableDownloads {
                Section(String(localized: "offline_mode")) {
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
                }

                Section(String(localized: "bulk_download")) {
                    Button {
                        showBulkDownloadSheet = true
                    } label: {
                        Label { Text(String(localized: "download_everything")) } icon: {
                            Image(systemName: "square.and.arrow.down.on.square").foregroundStyle(accentColor)
                        }
                    }
                    .disabled(offlineMode.isOffline)
                }

                Section(String(localized: "storage")) {
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

                Section {
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

                ActiveDownloadProgressCell()

                DownloadStatsCell()
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
                            Task { await DownloadService.shared.cancelBatch() }
                        }
                        .font(.caption)
                        .foregroundStyle(.red)
                    }
                }
            }
        }
    }
}
