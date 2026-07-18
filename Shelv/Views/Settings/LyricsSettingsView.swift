import SwiftUI

struct LyricsSettingsView: View {
    @EnvironmentObject var serverStore: ServerStore
    @EnvironmentObject var lyricsStore: LyricsStore
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("autoFetchLyrics") private var autoFetchLyrics = true
    @AppStorage("includeNavidromeLyrics") private var includeNavidromeLyrics = true
    @AppStorage("useCustomLrcLibServer") private var useCustomLrcLibServer = false
    @AppStorage("customLrcLibBaseURL") private var customLrcLibBaseURL = ""
    @AppStorage(LrcLibEndpoint.onlineFallbackEnabledKey) private var lrcLibOnlineFallbackEnabled = true

    @State private var showResetLyricsConfirm = false
    @State private var showPreCacheInfo = false

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        List {
            Section(String(localized: "database")) {
                HStack {
                    Label { Text(String(localized: "database")) } icon: {
                        Image(systemName: "text.bubble").foregroundStyle(accentColor)
                    }
                    Spacer()
                    LyricsDatabaseStatusText(
                        fetchedCount: lyricsStore.fetchedCount,
                        dbSize: lyricsStore.dbSize
                    )
                }

                Toggle(isOn: $autoFetchLyrics) {
                    Label { Text(String(localized: "autofetch_on_playback")) } icon: {
                        Image(systemName: "wand.and.stars").foregroundStyle(accentColor)
                    }
                }
                .tint(accentColor)

                Toggle(isOn: $includeNavidromeLyrics) {
                    Label { Text(String(localized: "include_navidrome_lyrics")) } icon: {
                        Image(systemName: "server.rack").foregroundStyle(accentColor)
                    }
                }
                .tint(accentColor)

                Toggle(isOn: $useCustomLrcLibServer) {
                    Label { Text(String(localized: "use_custom_lrclib_server")) } icon: {
                        Image(systemName: "globe").foregroundStyle(accentColor)
                    }
                }
                .tint(accentColor)
                .onChange(of: useCustomLrcLibServer) { _, _ in
                    Task { await CloudKitSyncService.shared.recordLyricsServerSettingsChange() }
                }

                if useCustomLrcLibServer {
                    TextField(String(localized: "lrclib_server_url"), text: $customLrcLibBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onChange(of: customLrcLibBaseURL) { _, _ in
                            Task { await CloudKitSyncService.shared.recordLyricsServerSettingsChange() }
                        }

                    Toggle(isOn: $lrcLibOnlineFallbackEnabled) {
                        Label { Text(String(localized: "lrclib_online_fallback")) } icon: {
                            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(accentColor)
                        }
                    }
                    .tint(accentColor)
                    .onChange(of: lrcLibOnlineFallbackEnabled) { _, _ in
                        Task { await CloudKitSyncService.shared.recordLyricsServerSettingsChange() }
                    }
                }

                LyricsDownloadControls(
                    accentColor: accentColor,
                    onStart: {
                        guard let sid = serverStore.activeServerID?.uuidString else { return }
                        lyricsStore.startBulkDownload(serverId: sid)
                    },
                    onCancel: {
                        lyricsStore.cancelBulkDownload()
                    }
                )

                Button(role: .destructive) {
                    showResetLyricsConfirm = true
                } label: {
                    Label { Text(String(localized: "reset_lyrics_database")) } icon: {
                        Image(systemName: "trash").foregroundStyle(.red)
                    }
                }
                .tint(.red)
            }

            PlayerBottomSpacer()
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .tint(accentColor)
        .listStyle(.insetGrouped)
        .scrollIndicators(.hidden)
        .navigationTitle(String(localized: "lyrics"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let sid = serverStore.activeServerID?.uuidString {
                await lyricsStore.refreshFetchedCount(serverId: sid)
            }
            lyricsStore.refreshDbSize()
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
    }
}

private struct LyricsDatabaseStatusText: View {
    let fetchedCount: Int
    let dbSize: String

    @ObservedObject private var activity = LyricsDownloadActivityStore.shared

    var body: some View {
        let snapshot = activity.snapshot
        Text(
            snapshot.isDownloading
                ? "\(snapshot.fetched) / \(snapshot.total)"
                : "\(fetchedCount) · \(dbSize)"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
}

private struct LyricsDownloadControls: View {
    let accentColor: Color
    let onStart: () -> Void
    let onCancel: () -> Void

    @ObservedObject private var activity = LyricsDownloadActivityStore.shared

    @ViewBuilder
    var body: some View {
        let snapshot = activity.snapshot
        if snapshot.isDownloading {
            VStack(alignment: .leading, spacing: 8) {
                let total = max(snapshot.total, 1)
                let fetched = max(0, min(snapshot.fetched, total))
                ProgressView(
                    value: Double(fetched),
                    total: Double(total)
                )
                .tint(accentColor)
                Button(String(localized: "cancel_download"), action: onCancel)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        } else {
            Button(action: onStart) {
                Label { Text(String(localized: "download_all_lyrics")) } icon: {
                    Image(systemName: "arrow.down.circle").foregroundStyle(accentColor)
                }
            }
        }
    }
}
