import SwiftUI

struct LyricsSettingsView: View {
    @EnvironmentObject var serverStore: ServerStore
    @EnvironmentObject var lyricsStore: LyricsStore
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("autoFetchLyrics") private var autoFetchLyrics = true
    @AppStorage("includeNavidromeLyrics") private var includeNavidromeLyrics = false

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

                Toggle(isOn: $includeNavidromeLyrics) {
                    Label { Text(String(localized: "include_navidrome_lyrics")) } icon: {
                        Image(systemName: "server.rack").foregroundStyle(accentColor)
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
